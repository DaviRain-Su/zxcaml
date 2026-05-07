//! Idempotency golden snapshots for `omlz fmt`.
//!
//! Each snapshot has an intentionally unformatted `*.input.ml` source and a
//! captured `*.expected.ml` output.  The test asserts both:
//! - `omlz fmt INPUT` matches the captured expected bytes.
//! - `omlz fmt EXPECTED` is unchanged byte-for-byte.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli_options = @import("cli_options");

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

const snapshots = [_][]const u8{
    "simple_let",
    "let_in_chain",
    "match_expression",
    "mutual_rec",
    "let_test_unit",
    "comments",
    "deeply_nested",
    "multi_arg_function",
    "record_pattern",
    "record_destructure_let",
    "string_escapes",
    "gadt_decl",
    "module_decl",
};

fn runFmt(allocator: Allocator, io: Io, path: []const u8) !CommandResult {
    const argv = [_][]const u8{ cli_options.omlz_bin, "fmt", path };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
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

fn expectFmtSuccess(result: CommandResult, path: []const u8) !void {
    if (result.exit_code != 0) {
        std.debug.print(
            "FMT GOLDEN FAIL: omlz fmt {s} exited {d}\nSTDERR:\n{s}\n",
            .{ path, result.exit_code, result.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "omlz_fmt_golden: snapshot outputs are bytewise idempotent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    try std.testing.expect(snapshots.len >= 10);

    for (snapshots) |snapshot| {
        const input_path = try std.fmt.allocPrint(allocator, "tests/golden/fmt/{s}.input.ml", .{snapshot});
        defer allocator.free(input_path);
        const expected_path = try std.fmt.allocPrint(allocator, "tests/golden/fmt/{s}.expected.ml", .{snapshot});
        defer allocator.free(expected_path);

        const expected = try cwd.readFileAlloc(io, expected_path, allocator, .limited(65536));
        defer allocator.free(expected);

        const formatted_input = try runFmt(allocator, io, input_path);
        defer freeResult(allocator, formatted_input);
        try expectFmtSuccess(formatted_input, input_path);
        try std.testing.expectEqualStrings(expected, formatted_input.stdout);

        const formatted_expected = try runFmt(allocator, io, expected_path);
        defer freeResult(allocator, formatted_expected);
        try expectFmtSuccess(formatted_expected, expected_path);
        try std.testing.expectEqualStrings(expected, formatted_expected.stdout);
    }
}

test "omlz_fmt_golden: gadt_decl snapshot is bytewise idempotent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const input_path = "tests/golden/fmt/gadt_decl.input.ml";
    const expected_path = "tests/golden/fmt/gadt_decl.expected.ml";

    const expected = try cwd.readFileAlloc(io, expected_path, allocator, .limited(65536));
    defer allocator.free(expected);

    const formatted_input = try runFmt(allocator, io, input_path);
    defer freeResult(allocator, formatted_input);
    try expectFmtSuccess(formatted_input, input_path);
    try std.testing.expectEqualStrings(expected, formatted_input.stdout);

    const formatted_expected = try runFmt(allocator, io, expected_path);
    defer freeResult(allocator, formatted_expected);
    try expectFmtSuccess(formatted_expected, expected_path);
    try std.testing.expectEqualStrings(expected, formatted_expected.stdout);
}

test "omlz_fmt_golden: module_decl snapshot is bytewise idempotent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const input_path = "tests/golden/fmt/module_decl.input.ml";
    const expected_path = "tests/golden/fmt/module_decl.expected.ml";

    const expected = try cwd.readFileAlloc(io, expected_path, allocator, .limited(65536));
    defer allocator.free(expected);

    const formatted_input = try runFmt(allocator, io, input_path);
    defer freeResult(allocator, formatted_input);
    try expectFmtSuccess(formatted_input, input_path);
    try std.testing.expectEqualStrings(expected, formatted_input.stdout);

    const formatted_expected = try runFmt(allocator, io, expected_path);
    defer freeResult(allocator, formatted_expected);
    try expectFmtSuccess(formatted_expected, expected_path);
    try std.testing.expectEqualStrings(expected, formatted_expected.stdout);
}
