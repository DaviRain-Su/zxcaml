//! Entrypoint for the `omlz-lsp` binary.
//!
//! The project layout follows `mission-internal/p9-investigation/report.md` §3:
//! a dedicated Zig stdio JSON-RPC server under `src/lsp/`, with framing and
//! protocol shapes split into sibling modules.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

pub const jsonrpc = @import("jsonrpc.zig");
pub const protocol = @import("protocol.zig");

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
    next_doc_id: u64 = 0,
    temp_dir_created: bool = false,

    fn init(allocator: std.mem.Allocator) ServerState {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap([]u8).init(allocator),
        };
    }

    fn deinit(self: *ServerState) void {
        var iter = self.documents.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.documents.deinit();
    }

    fn putDocument(self: *ServerState, uri: []const u8, text: []const u8) !void {
        if (self.documents.fetchRemove(uri)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }

        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        try self.documents.put(owned_uri, owned_text);
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
    try cleanupTempFiles(io, false);
    defer cleanupTempFiles(io, true) catch {};
    while (true) {
        var message_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer message_arena.deinit();
        const allocator = message_arena.allocator();

        const body = jsonrpc.readFrameFromReader(allocator, &stdin_reader.interface) catch |err| switch (err) {
            // Clean EOF from a stdio client should terminate the server.
            error.MalformedHeader, error.ReadFailed => return,
            else => return err,
        };

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
        cleanupTempFiles(io, true) catch {};
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

    if (id) |request_id| try writeErrorResponse(allocator, writer, request_id, -32601, "method not found");
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

fn publishDiagnosticsForText(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    state: *ServerState,
    uri: []const u8,
    text: []const u8,
) !void {
    try ensureTempDir(io, allocator, state);
    const tmp_path = try tempPath(allocator, state);
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

fn ensureTempDir(io: Io, allocator: std.mem.Allocator, state: *ServerState) !void {
    if (state.temp_dir_created) return;

    const tmp_dir_path = try tempDirPath(allocator, std.posix.system.getpid());
    defer allocator.free(tmp_dir_path);

    std.Io.Dir.createDirAbsolute(io, tmp_dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    state.temp_dir_created = true;
}

fn tempDirPath(allocator: std.mem.Allocator, pid: std.posix.pid_t) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/omlz_lsp_{d}", .{pid});
}

fn tempPath(allocator: std.mem.Allocator, state: *ServerState) ![]u8 {
    state.next_doc_id += 1;
    return std.fmt.allocPrint(
        allocator,
        "/tmp/omlz_lsp_{d}/{d}.ml",
        .{ std.posix.system.getpid(), state.next_doc_id },
    );
}

fn cleanupTempFiles(io: Io, remove_current_pid: bool) !void {
    var tmp_dir = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer tmp_dir.close(io);

    const current_pid = std.posix.system.getpid();
    var iter = tmp_dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                const pid = parseLspTempDirPid(entry.name) orelse continue;
                if (!shouldRemoveTempPath(pid, current_pid, remove_current_pid)) continue;
                tmp_dir.deleteTree(io, entry.name) catch {};
            },
            .file => {
                const pid = parseLegacyTempFilePid(entry.name) orelse continue;
                if (!shouldRemoveTempPath(pid, current_pid, remove_current_pid)) continue;
                tmp_dir.deleteFile(io, entry.name) catch {};
            },
            else => continue,
        }
    }
}

fn parseLspTempDirPid(name: []const u8) ?std.posix.pid_t {
    const prefix = "omlz_lsp_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;

    const rest = name[prefix.len..];
    const parsed = parsePositivePidPrefix(rest) orelse return null;
    if (parsed.consumed != rest.len) return null;
    return parsed.pid;
}

fn parseLegacyTempFilePid(name: []const u8) ?std.posix.pid_t {
    const prefix = "omlz_lsp_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (!std.mem.endsWith(u8, name, ".ml")) return null;

    const rest = name[prefix.len..];
    const parsed = parsePositivePidPrefix(rest) orelse return null;
    if (parsed.consumed >= rest.len or rest[parsed.consumed] != '_') return null;
    return parsed.pid;
}

const ParsedPid = struct {
    pid: std.posix.pid_t,
    consumed: usize,
};

fn parsePositivePidPrefix(rest: []const u8) ?ParsedPid {
    if (rest.len == 0) return null;

    var pid_end: usize = 0;
    while (pid_end < rest.len and std.ascii.isDigit(rest[pid_end])) : (pid_end += 1) {}
    if (pid_end == 0) return null;

    const pid = std.fmt.parseInt(std.posix.pid_t, rest[0..pid_end], 10) catch return null;
    if (pid <= 0) return null;
    return .{ .pid = pid, .consumed = pid_end };
}

fn shouldRemoveTempPath(pid: std.posix.pid_t, current_pid: std.posix.pid_t, remove_current_pid: bool) bool {
    if (pid == current_pid and remove_current_pid) return true;
    return isDeadPid(pid);
}

fn isDeadPid(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @as(std.posix.SIG, @enumFromInt(0))) catch |err| switch (err) {
        error.ProcessNotFound => return true,
        else => return false,
    };
    return false;
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
    try body.writer.writeAll(",\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"diagnosticProvider\":null},\"serverInfo\":{\"name\":");
    try std.json.Stringify.value(protocol.server_name, .{}, &body.writer);
    try body.writer.writeAll(",\"version\":");
    try std.json.Stringify.value(build_options.version, .{}, &body.writer);
    try body.writer.writeAll("}}}");

    try jsonrpc.writeFrame(writer, body.writer.buffered());
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
