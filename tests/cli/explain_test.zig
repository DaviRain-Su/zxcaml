//! Regression tests for `omlz check --explain <CODE>`.
//!
//! RESPONSIBILITIES:
//! - Assert every diagnostics catalog code has a non-trivial explanation.
//! - Assert unknown codes fail with a friendly hint.
//! - Assert the check help text advertises the lookup flag.

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

fn combinedLineCount(stdout: []const u8, stderr: []const u8) usize {
    var count: usize = 0;
    for (stdout) |byte| {
        if (byte == '\n') count += 1;
    }
    for (stderr) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn outputContainsNeedle(stdout: []const u8, stderr: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, stdout, needle) != null or std.mem.indexOf(u8, stderr, needle) != null;
}

test "cli: check --explain covers every diagnostics catalog code" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const codes = [_][]const u8{
        "E0001", "E0002", "E0003",
        "E0010", "E0011", "E0012",
        "E0013", "E0014", "E0015",
        "E0016", "E0017", "E0018",
        "E0019", "E0020", "E0021",
        "E0022", "E0023", "E0024",
        "E0030", "E0031",
        "E0090", "E0099",
        "E0200",
    };

    for (codes) |code| {
        const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--explain", code };
        const result = try runCommand(allocator, io, &argv);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.exit_code != 0 or combinedLineCount(result.stdout, result.stderr) < 3) {
            std.debug.print(
                "omlz check --explain {s} failed expectations\nexit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ code, result.exit_code, result.stdout, result.stderr },
            );
        }
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expect(combinedLineCount(result.stdout, result.stderr) >= 3);
        try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, code));
    }
}

test "cli: check --explain unknown code fails with hint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--explain", "E9999" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "Unknown diagnostic code"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "omlz check --help"));
}

test "cli: check help advertises --explain" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--help" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "--explain"));
}
