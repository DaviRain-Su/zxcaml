//! BPF build orchestration for emitted Zig source.
//!
//! RESPONSIBILITIES:
//! - Materialise the BPF runtime shim next to generated `out/program.zig`.
//! - Drive Zig's BPF bitcode emission step with the ADR-012 flags.
//! - Invoke `sbpf-linker` with the ADR-013 default SBPF CPU and diagnostics.
//! - Preserve an `entrypoint` symbol-table label for local objdump evidence.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// ADR-013: mainnet-compatible SBPF v2 is the default; v3 will be opt-in later.
const default_sbpf_cpu = "v2";
const pinned_sbpf_linker_version = "0.1.8";

/// Options for the Solana BPF build path.
pub const BpfBuildOptions = struct {
    bpf_entry_path: []const u8 = "out/bpf_entry.zig",
    bitcode_path: []const u8 = "out/program.bc",
    output_path: []const u8,
    environ: std.process.Environ,
};

const RuntimeFile = struct {
    src_path: []const u8,
    out_path: []const u8,
};

const runtime_files = [_]RuntimeFile{
    .{ .src_path = "runtime/zig/arena.zig", .out_path = "out/runtime/arena.zig" },
    .{ .src_path = "runtime/zig/panic.zig", .out_path = "out/runtime/panic.zig" },
    .{ .src_path = "runtime/zig/prelude.zig", .out_path = "out/runtime/prelude.zig" },
    .{ .src_path = "runtime/zig/bpf_entry.zig", .out_path = "out/bpf_entry.zig" },
};

/// Builds a Solana-loadable SBPF ELF shared object from generated Zig source.
pub fn buildBpf(allocator: Allocator, io: Io, options: BpfBuildOptions) !void {
    try materializeRuntime(allocator, io);

    const bitcode_arg = try std.fmt.allocPrint(allocator, "-femit-llvm-bc={s}", .{options.bitcode_path});
    defer allocator.free(bitcode_arg);

    const zig_argv = [_][]const u8{
        "zig",
        "build-lib",
        "-target",
        "bpfel-freestanding",
        "-O",
        "ReleaseSmall",
        "-fno-stack-check",
        "-fno-PIC",
        "-fno-PIE",
        "-fstrip",
        bitcode_arg,
        "-fno-emit-bin",
        options.bpf_entry_path,
    };

    try runAndForward(allocator, io, &zig_argv, null, error.BpfZigBuildFailed);

    var env_map = try makeLinkerEnv(allocator, io, options.environ);
    defer env_map.deinit();

    const linker_argv = [_][]const u8{
        "sbpf-linker",
        "--cpu",
        default_sbpf_cpu,
        "--export",
        "entrypoint",
        "-o",
        options.output_path,
        options.bitcode_path,
    };

    runAndForward(allocator, io, &linker_argv, &env_map, error.SbpfLinkFailed) catch |err| switch (err) {
        error.FileNotFound => {
            try writeMissingSbpfLinkerDiagnostic(io);
            return error.SbpfLinkerMissing;
        },
        else => |e| return e,
    };

    const objcopy = try findLlvmObjcopy(allocator, io);
    defer allocator.free(objcopy);

    const objcopy_argv = [_][]const u8{
        objcopy,
        "--add-symbol",
        "entrypoint=.text:0,global,function",
        options.output_path,
    };
    try runAndForward(allocator, io, &objcopy_argv, null, error.BpfObjcopyFailed);
}

fn materializeRuntime(allocator: Allocator, io: Io) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/runtime");

    inline for (runtime_files) |file| {
        const contents = try cwd.readFileAlloc(io, file.src_path, allocator, .limited(128 * 1024));
        defer allocator.free(contents);

        try cwd.writeFile(io, .{
            .sub_path = file.out_path,
            .data = contents,
            .flags = .{ .truncate = true },
        });
    }
}

fn runAndForward(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    failure: anyerror,
) !void {
    const completed = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = environ_map,
    });
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    if (completed.stdout.len > 0) try writeStdout(io, completed.stdout);
    if (completed.stderr.len > 0) try writeStderr(io, completed.stderr);

    switch (completed.term) {
        .exited => |code| {
            if (code == 0) return;
            return failure;
        },
        .signal, .stopped, .unknown => return failure,
    }
}

fn makeLinkerEnv(allocator: Allocator, io: Io, environ: std.process.Environ) !std.process.Environ.Map {
    var env_map = try std.process.Environ.createMap(environ, allocator);
    errdefer env_map.deinit();

    if (builtin.os.tag == .macos and env_map.get("DYLD_FALLBACK_LIBRARY_PATH") == null) {
        if (try detectHomebrewLlvm20Lib(allocator, io)) |llvm_lib| {
            defer allocator.free(llvm_lib);
            try env_map.put("DYLD_FALLBACK_LIBRARY_PATH", llvm_lib);
        }
    }

    return env_map;
}

fn detectHomebrewLlvm20Lib(allocator: Allocator, io: Io) !?[]const u8 {
    if (builtin.os.tag != .macos) return null;

    const prefix = try detectHomebrewLlvm20Prefix(allocator, io) orelse return null;
    defer allocator.free(prefix);

    const llvm_lib = try std.fs.path.join(allocator, &.{ prefix, "lib" });
    return @as([]const u8, llvm_lib);
}

fn findLlvmObjcopy(allocator: Allocator, io: Io) ![]const u8 {
    if (builtin.os.tag == .macos) {
        if (try detectHomebrewLlvm20Prefix(allocator, io)) |prefix| {
            defer allocator.free(prefix);
            const candidate = try std.fs.path.join(allocator, &.{ prefix, "bin", "llvm-objcopy" });
            errdefer allocator.free(candidate);
            if (isExecutable(io, candidate)) return candidate;
            allocator.free(candidate);
        }
    }

    return allocator.dupe(u8, "llvm-objcopy");
}

fn detectHomebrewLlvm20Prefix(allocator: Allocator, io: Io) !?[]const u8 {
    if (builtin.os.tag != .macos) return null;

    const argv = [_][]const u8{ "brew", "--prefix", "llvm@20" };
    const completed = std.process.run(allocator, io, .{ .argv = &argv }) catch return null;
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    switch (completed.term) {
        .exited => |code| if (code != 0) return null,
        .signal, .stopped, .unknown => return null,
    }

    const prefix = std.mem.trim(u8, completed.stdout, " \t\r\n");
    if (prefix.len == 0) return null;
    return try allocator.dupe(u8, prefix);
}

fn isExecutable(io: Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

fn writeMissingSbpfLinkerDiagnostic(io: Io) !void {
    try writeStderr(io, "error: sbpf-linker not found on PATH; ZxCaml requires sbpf-linker ");
    try writeStderr(io, pinned_sbpf_linker_version);
    try writeStderr(io, " per ADR-012. Run ./init.sh to install the pinned BPF toolchain.\n");
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

test "BPF linker argv pins ADR-013 default SBPF v2 CPU and entrypoint export" {
    const linker_argv = [_][]const u8{
        "sbpf-linker",
        "--cpu",
        default_sbpf_cpu,
        "--export",
        "entrypoint",
        "-o",
        "/tmp/m0_zero.so",
        "out/program.bc",
    };

    try std.testing.expectEqualStrings("sbpf-linker", linker_argv[0]);
    try std.testing.expectEqualStrings("--cpu", linker_argv[1]);
    try std.testing.expectEqualStrings("v2", linker_argv[2]);
    try std.testing.expectEqualStrings("--export", linker_argv[3]);
    try std.testing.expectEqualStrings("entrypoint", linker_argv[4]);
}
