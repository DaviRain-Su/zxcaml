//! JSON-RPC framing scaffold for `omlz-lsp`.
//!
//! Layout follows `mission-internal/p9-investigation/report.md` §3: keep the
//! hand-written LSP server under `src/lsp/`, with Content-Length framing in a
//! focused module. LSP 3.17's base protocol specifies messages as
//! `Content-Length: N\r\n\r\n<body>` with an optional `Content-Type` header:
//! https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#baseProtocol

const std = @import("std");

/// LSP base protocol framing header name.
pub const content_length_header = "Content-Length";

const content_type_header = "Content-Type";

/// Read a complete LSP base-protocol frame from an in-memory fixture.
///
/// This convenience wrapper keeps unit tests terse while `readFrameFromReader`
/// below is the streaming entry point for the stdio server.
pub fn readFrame(allocator: std.mem.Allocator, frame: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(frame);
    return readFrameFromReader(allocator, &reader);
}

/// Read a complete LSP base-protocol frame from `reader`.
///
/// The protocol requires ASCII headers terminated by an empty CRLF line, with a
/// mandatory `Content-Length` header and optional `Content-Type`; the returned
/// body is exactly `Content-Length` bytes and is caller-owned.
pub fn readFrameFromReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const content_length = try readHeaders(reader);
    return try reader.readAlloc(allocator, content_length);
}

/// Write a complete LSP base-protocol frame for a pre-serialized JSON body.
pub fn writeFrame(writer: anytype, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
}

fn readHeaders(reader: *std.Io.Reader) !usize {
    var content_length: ?usize = null;

    while (true) {
        // Zig 0.16's `std.Io.Reader.takeDelimiter` is the current spelling of
        // the simple line-oriented read used here for LSP/JSON-RPC headers.
        const raw_line = (reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.HeaderLineTooLong,
            error.ReadFailed => return error.ReadFailed,
        }) orelse return error.MalformedHeader;
        const line_without_cr = std.mem.trimEnd(u8, raw_line, "\r");

        if (line_without_cr.len == 0) break;

        const colon_index = std.mem.indexOfScalar(u8, line_without_cr, ':') orelse return error.MalformedHeader;
        const name = std.mem.trim(u8, line_without_cr[0..colon_index], " \t");
        const value = std.mem.trim(u8, line_without_cr[colon_index + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, content_length_header)) {
            if (content_length != null) return error.DuplicateContentLength;
            if (value.len == 0) return error.MalformedContentLength;
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.MalformedContentLength;
        } else if (std.ascii.eqlIgnoreCase(name, content_type_header)) {
            // Optional per LSP 3.17 base protocol.  `omlz-lsp` speaks UTF-8 JSON
            // regardless and does not need the value at this layer.
            continue;
        } else {
            // Be liberal with extension headers; clients may add tracing
            // metadata that is irrelevant to base framing.
            continue;
        }
    }

    return content_length orelse error.MissingContentLength;
}

test "jsonrpc_read_fixture_id_number_body_bytes" {
    const body =
        \\{"jsonrpc":"2.0","id":42,"method":"initialize"}
    ;
    const frame = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    const read_body = try readFrame(std.testing.allocator, frame);
    defer std.testing.allocator.free(read_body);

    try std.testing.expectEqualStrings(body, read_body);
    try expectIdInteger(read_body, 42);
}

test "jsonrpc_read_fixture_id_string_body_bytes" {
    const body =
        \\{"jsonrpc":"2.0","id":"abc","method":"shutdown"}
    ;
    const frame = std.fmt.comptimePrint("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    const read_body = try readFrame(std.testing.allocator, frame);
    defer std.testing.allocator.free(read_body);

    try std.testing.expectEqualStrings(body, read_body);
    try expectIdString(read_body, "abc");
}

test "jsonrpc_read_fixture_id_null_body_bytes" {
    const body =
        \\{"jsonrpc":"2.0","id":null,"method":"shutdown"}
    ;
    const frame = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    const read_body = try readFrame(std.testing.allocator, frame);
    defer std.testing.allocator.free(read_body);

    try std.testing.expectEqualStrings(body, read_body);
    try expectIdNull(read_body);
}

test "jsonrpc_roundtrip_write_then_read_byte_identical" {
    const body =
        \\{"jsonrpc":"2.0","id":"abc","result":{"capabilities":{"textDocumentSync":1}}}
    ;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try writeFrame(&out.writer, body);
    const frame = try out.toOwnedSlice();
    defer std.testing.allocator.free(frame);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, frame);

    const read_body = try readFrame(std.testing.allocator, frame);
    defer std.testing.allocator.free(read_body);
    try std.testing.expectEqualStrings(body, read_body);
}

test "jsonrpc_malformed_content_length_header_errors" {
    const frame =
        "Content-Length: not-a-number\r\n" ++
        "\r\n" ++
        "{}";

    try std.testing.expectError(error.MalformedContentLength, readFrame(std.testing.allocator, frame));
}

fn expectIdInteger(body: []const u8, expected: i64) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const id = parsed.value.object.get("id") orelse return error.MissingId;
    try std.testing.expectEqual(expected, id.integer);
}

fn expectIdString(body: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const id = parsed.value.object.get("id") orelse return error.MissingId;
    try std.testing.expectEqualStrings(expected, id.string);
}

fn expectIdNull(body: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const id = parsed.value.object.get("id") orelse return error.MissingId;
    try std.testing.expectEqual(.null, id);
}
