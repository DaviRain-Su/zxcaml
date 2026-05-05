//! CLI integration tests for `omlz unmap`.
//!
//! RESPONSIBILITIES:
//! - Build the canonical hackathon greet BPF artifact with source maps enabled.
//! - Assert reverse lookup works from both the JSON sidecar and embedded ELF section.
//! - Assert approximate fallback and clear error behavior.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli_options = @import("cli_options");
const srcmap = @import("srcmap");

const map_path = "out/hackathon_greet.map";
const so_path = "out/hackathon_greet.so";

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
        "-o",
        so_path,
    };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectCommandSuccess(result, "omlz build --target=bpf examples/hackathon_greet.ml");
}

fn runUnmap(allocator: Allocator, io: Io, source_flag: []const u8, source_path: []const u8, pc: u32) !CommandResult {
    const pc_arg = try std.fmt.allocPrint(allocator, "0x{x}", .{pc});
    defer allocator.free(pc_arg);
    const argv = [_][]const u8{
        cli_options.omlz_bin,
        "unmap",
        source_flag,
        source_path,
        "--pc",
        pc_arg,
    };
    return runCommand(allocator, io, &argv);
}

test "cli: unmap accepts --help" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{ cli_options.omlz_bin, "unmap", "--help" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try expectCommandSuccess(result, "omlz unmap --help");
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--pc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--map") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--so") != null);
}

fn renderedLocation(entry: srcmap.Entry) []const u8 {
    _ = entry;
    return "examples/hackathon_greet.ml:";
}

test "cli: unmap resolves sidecar and embedded source maps" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, map_path) catch {};
    cwd.deleteFile(io, so_path) catch {};
    try buildHackathonGreet(allocator, io);

    const map_bytes = try cwd.readFileAlloc(io, map_path, allocator, .limited(1024 * 1024));
    defer allocator.free(map_bytes);
    var parsed = try srcmap.deserializeJson(allocator, map_bytes);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.entries.len > 0);

    const first = parsed.value.entries[0];
    const exact_map = try runUnmap(allocator, io, "--map", map_path, first.pc);
    defer allocator.free(exact_map.stdout);
    defer allocator.free(exact_map.stderr);
    try expectCommandSuccess(exact_map, "omlz unmap --map");
    try std.testing.expect(std.mem.indexOf(u8, exact_map.stdout, renderedLocation(first)) != null);
    try std.testing.expect(!std.mem.startsWith(u8, exact_map.stdout, "~"));

    const exact_so = try runUnmap(allocator, io, "--so", so_path, first.pc);
    defer allocator.free(exact_so.stdout);
    defer allocator.free(exact_so.stderr);
    try expectCommandSuccess(exact_so, "omlz unmap --so");
    try std.testing.expectEqualStrings(exact_map.stdout, exact_so.stdout);

    const last = parsed.value.entries[parsed.value.entries.len - 1];
    const approximate = try runUnmap(allocator, io, "--map", map_path, last.pc + 1);
    defer allocator.free(approximate.stdout);
    defer allocator.free(approximate.stderr);
    try expectCommandSuccess(approximate, "omlz unmap approximate --map");
    try std.testing.expect(std.mem.startsWith(u8, approximate.stdout, "~"));
    try std.testing.expect(std.mem.indexOf(u8, approximate.stdout, renderedLocation(last)) != null);

    const empty_map_path = "/tmp/zxcaml_unmap_empty.map";
    try cwd.writeFile(io, .{
        .sub_path = empty_map_path,
        .data = "{\"version\":1,\"program\":\"empty\",\"entries\":[]}",
        .flags = .{ .truncate = true },
    });
    defer cwd.deleteFile(io, empty_map_path) catch {};

    const missing = try runUnmap(allocator, io, "--map", empty_map_path, 0);
    defer allocator.free(missing.stdout);
    defer allocator.free(missing.stderr);
    try std.testing.expect(missing.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "error: no source map entry for pc=0x0") != null);
}
