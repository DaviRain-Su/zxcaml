//! UI tests: end-to-end `omlz run` checks against `.expected` files.
//!
//! RESPONSIBILITIES:
//! - Iterate every `.ml` in `tests/ui/` (excluding this driver's own build artifact).
//! - Run `omlz run <file>` and capture stdout, stderr, and exit code.
//! - Positive tests (exit 0): diff stdout against `.expected`.
//! - Negative tests (exit non-zero): diff stderr against `.expected`.
//! - Report the first diverging line when a test fails.
//!
//! Conventions:
//! - Positive tests: `.ml` programs that compile and run; `.expected` contains
//!   the stdout (the interpreter's printed result, typically an integer).
//! - Negative tests: `.ml` programs exercising unsupported features; `.expected`
//!   contains the stderr diagnostic rendered by the compiler pipeline.
//!
//! Each `.ml` file must have a corresponding `.expected` file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ui_options = @import("ui_options");

/// Trims trailing newline / carriage-return from a slice.
fn trimTrailingNewline(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\n\r");
}

/// Reports the line number of the first difference between two strings,
/// or returns null if they are equal.
fn findFirstDiffLine(actual: []const u8, expected: []const u8) ?struct {
    line: usize,
    actual_line: []const u8,
    expected_line: []const u8,
} {
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var line_no: usize = 1;

    while (true) {
        const a = actual_lines.next();
        const e = expected_lines.next();

        if (a == null and e == null) return null;

        const a_trimmed = if (a) |s| std.mem.trimEnd(u8, s, "\r") else "";
        const e_trimmed = if (e) |s| std.mem.trimEnd(u8, s, "\r") else "";

        if (!std.mem.eql(u8, a_trimmed, e_trimmed)) {
            return .{ .line = line_no, .actual_line = a_trimmed, .expected_line = e_trimmed };
        }
        line_no += 1;
    }
}

/// Runs `omlz run <ml_file>` and returns (stdout, stderr, exit_code).
/// Caller owns stdout and stderr and must free both.
fn runOmlz(allocator: Allocator, io: Io, ml_file: []const u8) !struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
} {
    const argv = [_][]const u8{ ui_options.omlz_bin, "run", ml_file };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };

    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
}

test "ui: all .ml files match their .expected counterparts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, "tests/ui", .{});
    defer dir.close(io);

    var iter = dir.iterate();
    var tested: usize = 0;
    var failures: usize = 0;

    while (try iter.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".ml")) continue;

        const ml_path = try std.fmt.allocPrint(allocator, "tests/ui/{s}", .{entry.name});
        defer allocator.free(ml_path);

        const expected_name = try std.fmt.allocPrint(allocator, "{s}.expected", .{entry.name});
        defer allocator.free(expected_name);

        // Read expected output
        const expected_data = dir.readFileAlloc(io, expected_name, allocator, .limited(65536)) catch |err| {
            std.debug.print("UI SKIP: {s}: cannot read {s}: {s}\n", .{ ml_path, expected_name, @errorName(err) });
            continue;
        };
        defer allocator.free(expected_data);

        // Run omlz run
        const result = try runOmlz(allocator, io, ml_path);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        // Determine which stream to compare based on exit code
        const actual_raw = if (result.exit_code == 0) result.stdout else result.stderr;
        const stream_label = if (result.exit_code == 0) "stdout" else "stderr";

        const actual = trimTrailingNewline(actual_raw);
        const expected = trimTrailingNewline(expected_data);

        if (std.mem.eql(u8, actual, expected)) {
            tested += 1;
            continue;
        }

        // Find and report the first diverging line
        if (findFirstDiffLine(actual, expected)) |diff| {
            std.debug.print(
                "UI FAIL: {s}: {s} line {d} differs\n  expected: {s}\n  actual:   {s}\n",
                .{ ml_path, stream_label, diff.line, diff.expected_line, diff.actual_line },
            );
        } else {
            std.debug.print("UI FAIL: {s}: {s} length differs (expected {d}, got {d})\n", .{
                ml_path,
                stream_label,
                expected.len,
                actual.len,
            });
        }
        failures += 1;
        tested += 1;
    }

    if (tested == 0) {
        std.debug.print("WARNING: no UI test pairs found in tests/ui/\n", .{});
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
