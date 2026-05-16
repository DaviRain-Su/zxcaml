//! Solana cross-program invocation and return-data runtime bindings.
//!
//! RESPONSIBILITIES:
//! - Define the C ABI structs consumed by Solana CPI and PDA syscalls.
//! - Centralize MurmurHash3-32 dispatch addresses for CPI-related syscalls.
//! - Provide deterministic hosted fallbacks for PDA and return-data tests.

const std = @import("std");
const builtin = @import("builtin");
const Arena = @import("arena.zig").Arena;
const account = @import("account.zig");
const syscalls = @import("syscalls.zig");
const vendored_sdk = @import("vendored_sdk").solana_program_sdk;

/// 32-byte Solana public key.
pub const Pubkey = syscalls.Pubkey;
const SdkAccountInfo = vendored_sdk.account.AccountInfo;
const SdkCpiAccountInfo = vendored_sdk.account.CpiAccountInfo;
const SdkInstructionContext = vendored_sdk.entrypoint.InstructionContext;
const SdkAccountMeta = vendored_sdk.cpi.AccountMeta;
const SdkInstruction = vendored_sdk.cpi.Instruction;
const SdkSeed = vendored_sdk.cpi.Seed;
const SdkSigner = vendored_sdk.cpi.Signer;

/// Maximum Solana PDA seed length in bytes.
pub const max_seed_len: usize = 32;
/// Maximum number of seeds accepted by Solana PDA helpers.
pub const max_seeds: usize = 16;
/// Domain separator appended by Solana PDA derivation.
pub const pda_marker = "ProgramDerivedAddress";

/// C ABI account metadata for a CPI instruction.
pub const SolAccountMeta = extern struct {
    pubkey: *const Pubkey,
    is_writable: u8,
    is_signer: u8,
};

/// C ABI instruction descriptor consumed by `sol_invoke_signed_c`.
pub const SolInstruction = extern struct {
    program_id: *const Pubkey,
    accounts: [*]const SolAccountMeta,
    account_len: u64,
    data: [*]const u8,
    data_len: u64,

    /// Builds a C instruction descriptor from Zig slices.
    pub fn fromSlices(program_id: *const Pubkey, accounts: []const SolAccountMeta, data: []const u8) SolInstruction {
        return .{
            .program_id = program_id,
            .accounts = accounts.ptr,
            .account_len = accounts.len,
            .data = data.ptr,
            .data_len = data.len,
        };
    }
};

/// C ABI account-info descriptor passed to CPI.
pub const SolAccountInfo = extern struct {
    key: *const Pubkey,
    lamports: *align(1) u64,
    data_len: u64,
    data: [*]u8,
    owner: *const Pubkey,
    rent_epoch: u64,
    is_signer: u8,
    is_writable: u8,
    executable: u8,
};

/// C ABI one-seed byte slice.
pub const SolSignerSeed = extern struct {
    addr: [*]const u8,
    len: u64,

    /// Builds one C seed descriptor from a Zig byte slice.
    pub fn fromSlice(seed: []const u8) SolSignerSeed {
        return .{ .addr = seed.ptr, .len = seed.len };
    }
};

/// High-level signer seed collection used by hosted helpers and tests.
pub const SolSignerSeeds = struct {
    seeds: []const SolSignerSeed,

    /// Exposes the collection as the C ABI descriptor.
    pub fn toC(self: SolSignerSeeds) SolSignerSeedsC {
        return .{ .addr = self.seeds.ptr, .len = self.seeds.len };
    }
};

/// C ABI signer-seed collection consumed by `sol_invoke_signed_c`.
pub const SolSignerSeedsC = extern struct {
    addr: [*]const SolSignerSeed,
    len: u64,
};

/// MurmurHash3-32 dispatch address for `sol_invoke_signed_c`.
pub const sol_invoke_signed_c_address: usize = 0xa22b9c85;
/// MurmurHash3-32 dispatch address for `sol_create_program_address`.
pub const sol_create_program_address_address: usize = 0x9377323c;
/// MurmurHash3-32 dispatch address for `sol_try_find_program_address`.
pub const sol_try_find_program_address_address: usize = 0x48504a38;
/// MurmurHash3-32 dispatch address for `sol_set_return_data`.
pub const sol_set_return_data_address: usize = 0xa226d3eb;
/// MurmurHash3-32 dispatch address for `sol_get_return_data`.
pub const sol_get_return_data_address: usize = 0x5d2245e4;

const success: u64 = 0;
const invalid_seeds: u64 = 1;
const return_data_capacity: usize = 1024;
const is_bpf = std.mem.eql(u8, @tagName(builtin.target.cpu.arch), "sbf") or
    std.mem.eql(u8, @tagName(builtin.target.cpu.arch), "bpfel") or
    std.mem.eql(u8, @tagName(builtin.target.cpu.arch), "bpfeb");

const Syscall = struct {
    extern fn sol_invoke_signed_c(instruction: *const SolInstruction, account_infos: [*]const SolAccountInfo, account_len: u64, signer_seed_groups: [*]const SolSignerSeedsC, signer_seed_len: u64) callconv(.c) u64;
    extern fn sol_create_program_address(seeds: [*]const SolSignerSeed, seed_len: u64, program_id: *const Pubkey, out: *Pubkey) callconv(.c) u64;
    extern fn sol_try_find_program_address(seeds: [*]const SolSignerSeed, seed_len: u64, program_id: *const Pubkey, out: *Pubkey, bump_seed: *u8) callconv(.c) u64;
    extern fn sol_set_return_data(data: [*]const u8, data_len: u64) callconv(.c) void;
    extern fn sol_get_return_data(data: [*]u8, data_len: u64, program_id: *Pubkey) callconv(.c) u64;
};

var hosted_return_program_id: Pubkey = [_]u8{0} ** 32;
var hosted_return_data: [return_data_capacity]u8 = undefined;
var hosted_return_data_len: usize = 0;
var bpf_return_program_id: Pubkey = undefined;
var bpf_return_data: [return_data_capacity]u8 = undefined;

comptime {
    std.debug.assert(@sizeOf(SolAccountMeta) == @sizeOf(SdkAccountMeta));
    std.debug.assert(@offsetOf(SolAccountMeta, "pubkey") == @offsetOf(SdkAccountMeta, "pubkey"));
    std.debug.assert(@offsetOf(SolAccountMeta, "is_writable") == @offsetOf(SdkAccountMeta, "is_writable"));
    std.debug.assert(@offsetOf(SolAccountMeta, "is_signer") == @offsetOf(SdkAccountMeta, "is_signer"));

    std.debug.assert(@sizeOf(SolAccountInfo) == @sizeOf(SdkCpiAccountInfo));
    std.debug.assert(@offsetOf(SolAccountInfo, "key") == @offsetOf(SdkCpiAccountInfo, "key_ptr"));
    std.debug.assert(@offsetOf(SolAccountInfo, "lamports") == @offsetOf(SdkCpiAccountInfo, "lamports_ptr"));
    std.debug.assert(@offsetOf(SolAccountInfo, "data_len") == @offsetOf(SdkCpiAccountInfo, "data_len"));
    std.debug.assert(@offsetOf(SolAccountInfo, "data") == @offsetOf(SdkCpiAccountInfo, "data_ptr"));
    std.debug.assert(@offsetOf(SolAccountInfo, "owner") == @offsetOf(SdkCpiAccountInfo, "owner_ptr"));
    std.debug.assert(@offsetOf(SolAccountInfo, "rent_epoch") == @offsetOf(SdkCpiAccountInfo, "rent_epoch"));
    std.debug.assert(@offsetOf(SolAccountInfo, "is_signer") == @offsetOf(SdkCpiAccountInfo, "is_signer"));
    std.debug.assert(@offsetOf(SolAccountInfo, "is_writable") == @offsetOf(SdkCpiAccountInfo, "is_writable"));
    std.debug.assert(@offsetOf(SolAccountInfo, "executable") == @offsetOf(SdkCpiAccountInfo, "is_executable"));

    std.debug.assert(@sizeOf(SolSignerSeed) == @sizeOf(SdkSeed));
    std.debug.assert(@sizeOf(SolSignerSeedsC) == @sizeOf(SdkSigner));
}

fn accountInfoFromSdk(info: SdkCpiAccountInfo) SolAccountInfo {
    return .{
        .key = info.key_ptr,
        .lamports = @ptrCast(info.lamports_ptr),
        .data_len = info.data_len,
        .data = info.data_ptr,
        .owner = info.owner_ptr,
        .rent_epoch = info.rent_epoch,
        .is_signer = info.is_signer,
        .is_writable = info.is_writable,
        .executable = info.is_executable,
    };
}

fn asSdkAccountMetaSlice(metas: []const SolAccountMeta) []const SdkAccountMeta {
    return @as([*]const SdkAccountMeta, @ptrCast(metas.ptr))[0..metas.len];
}

fn asSdkAccountInfoSlice(infos: []const SolAccountInfo) []const SdkCpiAccountInfo {
    return @as([*]const SdkCpiAccountInfo, @ptrCast(infos.ptr))[0..infos.len];
}

fn asSdkSignerSlice(signers: []const SolSignerSeedsC) []const SdkSigner {
    return @as([*]const SdkSigner, @ptrCast(signers.ptr))[0..signers.len];
}

fn seedBytes(seed: SolSignerSeed) []const u8 {
    return seed.addr[0..@intCast(seed.len)];
}

fn pdaStatusFromError(err: vendored_sdk.program_error.ProgramError) u64 {
    return switch (err) {
        error.InvalidSeeds,
        error.MaxSeedLengthExceeded,
        => invalid_seeds,
        else => invalid_seeds,
    };
}

fn statusFromProgramResult(result: vendored_sdk.program_error.ProgramResult) u64 {
    result catch |err| return vendored_sdk.program_error.errorToU64(err);
    return success;
}

/// Converts a parsed account view into a CPI account-info descriptor.
pub fn accountInfoFromView(view: account.AccountView) SolAccountInfo {
    return .{
        .key = view.key,
        .lamports = view.lamports,
        .data_len = view.data.len,
        .data = view.data.ptr,
        .owner = view.owner,
        .rent_epoch = view.rentEpochValue(),
        .is_signer = @intFromBool(view.is_signer),
        .is_writable = @intFromBool(view.is_writable),
        .executable = @intFromBool(view.executable),
    };
}

/// Invokes another Solana program with optional signer seeds.
pub inline fn sol_invoke_signed_c(instruction: *const SolInstruction, account_infos: []const SolAccountInfo, signer_seeds: []const SolSignerSeedsC) u64 {
    if (!comptime is_bpf) return success;

    const metas = asSdkAccountMetaSlice(instruction.accounts[0..@intCast(instruction.account_len)]);
    const sdk_instruction = SdkInstruction.init(
        instruction.program_id,
        metas,
        instruction.data[0..@intCast(instruction.data_len)],
    );

    if (signer_seeds.len == 0) {
        var empty_seed_bytes = [_]u8{0};
        var empty_seed = [_]SolSignerSeed{.{ .addr = empty_seed_bytes[0..].ptr, .len = 0 }};
        var empty_seed_groups = [_]SolSignerSeedsC{.{ .addr = empty_seed[0..].ptr, .len = 0 }};
        return Syscall.sol_invoke_signed_c(
            instruction,
            account_infos.ptr,
            account_infos.len,
            empty_seed_groups[0..].ptr,
            0,
        );
    }

    return statusFromProgramResult(vendored_sdk.cpi.invokeSignedRaw(
        &sdk_instruction,
        asSdkAccountInfoSlice(account_infos),
        asSdkSignerSlice(signer_seeds),
    ));
}

/// Invokes another Solana program without PDA signer seeds.
pub inline fn invoke(instruction: *const SolInstruction, account_infos: []const SolAccountInfo) u64 {
    const empty: []const SolSignerSeedsC = &.{};
    return sol_invoke_signed_c(instruction, account_infos, empty);
}

/// Invokes the system program to transfer one lamport from account 0 to account 1.
pub inline fn zxcaml_system_transfer_one_lamport(arena: *Arena, input: [*]const u8) u64 {
    _ = arena;
    const input_mut: [*]u8 = @constCast(input);
    var cursor: usize = 0;
    _ = readU64Raw(input_mut, &cursor);

    var infos: [3]SolAccountInfo = undefined;
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[0]);
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[1]);
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[2]);

    var program_id = infos[2].key.*;
    var metas: [2]SolAccountMeta = undefined;
    metas[0] = .{ .pubkey = infos[0].key, .is_writable = 1, .is_signer = 1 };
    metas[1] = .{ .pubkey = infos[1].key, .is_writable = 1, .is_signer = 0 };

    var data: [12]u8 = undefined;
    data[0] = 2;
    data[1] = 0;
    data[2] = 0;
    data[3] = 0;
    data[4] = 1;
    data[5] = 0;
    data[6] = 0;
    data[7] = 0;
    data[8] = 0;
    data[9] = 0;
    data[10] = 0;
    data[11] = 0;

    const instruction: SolInstruction = .{
        .program_id = &program_id,
        .accounts = metas[0..].ptr,
        .account_len = 2,
        .data = data[0..].ptr,
        .data_len = data.len,
    };

    var seed: [6]u8 = undefined;
    seed[0] = 'z';
    seed[1] = 'x';
    seed[2] = 'c';
    seed[3] = 'a';
    seed[4] = 'm';
    seed[5] = 'l';
    var c_seeds = [_]SolSignerSeed{.{ .addr = seed[0..].ptr, .len = seed.len }};
    var seed_groups = [_]SolSignerSeedsC{.{ .addr = c_seeds[0..].ptr, .len = c_seeds.len }};
    return sol_invoke_signed_c(&instruction, infos[0..], seed_groups[0..]);
}

/// Invokes the system program to transfer one lamport without PDA signer seeds.
pub inline fn zxcaml_system_transfer_one_lamport_unsigned(arena: *Arena, input: [*]const u8) u64 {
    _ = arena;
    const input_mut: [*]u8 = @constCast(input);
    var cursor: usize = 0;
    _ = readU64Raw(input_mut, &cursor);

    var infos: [3]SolAccountInfo = undefined;
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[0]);
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[1]);
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[2]);

    var program_id = infos[2].key.*;
    var metas: [2]SolAccountMeta = undefined;
    metas[0] = .{ .pubkey = infos[0].key, .is_writable = 1, .is_signer = 1 };
    metas[1] = .{ .pubkey = infos[1].key, .is_writable = 1, .is_signer = 0 };

    var data: [12]u8 = undefined;
    data[0] = 2;
    data[1] = 0;
    data[2] = 0;
    data[3] = 0;
    data[4] = 1;
    data[5] = 0;
    data[6] = 0;
    data[7] = 0;
    data[8] = 0;
    data[9] = 0;
    data[10] = 0;
    data[11] = 0;

    const instruction: SolInstruction = .{
        .program_id = &program_id,
        .accounts = metas[0..].ptr,
        .account_len = 2,
        .data = data[0..].ptr,
        .data_len = data.len,
    };

    return invoke(&instruction, infos[0..]);
}

/// Invokes the system program transfer using already parsed account views.
pub inline fn zxcaml_system_transfer_one_lamport_from_views(arena: *Arena, views: []account.AccountView) u64 {
    if (views.len < 3) return 1;

    var program_id = views[2].key.*;
    var metas: [2]SolAccountMeta = undefined;
    metas[0] = .{
        .pubkey = views[0].key,
        .is_writable = 1,
        .is_signer = 1,
    };
    metas[1] = .{
        .pubkey = views[1].key,
        .is_writable = 1,
        .is_signer = 0,
    };

    var data: [12]u8 = undefined;
    data[0] = 2;
    data[1] = 0;
    data[2] = 0;
    data[3] = 0;
    data[4] = 1;
    data[5] = 0;
    data[6] = 0;
    data[7] = 0;
    data[8] = 0;
    data[9] = 0;
    data[10] = 0;
    data[11] = 0;
    const instruction: SolInstruction = .{
        .program_id = &program_id,
        .accounts = metas[0..].ptr,
        .account_len = metas.len,
        .data = data[0..].ptr,
        .data_len = data.len,
    };

    var infos: []SolAccountInfo = undefined;
    arena.allocIntoOrTrap(SolAccountInfo, views.len, &infos);
    for (views, 0..) |view, index| {
        infos[index] = .{
            .key = view.key,
            .lamports = view.lamports,
            .data_len = view.data.len,
            .data = view.data.ptr,
            .owner = view.owner,
            .rent_epoch = view.rentEpochValue(),
            .is_signer = @intFromBool(view.is_signer),
            .is_writable = @intFromBool(view.is_writable),
            .executable = @intFromBool(view.executable),
        };
    }

    var seed: [6]u8 = undefined;
    seed[0] = 'z';
    seed[1] = 'x';
    seed[2] = 'c';
    seed[3] = 'a';
    seed[4] = 'm';
    seed[5] = 'l';
    var c_seeds = [_]SolSignerSeed{.{ .addr = seed[0..].ptr, .len = seed.len }};
    var seed_groups = [_]SolSignerSeedsC{.{ .addr = c_seeds[0..].ptr, .len = c_seeds.len }};
    return sol_invoke_signed_c(&instruction, infos, seed_groups[0..]);
}

fn writeSystemTransferData(out: []u8, amount: u64) void {
    out[0] = 2;
    out[1] = 0;
    out[2] = 0;
    out[3] = 0;
    out[4] = @intCast(amount & 0xff);
    out[5] = @intCast((amount >> 8) & 0xff);
    out[6] = @intCast((amount >> 16) & 0xff);
    out[7] = @intCast((amount >> 24) & 0xff);
    out[8] = @intCast((amount >> 32) & 0xff);
    out[9] = @intCast((amount >> 40) & 0xff);
    out[10] = @intCast((amount >> 48) & 0xff);
    out[11] = @intCast((amount >> 56) & 0xff);
}

fn pubkeyEq(lhs: *const Pubkey, rhs: *const Pubkey) bool {
    return std.mem.eql(u8, lhs[0..], rhs[0..]);
}

inline fn readU64Raw(input: [*]const u8, cursor: *usize) u64 {
    const start = cursor.*;
    cursor.* += 8;
    return @as(u64, input[start]) |
        (@as(u64, input[start + 1]) << 8) |
        (@as(u64, input[start + 2]) << 16) |
        (@as(u64, input[start + 3]) << 24) |
        (@as(u64, input[start + 4]) << 32) |
        (@as(u64, input[start + 5]) << 40) |
        (@as(u64, input[start + 6]) << 48) |
        (@as(u64, input[start + 7]) << 56);
}

inline fn parseAccountInfoUnchecked(input: [*]u8, cursor: *usize, out: *SolAccountInfo) void {
    _ = input[cursor.*];
    cursor.* += 1;
    const is_signer = input[cursor.*];
    cursor.* += 1;
    const is_writable = input[cursor.*];
    cursor.* += 1;
    const executable = input[cursor.*];
    cursor.* += 1;
    cursor.* += 4;
    const key: *const Pubkey = @ptrCast(input + cursor.*);
    cursor.* += 32;
    const owner: *const Pubkey = @ptrCast(input + cursor.*);
    cursor.* += 32;
    const lamports: *align(1) u64 = @ptrCast(input + cursor.*);
    cursor.* += @sizeOf(u64);
    const data_len = readU64Raw(input, cursor);
    const data = (input + cursor.*)[0..@intCast(data_len)];
    cursor.* += @intCast(data_len);
    cursor.* += 10 * 1024;
    cursor.* = std.mem.alignForward(usize, cursor.*, 8);
    const rent_epoch: *align(1) u64 = @ptrCast(input + cursor.*);
    cursor.* += @sizeOf(u64);

    out.* = .{
        .key = key,
        .lamports = lamports,
        .data_len = data.len,
        .data = data.ptr,
        .owner = owner,
        .rent_epoch = rent_epoch.*,
        .is_signer = is_signer,
        .is_writable = is_writable,
        .executable = executable,
    };
}

/// Derives a program address from seeds and a program id.
pub inline fn sol_create_program_address(seeds: []const SolSignerSeed, program_id: *const Pubkey, out: *Pubkey) u64 {
    var seed_slices_buf: [max_seeds][]const u8 = undefined;
    for (seeds, 0..) |seed, index| {
        seed_slices_buf[index] = seedBytes(seed);
    }
    const derived = vendored_sdk.pda.createProgramAddress(seed_slices_buf[0..seeds.len], program_id) catch |err| {
        return pdaStatusFromError(err);
    };
    out.* = derived;
    return success;
}

/// Finds a valid program address and bump seed for a seed prefix.
pub inline fn sol_try_find_program_address(seeds: []const SolSignerSeed, program_id: *const Pubkey, out: *Pubkey, bump_seed: *u8) u64 {
    var seed_slices_buf: [max_seeds][]const u8 = undefined;
    for (seeds, 0..) |seed, index| {
        seed_slices_buf[index] = seedBytes(seed);
    }
    const derived = vendored_sdk.pda.findProgramAddress(seed_slices_buf[0..seeds.len], program_id) catch |err| {
        return pdaStatusFromError(err);
    };
    out.* = derived.address;
    bump_seed.* = derived.bump_seed;
    return success;
}

/// Stores return data for the current instruction.
pub inline fn sol_set_return_data(data: []const u8) void {
    if (comptime is_bpf) {
        vendored_sdk.cpi.setReturnData(data);
    } else {
        hosted_return_data_len = @min(data.len, hosted_return_data.len);
        @memcpy(hosted_return_data[0..hosted_return_data_len], data[0..hosted_return_data_len]);
    }
}

/// Copies return data into `out` and writes the producing program id.
pub inline fn sol_get_return_data(out: []u8, program_id: *Pubkey) u64 {
    if (comptime is_bpf) {
        if (vendored_sdk.cpi.getReturnData(out)) |result| {
            program_id.* = result[0];
            return result[1].len;
        }
        return 0;
    }
    const copy_len = @min(out.len, hosted_return_data_len);
    @memcpy(out[0..copy_len], hosted_return_data[0..copy_len]);
    program_id.* = hosted_return_program_id;
    return hosted_return_data_len;
}

/// Returns return data as an arena-owned byte slice for generated code.
pub inline fn sol_get_return_data_alloc(arena: *Arena) []const u8 {
    if (comptime is_bpf) {
        const total_len = sol_get_return_data(bpf_return_data[0..], &bpf_return_program_id);
        const copy_len: usize = @intCast(@min(total_len, @as(u64, bpf_return_data.len)));
        return bpf_return_data[0..copy_len];
    }
    var scratch: [return_data_capacity]u8 = undefined;
    var program_id: Pubkey = undefined;
    const total_len = sol_get_return_data(scratch[0..], &program_id);
    const copy_len = @min(total_len, scratch.len);
    const out = arena.alloc(u8, copy_len) catch unreachable;
    @memcpy(out, scratch[0..copy_len]);
    return out;
}

/// Parses the entrypoint account list into CPI account-info descriptors while
/// preserving Solana duplicate-account aliasing semantics.
pub fn parseAccountInfosFromPtrInto(arena: *Arena, input: [*]const u8, out: *[]SolAccountInfo) void {
    var ctx = SdkInstructionContext.init(@constCast(input));
    const account_count: usize = @intCast(ctx.remainingAccounts());

    var infos: []SolAccountInfo = undefined;
    arena.allocIntoOrTrap(SolAccountInfo, account_count, &infos);
    if (account_count == 0) {
        out.* = infos;
        return;
    }

    var resolved_accounts: []SdkAccountInfo = undefined;
    arena.allocIntoOrTrap(SdkAccountInfo, account_count, &resolved_accounts);

    for (0..account_count) |index| {
        const resolved = switch (ctx.nextAccountMaybe() catch unreachable) {
            .account => |value| value,
            .duplicated => |dup_index| blk: {
                std.debug.assert(dup_index < index);
                break :blk resolved_accounts[dup_index];
            },
        };
        resolved_accounts[index] = resolved;
        infos[index] = accountInfoFromSdk(resolved.toCpiInfo());
    }

    out.* = infos;
}

fn createProgramAddressHosted(seeds: []const SolSignerSeed, program_id: *const Pubkey, out: *Pubkey) u64 {
    if (!validateSeeds(seeds)) return invalid_seeds;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (seeds) |seed| {
        hasher.update(seed.addr[0..@intCast(seed.len)]);
    }
    hasher.update(program_id);
    hasher.update(pda_marker);
    hasher.final(out);

    return if (isOnCurve(out.*)) invalid_seeds else success;
}

fn tryFindProgramAddressHosted(seeds: []const SolSignerSeed, program_id: *const Pubkey, out: *Pubkey, bump_seed: *u8) u64 {
    if (seeds.len >= max_seeds or !validateSeeds(seeds)) return invalid_seeds;

    var bump: u16 = 255;
    while (true) : (bump -= 1) {
        const bump_byte: [1]u8 = .{@intCast(bump)};
        var all_seeds_buf: [max_seeds]SolSignerSeed = undefined;
        @memcpy(all_seeds_buf[0..seeds.len], seeds);
        all_seeds_buf[seeds.len] = SolSignerSeed.fromSlice(bump_byte[0..]);

        if (createProgramAddressHosted(all_seeds_buf[0 .. seeds.len + 1], program_id, out) == success) {
            bump_seed.* = @intCast(bump);
            return success;
        }
        if (bump == 0) break;
    }
    return invalid_seeds;
}

fn validateSeeds(seeds: []const SolSignerSeed) bool {
    if (seeds.len > max_seeds) return false;
    for (seeds) |seed| {
        if (seed.len > max_seed_len) return false;
    }
    return true;
}

fn isOnCurve(bytes: Pubkey) bool {
    _ = std.crypto.ecc.Edwards25519.fromBytes(bytes) catch return false;
    return true;
}

fn buildDuplicateCpiInput(buf: *[32768]u8) void {
    const SdkAccount = vendored_sdk.account.Account;
    const non_dup = vendored_sdk.account.NON_DUP_MARKER;
    const max_data_increase = vendored_sdk.account.MAX_PERMITTED_DATA_INCREASE;

    @memset(buf, 0);
    var ptr: [*]u8 = buf;

    std.mem.writeInt(u64, ptr[0..8], 3, .little);
    ptr += 8;

    const acc0: SdkAccount = .{
        .borrow_state = non_dup,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0xAA} ** 32,
        .owner = .{0xBB} ** 32,
        .lamports = 777,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(SdkAccount)], std.mem.asBytes(&acc0));
    ptr += @sizeOf(SdkAccount) + max_data_increase + 8;

    ptr[0] = 0;
    ptr += 8;

    const acc2: SdkAccount = .{
        .borrow_state = non_dup,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0xCC} ** 32,
        .owner = .{0xDD} ** 32,
        .lamports = 333,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(SdkAccount)], std.mem.asBytes(&acc2));
    ptr += @sizeOf(SdkAccount) + max_data_increase + 8;

    std.mem.writeInt(u64, ptr[0..8], 0, .little);
}

test "CPI syscall dispatch addresses match assigned MurmurHash3-32 values" {
    try std.testing.expectEqual(@as(usize, 0xa22b9c85), sol_invoke_signed_c_address);
    try std.testing.expectEqual(@as(usize, 0x9377323c), sol_create_program_address_address);
    try std.testing.expectEqual(@as(usize, 0x48504a38), sol_try_find_program_address_address);
    try std.testing.expectEqual(@as(usize, 0xa226d3eb), sol_set_return_data_address);
    try std.testing.expectEqual(@as(usize, 0x5d2245e4), sol_get_return_data_address);
}

test "CPI C ABI structs have stable field offsets" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(SolAccountMeta, "pubkey"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(SolAccountMeta, "is_writable"));
    try std.testing.expectEqual(@as(usize, 9), @offsetOf(SolAccountMeta, "is_signer"));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(SolAccountMeta));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(SolInstruction, "program_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(SolInstruction, "accounts"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(SolInstruction, "account_len"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(SolInstruction, "data"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(SolInstruction, "data_len"));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(SolInstruction));

    try std.testing.expectEqual(@as(usize, 16), @sizeOf(SolSignerSeed));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(SolSignerSeedsC));
}

test "hosted PDA derivation is deterministic and finds a bump" {
    var program_id: Pubkey = [_]u8{1} ** 32;
    const seed_bytes = "zxcaml";
    const seeds = [_]SolSignerSeed{SolSignerSeed.fromSlice(seed_bytes)};

    var bump: u8 = 0;
    var found: Pubkey = undefined;
    try std.testing.expectEqual(success, sol_try_find_program_address(seeds[0..], &program_id, &found, &bump));
    try std.testing.expect(bump <= 255);

    const bump_seed: [1]u8 = .{bump};
    const bumped_seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(seed_bytes),
        SolSignerSeed.fromSlice(bump_seed[0..]),
    };
    var first: Pubkey = undefined;
    var second: Pubkey = undefined;
    try std.testing.expectEqual(success, sol_create_program_address(bumped_seeds[0..], &program_id, &first));
    try std.testing.expectEqual(success, sol_create_program_address(bumped_seeds[0..], &program_id, &second));
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expectEqualSlices(u8, &found, &first);
}

test "CPI account info parser resolves duplicate accounts to shared backing state" {
    var input: [32768]u8 align(8) = undefined;
    buildDuplicateCpiInput(&input);

    var arena_buf: [256]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&arena_buf);
    var infos: []SolAccountInfo = undefined;
    parseAccountInfosFromPtrInto(&arena, input[0..].ptr, &infos);

    try std.testing.expectEqual(@as(usize, 3), infos.len);
    try std.testing.expectEqual(@intFromPtr(infos[0].key), @intFromPtr(infos[1].key));
    try std.testing.expectEqual(@intFromPtr(infos[0].lamports), @intFromPtr(infos[1].lamports));
    try std.testing.expectEqual(@as(u64, 777), infos[1].lamports.*);
    infos[0].lamports.* += 5;
    try std.testing.expectEqual(@as(u64, 782), infos[1].lamports.*);
    try std.testing.expectEqual(@as(u64, 333), infos[2].lamports.*);
}

test "hosted return data round-trips through set/get helpers" {
    sol_set_return_data("return payload");
    var out: [32]u8 = undefined;
    var program_id: Pubkey = undefined;

    const len = sol_get_return_data(out[0..], &program_id);
    try std.testing.expectEqual(@as(u64, "return payload".len), len);
    try std.testing.expectEqualSlices(u8, "return payload", out[0.."return payload".len]);

    var arena_buf: [64]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&arena_buf);
    const allocated = sol_get_return_data_alloc(&arena);
    try std.testing.expectEqualSlices(u8, "return payload", allocated);
}
