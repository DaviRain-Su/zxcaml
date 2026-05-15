//! CLI integration tests for `omlz doctor`.
//!
//! RESPONSIBILITIES:
//! - Invoke the installed compiler driver health-check surface.
//! - Assert each documented probe label appears as a status row.
//! - Assert the command exits 0 (no FAIL) or 1 (at least one FAIL).

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

fn lineContainsProbe(output: []const u8, label: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        // Look for `label:` followed by space then a status keyword.
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), label)) continue;
        const after = std.mem.trimStart(u8, line[colon + 1 ..], " \t");
        if (std.mem.startsWith(u8, after, "OK") or
            std.mem.startsWith(u8, after, "WARN") or
            std.mem.startsWith(u8, after, "FAIL")) return true;
    }
    return false;
}

test "cli: doctor reports every documented probe" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "doctor" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Doctor must exit 0 (no FAIL) or 1 (at least one FAIL); it never crashes.
    try std.testing.expect(result.exit_code == 0 or result.exit_code == 1);

    const expected_labels = [_][]const u8{
        "zig",
        "zxc-frontend",
        "ocamlc",
        "solana-zig",
        "llvm-objcopy",
        "solana",
        "cargo",
    };

    for (expected_labels) |label| {
        if (!lineContainsProbe(result.stdout, label)) {
            std.debug.print(
                "omlz doctor missing probe `{s}`\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ label, result.stdout, result.stderr },
            );
            return error.MissingProbe;
        }
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
    // The new help lists the probe set explicitly.
    try std.testing.expect(containsIgnoreCase(result.stdout, "zxc-frontend"));
    try std.testing.expect(containsIgnoreCase(result.stdout, "llvm-objcopy"));
}
