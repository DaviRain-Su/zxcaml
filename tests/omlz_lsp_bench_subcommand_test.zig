//! Integration tests for `omlz lsp-bench`.
//!
//! These tests exercise the public CLI wrapper around the Zig LSP latency
//! probe, including help text, default execution, explicit CLI thresholds, and
//! inherited threshold environment overrides.

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

fn freeResult(allocator: Allocator, result: CommandResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn outputContains(result: CommandResult, needle: []const u8) bool {
    return std.mem.indexOf(u8, result.stdout, needle) != null or
        std.mem.indexOf(u8, result.stderr, needle) != null;
}

test "omlz_lsp_bench_subcommand: help lists latency probe flags" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ cli_options.omlz_bin, "lsp-bench", "--help" });
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(outputContains(result, "--warmup"));
    try std.testing.expect(outputContains(result, "--rounds"));
    try std.testing.expect(outputContains(result, "--p50"));
    try std.testing.expect(outputContains(result, "--p99"));
}

test "omlz_lsp_bench_subcommand: default invocation uses default warmup and rounds" {
    const allocator = std.testing.allocator;
    const result = try runCommand(allocator, std.testing.io, &.{ cli_options.omlz_bin, "lsp-bench" });
    defer freeResult(allocator, result);

    if (result.exit_code != 0) {
        std.debug.print(
            "omlz lsp-bench default invocation failed\nexit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(outputContains(result, "warmup=3 rounds=10"));
    try std.testing.expect(outputContains(result, "samples_ms=["));
}

test "omlz_lsp_bench_subcommand: custom flags forward to the probe" {
    const allocator = std.testing.allocator;
    const result = try runCommand(
        allocator,
        std.testing.io,
        &.{ cli_options.omlz_bin, "lsp-bench", "--warmup", "0", "--rounds", "1", "--p50", "10000", "--p99", "10000" },
    );
    defer freeResult(allocator, result);

    if (result.exit_code != 0) {
        std.debug.print(
            "omlz lsp-bench custom flags failed\nexit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(outputContains(result, "warmup=0 rounds=1"));
    try std.testing.expect(outputContains(result, "p50_ms="));
    try std.testing.expect(outputContains(result, "p99_ms="));
}

test "omlz_lsp_bench_subcommand: threshold env override reaches the probe" {
    const allocator = std.testing.allocator;
    const result = try runCommand(
        allocator,
        std.testing.io,
        &.{ "env", "ZXCAML_LSP_LATENCY_P50_MS=1", "ZXCAML_LSP_LATENCY_P99_MS=10000", cli_options.omlz_bin, "lsp-bench", "--warmup", "0", "--rounds", "1" },
    );
    defer freeResult(allocator, result);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(outputContains(result, "FAIL: p50="));
    try std.testing.expect(outputContains(result, "threshold 1"));
}
