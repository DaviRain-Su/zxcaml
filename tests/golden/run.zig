//! Golden tests on Core IR: verify `omlz check --emit=core-ir` output
//! matches committed `.core.snapshot` files.
//!
//! RESPONSIBILITIES:
//! - Iterate every `.ml` in `tests/golden/`.
//! - Run `omlz check --emit=core-ir <file>` and capture stdout.
//! - Diff the captured stdout against the paired `.core.snapshot`.
//! - Report the first diverging line when a test fails.
//!
//! Snapshot determinism contract:
//! - No memory addresses, timestamps, or non-deterministic ordering.
//! - Pretty-printer output is a pure function of Core IR shape.
//!
//! Blessing: run `omlz check --emit=core-ir --bless <file>` to rewrite
//! the snapshot in-place.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const golden_options = @import("golden_options");

/// Runs `omlz check --emit=core-ir <ml_file>` and returns (stdout, exit_code).
/// Caller owns stdout and must free it.
fn runCoreIr(allocator: Allocator, io: Io, ml_file: []const u8) !struct { stdout: []u8, exit_code: u8 } {
    const argv = [_][]const u8{ golden_options.omlz_bin, "check", "--emit=core-ir", ml_file };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    // Free stderr immediately; caller only needs stdout.
    allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };

    return .{ .stdout = result.stdout, .exit_code = exit_code };
}

/// Trims trailing newline from a slice, returning the trimmed view.
fn trimTrailingNewline(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\n\r");
}

/// Reports the line number of the first difference between two strings,
/// or returns null if they are equal.
fn findFirstDiffLine(actual: []const u8, expected: []const u8) ?struct { line: usize, actual_line: []const u8, expected_line: []const u8 } {
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

test "golden: Core IR snapshots match for all tests/golden/*.ml" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, "tests/golden", .{});
    defer dir.close(io);

    var iter = dir.iterate();
    var tested: usize = 0;
    var failures: usize = 0;

    while (try iter.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".ml")) continue;

        const ml_path = try std.fmt.allocPrint(allocator, "tests/golden/{s}", .{entry.name});
        defer allocator.free(ml_path);

        const stem = entry.name[0 .. entry.name.len - 3];
        const snapshot_name = try std.fmt.allocPrint(allocator, "{s}.core.snapshot", .{stem});
        defer allocator.free(snapshot_name);

        // Read expected snapshot
        const snapshot_data = dir.readFileAlloc(io, snapshot_name, allocator, .limited(16384)) catch |err| {
            std.debug.print("GOLDEN SKIP: {s}: cannot read snapshot {s}: {s}\n", .{ ml_path, snapshot_name, @errorName(err) });
            continue;
        };
        defer allocator.free(snapshot_data);

        // Run omlz check --emit=core-ir
        const result = try runCoreIr(allocator, io, ml_path);
        defer allocator.free(result.stdout);

        if (result.exit_code != 0) {
            std.debug.print("GOLDEN FAIL: {s}: omlz exited {d}\n", .{ ml_path, result.exit_code });
            failures += 1;
            continue;
        }

        const actual = trimTrailingNewline(result.stdout);
        const expected = trimTrailingNewline(snapshot_data);

        if (std.mem.eql(u8, actual, expected)) {
            tested += 1;
            continue;
        }

        // Find and report the first diverging line
        if (findFirstDiffLine(actual, expected)) |diff| {
            std.debug.print(
                "GOLDEN FAIL: {s}: line {d} differs\n  expected: {s}\n  actual:   {s}\n",
                .{ ml_path, diff.line, diff.expected_line, diff.actual_line },
            );
        } else {
            std.debug.print("GOLDEN FAIL: {s}: output length differs\n", .{ml_path});
        }
        failures += 1;
        tested += 1;
    }

    if (tested == 0) {
        std.debug.print("WARNING: no golden test pairs found in tests/golden/\n", .{});
    }
    try std.testing.expect(failures == 0);
}

test "golden: snapshot determinism — no memory addresses or timestamps" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, "tests/golden", .{});
    defer dir.close(io);

    var iter = dir.iterate();

    while (try iter.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".core.snapshot")) continue;

        const snapshot_data = dir.readFileAlloc(io, entry.name, allocator, .limited(16384)) catch continue;
        defer allocator.free(snapshot_data);

        // Check for hex addresses (0x prefix followed by hex digits)
        if (std.mem.indexOf(u8, snapshot_data, "0x") != null) {
            std.debug.print("DETERMINISM FAIL: {s} contains '0x' (possible memory address)\n", .{entry.name});
            return error.SnapshotNonDeterministic;
        }

        // Check for common timestamp patterns
        if (std.mem.indexOf(u8, snapshot_data, "timestamp") != null) {
            std.debug.print("DETERMINISM FAIL: {s} contains 'timestamp'\n", .{entry.name});
            return error.SnapshotNonDeterministic;
        }

        // Verify output is a single line (no accidental multi-line with non-deterministic ordering)
        var lines = std.mem.splitScalar(u8, snapshot_data, '\n');
        var line_count: usize = 0;
        while (lines.next()) |line| {
            if (line.len > 0) line_count += 1;
        }
        if (line_count > 1) {
            std.debug.print("DETERMINISM WARNING: {s} has {d} non-empty lines (expected 1)\n", .{ entry.name, line_count });
            // Not a failure — multi-line snapshots are allowed if deterministic
        }
    }
}
