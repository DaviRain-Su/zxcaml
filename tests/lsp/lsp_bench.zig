const std = @import("std");
const Io = std.Io;

const default_warmup = 3;
const default_rounds = 10;
const default_doc_lines = 100;
const lsp_bin = "zig-out/bin/omlz-lsp";
const bench_uri = "file:///tmp/zxcaml_lsp_bench.ml";

const Config = struct {
    warmup: usize = default_warmup,
    rounds: usize = default_rounds,
};

const Stats = struct {
    p50_ms: u64,
    p99_ms: u64,
    min_ms: u64,
    max_ms: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    const config = parseArgs(args) catch |err| switch (err) {
        error.HelpRequested => {
            emitHelp();
            return;
        },
        else => return err,
    };
    validateConfig(config) catch |err| switch (err) {
        error.NotEnoughMeasuredSamples => {
            std.debug.print(
                "error: --rounds ({d}) must be greater than --warmup ({d}); no post-warmup samples would remain\n",
                .{ config.rounds, config.warmup },
            );
            std.process.exit(1);
        },
    };

    const samples_ms = try allocator.alloc(u64, config.rounds);
    for (samples_ms, 0..) |*sample, round_index| {
        sample.* = try runDiagnosticsRound(init.io, allocator, round_index);
    }

    const stats = try computeStatsDiscardingWarmup(allocator, samples_ms, config.warmup);
    emitSummary(config, samples_ms, stats);
}

fn parseArgs(args: []const []const u8) !Config {
    var config: Config = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            index += 1;
            if (index >= args.len) return error.MissingWarmupValue;
            config.warmup = try parseUsizeArg(args[index]);
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            index += 1;
            if (index >= args.len) return error.MissingRoundsValue;
            config.rounds = try parseUsizeArg(args[index]);
        } else {
            return error.UnknownArgument;
        }
    }
    return config;
}

fn parseUsizeArg(value: []const u8) !usize {
    return std.fmt.parseInt(usize, value, 10) catch error.InvalidIntegerArgument;
}

fn validateConfig(config: Config) !void {
    if (config.rounds <= config.warmup) return error.NotEnoughMeasuredSamples;
}

fn emitHelp() void {
    std.debug.print(
        \\Usage: lsp-bench [--warmup N] [--rounds K]
        \\
        \\Options:
        \\  --warmup N   Number of initial samples to discard before percentiles (default: 3)
        \\  --rounds K   Total diagnostics samples to collect, including warmup (default: 10)
        \\  --help       Show this help text
        \\
    , .{});
}

fn runDiagnosticsRound(io: Io, allocator: std.mem.Allocator, round_index: usize) !u64 {
    const clean_text = try makeDocument(allocator, default_doc_lines, false);
    defer allocator.free(clean_text);
    const broken_text = try makeDocument(allocator, default_doc_lines, true);
    defer allocator.free(broken_text);

    var child = try std.process.spawn(io, .{
        .argv = &.{lsp_bin},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_writer_file: Io.File.Writer = .init(child.stdin.?, io, &stdin_buffer);
    const stdin_writer = &stdin_writer_file.interface;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_reader_file: Io.File.Reader = .init(child.stdout.?, io, &stdout_buffer);
    const stdout_reader = &stdout_reader_file.interface;

    try sendInitialize(allocator, stdin_writer);
    try recvResponse(allocator, stdout_reader, 1);
    try sendInitialized(allocator, stdin_writer);

    try sendDidOpen(allocator, stdin_writer, clean_text);
    try recvPublishDiagnostics(allocator, stdout_reader, bench_uri, false);

    const started = Io.Clock.Timestamp.now(io, .awake);
    try sendDidChange(allocator, stdin_writer, broken_text, @as(u32, @intCast(round_index + 2)));
    try recvPublishDiagnostics(allocator, stdout_reader, bench_uri, true);
    const elapsed_ms = elapsedMs(started, Io.Clock.Timestamp.now(io, .awake));

    try sendShutdown(allocator, stdin_writer);
    try recvResponse(allocator, stdout_reader, 2);
    try sendExit(allocator, stdin_writer);
    const term = try child.wait(io);
    if (exitCode(term) != 0) return error.LspServerExitedNonZero;

    return elapsed_ms;
}

fn sendInitialize(allocator: std.mem.Allocator, writer: *Io.Writer) !void {
    var body = Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    try body.writer.writeAll(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}
    );
    try writeFrame(writer, body.writer.buffered());
}

fn sendInitialized(allocator: std.mem.Allocator, writer: *Io.Writer) !void {
    var body = Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    try body.writer.writeAll(
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try writeFrame(writer, body.writer.buffered());
}

fn sendDidOpen(allocator: std.mem.Allocator, writer: *Io.Writer, text: []const u8) !void {
    var body = Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    try body.writer.writeAll(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":
    );
    try std.json.Stringify.value(bench_uri, .{}, &body.writer);
    try body.writer.writeAll(
        \\,"languageId":"ocaml","version":1,"text":
    );
    try std.json.Stringify.value(text, .{}, &body.writer);
    try body.writer.writeAll("}}}");
    try writeFrame(writer, body.writer.buffered());
}

fn sendDidChange(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    text: []const u8,
    version: u32,
) !void {
    var body = Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    try body.writer.writeAll(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":
    );
    try std.json.Stringify.value(bench_uri, .{}, &body.writer);
    try body.writer.print(",\"version\":{d}", .{version});
    try body.writer.writeAll("},\"contentChanges\":[{\"text\":");
    try std.json.Stringify.value(text, .{}, &body.writer);
    try body.writer.writeAll("}]}}");
    try writeFrame(writer, body.writer.buffered());
}

fn sendShutdown(allocator: std.mem.Allocator, writer: *Io.Writer) !void {
    var body = Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    try body.writer.writeAll(
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}
    );
    try writeFrame(writer, body.writer.buffered());
}

fn sendExit(allocator: std.mem.Allocator, writer: *Io.Writer) !void {
    var body = Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    try body.writer.writeAll(
        \\{"jsonrpc":"2.0","method":"exit","params":null}
    );
    try writeFrame(writer, body.writer.buffered());
}

fn writeFrame(writer: *Io.Writer, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

fn recvResponse(allocator: std.mem.Allocator, reader: *Io.Reader, id: i64) !void {
    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();
        const body = try readFrame(frame_allocator, reader);
        var parsed = try std.json.parseFromSlice(std.json.Value, frame_allocator, body, .{});
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const response_id = parsed.value.object.get("id") orelse continue;
        if (response_id == .integer and response_id.integer == id) {
            if (parsed.value.object.get("error")) |_| return error.LspErrorResponse;
            return;
        }
    }
}

fn recvPublishDiagnostics(
    allocator: std.mem.Allocator,
    reader: *Io.Reader,
    uri: []const u8,
    expect_error: bool,
) !void {
    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();
        const body = try readFrame(frame_allocator, reader);
        var parsed = try std.json.parseFromSlice(std.json.Value, frame_allocator, body, .{});
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const method = parsed.value.object.get("method") orelse continue;
        if (method != .string or !std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) continue;

        const params = objectField(parsed.value, "params") catch continue;
        const got_uri = stringField(params, "uri") catch continue;
        if (!std.mem.eql(u8, got_uri, uri)) continue;

        const diagnostics = arrayField(params, "diagnostics") catch return error.MissingDiagnostics;
        if (expect_error and diagnostics.items.len == 0) return error.ExpectedDiagnostics;
        if (!expect_error and diagnostics.items.len != 0) return error.UnexpectedDiagnostics;
        return;
    }
}

fn readFrame(allocator: std.mem.Allocator, reader: *Io.Reader) ![]u8 {
    const content_length = try readHeaders(reader);
    return try reader.readAlloc(allocator, content_length);
}

fn readHeaders(reader: *Io.Reader) !usize {
    var content_length: ?usize = null;

    while (true) {
        const raw_line = (reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.HeaderLineTooLong,
            error.ReadFailed => return error.ReadFailed,
        }) orelse return error.MalformedHeader;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) break;

        const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedHeader;
        const name = std.mem.trim(u8, line[0..colon_index], " \t");
        const value = std.mem.trim(u8, line[colon_index + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.MalformedContentLength;
        }
    }

    return content_length orelse error.MissingContentLength;
}

fn makeDocument(allocator: std.mem.Allocator, line_count: usize, broken: bool) ![]u8 {
    if (line_count == 0) return error.EmptyDocument;

    var out = Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    if (line_count == 1) {
        if (broken) {
            try out.writer.writeAll("let entrypoint _ = 1 + true\n");
        } else {
            try out.writer.writeAll("let entrypoint _ = 0\n");
        }
        return out.toOwnedSlice();
    }

    for (0..line_count - 1) |index| {
        try out.writer.print("let helper_{d} = {d}\n", .{ index, index });
    }
    if (broken) {
        try out.writer.writeAll("let entrypoint _ = 1 + true\n");
    } else {
        try out.writer.writeAll("let entrypoint _ = helper_0\n");
    }
    return out.toOwnedSlice();
}

fn computeStats(allocator: std.mem.Allocator, samples_ms: []const u64) !Stats {
    if (samples_ms.len == 0) return error.NoSamples;

    const sorted = try allocator.dupe(u64, samples_ms);
    defer allocator.free(sorted);
    std.mem.sort(u64, sorted, {}, lessThanU64);

    return .{
        .p50_ms = percentileNearestRank(sorted, 50),
        .p99_ms = percentileNearestRank(sorted, 99),
        .min_ms = sorted[0],
        .max_ms = sorted[sorted.len - 1],
    };
}

fn computeStatsDiscardingWarmup(
    allocator: std.mem.Allocator,
    samples_ms: []const u64,
    warmup: usize,
) !Stats {
    if (samples_ms.len <= warmup) return error.NotEnoughMeasuredSamples;
    return computeStats(allocator, samples_ms[warmup..]);
}

fn percentileNearestRank(sorted_samples_ms: []const u64, percentile: u8) u64 {
    std.debug.assert(sorted_samples_ms.len > 0);
    const rank = @max(@as(usize, 1), (@as(usize, percentile) * sorted_samples_ms.len + 99) / 100);
    return sorted_samples_ms[@min(rank, sorted_samples_ms.len) - 1];
}

fn lessThanU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn emitSummary(config: Config, samples_ms: []const u64, stats: Stats) void {
    std.debug.print("samples_ms=[", .{});
    for (samples_ms, 0..) |sample, index| {
        if (index != 0) std.debug.print(",", .{});
        std.debug.print("{d}", .{sample});
    }
    std.debug.print("]\n", .{});
    std.debug.print(
        "warmup={d} rounds={d} p50_ms={d} p99_ms={d} min_ms={d} max_ms={d}\n",
        .{ config.warmup, config.rounds, stats.p50_ms, stats.p99_ms, stats.min_ms, stats.max_ms },
    );
}

fn objectField(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.ExpectedObject;
    return value.object.get(name) orelse error.MissingField;
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    const field = try objectField(value, name);
    if (field != .string) return error.ExpectedString;
    return field.string;
}

fn arrayField(value: std.json.Value, name: []const u8) !std.json.Array {
    const field = try objectField(value, name);
    if (field != .array) return error.ExpectedArray;
    return field.array;
}

fn elapsedMs(started: Io.Clock.Timestamp, ended: Io.Clock.Timestamp) u64 {
    const elapsed_ns = @max(@as(i128, 0), @as(i128, started.durationTo(ended).raw.nanoseconds));
    const rounded_up = @divTrunc(elapsed_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return @intCast(rounded_up);
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

fn lineCount(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

test "small degenerate doc builder emits one-line entrypoint" {
    const doc = try makeDocument(std.testing.allocator, 1, false);
    defer std.testing.allocator.free(doc);

    try std.testing.expectEqual(@as(usize, 1), lineCount(doc));
    try std.testing.expect(std.mem.indexOf(u8, doc, "let entrypoint _ = 0") != null);
}

test "medium doc builder emits exactly 100 lines" {
    const doc = try makeDocument(std.testing.allocator, 100, false);
    defer std.testing.allocator.free(doc);

    try std.testing.expectEqual(@as(usize, 100), lineCount(doc));
    try std.testing.expect(std.mem.indexOf(u8, doc, "let helper_98 = 98") != null);
    try std.testing.expect(std.mem.endsWith(u8, doc, "let entrypoint _ = helper_0\n"));
}

test "large doc builder emits exactly 500 lines" {
    const doc = try makeDocument(std.testing.allocator, 500, true);
    defer std.testing.allocator.free(doc);

    try std.testing.expectEqual(@as(usize, 500), lineCount(doc));
    try std.testing.expect(std.mem.indexOf(u8, doc, "let helper_498 = 498") != null);
    try std.testing.expect(std.mem.endsWith(u8, doc, "let entrypoint _ = 1 + true\n"));
}

test "warmup defaults to three samples and rounds defaults to ten" {
    const config = try parseArgs(&.{"lsp-bench"});

    try std.testing.expectEqual(@as(usize, 3), config.warmup);
    try std.testing.expectEqual(@as(usize, 10), config.rounds);
}

test "custom warmup and rounds flags override defaults" {
    const config = try parseArgs(&.{ "lsp-bench", "--warmup", "5", "--rounds", "30" });

    try std.testing.expectEqual(@as(usize, 5), config.warmup);
    try std.testing.expectEqual(@as(usize, 30), config.rounds);
}

test "percentiles are computed from synthetic samples after warmup is discarded" {
    const samples = [_]u64{ 999, 1000, 10, 20, 30, 40, 50, 60, 70, 80 };
    const stats = try computeStatsDiscardingWarmup(std.testing.allocator, &samples, 2);

    try std.testing.expectEqual(@as(u64, 40), stats.p50_ms);
    try std.testing.expectEqual(@as(u64, 80), stats.p99_ms);
    try std.testing.expectEqual(@as(u64, 10), stats.min_ms);
    try std.testing.expectEqual(@as(u64, 80), stats.max_ms);
}

test "rounds less than warmup reports a clear error" {
    const samples = [_]u64{ 1, 2 };

    try std.testing.expectError(
        error.NotEnoughMeasuredSamples,
        computeStatsDiscardingWarmup(std.testing.allocator, &samples, 3),
    );
}
