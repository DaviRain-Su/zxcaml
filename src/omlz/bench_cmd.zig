//! `omlz bench` subcommand implementation.
//!
//! RESPONSIBILITIES:
//! - Compile the fixed local BPF fixture set and print a Markdown metrics
//!   table (compile time, artifact size, source-map entries).
//! - Support `--rounds`/`--warmup-rounds` warm-median rows for stability.
const std = @import("std");
const Io = std.Io;
const cmd_common = @import("cmd_common.zig");
const build_cmd = @import("build_cmd.zig");
const cli = @import("cli_surface.zig");
const pipeline = @import("../driver/pipeline.zig");
const driver_srcmap = @import("../driver/srcmap.zig");
const target_registry = @import("../target/registry.zig");

const writeStdout = cmd_common.writeStdout;
const writeStderr = cmd_common.writeStderr;
const BenchArgs = cli.BenchArgs;

const BenchFixture = struct {
    program: []const u8,
    path: []const u8,
};

const bench_fixtures = [_]BenchFixture{
    .{ .program = "hackathon_greet", .path = "examples/hackathon_greet.ml" },
    .{ .program = "escrow_full", .path = "examples/escrow_full.ml" },
    .{ .program = "spl_token_transfer", .path = "examples/spl_token_transfer.ml" },
};

const BenchResult = struct {
    program: []const u8,
    compile_ms: u64,
    so_bytes: usize,
    entries: usize,
};

pub fn runBench(init: std.process.Init, argv0: []const u8, args: BenchArgs) !void {
    if (args.explicit_rounds) {
        try runBenchWithWarmRows(init, argv0, args);
        return;
    }

    var results: [bench_fixtures.len]BenchResult = undefined;
    for (bench_fixtures, 0..) |fixture, index| {
        results[index] = try runBenchFixture(init, argv0, fixture);
    }

    var table = std.Io.Writer.Allocating.init(init.gpa);
    errdefer table.deinit();
    try table.writer.writeAll("| program | compile_ms | so_bytes | entries |\n");
    try table.writer.writeAll("| --- | ---: | ---: | ---: |\n");
    for (results) |result| {
        try table.writer.print(
            "| {s} | {d} | {d} | {d} |\n",
            .{ result.program, result.compile_ms, result.so_bytes, result.entries },
        );
    }
    const bytes = try table.toOwnedSlice();
    defer init.gpa.free(bytes);
    try writeStdout(init.io, bytes);
}

fn runBenchWithWarmRows(init: std.process.Init, argv0: []const u8, args: BenchArgs) !void {
    var table = std.Io.Writer.Allocating.init(init.gpa);
    errdefer table.deinit();
    try table.writer.writeAll("| program | mode | compile_ms | so_bytes | entries |\n");
    try table.writer.writeAll("| --- | --- | ---: | ---: | ---: |\n");

    for (bench_fixtures) |fixture| {
        const cold = try runBenchFixture(init, argv0, fixture);
        try writeBenchModeRow(&table, cold, "cold");

        var warmup_index: usize = 0;
        while (warmup_index < args.warmup_rounds) : (warmup_index += 1) {
            _ = try runBenchFixture(init, argv0, fixture);
        }

        if (args.rounds > 0) {
            const warm_results = try init.gpa.alloc(BenchResult, args.rounds);
            defer init.gpa.free(warm_results);
            for (warm_results) |*warm_result| {
                warm_result.* = try runBenchFixture(init, argv0, fixture);
            }
            try writeBenchModeRow(&table, try medianBenchResult(init.gpa, warm_results), "warm-median");
        }
    }

    const bytes = try table.toOwnedSlice();
    defer init.gpa.free(bytes);
    try writeStdout(init.io, bytes);
}

fn writeBenchModeRow(table: *std.Io.Writer.Allocating, result: BenchResult, mode: []const u8) !void {
    try table.writer.print(
        "| {s} | {s} | {d} | {d} | {d} |\n",
        .{ result.program, mode, result.compile_ms, result.so_bytes, result.entries },
    );
}

fn medianBenchResult(allocator: std.mem.Allocator, results: []const BenchResult) !BenchResult {
    if (results.len == 0) return error.UnsupportedArgs;
    const sorted = try allocator.dupe(BenchResult, results);
    defer allocator.free(sorted);
    std.mem.sort(BenchResult, sorted, {}, struct {
        fn lessThan(_: void, a: BenchResult, b: BenchResult) bool {
            return a.compile_ms < b.compile_ms;
        }
    }.lessThan);
    return sorted[sorted.len / 2];
}

fn runBenchFixture(init: std.process.Init, argv0: []const u8, fixture: BenchFixture) !BenchResult {
    const bench_program = try std.fmt.allocPrint(init.gpa, "bench_{s}", .{fixture.program});
    defer init.gpa.free(bench_program);

    const bench_input_name = try std.fmt.allocPrint(init.gpa, "{s}.ml", .{bench_program});
    defer init.gpa.free(bench_input_name);

    const so_path = try build_cmd.sourceMapOutputPath(init.gpa, bench_program, ".so");
    defer init.gpa.free(so_path);

    const map_path = try build_cmd.sourceMapOutputPath(init.gpa, bench_program, ".map");
    defer init.gpa.free(map_path);

    cleanupBenchArtifact(init.io, so_path);
    cleanupBenchArtifact(init.io, map_path);
    defer cleanupBenchArtifact(init.io, so_path);
    defer cleanupBenchArtifact(init.io, map_path);

    const start_ns = try monotonicNanos();
    var frontend_result = pipeline.runFrontendFromArgv0WithOptions(
        init.gpa,
        init.io,
        init.minimal.environ,
        argv0,
        fixture.path,
        .{},
    ) catch |err| {
        if (cmd_common.shouldPrintGenericFrontendFailure(err)) {
            try writeStderr(init.io, "error: failed to run zxc-frontend subprocess\n");
        }
        std.process.exit(1);
    };
    defer frontend_result.deinit();

    switch (frontend_result) {
        .success => |parsed| {
            const bpf_target = target_registry.lookupByCliName("bpf") orelse return error.UnsupportedBuildTarget;
            try build_cmd.buildBpf(init, bpf_target, parsed.module, .{
                .target = "bpf",
                .keep_zig = false,
                .input_file = bench_input_name,
                .output_path = so_path,
                .srcmap = true,
                .quiet = true,
                .diagnostics = .{},
            });
        },
        .failed => |code| std.process.exit(if (code == 0) 1 else code),
    }
    const end_ns = try monotonicNanos();

    const so_bytes = try readFileSize(init, so_path);
    const entries = try readSourceMapEntryCount(init, map_path);

    return .{
        .program = fixture.program,
        .compile_ms = elapsedMillis(start_ns, end_ns),
        .so_bytes = so_bytes,
        .entries = entries,
    };
}

fn cleanupBenchArtifact(io: Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn readFileSize(init: std.process.Init, path: []const u8) !usize {
    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(128 * 1024 * 1024)) catch |err| {
        try writeStderr(init.io, "error: failed to read benchmark artifact ");
        try writeStderr(init.io, path);
        try writeStderr(init.io, ": ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    defer init.gpa.free(bytes);
    return bytes.len;
}

fn readSourceMapEntryCount(init: std.process.Init, path: []const u8) !usize {
    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(16 * 1024 * 1024)) catch |err| {
        try writeStderr(init.io, "error: failed to read benchmark source map ");
        try writeStderr(init.io, path);
        try writeStderr(init.io, ": ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    defer init.gpa.free(bytes);

    var parsed = driver_srcmap.deserializeJson(init.gpa, bytes) catch |err| {
        try writeStderr(init.io, "error: invalid benchmark source map ");
        try writeStderr(init.io, path);
        try writeStderr(init.io, ": ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    defer parsed.deinit();

    return parsed.value.entries.len;
}

fn monotonicNanos() !u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.ClockFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedMillis(start_ns: u64, end_ns: u64) u64 {
    if (end_ns <= start_ns) return 0;
    const elapsed_ns = end_ns - start_ns;
    return @divTrunc(elapsed_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
}
