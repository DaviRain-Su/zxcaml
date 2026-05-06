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
    writer_mutex: std.atomic.Mutex = .unlocked,
    next_doc_id: u64 = 0,
    temp_dir_created: bool = false,

    fn init(allocator: std.mem.Allocator) ServerState {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap([]u8).init(allocator),
            .test_statuses = std.StringHashMap(TestRunStatus).init(allocator),
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

    if (std.mem.eql(u8, method, "textDocument/codeLens")) {
        if (id) |request_id| try handleCodeLens(allocator, writer, object.get("params") orelse .null, state, request_id);
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
    try body.writer.writeAll(",\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"diagnosticProvider\":null,\"codeLensProvider\":{},\"executeCommandProvider\":{\"commands\":[\"omlz.runTest\"]}},\"serverInfo\":{\"name\":");
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
