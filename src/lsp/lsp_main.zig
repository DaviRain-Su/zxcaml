//! Entrypoint for the `omlz-lsp` binary.
//!
//! The project layout follows `mission-internal/p9-investigation/report.md` §3:
//! a dedicated Zig stdio JSON-RPC server under `src/lsp/`, with framing and
//! protocol shapes split into sibling modules. F-LSP-1 intentionally exposes
//! only `--version`; the JSON-RPC loop is implemented by later F-LSP-* work.

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

    try writeStderr(init.io, "error: omlz-lsp currently supports only --version; the LSP loop lands in later F-LSP features.\n");
    std.process.exit(64);
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
