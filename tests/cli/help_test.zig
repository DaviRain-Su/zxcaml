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

fn runHelp(allocator: Allocator, io: Io, subcommand: []const u8) !HelpResult {
    const argv = [_][]const u8{ cli_options.omlz_bin, subcommand, "--help" };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });

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

test "cli: every subcommand accepts --help" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const subcommands = [_][]const u8{ "check", "build", "idl", "run" };
    for (subcommands) |subcommand| {
        const result = try runHelp(allocator, io, subcommand);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.exit_code != 0 or !outputContainsHelpText(result.stdout, result.stderr, subcommand)) {
            std.debug.print(
                "omlz {s} --help failed expectations\nexit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ subcommand, result.exit_code, result.stdout, result.stderr },
            );
        }
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expect(outputContainsHelpText(result.stdout, result.stderr, subcommand));
    }
}
