//! WASM build orchestration for emitted Zig source.
//!
//! RESPONSIBILITIES:
//! - Materialise the WASM runtime shim next to generated `out/program.zig`.
//! - Invoke Zig for `wasm32-freestanding` module output.
//! - Keep the WASM path isolated from native and Solana/BPF tooling.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const WasmBuildOptions = struct {
    wasm_entry_path: []const u8 = "out/wasm_entry.zig",
    output_path: []const u8,
    quiet: bool = false,
};

fn appendWasmBuildArgs(
    allocator: Allocator,
    argv: *std.ArrayList([]const u8),
    options: WasmBuildOptions,
) !void {
    const root_module_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{options.wasm_entry_path});
    errdefer allocator.free(root_module_arg);
    const emit_bin_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{options.output_path});
    errdefer allocator.free(emit_bin_arg);

    try argv.appendSlice(allocator, &.{
        "zig",
        "build-exe",
        "-target",
        "wasm32-freestanding",
        "-O",
        "ReleaseSmall",
        "-fno-entry",
        "--export=entrypoint",
    });
    try argv.append(allocator, root_module_arg);
    try argv.append(allocator, emit_bin_arg);
}

pub fn buildWasm(allocator: Allocator, io: Io, options: WasmBuildOptions) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer {
        for (argv.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-Mroot=") or std.mem.startsWith(u8, arg, "-femit-bin=")) {
                allocator.free(arg);
            }
        }
        argv.deinit(allocator);
    }

    try appendWasmBuildArgs(allocator, &argv, options);

    const completed = try std.process.run(allocator, io, .{ .argv = argv.items });
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    const success = switch (completed.term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };

    if (!options.quiet or !success) {
        if (completed.stdout.len > 0) try writeStdout(io, completed.stdout);
        if (completed.stderr.len > 0) try writeStderr(io, completed.stderr);
    }

    if (success) return;
    return error.WasmBuildFailed;
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

test "wasm build argv targets freestanding module output and excludes native or Solana flags" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).empty;
    defer {
        for (argv.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-Mroot=") or std.mem.startsWith(u8, arg, "-femit-bin=")) {
                allocator.free(arg);
            }
        }
        argv.deinit(allocator);
    }

    try appendWasmBuildArgs(allocator, &argv, .{
        .wasm_entry_path = "out/wasm_entry.zig",
        .output_path = "/tmp/mtf1-smoke.wasm",
    });

    try std.testing.expectEqualStrings("zig", argv.items[0]);
    try std.testing.expectEqualStrings("build-exe", argv.items[1]);
    try std.testing.expectEqualStrings("-target", argv.items[2]);
    try std.testing.expectEqualStrings("wasm32-freestanding", argv.items[3]);

    const joined = try std.mem.join(allocator, " ", argv.items);
    defer allocator.free(joined);

    try std.testing.expect(std.mem.indexOf(u8, joined, "-femit-bin=/tmp/mtf1-smoke.wasm") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-Mroot=out/wasm_entry.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-fno-entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--export=entrypoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "solana-zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "sbf-solana") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "bpf.ld") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "vendored_sdk") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "out/native_entry.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "out/bpf_entry.zig") == null);
}
