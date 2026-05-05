//! Source-map determinism property test.
//!
//! Follows the property-suite convention under `tests/property/`: invoke the
//! installed `omlz` binary as a subprocess from the repository root, then assert
//! a project invariant.  Here the invariant is that repeated BPF builds of the
//! same input produce byte-identical source-map JSON.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const srcmap_det_options = @import("srcmap_det_options");

const map_path = "out/hackathon_greet.map";
const first_tmp = "/tmp/zxcaml_srcmap_determinism_first.map";
const second_tmp = "/tmp/zxcaml_srcmap_determinism_second.map";

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
        srcmap_det_options.omlz_bin,
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

test "srcmap determinism: hackathon_greet map is byte-identical across builds" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, map_path) catch {};
    cwd.deleteFile(io, first_tmp) catch {};
    cwd.deleteFile(io, second_tmp) catch {};

    try buildHackathonGreet(allocator, io);
    try copyFile(allocator, io, map_path, first_tmp);

    cwd.deleteFile(io, map_path) catch {};
    try buildHackathonGreet(allocator, io);
    try copyFile(allocator, io, map_path, second_tmp);

    const cmp_argv = [_][]const u8{ "cmp", first_tmp, second_tmp };
    const cmp_result = try runCommand(allocator, io, &cmp_argv);
    defer allocator.free(cmp_result.stdout);
    defer allocator.free(cmp_result.stderr);
    try expectCommandSuccess(cmp_result, "cmp source-map outputs");
}
