//! CLI integration tests for `omlz bench`.
//!
//! RESPONSIBILITIES:
//! - Invoke the default three-fixture benchmark surface.
//! - Assert it prints a markdown-style table with numeric timing/artifact data.
//! - Assert benchmark artifacts are removed before the command exits.

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

fn fileExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn cellIsDecimal(cell: []const u8) bool {
    const trimmed = std.mem.trim(u8, cell, " \t\r\n");
    if (trimmed.len == 0) return false;
    for (trimmed) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn dataRowHasNumericColumns(line: []const u8) bool {
    var cells = std.mem.splitScalar(u8, line, '|');
    _ = cells.next(); // leading empty cell before the first pipe
    const program = std.mem.trim(u8, cells.next() orelse return false, " \t\r\n");
    if (program.len == 0) return false;
    return cellIsDecimal(cells.next() orelse return false) and
        cellIsDecimal(cells.next() orelse return false) and
        cellIsDecimal(cells.next() orelse return false);
}

test "cli: bench prints table and cleans generated artifacts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const stale_artifacts = [_][]const u8{
        "out/bench_hackathon_greet.so",
        "out/bench_hackathon_greet.map",
        "out/bench_escrow_full.so",
        "out/bench_escrow_full.map",
        "out/bench_spl_token_transfer.so",
        "out/bench_spl_token_transfer.map",
    };
    for (stale_artifacts) |path| cwd.deleteFile(io, path) catch {};

    const argv = [_][]const u8{ cli_options.omlz_bin, "bench" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        std.debug.print(
            "omlz bench failed\nexit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "| program | compile_ms | so_bytes | entries |") != null);

    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (dataRowHasNumericColumns(line)) rows += 1;
    }
    try std.testing.expect(rows >= 3);

    for (stale_artifacts) |path| {
        try std.testing.expect(!fileExists(io, path));
    }
}

test "cli: bench --help describes the BPF target" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "bench", "--help" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--target") != null or
        std.mem.indexOf(u8, result.stderr, "--target") != null);
}
