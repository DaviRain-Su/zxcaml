//! CLI integration tests for `omlz doctor`.
//!
//! RESPONSIBILITIES:
//! - Invoke the installed compiler driver health-check surface.
//! - Assert required tool probes are named and use OK/WARN/MISS status lines.
//! - Assert the command exits successfully on the mission-provisioned machine.

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

fn startsWithStatus(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "OK ") or
        std.mem.startsWith(u8, line, "WARN ") or
        std.mem.startsWith(u8, line, "MISS ");
}

fn statusLineCount(output: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (startsWithStatus(line)) count += 1;
    }
    return count;
}

fn statusLineAt(output: []const u8, wanted_index: usize) ?[]const u8 {
    var status_index: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (!startsWithStatus(line)) continue;
        if (status_index == wanted_index) return line;
        status_index += 1;
    }
    return null;
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

test "cli: doctor reports toolchain health" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "doctor" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const observed_status_lines = statusLineCount(result.stdout);
    const expected_order = [_][]const u8{
        "zig",
        "opam-switch (zxcaml-p1)",
        "ocamlc",
        "solana-zig",
        "cargo",
        "llvm-objcopy",
        "surfpool",
    };

    if (observed_status_lines != expected_order.len) {
        std.debug.print(
            "omlz doctor returned unexpected status-line count (expected {d}, got {d})\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ expected_order.len, observed_status_lines, result.stdout, result.stderr },
        );
        return error.UnexpectedStatusLineCount;
    }

    if (result.exit_code != 0 or observed_status_lines != expected_order.len) {
        std.debug.print(
            "omlz doctor failed expectations\nexit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
    }

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqual(expected_order.len, observed_status_lines);
    for (expected_order, 0..) |needle, index| {
        const line = statusLineAt(result.stdout, index) orelse return error.MissingStatusLine;
        try std.testing.expect(containsIgnoreCase(line, needle));
    }
}

test "cli: doctor --help exits successfully" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "doctor", "--help" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(containsIgnoreCase(result.stdout, "doctor"));
}
