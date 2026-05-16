//! Native build orchestration for emitted Zig source.
//!
//! RESPONSIBILITIES:
//! - Materialise runtime helper files next to generated `out/program.zig`.
//! - Drive `zig build-exe -O ReleaseSmall` for `--target=native`.
//! - Keep the native path independent from `sbpf-linker` and BPF tooling.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const target_manifest = @import("../target/manifest.zig");

/// Options for the developer-convenience native build path.
pub const NativeBuildOptions = struct {
    generated_zig_path: []const u8 = "out/program.zig",
    native_entry_path: []const u8 = "out/native_entry.zig",
    output_path: []const u8,
};

const vendored_sdk_runtime_root = "out/runtime/sdk/root.zig";
const vendored_solana_sdk_m2_root = "vendor/solana-program-sdk-zig/src/zxcaml_m2_root.zig";
const vendored_solana_program_sdk_root = "runtime/zig/sdk/solana_program_sdk_m4.zig";
const vendored_solana_codec_root = "vendor/solana-program-sdk-zig/packages/solana-codec/src/root.zig";
const vendored_spl_token_m4_root = "vendor/solana-program-sdk-zig/packages/spl-token/src/zxcaml_m4_root.zig";
const vendored_spl_ata_m4_root = "vendor/solana-program-sdk-zig/packages/spl-ata/src/zxcaml_m4_root.zig";

fn appendVendoredSdkModuleArgs(
    allocator: Allocator,
    args: *std.ArrayList([]const u8),
    root_module_path: []const u8,
) !void {
    const root_module_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{root_module_path});
    try args.appendSlice(allocator, &.{
        "--dep",
        "vendored_sdk",
        "--dep",
        "solana_program_sdk",
        "--dep",
        "solana_codec",
        "--dep",
        "spl_token_m4",
        "--dep",
        "spl_ata_m4",
    });
    try args.append(allocator, root_module_arg);
    try args.appendSlice(allocator, &.{
        "--dep",
        "solana_sdk_m2",
        "-Mvendored_sdk=" ++ vendored_sdk_runtime_root,
        "-Msolana_sdk_m2=" ++ vendored_solana_sdk_m2_root,
        "--dep",
        "solana_sdk_m2",
        "-Msolana_program_sdk=" ++ vendored_solana_program_sdk_root,
        "--dep",
        "solana_program_sdk",
        "-Msolana_codec=" ++ vendored_solana_codec_root,
        "--dep",
        "solana_program_sdk",
        "--dep",
        "solana_codec",
        "-Mspl_token_m4=" ++ vendored_spl_token_m4_root,
        "--dep",
        "solana_program_sdk",
        "-Mspl_ata_m4=" ++ vendored_spl_ata_m4_root,
    });
}

/// Builds a hosted native executable from generated Zig source.
pub fn buildNative(allocator: Allocator, io: Io, options: NativeBuildOptions) !void {
    try target_manifest.materializeRuntimeForDispatch(allocator, io, .native);

    const emit_bin_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{options.output_path});
    defer allocator.free(emit_bin_arg);

    var argv = std.ArrayList([]const u8).empty;
    defer {
        for (argv.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-Mroot=")) allocator.free(arg);
        }
        argv.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{
        "zig",
        "build-exe",
        "-O",
        "ReleaseSmall",
    });
    try appendVendoredSdkModuleArgs(allocator, &argv, options.native_entry_path);
    try argv.append(allocator, emit_bin_arg);

    const completed = try std.process.run(allocator, io, .{ .argv = argv.items });
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    if (completed.stdout.len > 0) try writeStdout(io, completed.stdout);
    if (completed.stderr.len > 0) try writeStderr(io, completed.stderr);

    switch (completed.term) {
        .exited => |code| {
            if (code == 0) return;
            return error.NativeBuildFailed;
        },
        .signal, .stopped, .unknown => return error.NativeBuildFailed,
    }
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

test "native build wiring references vendored SDK modules and never references sbpf-linker" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).empty;
    defer {
        for (argv.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-Mroot=")) allocator.free(arg);
        }
        argv.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{
        "zig",
        "build-exe",
        "-O",
        "ReleaseSmall",
    });
    try appendVendoredSdkModuleArgs(allocator, &argv, "out/native_entry.zig");
    try argv.append(allocator, "-femit-bin=/tmp/m0_zero");

    try std.testing.expectEqualStrings("zig", argv.items[0]);
    try std.testing.expectEqualStrings("build-exe", argv.items[1]);
    try std.testing.expectEqualStrings("-O", argv.items[2]);
    try std.testing.expectEqualStrings("ReleaseSmall", argv.items[3]);
    const joined = try std.mem.join(allocator, " ", argv.items);
    defer allocator.free(joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "vendored_sdk") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "out/native_entry.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, argv.items[argv.items.len - 1], "/tmp/m0_zero") != null);
    for (argv.items) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "sbpf-linker") == null);
    }
}
