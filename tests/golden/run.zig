//! Golden tests on Core IR and frontend diagnostics.
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
const test_util = @import("test_util");

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

/// Runs `omlz check <ml_file>` and returns (stderr, exit_code).
/// Caller owns stderr and must free it.
fn runCheckStderr(allocator: Allocator, io: Io, ml_file: []const u8) !struct { stderr: []u8, exit_code: u8 } {
    // Existing stderr fixtures lock the pre-P9 one-line shape until the
    // dedicated DX1 re-bless feature migrates them to caret-format goldens.
    const argv = [_][]const u8{ golden_options.omlz_bin, "check", "--error-format=oneline", ml_file };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    allocator.free(result.stdout);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };

    return .{ .stderr = result.stderr, .exit_code = exit_code };
}

/// Runs `omlz check --error-format=json <ml_file>` and returns (stderr, exit_code).
/// Caller owns stderr and must free it.
fn runCheckJsonStderr(allocator: Allocator, io: Io, ml_file: []const u8) !struct { stderr: []u8, exit_code: u8 } {
    const argv = [_][]const u8{ golden_options.omlz_bin, "check", "--error-format=json", ml_file };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    allocator.free(result.stdout);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };

    return .{ .stderr = result.stderr, .exit_code = exit_code };
}

const JsonDiagnostic = struct {
    file: []const u8,
    line: u32,
    col: u32,
    end_line: ?u32 = null,
    end_col: ?u32 = null,
    severity: []const u8,
    code: ?[]const u8 = null,
    message: []const u8,
};

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

fn pathExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn containsExpectedOfTypeWithToken(stderr: []const u8) bool {
    const phrase = "expected of type";
    const start = std.mem.indexOf(u8, stderr, phrase) orelse return false;
    const after = stderr[start + phrase.len ..];
    const trimmed = std.mem.trim(u8, after, " \t\r\n");
    return trimmed.len > 0 and !std.ascii.isWhitespace(trimmed[0]);
}

test "golden: Core IR snapshots match for all tests/golden/*.ml" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    const names = try test_util.listBasenamesWithSuffix(allocator, io, "tests/golden", ".ml");
    defer test_util.freeStringList(allocator, names);

    var tested: usize = 0;
    var failures: usize = 0;

    for (names) |name| {
        const ml_path = try std.fmt.allocPrint(allocator, "tests/golden/{s}", .{name});
        defer allocator.free(ml_path);

        const stem = name[0 .. name.len - 3];
        const snapshot_path = try std.fmt.allocPrint(allocator, "tests/golden/{s}.core.snapshot", .{stem});
        defer allocator.free(snapshot_path);

        const stderr_path = try std.fmt.allocPrint(allocator, "tests/golden/{s}.stderr.txt", .{stem});
        defer allocator.free(stderr_path);

        if (pathExists(io, stderr_path)) {
            continue;
        }

        // Read expected snapshot
        const snapshot_data = cwd.readFileAlloc(io, snapshot_path, allocator, .limited(16384)) catch |err| {
            std.debug.print("GOLDEN SKIP: {s}: cannot read snapshot {s}: {s}\n", .{ ml_path, snapshot_path, @errorName(err) });
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

test "golden: frontend stderr diagnostics match for tests/golden/*.stderr.txt fixtures" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    const names = try test_util.listBasenamesWithSuffix(allocator, io, "tests/golden", ".stderr.txt");
    defer test_util.freeStringList(allocator, names);

    var tested: usize = 0;
    var failures: usize = 0;

    for (names) |name| {
        const stem = name[0 .. name.len - ".stderr.txt".len];
        const ml_path = try std.fmt.allocPrint(allocator, "tests/golden/{s}.ml", .{stem});
        defer allocator.free(ml_path);

        const expected_path = try std.fmt.allocPrint(allocator, "tests/golden/{s}", .{name});
        defer allocator.free(expected_path);

        const expected_data = cwd.readFileAlloc(io, expected_path, allocator, .limited(65536)) catch |err| {
            std.debug.print("GOLDEN STDERR SKIP: {s}: cannot read {s}: {s}\n", .{ ml_path, expected_path, @errorName(err) });
            continue;
        };
        defer allocator.free(expected_data);

        const result = try runCheckStderr(allocator, io, ml_path);
        defer allocator.free(result.stderr);

        if (result.exit_code == 0) {
            std.debug.print("GOLDEN STDERR FAIL: {s}: omlz unexpectedly exited 0\n", .{ml_path});
            failures += 1;
            tested += 1;
            continue;
        }

        const actual = trimTrailingNewline(result.stderr);
        const expected = trimTrailingNewline(expected_data);

        if (std.mem.eql(u8, actual, expected) and containsExpectedOfTypeWithToken(actual)) {
            tested += 1;
            continue;
        }

        if (!containsExpectedOfTypeWithToken(actual)) {
            std.debug.print(
                "GOLDEN STDERR FAIL: {s}: stderr lacks `expected of type` followed by a type token\n  actual: {s}\n",
                .{ ml_path, actual },
            );
        } else if (findFirstDiffLine(actual, expected)) |diff| {
            std.debug.print(
                "GOLDEN STDERR FAIL: {s}: stderr line {d} differs\n  expected: {s}\n  actual:   {s}\n",
                .{ ml_path, diff.line, diff.expected_line, diff.actual_line },
            );
        } else {
            std.debug.print("GOLDEN STDERR FAIL: {s}: stderr length differs\n", .{ml_path});
        }
        failures += 1;
        tested += 1;
    }

    if (tested == 0) {
        std.debug.print("WARNING: no golden stderr fixtures found in tests/golden/\n", .{});
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "golden: JSON diagnostics expose multi-character span end column" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const result = try runCheckJsonStderr(allocator, io, "tests/golden/dx1_type_caret.ml");
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);

    const first_line = std.mem.sliceTo(result.stderr, '\n');
    var parsed = try std.json.parseFromSlice(JsonDiagnostic, allocator, first_line, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("error", parsed.value.severity);
    try std.testing.expectEqualStrings("OCAML-FRONTEND", parsed.value.code orelse "");
    try std.testing.expectEqual(@as(u32, 1), parsed.value.line);
    try std.testing.expectEqual(parsed.value.line, parsed.value.end_line orelse 0);
    try std.testing.expect((parsed.value.end_col orelse parsed.value.col) > parsed.value.col);
}

test "golden: snapshot determinism — no memory addresses or timestamps" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = std.Io.Dir.cwd();
    const names = try test_util.listBasenamesWithSuffix(allocator, io, "tests/golden", ".core.snapshot");
    defer test_util.freeStringList(allocator, names);

    for (names) |name| {
        const snapshot_path = try std.fmt.allocPrint(allocator, "tests/golden/{s}", .{name});
        defer allocator.free(snapshot_path);

        const snapshot_data = cwd.readFileAlloc(io, snapshot_path, allocator, .limited(16384)) catch continue;
        defer allocator.free(snapshot_data);

        // Check for hex addresses (0x prefix followed by hex digits)
        if (std.mem.indexOf(u8, snapshot_data, "0x") != null) {
            std.debug.print("DETERMINISM FAIL: {s} contains '0x' (possible memory address)\n", .{name});
            return error.SnapshotNonDeterministic;
        }

        // Check for common timestamp patterns
        if (std.mem.indexOf(u8, snapshot_data, "timestamp") != null) {
            std.debug.print("DETERMINISM FAIL: {s} contains 'timestamp'\n", .{name});
            return error.SnapshotNonDeterministic;
        }

        // Verify output is a single line (no accidental multi-line with non-deterministic ordering)
        var lines = std.mem.splitScalar(u8, snapshot_data, '\n');
        var line_count: usize = 0;
        while (lines.next()) |line| {
            if (line.len > 0) line_count += 1;
        }
        if (line_count > 1) {
            std.debug.print("DETERMINISM WARNING: {s} has {d} non-empty lines (expected 1)\n", .{ name, line_count });
            // Not a failure — multi-line snapshots are allowed if deterministic
        }
    }
}
