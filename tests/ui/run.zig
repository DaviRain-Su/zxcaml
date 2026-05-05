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
const test_util = @import("test_util");

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

fn pathExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn stemFromMlName(name: []const u8) []const u8 {
    std.debug.assert(std.mem.endsWith(u8, name, ".ml"));
    return name[0 .. name.len - 3];
}

fn resolveExpectedPath(allocator: Allocator, io: Io, name: []const u8) ![]u8 {
    const stem = stemFromMlName(name);
    const stem_expected_path = try std.fmt.allocPrint(allocator, "tests/ui/{s}.expected", .{stem});
    if (pathExists(io, stem_expected_path)) return stem_expected_path;
    allocator.free(stem_expected_path);

    return std.fmt.allocPrint(allocator, "tests/ui/{s}.expected", .{name});
}

fn resolveCmdPath(allocator: Allocator, io: Io, name: []const u8) !?[]u8 {
    const stem = stemFromMlName(name);
    const stem_cmd_path = try std.fmt.allocPrint(allocator, "tests/ui/{s}.cmd", .{stem});
    if (pathExists(io, stem_cmd_path)) return stem_cmd_path;
    allocator.free(stem_cmd_path);

    const legacy_cmd_path = try std.fmt.allocPrint(allocator, "tests/ui/{s}.cmd", .{name});
    if (pathExists(io, legacy_cmd_path)) return legacy_cmd_path;
    allocator.free(legacy_cmd_path);
    return null;
}

fn isExplicitSubcommand(token: []const u8) bool {
    return std.mem.eql(u8, token, "check") or
        std.mem.eql(u8, token, "run") or
        std.mem.eql(u8, token, "build") or
        std.mem.eql(u8, token, "idl");
}

/// Runs `omlz` for a UI fixture and returns (stdout, stderr, exit_code).
/// A sibling `.cmd` file may provide per-fixture subcommand flags. If the
/// first token is an `omlz` subcommand it replaces the default `run`;
/// otherwise all tokens are passed as flags to `omlz run`.
/// Caller owns stdout and stderr and must free both.
fn runOmlz(allocator: Allocator, io: Io, ml_file: []const u8, cmd_path: ?[]const u8) !struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
} {
    var cmd_data: ?[]u8 = null;
    defer if (cmd_data) |data| allocator.free(data);

    var tokens = std.ArrayList([]const u8).empty;
    defer tokens.deinit(allocator);

    if (cmd_path) |path| {
        cmd_data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
        var iter = std.mem.tokenizeAny(u8, cmd_data.?, " \t\r\n");
        while (iter.next()) |token| {
            try tokens.append(allocator, token);
        }
    }

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, ui_options.omlz_bin);

    var first_flag_index: usize = 0;
    if (tokens.items.len > 0 and isExplicitSubcommand(tokens.items[0])) {
        try argv.append(allocator, tokens.items[0]);
        first_flag_index = 1;
    } else {
        try argv.append(allocator, "run");
    }

    for (tokens.items[first_flag_index..]) |token| {
        try argv.append(allocator, token);
    }
    try argv.append(allocator, ml_file);

    const result = try std.process.run(allocator, io, .{ .argv = argv.items });

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
    const names = try test_util.listBasenamesWithSuffix(allocator, io, "tests/ui", ".ml");
    defer test_util.freeStringList(allocator, names);

    var tested: usize = 0;
    var failures: usize = 0;

    for (names) |name| {
        const ml_path = try std.fmt.allocPrint(allocator, "tests/ui/{s}", .{name});
        defer allocator.free(ml_path);

        const expected_path = try resolveExpectedPath(allocator, io, name);
        defer allocator.free(expected_path);

        const cmd_path = try resolveCmdPath(allocator, io, name);
        defer if (cmd_path) |path| allocator.free(path);

        // Read expected output
        const expected_data = cwd.readFileAlloc(io, expected_path, allocator, .limited(65536)) catch |err| {
            std.debug.print("UI SKIP: {s}: cannot read {s}: {s}\n", .{ ml_path, expected_path, @errorName(err) });
            continue;
        };
        defer allocator.free(expected_data);

        // Run omlz run
        const result = try runOmlz(allocator, io, ml_path, cmd_path);
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
