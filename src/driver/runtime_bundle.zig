//! Shared runtime-bundle helpers for native and BPF build orchestration.
//!
//! The public CLI keeps the same output paths (`out/runtime/**`,
//! `out/native_entry.zig`, `out/bpf_entry.zig`) while the materialization logic
//! and vendored SDK command wiring live in one place.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const RuntimeFile = struct {
    src_path: []const u8,
    out_path: []const u8,
};

pub const EntryKind = enum {
    native,
    bpf,
};

const vendored_sdk_runtime_root = "out/runtime/sdk/root.zig";
const vendored_solana_sdk_m2_root = "vendor/solana-program-sdk-zig/src/zxcaml_m2_root.zig";
const vendored_solana_program_sdk_root = "runtime/zig/sdk/solana_program_sdk_m4.zig";
const vendored_solana_codec_root = "vendor/solana-program-sdk-zig/packages/solana-codec/src/root.zig";
const vendored_spl_token_m4_root = "vendor/solana-program-sdk-zig/packages/spl-token/src/zxcaml_m4_root.zig";
const vendored_spl_ata_m4_root = "vendor/solana-program-sdk-zig/packages/spl-ata/src/zxcaml_m4_root.zig";

const normalized_runtime_files = [_]RuntimeFile{
    .{ .src_path = "runtime/zig/root.zig", .out_path = "out/runtime/root.zig" },
    .{ .src_path = "runtime/zig/core.zig", .out_path = "out/runtime/core.zig" },
    .{ .src_path = "runtime/zig/solana.zig", .out_path = "out/runtime/solana.zig" },
    .{ .src_path = "runtime/zig/shims.zig", .out_path = "out/runtime/shims.zig" },
    .{ .src_path = "runtime/zig/sdk/root.zig", .out_path = "out/runtime/sdk/root.zig" },
    .{ .src_path = "runtime/zig/sdk/import_smoke.zig", .out_path = "out/runtime/sdk/import_smoke.zig" },
    .{ .src_path = "runtime/zig/programs/root.zig", .out_path = "out/runtime/programs/root.zig" },
};

const generated_import_compat_files = [_]RuntimeFile{
    .{ .src_path = "runtime/zig/arena.zig", .out_path = "out/runtime/arena.zig" },
    .{ .src_path = "runtime/zig/account.zig", .out_path = "out/runtime/account.zig" },
    .{ .src_path = "runtime/zig/bs58.zig", .out_path = "out/runtime/bs58.zig" },
    .{ .src_path = "runtime/zig/cpi.zig", .out_path = "out/runtime/cpi.zig" },
    .{ .src_path = "runtime/zig/entry_context.zig", .out_path = "out/runtime/entry_context.zig" },
    .{ .src_path = "runtime/zig/panic.zig", .out_path = "out/runtime/panic.zig" },
    .{ .src_path = "runtime/zig/prelude.zig", .out_path = "out/runtime/prelude.zig" },
    .{ .src_path = "runtime/zig/spl_token.zig", .out_path = "out/runtime/spl_token.zig" },
    .{ .src_path = "runtime/zig/syscalls.zig", .out_path = "out/runtime/syscalls.zig" },
    .{ .src_path = "runtime/zig/sysvar.zig", .out_path = "out/runtime/sysvar.zig" },
};

const program_runtime_files = [_]RuntimeFile{
    .{ .src_path = "runtime/zig/programs/ata.zig", .out_path = "out/runtime/programs/ata.zig" },
    .{ .src_path = "runtime/zig/programs/ata_transfer.zig", .out_path = "out/runtime/programs/ata_transfer.zig" },
    .{ .src_path = "runtime/zig/programs/combined.zig", .out_path = "out/runtime/programs/combined.zig" },
    .{ .src_path = "runtime/zig/programs/common.zig", .out_path = "out/runtime/programs/common.zig" },
    .{ .src_path = "runtime/zig/programs/dao_voting.zig", .out_path = "out/runtime/programs/dao_voting.zig" },
    .{ .src_path = "runtime/zig/programs/escrow_full.zig", .out_path = "out/runtime/programs/escrow_full.zig" },
    .{ .src_path = "runtime/zig/programs/hackathon_greet.zig", .out_path = "out/runtime/programs/hackathon_greet.zig" },
    .{ .src_path = "runtime/zig/programs/order_book.zig", .out_path = "out/runtime/programs/order_book.zig" },
    .{ .src_path = "runtime/zig/programs/spl_burn.zig", .out_path = "out/runtime/programs/spl_burn.zig" },
    .{ .src_path = "runtime/zig/programs/spl_close_account.zig", .out_path = "out/runtime/programs/spl_close_account.zig" },
    .{ .src_path = "runtime/zig/programs/spl_revoke.zig", .out_path = "out/runtime/programs/spl_revoke.zig" },
    .{ .src_path = "runtime/zig/programs/token_vault.zig", .out_path = "out/runtime/programs/token_vault.zig" },
    .{ .src_path = "runtime/zig/programs/transfer_sol.zig", .out_path = "out/runtime/programs/transfer_sol.zig" },
    .{ .src_path = "runtime/zig/programs/vault.zig", .out_path = "out/runtime/programs/vault.zig" },
    .{ .src_path = "runtime/zig/programs/vault_v2.zig", .out_path = "out/runtime/programs/vault_v2.zig" },
};

pub fn materializeRuntime(allocator: Allocator, io: Io, entry_kind: EntryKind) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/runtime");
    try cwd.createDirPath(io, "out/runtime/sdk");
    try cwd.createDirPath(io, "out/runtime/programs");

    inline for (normalized_runtime_files) |file| {
        try copyRuntimeFile(allocator, io, file);
    }
    inline for (generated_import_compat_files) |file| {
        try copyRuntimeFile(allocator, io, file);
    }
    inline for (program_runtime_files) |file| {
        try copyRuntimeFile(allocator, io, file);
    }
    try copyRuntimeFile(allocator, io, switch (entry_kind) {
        .native => .{ .src_path = "runtime/zig/native_entry.zig", .out_path = "out/native_entry.zig" },
        .bpf => .{ .src_path = "runtime/zig/bpf_entry.zig", .out_path = "out/bpf_entry.zig" },
    });
}

pub fn appendVendoredSdkModuleArgs(
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

fn copyRuntimeFile(allocator: Allocator, io: Io, file: RuntimeFile) !void {
    const cwd = std.Io.Dir.cwd();
    const contents = try cwd.readFileAlloc(io, file.src_path, allocator, .limited(128 * 1024));
    defer allocator.free(contents);

    try cwd.writeFile(io, .{
        .sub_path = file.out_path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
}
