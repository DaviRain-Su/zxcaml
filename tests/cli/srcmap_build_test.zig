//! CLI integration tests for BPF source-map sidecar emission.
//!
//! RESPONSIBILITIES:
//! - Build the canonical hackathon greet example through `omlz build --target=bpf`.
//! - Assert default builds write deterministic `out/hackathon_greet.map` JSON.
//! - Assert `--no-srcmap` suppresses sidecar emission.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli_options = @import("cli_options");
const srcmap = @import("srcmap");

const map_path = "out/hackathon_greet.map";

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

fn expectCommandSuccess(result: CommandResult, argv_label: []const u8) !void {
    if (result.exit_code != 0) {
        std.debug.print(
            "{s} failed\nexit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ argv_label, result.exit_code, result.stdout, result.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

fn buildHackathonGreet(allocator: Allocator, io: Io) !void {
    const argv = [_][]const u8{
        cli_options.omlz_bin,
        "build",
        "--target=bpf",
        "examples/hackathon_greet.ml",
    };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectCommandSuccess(result, "omlz build --target=bpf examples/hackathon_greet.ml");
}

fn copyFile(allocator: Allocator, io: Io, src: []const u8, dst: []const u8) !void {
    const argv = [_][]const u8{ "cp", src, dst };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectCommandSuccess(result, "cp source map");
}

fn fileExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "cli: bpf build emits deterministic source-map sidecar" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, map_path) catch {};
    try buildHackathonGreet(allocator, io);
    try std.testing.expect(fileExists(io, map_path));

    const first_bytes = try cwd.readFileAlloc(io, map_path, allocator, .limited(1024 * 1024));
    defer allocator.free(first_bytes);
    var parsed = try srcmap.deserializeJson(allocator, first_bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hackathon_greet", parsed.value.program);
    try std.testing.expect(parsed.value.entries.len > 0);

    const first_tmp = "/tmp/zxcaml_hackathon_greet_first.map";
    const second_tmp = "/tmp/zxcaml_hackathon_greet_second.map";
    try copyFile(allocator, io, map_path, first_tmp);

    cwd.deleteFile(io, map_path) catch {};
    try buildHackathonGreet(allocator, io);
    try copyFile(allocator, io, map_path, second_tmp);

    const cmp_argv = [_][]const u8{ "cmp", first_tmp, second_tmp };
    const cmp_result = try runCommand(allocator, io, &cmp_argv);
    defer allocator.free(cmp_result.stdout);
    defer allocator.free(cmp_result.stderr);
    try expectCommandSuccess(cmp_result, "cmp /tmp/zxcaml_hackathon_greet_first.map /tmp/zxcaml_hackathon_greet_second.map");
}

test "cli: bpf build --no-srcmap suppresses sidecar" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, map_path) catch {};
    const argv = [_][]const u8{
        cli_options.omlz_bin,
        "build",
        "--target=bpf",
        "--no-srcmap",
        "examples/hackathon_greet.ml",
    };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectCommandSuccess(result, "omlz build --target=bpf --no-srcmap examples/hackathon_greet.ml");

    try std.testing.expect(!fileExists(io, map_path));
}
