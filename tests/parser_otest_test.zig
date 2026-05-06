//! Frontend parser regression tests for `let%test_unit` pre-scan behavior.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const zxc_frontend_bin = "zig-out/bin/zxc-frontend";

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn runCommand(allocator: Allocator, io: Io, argv: []const []const u8) !CommandResult {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
}

fn freeResult(allocator: Allocator, result: CommandResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn expectFrontendAccepts(path: []const u8, source: []const u8, expected_name: []const u8) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    try cwd.writeFile(io, .{ .sub_path = path, .data = source });
    defer cwd.deleteFile(io, path) catch {};

    const result = try runCommand(
        allocator,
        io,
        &.{ zxc_frontend_bin, "--emit=sexp", "--wire=1.1", path },
    );
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(contains(result.stdout, expected_name));
    try std.testing.expect(contains(result.stdout, "__otest_registry__"));
}

test "parser_otest: comment extension text accepted" {
    try expectFrontendAccepts(
        "/tmp/zxcaml_parser_otest_comment_text.ml",
        "(* Documents let%test_unit syntax *)\n" ++
            "let%test_unit \"comment ignored\" = ()\n",
        "comment ignored",
    );
}

test "parser_otest: nested comment extension text accepted" {
    try expectFrontendAccepts(
        "/tmp/zxcaml_parser_otest_nested_comment_text.ml",
        "(* outer (* inner has let%foo *) closes *)\n" ++
            "let%test_unit \"nested comments ignored\" = assert (1 = 1)\n",
        "nested comments ignored",
    );
}
