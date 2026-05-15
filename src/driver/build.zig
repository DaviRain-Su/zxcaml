//! Native build orchestration for emitted Zig source.
//!
//! RESPONSIBILITIES:
//! - Materialise runtime helper files next to generated `out/program.zig`.
//! - Drive `zig build-exe -O ReleaseSmall` for `--target=native`.
//! - Keep the native path independent from `sbpf-linker` and BPF tooling.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Options for the developer-convenience native build path.
pub const NativeBuildOptions = struct {
    generated_zig_path: []const u8 = "out/program.zig",
    native_entry_path: []const u8 = "out/native_entry.zig",
    output_path: []const u8,
};

const RuntimeFile = struct {
    src_path: []const u8,
    out_path: []const u8,
};

const vendored_sdk_runtime_root = "out/runtime/sdk/root.zig";
const vendored_solana_program_sdk_root = "vendor/solana-program-sdk-zig/src/root.zig";
const vendored_solana_codec_root = "vendor/solana-program-sdk-zig/packages/solana-codec/src/root.zig";
const vendored_spl_token_root = "vendor/solana-program-sdk-zig/packages/spl-token/src/root.zig";
const vendored_spl_ata_root = "vendor/solana-program-sdk-zig/packages/spl-ata/src/root.zig";
const vendored_solana_system_root = "vendor/solana-program-sdk-zig/packages/solana-system/src/root.zig";
const vendored_spl_memo_root = "vendor/solana-program-sdk-zig/packages/spl-memo/src/root.zig";

const runtime_files = [_]RuntimeFile{
    .{ .src_path = "runtime/zig/arena.zig", .out_path = "out/runtime/arena.zig" },
    .{ .src_path = "runtime/zig/account.zig", .out_path = "out/runtime/account.zig" },
    .{ .src_path = "runtime/zig/cpi.zig", .out_path = "out/runtime/cpi.zig" },
    .{ .src_path = "runtime/zig/sdk/root.zig", .out_path = "out/runtime/sdk/root.zig" },
    .{ .src_path = "runtime/zig/sdk/import_smoke.zig", .out_path = "out/runtime/sdk/import_smoke.zig" },
    .{ .src_path = "runtime/zig/programs/common.zig", .out_path = "out/runtime/programs/common.zig" },
    .{ .src_path = "runtime/zig/programs/transfer_sol.zig", .out_path = "out/runtime/programs/transfer_sol.zig" },
    .{ .src_path = "runtime/zig/programs/vault.zig", .out_path = "out/runtime/programs/vault.zig" },
    .{ .src_path = "runtime/zig/programs/vault_v2.zig", .out_path = "out/runtime/programs/vault_v2.zig" },
    .{ .src_path = "runtime/zig/programs/hackathon_greet.zig", .out_path = "out/runtime/programs/hackathon_greet.zig" },
    .{ .src_path = "runtime/zig/programs/token_vault.zig", .out_path = "out/runtime/programs/token_vault.zig" },
    .{ .src_path = "runtime/zig/programs/escrow_full.zig", .out_path = "out/runtime/programs/escrow_full.zig" },
    .{ .src_path = "runtime/zig/programs/dao_voting.zig", .out_path = "out/runtime/programs/dao_voting.zig" },
    .{ .src_path = "runtime/zig/programs/ata_transfer.zig", .out_path = "out/runtime/programs/ata_transfer.zig" },
    .{ .src_path = "runtime/zig/programs/spl_burn.zig", .out_path = "out/runtime/programs/spl_burn.zig" },
    .{ .src_path = "runtime/zig/programs/spl_close_account.zig", .out_path = "out/runtime/programs/spl_close_account.zig" },
    .{ .src_path = "runtime/zig/programs/spl_revoke.zig", .out_path = "out/runtime/programs/spl_revoke.zig" },
    .{ .src_path = "runtime/zig/programs/order_book.zig", .out_path = "out/runtime/programs/order_book.zig" },
    .{ .src_path = "runtime/zig/programs/ata.zig", .out_path = "out/runtime/programs/ata.zig" },
    .{ .src_path = "runtime/zig/bs58.zig", .out_path = "out/runtime/bs58.zig" },
    .{ .src_path = "runtime/zig/panic.zig", .out_path = "out/runtime/panic.zig" },
    .{ .src_path = "runtime/zig/prelude.zig", .out_path = "out/runtime/prelude.zig" },
    .{ .src_path = "runtime/zig/spl_token.zig", .out_path = "out/runtime/spl_token.zig" },
    .{ .src_path = "runtime/zig/syscalls.zig", .out_path = "out/runtime/syscalls.zig" },
    .{ .src_path = "runtime/zig/sysvar.zig", .out_path = "out/runtime/sysvar.zig" },
    .{ .src_path = "runtime/zig/native_entry.zig", .out_path = "out/native_entry.zig" },
};

fn appendVendoredSdkModuleArgs(
    allocator: Allocator,
    args: *std.ArrayList([]const u8),
    root_module_path: []const u8,
) !void {
    const root_module_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{root_module_path});
    try args.appendSlice(allocator, &.{
        "--dep",
        "vendored_sdk",
    });
    try args.append(allocator, root_module_arg);
    try args.appendSlice(allocator, &.{
        "--dep",
        "solana_program_sdk",
        "--dep",
        "solana_codec",
        "--dep",
        "spl_token",
        "--dep",
        "spl_ata",
        "--dep",
        "solana_system",
        "--dep",
        "spl_memo",
        "-Mvendored_sdk=" ++ vendored_sdk_runtime_root,
        "-Msolana_program_sdk=" ++ vendored_solana_program_sdk_root,
        "--dep",
        "solana_program_sdk",
        "-Msolana_codec=" ++ vendored_solana_codec_root,
        "--dep",
        "solana_program_sdk",
        "--dep",
        "solana_codec",
        "-Mspl_token=" ++ vendored_spl_token_root,
        "--dep",
        "solana_program_sdk",
        "-Mspl_ata=" ++ vendored_spl_ata_root,
        "--dep",
        "solana_program_sdk",
        "-Msolana_system=" ++ vendored_solana_system_root,
        "--dep",
        "solana_program_sdk",
        "-Mspl_memo=" ++ vendored_spl_memo_root,
    });
}

/// Builds a hosted native executable from generated Zig source.
pub fn buildNative(allocator: Allocator, io: Io, options: NativeBuildOptions) !void {
    try materializeRuntime(allocator, io);

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

fn materializeRuntime(allocator: Allocator, io: Io) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/runtime");
    try cwd.createDirPath(io, "out/runtime/sdk");
    try cwd.createDirPath(io, "out/runtime/programs");

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
