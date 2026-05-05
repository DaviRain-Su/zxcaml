//! Regression tests for per-subcommand `omlz <subcmd> --help`.
//!
//! RESPONSIBILITIES:
//! - Invoke the installed compiler driver for each advertised subcommand.
//! - Assert `--help` exits successfully instead of parsing as regular flags or paths.
//! - Assert the captured help text identifies usage or the requested subcommand.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli_options = @import("cli_options");

const HelpResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

const CommandResult = HelpResult;

fn runHelp(allocator: Allocator, io: Io, subcommand: []const u8) !HelpResult {
    const argv = [_][]const u8{ cli_options.omlz_bin, subcommand, "--help" };
    return runCommand(allocator, io, &argv);
}

fn runCommand(allocator: Allocator, io: Io, argv: []const []const u8) !CommandResult {
    const result = try std.process.run(allocator, io, .{ .argv = argv });

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };

    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    const last_start = haystack.len - needle.len;
    for (0..last_start + 1) |start| {
        for (needle, 0..) |needle_char, offset| {
            const actual = std.ascii.toLower(haystack[start + offset]);
            const expected = std.ascii.toLower(needle_char);
            if (actual != expected) break;
        } else {
            return true;
        }
    }
    return false;
}

fn outputContainsHelpText(stdout: []const u8, stderr: []const u8, subcommand: []const u8) bool {
    return containsIgnoreCase(stdout, "Usage") or
        containsIgnoreCase(stderr, "Usage") or
        containsIgnoreCase(stdout, subcommand) or
        containsIgnoreCase(stderr, subcommand);
}

fn outputContainsNeedle(stdout: []const u8, stderr: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, stdout, needle) != null or std.mem.indexOf(u8, stderr, needle) != null;
}

test "cli: every subcommand accepts --help" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const subcommands = [_][]const u8{ "check", "build", "idl", "run" };
    for (subcommands) |subcommand| {
        const result = try runHelp(allocator, io, subcommand);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const has_help = outputContainsHelpText(result.stdout, result.stderr, subcommand);
        const has_error_format = outputContainsNeedle(result.stdout, result.stderr, "--error-format");
        const has_color = outputContainsNeedle(result.stdout, result.stderr, "--color");
        const has_no_srcmap = !std.mem.eql(u8, subcommand, "build") or
            outputContainsNeedle(result.stdout, result.stderr, "--no-srcmap");

        if (result.exit_code != 0 or !has_help or !has_error_format or !has_color or !has_no_srcmap) {
            std.debug.print(
                "omlz {s} --help failed expectations\nexit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ subcommand, result.exit_code, result.stdout, result.stderr },
            );
        }
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expect(has_help);
        try std.testing.expect(has_error_format);
        try std.testing.expect(has_color);
        try std.testing.expect(has_no_srcmap);
    }
}

test "cli: check --color=never emits no ANSI escapes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{
        cli_options.omlz_bin,
        "check",
        "--color=never",
        "tests/golden/dx1_type_caret.ml",
    };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "\x1b[") == null);
}

test "cli: default error format matches explicit human" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const default_argv = [_][]const u8{
        cli_options.omlz_bin,
        "check",
        "--color=never",
        "tests/golden/dx1_type_caret.ml",
    };
    const explicit_argv = [_][]const u8{
        cli_options.omlz_bin,
        "check",
        "--color=never",
        "--error-format=human",
        "tests/golden/dx1_type_caret.ml",
    };

    const default_result = try runCommand(allocator, io, &default_argv);
    defer allocator.free(default_result.stdout);
    defer allocator.free(default_result.stderr);
    const explicit_result = try runCommand(allocator, io, &explicit_argv);
    defer allocator.free(explicit_result.stdout);
    defer allocator.free(explicit_result.stderr);

    try std.testing.expect(default_result.exit_code != 0);
    try std.testing.expectEqual(default_result.exit_code, explicit_result.exit_code);
    try std.testing.expectEqualStrings(default_result.stdout, explicit_result.stdout);
    try std.testing.expectEqualStrings(default_result.stderr, explicit_result.stderr);
}
