//! Golden snapshots for `let%test_prop` Core IR lowering.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const golden_options = @import("golden_options");
const test_util = @import("test_util");

fn runCoreIr(allocator: Allocator, io: Io, ml_file: []const u8) !struct { stdout: []u8, exit_code: u8 } {
    const argv = [_][]const u8{ golden_options.omlz_bin, "check", "--emit=core-ir", ml_file };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };

    return .{ .stdout = result.stdout, .exit_code = exit_code };
}

fn trimTrailingNewline(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\n\r");
}

fn findFirstDiffLine(actual: []const u8, expected: []const u8) ?struct { line: usize, actual_line: []const u8, expected_line: []const u8 } {
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var line_no: usize = 1;

    while (true) {
        const actual_line = actual_lines.next();
        const expected_line = expected_lines.next();

        if (actual_line == null and expected_line == null) return null;

        const actual_trimmed = if (actual_line) |line| std.mem.trimEnd(u8, line, "\r") else "";
        const expected_trimmed = if (expected_line) |line| std.mem.trimEnd(u8, line, "\r") else "";

        if (!std.mem.eql(u8, actual_trimmed, expected_trimmed)) {
            return .{ .line = line_no, .actual_line = actual_trimmed, .expected_line = expected_trimmed };
        }

        line_no += 1;
    }
}

test "otest_prop golden: Core IR snapshots match" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const names = try test_util.listBasenamesWithSuffix(allocator, io, "tests/golden/otest_prop", ".ml");
    defer test_util.freeStringList(allocator, names);

    var tested: usize = 0;
    var failures: usize = 0;

    for (names) |name| {
        const ml_path = try std.fmt.allocPrint(allocator, "tests/golden/otest_prop/{s}", .{name});
        defer allocator.free(ml_path);

        const stem = name[0 .. name.len - 3];
        const snapshot_path = try std.fmt.allocPrint(allocator, "tests/golden/otest_prop/{s}.core.snapshot", .{stem});
        defer allocator.free(snapshot_path);

        const expected_data = cwd.readFileAlloc(io, snapshot_path, allocator, .limited(16384)) catch |err| {
            std.debug.print("OTEST_PROP GOLDEN SKIP: {s}: cannot read {s}: {s}\n", .{ ml_path, snapshot_path, @errorName(err) });
            continue;
        };
        defer allocator.free(expected_data);

        const result = try runCoreIr(allocator, io, ml_path);
        defer allocator.free(result.stdout);

        if (result.exit_code != 0) {
            std.debug.print("OTEST_PROP GOLDEN FAIL: {s}: omlz exited {d}\n", .{ ml_path, result.exit_code });
            failures += 1;
            continue;
        }

        const actual = trimTrailingNewline(result.stdout);
        const expected = trimTrailingNewline(expected_data);
        if (std.mem.eql(u8, actual, expected)) {
            tested += 1;
            continue;
        }

        if (findFirstDiffLine(actual, expected)) |diff| {
            std.debug.print(
                "OTEST_PROP GOLDEN FAIL: {s}: line {d} differs\n  expected: {s}\n  actual:   {s}\n",
                .{ ml_path, diff.line, diff.expected_line, diff.actual_line },
            );
        } else {
            std.debug.print("OTEST_PROP GOLDEN FAIL: {s}: output length differs\n", .{ml_path});
        }
        failures += 1;
        tested += 1;
    }

    try std.testing.expect(tested >= 4);
    try std.testing.expect(failures == 0);
}
