//! CLI characterization tests for direct SBF build behavior.
//!
//! RESPONSIBILITIES:
//! - Verify `SOLANA_ZIG=0` fails fast with the documented diagnostic.
//! - Verify a custom `SOLANA_ZIG` wrapper sees the direct `solana-zig build-lib`
//!   argv shape used by `omlz build --target=bpf`.
//! - Verify generated Zig refreshes per source while sidecar source maps remain
//!   usable for `omlz unmap`, including the missing-`llvm-objcopy` warning path.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli_options = @import("cli_options");
const srcmap = @import("srcmap");

const characterization_dir_rel = ".zig-cache/characterization-tests";

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

fn fileExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn commandExecutable(allocator: Allocator, io: Io, path: []const u8) bool {
    const argv = [_][]const u8{ path, "--version" };
    const completed = std.process.run(allocator, io, .{ .argv = &argv }) catch return false;
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);
    return switch (completed.term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };
}

fn llvmObjcopyPath(allocator: Allocator, io: Io) ?[]const u8 {
    const candidates = [_][]const u8{
        "llvm-objcopy",
        "/opt/homebrew/bin/llvm-objcopy",
        "/usr/local/bin/llvm-objcopy",
        "/usr/bin/llvm-objcopy",
    };
    for (candidates) |path| {
        if (commandExecutable(allocator, io, path)) return path;
    }
    return null;
}

fn repoRoot(allocator: Allocator, io: Io) ![]u8 {
    const argv = [_][]const u8{ "pwd" };
    const result = try runCommand(allocator, io, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectCommandSuccess(result, "pwd");
    const trimmed = std.mem.trim(u8, result.stdout, "\r\n");
    return allocator.dupe(u8, trimmed);
}

fn runBpfBuild(
    allocator: Allocator,
    io: Io,
    env_args: []const []const u8,
    source_path: []const u8,
    output_path: []const u8,
) !CommandResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "env");
    try argv.appendSlice(allocator, env_args);
    try argv.appendSlice(allocator, &.{
        cli_options.omlz_bin,
        "build",
        "--target=bpf",
        "--keep-zig",
        source_path,
        "-o",
        output_path,
    });
    return runCommand(allocator, io, argv.items);
}

fn runUnmap(allocator: Allocator, io: Io, map_path: []const u8, pc: u32) !CommandResult {
    const pc_arg = try std.fmt.allocPrint(allocator, "0x{x}", .{pc});
    defer allocator.free(pc_arg);
    const argv = [_][]const u8{
        cli_options.omlz_bin,
        "unmap",
        "--map",
        map_path,
        "--pc",
        pc_arg,
    };
    return runCommand(allocator, io, &argv);
}

test "cli: bpf build rejects SOLANA_ZIG=0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expect(std.mem.startsWith(u8, characterization_dir_rel, ".zig-cache/"));

    const result = try runBpfBuild(
        allocator,
        io,
        &.{"SOLANA_ZIG=0"},
        "examples/solana_hello.ml",
        characterization_dir_rel ++ "/solana_zig_zero.so",
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "SOLANA_ZIG=0 is not supported") != null);
}

test "cli: custom SOLANA_ZIG wrapper records direct solana-zig argv" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, characterization_dir_rel);

    const root = try repoRoot(allocator, io);
    defer allocator.free(root);

    const wrapper_rel = characterization_dir_rel ++ "/solana_zig_wrapper.sh";
    const wrapper_log_rel = characterization_dir_rel ++ "/solana_zig_wrapper.log";
    const wrapper_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, wrapper_rel });
    defer allocator.free(wrapper_abs);
    const wrapper_log_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, wrapper_log_rel });
    defer allocator.free(wrapper_log_abs);

    const wrapper_script = try std.fmt.allocPrint(
        allocator,
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\log_path="{s}"
        \\: > "$log_path"
        \\printf 'cwd=%s\n' "$PWD" >> "$log_path"
        \\i=0
        \\for arg in "$@"; do
        \\  printf 'argv[%s]=%s\n' "$i" "$arg" >> "$log_path"
        \\  i=$((i + 1))
        \\done
        \\exec "./solana-zig/zig" "$@"
        \\
    , .{wrapper_log_abs});
    defer allocator.free(wrapper_script);

    try cwd.writeFile(io, .{
        .sub_path = wrapper_rel,
        .data = wrapper_script,
        .flags = .{ .truncate = true },
    });

    const chmod_argv = [_][]const u8{ "chmod", "+x", wrapper_rel };
    const chmod_result = try runCommand(allocator, io, &chmod_argv);
    defer allocator.free(chmod_result.stdout);
    defer allocator.free(chmod_result.stderr);
    try expectCommandSuccess(chmod_result, "chmod +x solana_zig_wrapper.sh");

    const env_assignment = try std.fmt.allocPrint(allocator, "SOLANA_ZIG={s}", .{wrapper_abs});
    defer allocator.free(env_assignment);

    const result = try runBpfBuild(
        allocator,
        io,
        &.{env_assignment},
        "examples/hackathon_greet.ml",
        characterization_dir_rel ++ "/hackathon_greet_wrapper.so",
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectCommandSuccess(result, "SOLANA_ZIG=<wrapper> omlz build --target=bpf examples/hackathon_greet.ml");

    try std.testing.expect(fileExists(io, wrapper_log_rel));
    const wrapper_log = try cwd.readFileAlloc(io, wrapper_log_rel, allocator, .limited(128 * 1024));
    defer allocator.free(wrapper_log);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_log, "argv[0]=build-lib") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_log, "-target") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_log, "sbf-solana") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_log, "-fPIC") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_log, "-fstrip") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_log, "-dynamic") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_log, "-fentry=entrypoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_log, "-Mroot=out/bpf_entry.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_log, "-Mvendored_sdk=out/runtime/sdk/root.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper_log, "-Msolana_sdk_m2=vendor/solana-program-sdk-zig/src/zxcaml_m2_root.zig") != null);

    const bpf_entry = try cwd.readFileAlloc(io, "out/bpf_entry.zig", allocator, .limited(128 * 1024));
    defer allocator.free(bpf_entry);
    try std.testing.expect(std.mem.indexOf(u8, bpf_entry, "@import(\"program.zig\")") != null);
}

test "cli: bpf build refreshes generated Zig and preserves sidecar unmap behavior" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, characterization_dir_rel);

    cwd.deleteFile(io, "out/solana_hello.map") catch {};
    cwd.deleteFile(io, "out/hackathon_greet.map") catch {};

    const hello_result = try runBpfBuild(
        allocator,
        io,
        &.{ "-u", "SOLANA_ZIG" },
        "examples/solana_hello.ml",
        characterization_dir_rel ++ "/solana_hello_default.so",
    );
    defer allocator.free(hello_result.stdout);
    defer allocator.free(hello_result.stderr);
    try expectCommandSuccess(hello_result, "env -u SOLANA_ZIG omlz build --target=bpf examples/solana_hello.ml");

    try std.testing.expect(fileExists(io, "out/solana_hello.map"));
    const first_program = try cwd.readFileAlloc(io, "out/program.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(first_program);

    const map_bytes = try cwd.readFileAlloc(io, "out/solana_hello.map", allocator, .limited(1024 * 1024));
    defer allocator.free(map_bytes);
    var parsed = try srcmap.deserializeJson(allocator, map_bytes);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.entries.len > 0);

    const first_entry = parsed.value.entries[0];
    const unmap_result = try runUnmap(allocator, io, "out/solana_hello.map", first_entry.pc);
    defer allocator.free(unmap_result.stdout);
    defer allocator.free(unmap_result.stderr);
    try expectCommandSuccess(unmap_result, "omlz unmap --map out/solana_hello.map");
    try std.testing.expect(std.mem.indexOf(u8, unmap_result.stdout, "examples/solana_hello.ml:") != null);

    if (llvmObjcopyPath(allocator, io) == null) {
        try std.testing.expect(std.mem.indexOf(u8, hello_result.stderr, "llvm-objcopy not found on PATH") != null);
        try std.testing.expect(std.mem.indexOf(u8, hello_result.stderr, ".map sidecar is still written") != null);
    }

    const greet_result = try runBpfBuild(
        allocator,
        io,
        &.{ "-u", "SOLANA_ZIG" },
        "examples/hackathon_greet.ml",
        characterization_dir_rel ++ "/hackathon_greet_default.so",
    );
    defer allocator.free(greet_result.stdout);
    defer allocator.free(greet_result.stderr);
    try expectCommandSuccess(greet_result, "env -u SOLANA_ZIG omlz build --target=bpf examples/hackathon_greet.ml");

    const second_program = try cwd.readFileAlloc(io, "out/program.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(second_program);
    try std.testing.expect(!std.mem.eql(u8, first_program, second_program));
}
