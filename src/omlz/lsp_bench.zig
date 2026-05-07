//! CLI wrapper for the LSP latency probe.
//!
//! The actual stdio JSON-RPC benchmark lives in `tests/lsp/lsp_bench.zig` and
//! is installed as `zig-out/bin/lsp-bench`.  This module keeps the user-facing
//! `omlz lsp-bench` surface small: parse public flags, map threshold flags to
//! the probe's environment variables, run the installed sibling executable, and
//! forward its output and exit status unchanged.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const env_p50_threshold = "ZXCAML_LSP_LATENCY_P50_MS";
const env_p99_threshold = "ZXCAML_LSP_LATENCY_P99_MS";

const Args = struct {
    warmup: ?[]const u8 = null,
    rounds: ?[]const u8 = null,
    p50: ?[]const u8 = null,
    p99: ?[]const u8 = null,
    json: bool = false,
};

pub fn writeHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz lsp-bench [--warmup N] [--rounds K] [--p50 MS] [--p99 MS] [--json]
        \\
        \\Runs the Zig LSP latency probe against zig-out/bin/omlz-lsp and
        \\prints samples_ms plus p50/p99/min/max latency statistics.
        \\
        \\Flags:
        \\  --warmup N   Number of initial samples to discard before percentiles (default: 3)
        \\  --rounds K   Total diagnostics samples to collect, including warmup (default: 10)
        \\  --p50 MS     p50 latency threshold in milliseconds (default: 350)
        \\  --p99 MS     p99 latency threshold in milliseconds (default: 800)
        \\  --json       Emit one machine-readable JSON object to stdout
        \\  --help       Show this help text
        \\
        \\Environment:
        \\  ZXCAML_LSP_LATENCY_P50_MS   Default p50 threshold override.
        \\  ZXCAML_LSP_LATENCY_P99_MS   Default p99 threshold override.
        \\
    );
}

pub fn run(init: std.process.Init, argv0: []const u8, raw_args: []const []const u8) !void {
    const allocator = init.arena.allocator();
    const args = parseArgs(raw_args) catch |err| switch (err) {
        error.HelpRequested => {
            try writeHelp(init.io);
            return;
        },
        else => {
            try writeStderr(init.io, "error: unsupported lsp-bench option; run `omlz lsp-bench --help` for usage.\n");
            std.process.exit(2);
        },
    };

    var env_map = try std.process.Environ.createMap(init.minimal.environ, allocator);
    defer env_map.deinit();
    if (args.p50) |threshold| try env_map.put(env_p50_threshold, threshold);
    if (args.p99) |threshold| try env_map.put(env_p99_threshold, threshold);

    const bench_path = try siblingBenchPath(allocator, argv0);
    var bench_argv = std.ArrayList([]const u8).empty;
    defer bench_argv.deinit(allocator);
    try bench_argv.append(allocator, bench_path);
    if (args.warmup) |warmup| {
        try bench_argv.append(allocator, "--warmup");
        try bench_argv.append(allocator, warmup);
    }
    if (args.rounds) |rounds| {
        try bench_argv.append(allocator, "--rounds");
        try bench_argv.append(allocator, rounds);
    }
    if (args.json) try bench_argv.append(allocator, "--json");

    const completed = try std.process.run(allocator, init.io, .{
        .argv = bench_argv.items,
        .environ_map = &env_map,
    });
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    if (completed.stdout.len > 0) try writeStdout(init.io, completed.stdout);
    if (completed.stderr.len > 0) try writeStderr(init.io, completed.stderr);

    const code = exitCode(completed.term);
    if (code != 0) std.process.exit(code);
}

fn parseArgs(raw_args: []const []const u8) !Args {
    var args: Args = .{};
    var index: usize = 2;
    while (index < raw_args.len) : (index += 1) {
        const arg = raw_args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            args.warmup = raw_args[index];
        } else if (std.mem.startsWith(u8, arg, "--warmup=")) {
            args.warmup = arg["--warmup=".len..];
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            args.rounds = raw_args[index];
        } else if (std.mem.startsWith(u8, arg, "--rounds=")) {
            args.rounds = arg["--rounds=".len..];
        } else if (std.mem.eql(u8, arg, "--p50")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            args.p50 = raw_args[index];
        } else if (std.mem.startsWith(u8, arg, "--p50=")) {
            args.p50 = arg["--p50=".len..];
        } else if (std.mem.eql(u8, arg, "--p99")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            args.p99 = raw_args[index];
        } else if (std.mem.startsWith(u8, arg, "--p99=")) {
            args.p99 = arg["--p99=".len..];
        } else if (std.mem.eql(u8, arg, "--json")) {
            args.json = true;
        } else {
            return error.UnsupportedArgs;
        }
    }
    return args;
}

fn siblingBenchPath(allocator: Allocator, argv0: []const u8) ![]const u8 {
    const dirname = std.fs.path.dirname(argv0) orelse "zig-out/bin";
    return std.fs.path.join(allocator, &.{ dirname, "lsp-bench" });
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

fn writeStderr(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}
