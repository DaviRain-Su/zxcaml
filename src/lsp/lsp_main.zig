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
    /// LSP 3.17 §Server lifetime requires `initialize` as the first request;
    /// until then, servers reject all other requests as not initialized.
    initialized: bool = false,
};

fn runServer(io: Io) !void {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var state: ServerState = .{};
    while (true) {
        var message_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer message_arena.deinit();
        const allocator = message_arena.allocator();

        const body = jsonrpc.readFrameFromReader(allocator, &stdin_reader.interface) catch |err| switch (err) {
            // Clean EOF from a stdio client should terminate the server.
            error.MalformedHeader, error.ReadFailed => return,
            else => return err,
        };

        try handleMessage(allocator, stdout_writer, body, &state);
        try stdout_writer.flush();
    }
}

fn handleMessage(
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
    if (std.mem.eql(u8, method, "initialize")) {
        state.initialized = true;
        if (id) |request_id| try writeInitializeResponse(allocator, writer, request_id);
        return;
    }

    if (!state.initialized) {
        if (id) |request_id| try writeErrorResponse(allocator, writer, request_id, -32002, "server not initialized: send initialize first");
        return;
    }

    if (id) |request_id| try writeErrorResponse(allocator, writer, request_id, -32601, "method not found");
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
