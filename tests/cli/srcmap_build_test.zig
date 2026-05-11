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

fn commandExecutable(io: Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    }
    return true;
}

fn llvmObjdumpPath(io: Io) ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/llvm@20/bin/llvm-objdump",
        "llvm-objdump",
        "/usr/bin/objdump",
        "objdump",
    };
    for (candidates) |path| {
        if (commandExecutable(io, path)) return path;
    }
    return null;
}

fn llvmReadelfPath(io: Io) ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/llvm@20/bin/llvm-readelf",
        "llvm-readelf",
        "/usr/bin/readelf",
        "readelf",
    };
    for (candidates) |path| {
        if (commandExecutable(io, path)) return path;
    }
    return null;
}

fn hasSolanaZigEnabled() bool {
    const value = std.c.getenv("SOLANA_ZIG") orelse return false;
    const text = std.mem.span(value);
    return text.len > 0 and !std.mem.eql(u8, text, "0");
}

fn findSrcmapSectionLine(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, ".zxcaml.srcmap") != null) return line;
    }
    return null;
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

test "cli: bpf build embeds non-allocated source-map ELF section" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(io, so_path) catch {};
    cwd.deleteFile(io, map_path) catch {};
    try buildHackathonGreet(allocator, io);
    try std.testing.expect(fileExists(io, so_path));
    try std.testing.expect(fileExists(io, map_path));

    const objdump_path = llvmObjdumpPath(io) orelse {
        // Keep this test runnable on environments without LLVM objdump tooling.
        return;
    };
    const objdump_argv = [_][]const u8{ objdump_path, "-h", so_path };
    const objdump = try runCommand(allocator, io, &objdump_argv);
    defer allocator.free(objdump.stdout);
    defer allocator.free(objdump.stderr);
    try expectCommandSuccess(objdump, "llvm-objdump -h out/hackathon_greet.so");

    const section_line = findSrcmapSectionLine(objdump.stdout) orelse {
        if (hasSolanaZigEnabled()) return;
        std.debug.print(
            "llvm-objdump did not list .zxcaml.srcmap\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ objdump.stdout, objdump.stderr },
        );
        return error.MissingSrcmapElfSection;
    };
    try std.testing.expect(std.mem.indexOf(u8, section_line, "ALLOC") == null);

    if (llvmReadelfPath(io)) |readelf_path| {
        const readelf_argv = [_][]const u8{ readelf_path, "-S", so_path };
        const readelf = try runCommand(allocator, io, &readelf_argv);
        defer allocator.free(readelf.stdout);
        defer allocator.free(readelf.stderr);
        try expectCommandSuccess(readelf, "llvm-readelf -S out/hackathon_greet.so");

        const readelf_section_line = findSrcmapSectionLine(readelf.stdout) orelse {
            if (hasSolanaZigEnabled()) return;
            std.debug.print(
                "llvm-readelf did not list .zxcaml.srcmap\nstderr:\n{s}\nstderr:\n{s}\n",
                .{ readelf.stdout, readelf.stderr },
            );
            return error.MissingSrcmapElfSection;
        };
        try std.testing.expect(std.mem.indexOf(u8, readelf_section_line, "PROGBITS") != null);
        try std.testing.expect(std.mem.indexOf(u8, readelf_section_line, "ALLOC") == null);
    }
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
