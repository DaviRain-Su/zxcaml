//! Entrypoint for the `omlz-lsp` binary.
//!
//! The project layout follows `mission-internal/p9-investigation/report.md` §3:
//! a dedicated Zig stdio JSON-RPC server under `src/lsp/`, with framing and
//! protocol shapes split into sibling modules.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const frontend_fmt = @import("frontend_fmt");

pub const jsonrpc = @import("jsonrpc.zig");
pub const protocol = @import("protocol.zig");
pub const hover = @import("hover.zig");
const session = @import("session.zig");
pub const completion_stdlib = @import("completion_stdlib.zig");

const JsonDiagnostic = struct {
    file: []const u8,
    line: u32,
    col: u32,
    end_line: ?u32 = null,
    end_col: ?u32 = null,
    severity: []const u8,
    code: ?[]const u8 = null,
    message: []const u8,
    snippet: ?[]const u8 = null,
};

const TestBinding = struct {
    name: []const u8,
    line: u32,
    start_character: u32,
    end_character: u32,
};

const TestRunStatus = union(enum) {
    passed,
    failed: u32,
};

const JsonTestOutput = struct {
    type: []const u8,
    file: ?[]const u8 = null,
    name: ?[]const u8 = null,
    status: ?[]const u8 = null,
    elapsed_ms: ?i64 = null,
    message: ?[]const u8 = null,
    line: ?u32 = null,
    col: ?u32 = null,
    total: ?usize = null,
    passed: ?usize = null,
    failed: ?usize = null,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try writeStdout(init.io, protocol.server_name);
        try writeStdout(init.io, " ");
        try writeStdout(init.io, build_options.version);
        try writeStdout(init.io, "\n");
        return;
    }

    if (args.len != 1) {
        try writeStderr(init.io, "usage: omlz-lsp [--version]\n");
        std.process.exit(64);
    }

    try runServer(init.io);
}

const ServerState = struct {
    allocator: std.mem.Allocator,
    /// LSP 3.17 §Server lifetime requires `initialize` as the first request;
    /// until then, servers reject all other requests as not initialized.
    initialized: bool = false,
    /// LSP 3.17 §`shutdown` / §`exit`: `shutdown` is a request that returns
    /// a null result and records intent to terminate; a later `exit`
    /// notification terminates with status 0 only if this flag was set.
    shutdown_received: bool = false,
    documents: std.StringHashMap([]u8),
    test_statuses: std.StringHashMap(TestRunStatus),
    /// Cached `(line, character) -> type` lookup tables per document URI.
    /// Invalidated whenever the document text changes via `putDocument`.
    hover_caches: std.StringHashMap(hover.Cache),
    writer_mutex: std.atomic.Mutex = .unlocked,
    next_doc_id: u64 = 0,
    temp_dir_created: bool = false,

    fn init(allocator: std.mem.Allocator) ServerState {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap([]u8).init(allocator),
            .test_statuses = std.StringHashMap(TestRunStatus).init(allocator),
            .hover_caches = std.StringHashMap(hover.Cache).init(allocator),
        };
    }

    fn deinit(self: *ServerState) void {
        var iter = self.documents.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.documents.deinit();
        var status_iter = self.test_statuses.iterator();
        while (status_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.test_statuses.deinit();
        var hover_iter = self.hover_caches.iterator();
        while (hover_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.hover_caches.deinit();
    }

    fn putDocument(self: *ServerState, uri: []const u8, text: []const u8) !void {
        if (self.documents.fetchRemove(uri)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        if (self.hover_caches.fetchRemove(uri)) |entry| {
            self.allocator.free(entry.key);
            var cache = entry.value;
            cache.deinit();
        }

        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        try self.documents.put(owned_uri, owned_text);
    }

    fn putHoverCache(self: *ServerState, uri: []const u8, cache: hover.Cache) !void {
        if (self.hover_caches.fetchRemove(uri)) |entry| {
            self.allocator.free(entry.key);
            var old = entry.value;
            old.deinit();
        }
        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        try self.hover_caches.put(owned_uri, cache);
    }

    fn updateTestStatus(self: *ServerState, uri: []const u8, name: []const u8, status: TestRunStatus) !void {
        const key = try statusKey(self.allocator, uri, name);
        errdefer self.allocator.free(key);
        if (self.test_statuses.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
        }
        try self.test_statuses.put(key, status);
    }

    fn getTestStatus(self: *ServerState, allocator: std.mem.Allocator, uri: []const u8, name: []const u8) !?TestRunStatus {
        const key = try statusKey(allocator, uri, name);
        defer allocator.free(key);
        return self.test_statuses.get(key);
    }
};

fn runServer(io: Io) !void {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var state = ServerState.init(std.heap.page_allocator);
    defer state.deinit();
    try session.cleanupTempFiles(io, false);
    defer session.cleanupTempFiles(io, true) catch {};
    while (true) {
        var message_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer message_arena.deinit();
        const allocator = message_arena.allocator();

        const body = jsonrpc.readFrameFromReader(allocator, &stdin_reader.interface) catch |err| switch (err) {
            // Clean EOF from a stdio client should terminate the server.
            error.MalformedHeader, error.ReadFailed => return,
            else => return err,
        };

        lockWriter(&state);
        defer state.writer_mutex.unlock();
        try handleMessage(io, allocator, stdout_writer, body, &state);
        try stdout_writer.flush();
    }
}

fn handleMessage(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    body: []const u8,
    state: *ServerState,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try writeErrorResponse(allocator, writer, null, -32700, "parse error");
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try writeErrorResponse(allocator, writer, null, -32600, "invalid request");
        return;
    }

    const object = parsed.value.object;
    const id = object.get("id");
    const method_value = object.get("method") orelse {
        if (id) |request_id| try writeErrorResponse(allocator, writer, request_id, -32600, "missing method");
        return;
    };
    if (method_value != .string) {
        if (id) |request_id| try writeErrorResponse(allocator, writer, request_id, -32600, "method must be a string");
        return;
    }

    const method = method_value.string;
    if (std.mem.eql(u8, method, "exit")) {
        session.cleanupTempFiles(io, true) catch {};
        std.process.exit(if (state.shutdown_received) 0 else 1);
    }

    if (std.mem.eql(u8, method, "initialize")) {
        state.initialized = true;
        if (id) |request_id| try writeInitializeResponse(allocator, writer, request_id);
        return;
    }

    if (!state.initialized) {
        if (id) |request_id| try writeErrorResponse(allocator, writer, request_id, -32002, "server not initialized: send initialize first");
        return;
    }

    if (std.mem.eql(u8, method, "initialized")) {
        return;
    }

    if (std.mem.eql(u8, method, "shutdown")) {
        state.shutdown_received = true;
        if (id) |request_id| try writeNullResultResponse(allocator, writer, request_id);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        try handleDidOpen(io, allocator, writer, object.get("params") orelse .null, state);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/didChange")) {
        try handleDidChange(io, allocator, writer, object.get("params") orelse .null, state);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/formatting")) {
        if (id) |request_id| try handleFormatting(allocator, writer, object.get("params") orelse .null, state, request_id);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/rangeFormatting")) {
        if (id) |request_id| try handleRangeFormatting(allocator, writer, object.get("params") orelse .null, state, request_id);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/codeLens")) {
        if (id) |request_id| try handleCodeLens(allocator, writer, object.get("params") orelse .null, state, request_id);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/hover")) {
        if (id) |request_id| try handleHover(io, allocator, writer, object.get("params") orelse .null, state, request_id);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/definition")) {
        if (id) |request_id| try handleDefinition(io, allocator, writer, object.get("params") orelse .null, state, request_id);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/completion")) {
        if (id) |request_id| try handleCompletion(io, allocator, writer, object.get("params") orelse .null, state, request_id);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/references")) {
        if (id) |request_id| try handleReferences(io, allocator, writer, object.get("params") orelse .null, state, request_id);
        return;
    }

    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        if (id) |request_id| try handleDocumentSymbol(io, allocator, writer, object.get("params") orelse .null, state, request_id);
        return;
    }

    if (std.mem.eql(u8, method, "workspace/executeCommand")) {
        if (id) |request_id| try handleExecuteCommand(io, allocator, writer, object.get("params") orelse .null, state, request_id);
        return;
    }

    if (id) |request_id| try writeErrorResponse(allocator, writer, request_id, -32601, "method not found");
}

fn lockWriter(state: *ServerState) void {
    while (!state.writer_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn handleDidOpen(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
) !void {
    const text_document = try objectField(params_value, "textDocument");
    const uri = try stringField(text_document, "uri");
    const text = try stringField(text_document, "text");

    try state.putDocument(uri, text);
    try publishDiagnosticsForText(io, allocator, writer, state, uri, text);
}

fn handleDidChange(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
) !void {
    const text_document = try objectField(params_value, "textDocument");
    const uri = try stringField(text_document, "uri");
    const changes = try arrayField(params_value, "contentChanges");
    if (changes.items.len == 0) return;
    const last_change = changes.items[changes.items.len - 1];
    const text = try stringField(last_change, "text");

    try state.putDocument(uri, text);
    try publishDiagnosticsForText(io, allocator, writer, state, uri, text);
}

const LspPosition = struct {
    line: u32,
    character: u32,
};

const LspRange = struct {
    start: LspPosition,
    end: LspPosition,
};

fn handleFormatting(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
    id: std.json.Value,
) !void {
    const text_document = try objectField(params_value, "textDocument");
    const uri = try stringField(text_document, "uri");
    const text = state.documents.get(uri) orelse {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    };

    if (formattingInputMalformed(text)) {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    }

    const formatted = frontend_fmt.formatAlloc(allocator, text) catch {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    };
    defer allocator.free(formatted);

    if (std.mem.eql(u8, text, formatted)) {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    }

    try writeSingleTextEditResponse(allocator, writer, id, fullDocumentRange(text), formatted);
}

fn handleRangeFormatting(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
    id: std.json.Value,
) !void {
    const text_document = try objectField(params_value, "textDocument");
    const uri = try stringField(text_document, "uri");
    const text = state.documents.get(uri) orelse {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    };
    const lsp_range = parseRange(try objectField(params_value, "range")) catch {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    };
    const start_offset = byteOffsetForPosition(text, lsp_range.start) catch {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    };
    const end_offset = byteOffsetForPosition(text, lsp_range.end) catch {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    };
    if (end_offset < start_offset) {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    }

    const selected = text[start_offset..end_offset];
    if (formattingInputMalformed(selected)) {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    }

    const formatted_owned = frontend_fmt.formatAlloc(allocator, selected) catch {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    };
    defer allocator.free(formatted_owned);

    var replacement = formatted_owned;
    if (!endsWithLineBreak(selected) and std.mem.endsWith(u8, replacement, "\n")) {
        replacement = replacement[0 .. replacement.len - 1];
    }

    if (std.mem.eql(u8, selected, replacement)) {
        try writeEmptyTextEditResponse(allocator, writer, id);
        return;
    }

    try writeSingleTextEditResponse(allocator, writer, id, lsp_range, replacement);
}

fn handleCodeLens(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
    id: std.json.Value,
) !void {
    const text_document = try objectField(params_value, "textDocument");
    const uri = try stringField(text_document, "uri");
    const text = state.documents.get(uri) orelse "";
    const bindings = try collectTestBindings(allocator, text);
    try writeCodeLensResponse(allocator, writer, state, id, uri, bindings);
}

fn handleHover(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
    id: std.json.Value,
) !void {
    const text_document = try objectField(params_value, "textDocument");
    const uri = try stringField(text_document, "uri");
    const position_value = try objectField(params_value, "position");
    const position = parsePosition(position_value) catch {
        try writeNullResultResponse(allocator, writer, id);
        return;
    };

    const text = state.documents.get(uri) orelse {
        try writeNullResultResponse(allocator, writer, id);
        return;
    };

    // Comments and whitespace yield `null` per the LSP spec / task contract.
    if (hover.isInsideComment(text, position.line, position.character)) {
        try writeNullResultResponse(allocator, writer, id);
        return;
    }
    const word = hover.wordAtPosition(text, position.line, position.character) orelse {
        try writeNullResultResponse(allocator, writer, id);
        return;
    };

    // Reuse the cached hover lookup when the document text has not changed
    // since the cache was built. Otherwise run a one-shot Core IR parse.
    var cached_symbol: ?hover.Symbol = null;
    if (state.hover_caches.getPtr(uri)) |cache_ptr| {
        if (std.mem.eql(u8, cache_ptr.text, text)) {
            cached_symbol = cache_ptr.symbols.get(word.text);
        }
    }

    if (cached_symbol == null) {
        const new_cache = ensureHoverCache(io, allocator, state, uri, text) catch {
            try writeNullResultResponse(allocator, writer, id);
            return;
        } orelse {
            try writeNullResultResponse(allocator, writer, id);
            return;
        };
        cached_symbol = new_cache.symbols.get(word.text);
    }

    const symbol = cached_symbol orelse {
        try writeNullResultResponse(allocator, writer, id);
        return;
    };

    try writeHoverResponse(allocator, writer, id, word, symbol.rendered_ty);
}

fn handleCompletion(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
    id: std.json.Value,
) !void {
    const text_document = try objectField(params_value, "textDocument");
    const uri = try stringField(text_document, "uri");
    // `position` and `context` are accepted but ignored: this first cut
    // returns the union of user-defined top-level bindings and the static
    // stdlib whitelist, without prefix or type filtering.

    const text = state.documents.get(uri) orelse "";

    var cache_ptr: ?*hover.Cache = null;
    if (state.hover_caches.getPtr(uri)) |cache| {
        if (std.mem.eql(u8, cache.text, text)) {
            cache_ptr = cache;
        }
    }
    if (cache_ptr == null and text.len > 0) {
        // Build a hover cache on demand. Failure (parse error, missing
        // `omlz`) is non-fatal: we still emit the stdlib whitelist.
        cache_ptr = ensureHoverCache(io, allocator, state, uri, text) catch null;
    }

    try writeCompletionResponse(allocator, writer, id, cache_ptr);
}

fn writeCompletionResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: std.json.Value,
    cache_ptr: ?*hover.Cache,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":{\"isIncomplete\":false,\"items\":[");

    var first = true;
    if (cache_ptr) |cache| {
        var iter = cache.symbols.iterator();
        while (iter.next()) |entry| {
            if (!first) try body.writer.writeByte(',');
            first = false;
            const symbol = entry.value_ptr.*;
            const kind: u8 = if (hover.isFunctionType(symbol.rendered_ty)) 3 else 12;
            try body.writer.writeAll("{\"label\":");
            try std.json.Stringify.value(symbol.name, .{}, &body.writer);
            try body.writer.print(",\"kind\":{d},\"detail\":", .{kind});
            try std.json.Stringify.value(symbol.rendered_ty, .{}, &body.writer);
            try body.writer.writeByte('}');
        }
    }

    const completion_stdlib_items = completion_stdlib.items;
    for (completion_stdlib_items) |item| {
        if (!first) try body.writer.writeByte(',');
        first = false;
        try body.writer.writeAll("{\"label\":");
        try std.json.Stringify.value(item.label, .{}, &body.writer);
        try body.writer.print(",\"kind\":{d},\"detail\":", .{@intFromEnum(item.kind)});
        try std.json.Stringify.value(item.detail, .{}, &body.writer);
        try body.writer.writeByte('}');
    }

    try body.writer.writeAll("]}}");

    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn ensureHoverCache(
    io: Io,
    allocator: std.mem.Allocator,
    state: *ServerState,
    uri: []const u8,
    text: []const u8,
) !?*hover.Cache {
    // Build a one-shot Core IR sexp from the document text and feed it into
    // the hover symbol table. Returns `null` if the build fails or the sexp
    // is unparseable.
    try session.ensureTempDir(io, allocator, &state.temp_dir_created);
    const tmp_path = try session.tempPath(allocator, &state.next_doc_id);
    defer allocator.free(tmp_path);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_path,
        .data = text,
        .flags = .{ .truncate = true },
    });

    const argv = [_][]const u8{ "zig-out/bin/omlz", "check", "--emit=core-ir-with-loc", tmp_path };
    const completed = std.process.run(allocator, io, .{ .argv = &argv }) catch return null;
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    const trimmed = std.mem.trim(u8, completed.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;

    const built = hover.buildSymbolsFromCoreIr(state.allocator, text, trimmed) catch return null;
    var cache = built orelse return null;
    state.putHoverCache(uri, cache) catch {
        cache.deinit();
        return null;
    };
    return state.hover_caches.getPtr(uri);
}

fn writeHoverResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: std.json.Value,
    word: hover.WordSpan,
    rendered_ty: []const u8,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":");

    const markdown = try std.fmt.allocPrint(allocator, "```ocaml\n{s}\n```", .{rendered_ty});
    defer allocator.free(markdown);
    try std.json.Stringify.value(markdown, .{}, &body.writer);

    try body.writer.print(
        "}},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}}}",
        .{ word.start_line, word.start_character, word.end_line, word.end_character },
    );

    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn handleDefinition(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
    id: std.json.Value,
) !void {
    const text_document = try objectField(params_value, "textDocument");
    const uri = try stringField(text_document, "uri");
    const position_value = try objectField(params_value, "position");
    const position = parsePosition(position_value) catch {
        try writeNullResultResponse(allocator, writer, id);
        return;
    };

    const text = state.documents.get(uri) orelse {
        try writeNullResultResponse(allocator, writer, id);
        return;
    };

    // Comments and whitespace yield `null` per the LSP spec / task contract.
    if (hover.isInsideComment(text, position.line, position.character)) {
        try writeNullResultResponse(allocator, writer, id);
        return;
    }
    const word = hover.wordAtPosition(text, position.line, position.character) orelse {
        try writeNullResultResponse(allocator, writer, id);
        return;
    };

    // Reuse the same Core IR hover cache used by `textDocument/hover`. The
    // cache stores the binding name's source range alongside the rendered
    // type, so goto-definition is a pure lookup once the cache is warm.
    var cached_symbol: ?hover.Symbol = null;
    if (state.hover_caches.getPtr(uri)) |cache_ptr| {
        if (std.mem.eql(u8, cache_ptr.text, text)) {
            cached_symbol = hover.findSymbol(cache_ptr, word.text);
        }
    }
    if (cached_symbol == null) {
        const new_cache = ensureHoverCache(io, allocator, state, uri, text) catch {
            try writeNullResultResponse(allocator, writer, id);
            return;
        } orelse {
            try writeNullResultResponse(allocator, writer, id);
            return;
        };
        cached_symbol = hover.findSymbol(new_cache, word.text);
    }

    const symbol = cached_symbol orelse {
        try writeNullResultResponse(allocator, writer, id);
        return;
    };
    const range = symbol.def_range orelse {
        try writeNullResultResponse(allocator, writer, id);
        return;
    };

    try writeDefinitionResponse(allocator, writer, id, uri, range);
}

fn writeDefinitionResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: std.json.Value,
    uri: []const u8,
    range: hover.DefRange,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":{\"uri\":");
    try std.json.Stringify.value(uri, .{}, &body.writer);
    try body.writer.print(
        ",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}}}",
        .{ range.line, range.start_character, range.line, range.end_character },
    );

    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn handleReferences(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
    id: std.json.Value,
) !void {
    const text_document = try objectField(params_value, "textDocument");
    const uri = try stringField(text_document, "uri");
    const position_value = try objectField(params_value, "position");
    const position = parsePosition(position_value) catch {
        try writeEmptyArrayResponse(allocator, writer, id);
        return;
    };

    // `context.includeDeclaration` defaults to `true` when the field or the
    // entire `context` object is absent, matching common editor behavior.
    var include_declaration: bool = true;
    if (params_value == .object) {
        if (params_value.object.get("context")) |ctx| {
            if (ctx == .object) {
                if (ctx.object.get("includeDeclaration")) |flag| {
                    if (flag == .bool) include_declaration = flag.bool;
                }
            }
        }
    }

    const text = state.documents.get(uri) orelse {
        try writeEmptyArrayResponse(allocator, writer, id);
        return;
    };

    if (hover.isInsideComment(text, position.line, position.character)) {
        try writeEmptyArrayResponse(allocator, writer, id);
        return;
    }
    const word = hover.wordAtPosition(text, position.line, position.character) orelse {
        try writeEmptyArrayResponse(allocator, writer, id);
        return;
    };

    var cached_symbol: ?hover.Symbol = null;
    if (state.hover_caches.getPtr(uri)) |cache_ptr| {
        if (std.mem.eql(u8, cache_ptr.text, text)) {
            cached_symbol = hover.findSymbol(cache_ptr, word.text);
        }
    }
    if (cached_symbol == null) {
        const new_cache = ensureHoverCache(io, allocator, state, uri, text) catch {
            try writeEmptyArrayResponse(allocator, writer, id);
            return;
        } orelse {
            try writeEmptyArrayResponse(allocator, writer, id);
            return;
        };
        cached_symbol = hover.findSymbol(new_cache, word.text);
    }

    const symbol = cached_symbol orelse {
        try writeEmptyArrayResponse(allocator, writer, id);
        return;
    };

    const occurrences = hover.collectOccurrences(allocator, text, word.text) catch {
        try writeEmptyArrayResponse(allocator, writer, id);
        return;
    };
    defer allocator.free(occurrences);

    try writeReferencesResponse(allocator, writer, id, uri, occurrences, symbol.def_range, include_declaration);
}

fn writeReferencesResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: std.json.Value,
    uri: []const u8,
    occurrences: []const hover.Occurrence,
    def_range: ?hover.DefRange,
    include_declaration: bool,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":[");

    var first = true;
    for (occurrences) |occ| {
        if (!include_declaration) {
            if (def_range) |dr| {
                if (dr.line == occ.line and dr.start_character == occ.start_character and dr.end_character == occ.end_character) {
                    continue;
                }
            }
        }
        if (!first) try body.writer.writeByte(',');
        first = false;
        try body.writer.writeAll("{\"uri\":");
        try std.json.Stringify.value(uri, .{}, &body.writer);
        try body.writer.print(
            ",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
            .{ occ.line, occ.start_character, occ.line, occ.end_character },
        );
    }

    try body.writer.writeAll("]}");
    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn handleDocumentSymbol(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
    id: std.json.Value,
) !void {
    const text_document = try objectField(params_value, "textDocument");
    const uri = try stringField(text_document, "uri");

    const text = state.documents.get(uri) orelse {
        try writeEmptyArrayResponse(allocator, writer, id);
        return;
    };

    var cache_ptr: ?*hover.Cache = null;
    if (state.hover_caches.getPtr(uri)) |cache| {
        if (std.mem.eql(u8, cache.text, text)) {
            cache_ptr = cache;
        }
    }
    if (cache_ptr == null and text.len > 0) {
        cache_ptr = ensureHoverCache(io, allocator, state, uri, text) catch null;
    }

    try writeDocumentSymbolResponse(allocator, writer, id, text, cache_ptr);
}

const OrderedSymbol = struct {
    name: []const u8,
    rendered_ty: []const u8,
    range: hover.DefRange,
};

fn writeDocumentSymbolResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: std.json.Value,
    text: []const u8,
    cache_ptr: ?*hover.Cache,
) !void {
    // Walk the source-order list of top-level binding sites and emit one
    // DocumentSymbol per name we have a typed entry for. This guarantees
    // outline order matches file order, which matches what editors expect.
    var entries = std.ArrayList(OrderedSymbol).empty;
    defer entries.deinit(allocator);

    if (cache_ptr) |cache| {
        var iter = cache.symbols.iterator();
        while (iter.next()) |entry| {
            const sym = entry.value_ptr.*;
            const range = sym.def_range orelse continue;
            try entries.append(allocator, .{
                .name = sym.name,
                .rendered_ty = sym.rendered_ty,
                .range = range,
            });
        }
    }

    std.mem.sort(OrderedSymbol, entries.items, {}, orderedSymbolLessThan);

    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":[");

    for (entries.items, 0..) |entry, i| {
        if (i != 0) try body.writer.writeByte(',');
        // SymbolKind: Function = 12, Variable = 13.
        const kind: u8 = if (hover.isFunctionType(entry.rendered_ty)) 12 else 13;
        const full_range = bindingFullRange(text, entry.range);
        try body.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(entry.name, .{}, &body.writer);
        try body.writer.writeAll(",\"detail\":");
        try std.json.Stringify.value(entry.rendered_ty, .{}, &body.writer);
        try body.writer.print(",\"kind\":{d},\"range\":", .{kind});
        try body.writer.print(
            "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ full_range.start.line, full_range.start.character, full_range.end.line, full_range.end.character },
        );
        try body.writer.print(
            ",\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ entry.range.line, entry.range.start_character, entry.range.line, entry.range.end_character },
        );
        try body.writer.writeAll(",\"children\":[]}");
    }

    try body.writer.writeAll("]}");
    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn orderedSymbolLessThan(_: void, a: OrderedSymbol, b: OrderedSymbol) bool {
    if (a.range.line != b.range.line) return a.range.line < b.range.line;
    return a.range.start_character < b.range.start_character;
}

/// Best-effort extent of `let X = body`: starts at the binding name and ends
/// at the byte just before the next top-level binding head (or EOF). This
/// avoids parsing the body while still giving editors a reasonable folding
/// region for each top-level definition.
fn bindingFullRange(text: []const u8, name_range: hover.DefRange) LspRange {
    const start: LspPosition = .{ .line = name_range.line, .character = name_range.start_character };
    const start_offset = byteOffsetForPosition(text, start) catch {
        return .{
            .start = start,
            .end = .{ .line = name_range.line, .character = name_range.end_character },
        };
    };

    // Scan forward, tracking comments/strings, until we hit the next
    // top-level `let`/`and` keyword (preceded by start-of-line or only
    // whitespace on its line).
    var i: usize = start_offset + 1;
    var line: u32 = name_range.line;
    var character: u32 = name_range.start_character + 1;
    var last_line: u32 = line;
    var last_character: u32 = name_range.end_character;
    var comment_depth: usize = 0;
    var in_string = false;
    var in_char = false;
    var escaped = false;
    var at_line_start = false;

    while (i < text.len) {
        const byte = text[i];

        if (in_string or in_char) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (in_string and byte == '"') {
                in_string = false;
            } else if (in_char and byte == '\'') {
                in_char = false;
            }
        } else if (comment_depth > 0) {
            if (i + 1 < text.len and byte == '(' and text[i + 1] == '*') {
                comment_depth += 1;
                advance(text[i], &i, &line, &character);
                advance(text[i], &i, &line, &character);
                continue;
            }
            if (i + 1 < text.len and byte == '*' and text[i + 1] == ')') {
                comment_depth -= 1;
                advance(text[i], &i, &line, &character);
                last_line = line;
                last_character = character;
                advance(text[i], &i, &line, &character);
                continue;
            }
        } else {
            if (i + 1 < text.len and byte == '(' and text[i + 1] == '*') {
                comment_depth += 1;
                advance(text[i], &i, &line, &character);
                advance(text[i], &i, &line, &character);
                continue;
            }
            if (byte == '"') {
                in_string = true;
            } else if (at_line_start and (isTopLevelKeyword(text, i, "let") or isTopLevelKeyword(text, i, "and"))) {
                return .{
                    .start = start,
                    .end = .{ .line = last_line, .character = last_character },
                };
            }
        }

        if (byte == '\n') {
            at_line_start = true;
        } else if (byte != ' ' and byte != '\t' and byte != '\r') {
            at_line_start = false;
        }

        last_line = line;
        last_character = character + 1;
        advance(byte, &i, &line, &character);
    }

    return .{
        .start = start,
        .end = .{ .line = line, .character = character },
    };
}

fn isTopLevelKeyword(text: []const u8, pos: usize, keyword: []const u8) bool {
    if (pos + keyword.len > text.len) return false;
    if (!std.mem.eql(u8, text[pos .. pos + keyword.len], keyword)) return false;
    if (pos > 0) {
        const prev = text[pos - 1];
        if (prev != '\n' and prev != ' ' and prev != '\t' and prev != '\r') return false;
    }
    const after = pos + keyword.len;
    if (after < text.len) {
        const next = text[after];
        if (std.ascii.isAlphanumeric(next) or next == '_' or next == '\'') return false;
    }
    return true;
}

fn advance(byte: u8, i: *usize, line: *u32, character: *u32) void {
    if (byte == '\n') {
        line.* += 1;
        character.* = 0;
    } else {
        character.* += 1;
    }
    i.* += 1;
}

fn writeEmptyArrayResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: std.json.Value,
) !void {
    var body = Io.Writer.Allocating.init(allocator);
    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":[]}");
    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn handleExecuteCommand(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    params_value: std.json.Value,
    state: *ServerState,
    id: std.json.Value,
) !void {
    const command = try stringField(params_value, "command");
    if (!std.mem.eql(u8, command, "omlz.runTest")) {
        try writeErrorResponse(allocator, writer, id, -32602, "unsupported executeCommand");
        return;
    }

    const arguments = try arrayField(params_value, "arguments");
    if (arguments.items.len < 2 or arguments.items[0] != .string or arguments.items[1] != .string) {
        try writeErrorResponse(allocator, writer, id, -32602, "omlz.runTest expects [uri, name]");
        return;
    }

    const uri = arguments.items[0].string;
    const name = arguments.items[1].string;
    const path = try filePathFromUri(allocator, uri);
    defer allocator.free(path);

    const owned_uri = try std.heap.page_allocator.dupe(u8, uri);
    errdefer std.heap.page_allocator.free(owned_uri);
    const owned_name = try std.heap.page_allocator.dupe(u8, name);
    errdefer std.heap.page_allocator.free(owned_name);
    const owned_path = try std.heap.page_allocator.dupe(u8, path);
    errdefer std.heap.page_allocator.free(owned_path);

    try writeNullResultResponse(allocator, writer, id);
    try writer.flush();

    const thread = try std.Thread.spawn(.{}, runTestThread, .{ io, writer, state, owned_uri, owned_name, owned_path });
    thread.detach();
}

fn objectField(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidLspParams;
    const field = value.object.get(name) orelse return error.InvalidLspParams;
    if (field != .object) return error.InvalidLspParams;
    return field;
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidLspParams;
    const field = value.object.get(name) orelse return error.InvalidLspParams;
    if (field != .string) return error.InvalidLspParams;
    return field.string;
}

fn arrayField(value: std.json.Value, name: []const u8) !std.json.Array {
    if (value != .object) return error.InvalidLspParams;
    const field = value.object.get(name) orelse return error.InvalidLspParams;
    if (field != .array) return error.InvalidLspParams;
    return field.array;
}

fn u32Field(value: std.json.Value, name: []const u8) !u32 {
    if (value != .object) return error.InvalidLspParams;
    const field = value.object.get(name) orelse return error.InvalidLspParams;
    if (field != .integer) return error.InvalidLspParams;
    if (field.integer < 0 or field.integer > std.math.maxInt(u32)) return error.InvalidLspParams;
    return @intCast(field.integer);
}

fn parsePosition(value: std.json.Value) !LspPosition {
    return .{
        .line = try u32Field(value, "line"),
        .character = try u32Field(value, "character"),
    };
}

fn parseRange(value: std.json.Value) !LspRange {
    return .{
        .start = try parsePosition(try objectField(value, "start")),
        .end = try parsePosition(try objectField(value, "end")),
    };
}

fn fullDocumentRange(text: []const u8) LspRange {
    return .{
        .start = .{ .line = 0, .character = 0 },
        .end = endPosition(text),
    };
}

fn endPosition(text: []const u8) LspPosition {
    var position: LspPosition = .{ .line = 0, .character = 0 };
    for (text) |byte| {
        if (byte == '\n') {
            position.line += 1;
            position.character = 0;
        } else {
            position.character += 1;
        }
    }
    return position;
}

fn byteOffsetForPosition(text: []const u8, target: LspPosition) !usize {
    var current: LspPosition = .{ .line = 0, .character = 0 };
    for (text, 0..) |byte, index| {
        if (current.line == target.line and current.character == target.character) return index;
        if (byte == '\n') {
            current.line += 1;
            current.character = 0;
        } else {
            current.character += 1;
        }
    }
    if (current.line == target.line and current.character == target.character) return text.len;
    return error.InvalidLspRange;
}

fn endsWithLineBreak(text: []const u8) bool {
    return std.mem.endsWith(u8, text, "\n") or std.mem.endsWith(u8, text, "\r\n");
}

fn formattingInputMalformed(text: []const u8) bool {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var comment_depth: usize = 0;
    var in_string = false;
    var in_char = false;
    var escaped = false;
    var index: usize = 0;

    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (in_string or in_char) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (in_string and byte == '"') {
                in_string = false;
            } else if (in_char and byte == '\'') {
                in_char = false;
            }
            continue;
        }

        if (comment_depth > 0) {
            if (index + 1 < text.len and byte == '(' and text[index + 1] == '*') {
                comment_depth += 1;
                index += 1;
            } else if (index + 1 < text.len and byte == '*' and text[index + 1] == ')') {
                comment_depth -= 1;
                index += 1;
            }
            continue;
        }

        if (index + 1 < text.len and byte == '(' and text[index + 1] == '*') {
            comment_depth += 1;
            index += 1;
        } else if (byte == '"') {
            in_string = true;
        } else if (byte == '\'') {
            in_char = true;
        } else if (byte == '(') {
            paren_depth += 1;
        } else if (byte == ')') {
            if (paren_depth == 0) return true;
            paren_depth -= 1;
        } else if (byte == '[') {
            bracket_depth += 1;
        } else if (byte == ']') {
            if (bracket_depth == 0) return true;
            bracket_depth -= 1;
        } else if (byte == '{') {
            brace_depth += 1;
        } else if (byte == '}') {
            if (brace_depth == 0) return true;
            brace_depth -= 1;
        }
    }

    return in_string or in_char or comment_depth != 0 or paren_depth != 0 or bracket_depth != 0 or brace_depth != 0;
}

fn collectTestBindings(allocator: std.mem.Allocator, text: []const u8) ![]TestBinding {
    var bindings = std.ArrayList(TestBinding).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_index: u32 = 0;
    while (lines.next()) |raw_line| : (line_index += 1) {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, line, search_start, "let%test_unit")) |let_index| {
            const after_keyword = let_index + "let%test_unit".len;
            var cursor = after_keyword;
            while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) : (cursor += 1) {}
            if (cursor >= line.len or line[cursor] != '"') {
                search_start = after_keyword;
                continue;
            }

            const name_start = cursor + 1;
            cursor = name_start;
            while (cursor < line.len) : (cursor += 1) {
                if (line[cursor] == '\\') {
                    cursor += 1;
                    continue;
                }
                if (line[cursor] == '"') break;
            }
            if (cursor >= line.len) break;

            try bindings.append(allocator, .{
                .name = try allocator.dupe(u8, line[name_start..cursor]),
                .line = line_index,
                .start_character = @intCast(name_start),
                .end_character = @intCast(cursor),
            });
            search_start = cursor + 1;
        }
    }
    return bindings.toOwnedSlice(allocator);
}

fn statusKey(allocator: std.mem.Allocator, uri: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ uri, name });
}

fn filePathFromUri(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.InvalidLspParams;
    return percentDecode(allocator, uri[prefix.len..]);
}

fn percentDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch {
                try out.append(allocator, encoded[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch {
                try out.append(allocator, encoded[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, @intCast(hi * 16 + lo));
            i += 3;
        } else {
            try out.append(allocator, encoded[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn publishDiagnosticsForText(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    state: *ServerState,
    uri: []const u8,
    text: []const u8,
) !void {
    try session.ensureTempDir(io, allocator, &state.temp_dir_created);
    const tmp_path = try session.tempPath(allocator, &state.next_doc_id);
    defer allocator.free(tmp_path);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_path,
        .data = text,
        .flags = .{ .truncate = true },
    });

    const argv = [_][]const u8{ "zig-out/bin/omlz", "check", "--error-format=json", tmp_path };
    const completed = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    try writePublishDiagnostics(allocator, writer, uri, completed.stderr);
}

fn writeCodeLensResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    state: *ServerState,
    id: std.json.Value,
    uri: []const u8,
    bindings: []const TestBinding,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":[");
    for (bindings, 0..) |binding, index| {
        if (index != 0) try body.writer.writeByte(',');
        try body.writer.print(
            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"command\":{{\"title\":",
            .{ binding.line, binding.start_character, binding.line, binding.end_character },
        );
        const status = try state.getTestStatus(allocator, uri, binding.name);
        try writeCodeLensTitle(&body.writer, binding.name, status);
        try body.writer.writeAll(",\"command\":\"omlz.runTest\",\"arguments\":[");
        try std.json.Stringify.value(uri, .{}, &body.writer);
        try body.writer.writeByte(',');
        try std.json.Stringify.value(binding.name, .{}, &body.writer);
        try body.writer.writeAll("]}}");
    }
    try body.writer.writeAll("]}");

    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn writeCodeLensTitle(writer: *Io.Writer, name: []const u8, status: ?TestRunStatus) !void {
    var title = Io.Writer.Allocating.init(std.heap.page_allocator);
    defer title.deinit();

    if (status) |known| {
        switch (known) {
            .passed => try title.writer.print("✓ {s}", .{name}),
            .failed => |line| try title.writer.print("✗ {s} (line {d})", .{ name, line }),
        }
    } else {
        try title.writer.print("▶ Run test \"{s}\"", .{name});
    }
    try std.json.Stringify.value(title.writer.buffered(), .{}, writer);
}

fn runTestThread(
    io: Io,
    writer: *Io.Writer,
    state: *ServerState,
    uri: []u8,
    name: []u8,
    path: []u8,
) void {
    defer std.heap.page_allocator.free(uri);
    defer std.heap.page_allocator.free(name);
    defer std.heap.page_allocator.free(path);

    runTestThreadInner(io, writer, state, uri, name, path) catch |err| {
        lockWriter(state);
        defer state.writer_mutex.unlock();
        writeShowMessage(std.heap.page_allocator, writer, .Error, @errorName(err)) catch {};
        writer.flush() catch {};
    };
}

fn runTestThreadInner(
    io: Io,
    writer: *Io.Writer,
    state: *ServerState,
    uri: []const u8,
    name: []const u8,
    path: []const u8,
) !void {
    const allocator = std.heap.page_allocator;
    const argv = [_][]const u8{ "zig-out/bin/omlz", "test", "--filter", name, "--format=json", path };
    const completed = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    const exit_code = testExitCode(completed.term);
    var first_failure_name: ?[]const u8 = null;
    var first_failure_line: ?u32 = null;

    lockWriter(state);
    defer state.writer_mutex.unlock();

    var lines = std.mem.splitScalar(u8, completed.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        try writeWindowLogMessage(allocator, writer, .Info, line);
        try writeTestOutputNotification(allocator, writer, uri, name, line);

        var parsed = std.json.parseFromSlice(JsonTestOutput, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.type, "test") and
            parsed.value.status != null and
            std.mem.eql(u8, parsed.value.status.?, "failed") and
            first_failure_name == null)
        {
            first_failure_name = try allocator.dupe(u8, parsed.value.name orelse name);
            first_failure_line = parsed.value.line orelse 0;
        }
    }
    defer {
        if (first_failure_name) |owned| allocator.free(owned);
    }

    if (exit_code == 0) {
        try state.updateTestStatus(uri, name, .passed);
    } else {
        const failed_name = first_failure_name orelse name;
        const failed_line = first_failure_line orelse 0;
        try state.updateTestStatus(uri, name, .{ .failed = failed_line });
        const message = try std.fmt.allocPrint(allocator, "{s} failed at line {d}", .{ failed_name, failed_line });
        defer allocator.free(message);
        try writeShowMessage(allocator, writer, .Error, message);
    }

    try writer.flush();
}

fn testExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

const MessageType = enum(u8) {
    Error = 1,
    Warning = 2,
    Info = 3,
    Log = 4,
};

fn writeWindowLogMessage(allocator: std.mem.Allocator, writer: *Io.Writer, message_type: MessageType, message: []const u8) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.print("{{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{{\"type\":{d},\"message\":", .{@intFromEnum(message_type)});
    try std.json.Stringify.value(message, .{}, &body.writer);
    try body.writer.writeAll("}}");
    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn writeShowMessage(allocator: std.mem.Allocator, writer: *Io.Writer, message_type: MessageType, message: []const u8) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.print("{{\"jsonrpc\":\"2.0\",\"method\":\"window/showMessage\",\"params\":{{\"type\":{d},\"message\":", .{@intFromEnum(message_type)});
    try std.json.Stringify.value(message, .{}, &body.writer);
    try body.writer.writeAll("}}");
    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn writeTestOutputNotification(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    uri: []const u8,
    name: []const u8,
    line: []const u8,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"$/omlz.testOutput\",\"params\":{\"uri\":");
    try std.json.Stringify.value(uri, .{}, &body.writer);
    try body.writer.writeAll(",\"name\":");
    try std.json.Stringify.value(name, .{}, &body.writer);
    try body.writer.writeAll(",\"line\":");
    try std.json.Stringify.value(line, .{}, &body.writer);
    try body.writer.writeAll("}}");
    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn writePublishDiagnostics(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    uri: []const u8,
    stderr: []const u8,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
    try std.json.Stringify.value(uri, .{}, &body.writer);
    try body.writer.writeAll(",\"diagnostics\":[");

    var first = true;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!looksLikeJson(line)) continue;

        var parsed = std.json.parseFromSlice(JsonDiagnostic, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        if (!first) try body.writer.writeByte(',');
        first = false;
        try writeLspDiagnostic(&body.writer, parsed.value);
    }

    try body.writer.writeAll("]}}");
    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn writeLspDiagnostic(writer: *Io.Writer, diagnostic: JsonDiagnostic) !void {
    const start_line = zeroBased(diagnostic.line);
    const start_character = zeroBased(diagnostic.col);
    const end_line = zeroBased(diagnostic.end_line orelse diagnostic.line);
    var end_character = zeroBased(diagnostic.end_col orelse diagnostic.col + 1);
    if (end_line == start_line and end_character <= start_character) {
        end_character = start_character + 1;
    }

    try writer.print(
        "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"message\":",
        .{ start_line, start_character, end_line, end_character, severityCode(diagnostic.severity) },
    );
    try std.json.Stringify.value(diagnostic.message, .{}, writer);
    try writer.writeByte('}');
}

fn zeroBased(one_based: u32) u32 {
    return if (one_based == 0) 0 else one_based - 1;
}

fn severityCode(severity: []const u8) u8 {
    if (std.ascii.eqlIgnoreCase(severity, "error")) return 1;
    if (std.ascii.eqlIgnoreCase(severity, "warning") or std.ascii.eqlIgnoreCase(severity, "warn")) return 2;
    if (std.ascii.eqlIgnoreCase(severity, "information") or std.ascii.eqlIgnoreCase(severity, "info")) return 3;
    if (std.ascii.eqlIgnoreCase(severity, "hint")) return 4;
    return 1;
}

fn looksLikeJson(line: []const u8) bool {
    return line.len >= 2 and line[0] == '{' and line[line.len - 1] == '}';
}

fn writeInitializeResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: std.json.Value,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"diagnosticProvider\":null,\"documentFormattingProvider\":true,\"documentRangeFormattingProvider\":true,\"codeLensProvider\":{},\"hoverProvider\":true,\"definitionProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\"]},\"referencesProvider\":true,\"documentSymbolProvider\":true,\"executeCommandProvider\":{\"commands\":[\"omlz.runTest\"]}},\"serverInfo\":{\"name\":");
    try std.json.Stringify.value(protocol.server_name, .{}, &body.writer);
    try body.writer.writeAll(",\"version\":");
    try std.json.Stringify.value(build_options.version, .{}, &body.writer);
    try body.writer.writeAll("}}}");

    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn writeEmptyTextEditResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: std.json.Value,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":[]}");

    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn writeSingleTextEditResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: std.json.Value,
    range: LspRange,
    new_text: []const u8,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":[{\"range\":");
    try writeRangeJson(&body.writer, range);
    try body.writer.writeAll(",\"newText\":");
    try std.json.Stringify.value(new_text, .{}, &body.writer);
    try body.writer.writeAll("}]}");

    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn writeRangeJson(writer: *Io.Writer, range: LspRange) !void {
    try writer.print(
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ range.start.line, range.start.character, range.end.line, range.end.character },
    );
}

fn writeNullResultResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: std.json.Value,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &body.writer);
    try body.writer.writeAll(",\"result\":null}");

    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn writeErrorResponse(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    id: ?std.json.Value,
    code: i64,
    message: []const u8,
) !void {
    var body = Io.Writer.Allocating.init(allocator);

    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |request_id| {
        try std.json.Stringify.value(request_id, .{}, &body.writer);
    } else {
        try body.writer.writeAll("null");
    }
    try body.writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try std.json.Stringify.value(message, .{}, &body.writer);
    try body.writer.writeAll("}}");

    try jsonrpc.writeFrame(writer, body.writer.buffered());
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

fn writeStderr(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

test "server name is stable for version output" {
    try std.testing.expectEqualStrings("omlz-lsp", protocol.server_name);
}

test "jsonrpc scaffold reserves Content-Length header" {
    try std.testing.expectEqualStrings("Content-Length", jsonrpc.content_length_header);
}
