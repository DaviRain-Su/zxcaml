//! Integration tests for `omlz fmt`.
//!
//! These tests spawn the installed `omlz` binary and exercise the user-facing
//! formatter subcommand contract: help, stdout formatting, check/write modes,
//! stdin, JSON summaries, directory discovery, and exit codes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli_options = @import("cli_options");

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

test "omlz_fmt_subcommand: help lists supported options" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ cli_options.omlz_bin, "fmt", "--help" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(contains(result.stdout, "--check"));
    try std.testing.expect(contains(result.stdout, "--write"));
    try std.testing.expect(contains(result.stdout, "--stdin"));
    try std.testing.expect(contains(result.stdout, "--format"));
    try std.testing.expect(contains(result.stdout, "--no-color"));
}

test "omlz_fmt_subcommand: default path prints formatted output without modifying file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "tests/fixtures/fmt/needs_reformat.ml";

    const before = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(before);
    const result = try runCommand(allocator, io, &.{ cli_options.omlz_bin, "fmt", path });
    defer freeResult(allocator, result);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(after);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("let x = 1\n", result.stdout);
    try std.testing.expectEqualStrings(before, after);
}

test "omlz_fmt_subcommand: check exits zero for well formatted file" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ cli_options.omlz_bin, "fmt", "--check", "tests/fixtures/fmt/well_formed.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "omlz_fmt_subcommand: check exits one and prints mismatched path" {
    const allocator = std.testing.allocator;
    const path = "tests/fixtures/fmt/needs_reformat.ml";
    const result = try runCommand(allocator, std.testing.io, &.{ cli_options.omlz_bin, "fmt", "--check", path });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(contains(result.stderr, path));
}

test "omlz_fmt_subcommand: write rewrites file in place" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    const path = "out/omlz_fmt_write_test.ml";
    try cwd.writeFile(io, .{ .sub_path = path, .data = "let y=2\n", .flags = .{ .truncate = true } });
    defer cwd.deleteFile(io, path) catch {};

    const result = try runCommand(allocator, io, &.{ cli_options.omlz_bin, "fmt", "--write", path });
    defer freeResult(allocator, result);
    const written = try cwd.readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(written);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("let y = 2\n", written);
}

test "omlz_fmt_subcommand: stdin reads source and writes formatted stdout" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ "sh", "-c", "echo 'let z=3' | zig-out/bin/omlz fmt --stdin" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("let z = 3\n", result.stdout);
}

test "omlz_fmt_subcommand: malformed input exits two" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ cli_options.omlz_bin, "fmt", "--check", "tests/fixtures/fmt/malformed.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 2), result.exit_code);
    try std.testing.expect(contains(result.stderr, "error"));
}

test "omlz_fmt_subcommand: json format emits per-file diff summary" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ cli_options.omlz_bin, "fmt", "--check", "--format=json", "tests/fixtures/fmt/needs_reformat.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trim(u8, result.stdout, " \t\r\n"), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("tests/fixtures/fmt/needs_reformat.ml", object.get("path").?.string);
    try std.testing.expect(object.get("changed").?.bool);
    try std.testing.expect(object.contains("original_bytes"));
    try std.testing.expect(object.contains("formatted_bytes"));
}

test "omlz_fmt_subcommand: directory inputs recurse over ml files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, "out/omlz_fmt_dir_test") catch {};
    try cwd.createDirPath(io, "out/omlz_fmt_dir_test/nested");
    defer cwd.deleteTree(io, "out/omlz_fmt_dir_test") catch {};

    try cwd.writeFile(io, .{ .sub_path = "out/omlz_fmt_dir_test/a.ml", .data = "let a=1\n", .flags = .{ .truncate = true } });
    try cwd.writeFile(io, .{ .sub_path = "out/omlz_fmt_dir_test/nested/b.ml", .data = "let b=2\n", .flags = .{ .truncate = true } });
    try cwd.writeFile(io, .{ .sub_path = "out/omlz_fmt_dir_test/ignore.txt", .data = "let ignored=0\n", .flags = .{ .truncate = true } });

    const result = try runCommand(allocator, io, &.{ cli_options.omlz_bin, "fmt", "out/omlz_fmt_dir_test" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("let a = 1\nlet b = 2\n", result.stdout);
}

test "omlz_fmt_subcommand: missing file exits two" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ cli_options.omlz_bin, "fmt", "/tmp/omlz_fmt_missing_file.ml" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 2), result.exit_code);
    try std.testing.expect(contains(result.stderr, "file not found"));
}
