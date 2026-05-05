const std = @import("std");
const lsp_main = @import("lsp_main");

test "omlz-lsp entrypoint module exports main" {
    try std.testing.expect(@hasDecl(lsp_main, "main"));
}

test "omlz-lsp binary is installed by zig build" {
    try std.Io.Dir.cwd().access(std.testing.io, "zig-out/bin/omlz-lsp", .{});
}
