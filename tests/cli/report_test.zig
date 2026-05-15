//! Regression tests for `omlz check --report=<kinds>`.
//!
//! RESPONSIBILITIES:
//! - Exercise the static profiling report end-to-end through the installed
//!   `omlz` binary.
//! - Pin the rendered factorial report to its golden file.
//! - Confirm that unknown report kinds fail with `E0200`.

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

test "cli: check --report=cu factorial exits 0 and prints CU section" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--report=cu", "examples/factorial.ml" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "== Compute units (static estimate) ==") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "== Max function stack depth") == null);
}

test "cli: check --report=stack factorial exits 0 and prints stack section" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--report=stack", "examples/factorial.ml" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "== Max function stack depth (static estimate) ==") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "== Compute units") == null);
}

test "cli: check --report=bogus fails with E0200" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--report=bogus", "examples/factorial.ml" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "E0200") != null);
}

test "cli: check --report=all hello.ml emits sections in stable order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--report=all", "examples/hello.ml" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    const cu_index = std.mem.indexOf(u8, result.stdout, "== Compute units") orelse {
        try std.testing.expect(false);
        return;
    };
    const stack_index = std.mem.indexOf(u8, result.stdout, "== Max function stack depth") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(cu_index < stack_index);
}

test "cli: check --report=all for_loop_demo matches golden snapshot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--report=all", "examples/for_loop_demo.ml" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const golden_path = "tests/golden/report_for_loop_demo.expected.txt";
    const expected = std.Io.Dir.cwd().readFileAlloc(io, golden_path, allocator, .limited(64 * 1024)) catch |err| {
        std.debug.print("missing golden: {s} ({s})\n", .{ golden_path, @errorName(err) });
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(expected);

    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print(
            "report golden mismatch\nexpected:\n{s}\nactual:\n{s}\n",
            .{ expected, result.stdout },
        );
    }
    try std.testing.expectEqualSlices(u8, expected, result.stdout);
}

test "cli: check --report=all while_loop_demo matches golden snapshot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--report=all", "examples/while_loop_demo.ml" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const golden_path = "tests/golden/report_while_loop_demo.expected.txt";
    const expected = std.Io.Dir.cwd().readFileAlloc(io, golden_path, allocator, .limited(64 * 1024)) catch |err| {
        std.debug.print("missing golden: {s} ({s})\n", .{ golden_path, @errorName(err) });
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(expected);

    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print(
            "report golden mismatch\nexpected:\n{s}\nactual:\n{s}\n",
            .{ expected, result.stdout },
        );
    }
    try std.testing.expectEqualSlices(u8, expected, result.stdout);
}

test "cli: check --report=cu ref_loop_demo matches golden snapshot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--report=cu", "examples/ref_loop_demo.ml" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const golden_path = "tests/golden/report_ref_loop.expected.txt";
    const expected = std.Io.Dir.cwd().readFileAlloc(io, golden_path, allocator, .limited(64 * 1024)) catch |err| {
        std.debug.print("missing golden: {s} ({s})\n", .{ golden_path, @errorName(err) });
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(expected);

    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print(
            "report golden mismatch\nexpected:\n{s}\nactual:\n{s}\n",
            .{ expected, result.stdout },
        );
    }
    try std.testing.expectEqualSlices(u8, expected, result.stdout);
}

test "cli: check --report=all factorial matches golden snapshot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "check", "--report=all", "examples/factorial.ml" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const golden_path = "tests/golden/report_factorial.expected.txt";
    const expected = std.Io.Dir.cwd().readFileAlloc(io, golden_path, allocator, .limited(64 * 1024)) catch |err| {
        std.debug.print("missing golden: {s} ({s})\n", .{ golden_path, @errorName(err) });
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(expected);

    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print(
            "report golden mismatch\nexpected:\n{s}\nactual:\n{s}\n",
            .{ expected, result.stdout },
        );
    }
    try std.testing.expectEqualSlices(u8, expected, result.stdout);
}
