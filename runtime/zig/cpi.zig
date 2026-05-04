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

/// 32-byte Solana public key.
pub const Pubkey = syscalls.Pubkey;

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
const is_bpf = builtin.target.cpu.arch == .bpfel or builtin.target.cpu.arch == .bpfeb;

const SolInvokeSignedCFn = *align(1) const fn (*const SolInstruction, [*]const SolAccountInfo, u64, [*]const SolSignerSeedsC, u64) u64;
const SolCreateProgramAddressFn = *align(1) const fn ([*]const SolSignerSeed, u64, *const Pubkey, *Pubkey) u64;
const SolTryFindProgramAddressFn = *align(1) const fn ([*]const SolSignerSeed, u64, *const Pubkey, *Pubkey, *u8) u64;
const SolSetReturnDataFn = *align(1) const fn ([*]const u8, u64) void;
const SolGetReturnDataFn = *align(1) const fn ([*]u8, u64, *Pubkey) u64;

var hosted_return_program_id: Pubkey = [_]u8{0} ** 32;
var hosted_return_data: [return_data_capacity]u8 = undefined;
var hosted_return_data_len: usize = 0;

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
    if (comptime is_bpf) {
        const syscall: SolInvokeSignedCFn = @ptrFromInt(sol_invoke_signed_c_address);
        if (signer_seeds.len == 0) {
            var empty_seed_bytes = [_]u8{0};
            var empty_seed = [_]SolSignerSeed{.{ .addr = empty_seed_bytes[0..].ptr, .len = 0 }};
            var empty_seed_groups = [_]SolSignerSeedsC{.{ .addr = empty_seed[0..].ptr, .len = 0 }};
            return syscall(instruction, account_infos.ptr, account_infos.len, empty_seed_groups[0..].ptr, 0);
        }
        return syscall(instruction, account_infos.ptr, account_infos.len, signer_seeds.ptr, signer_seeds.len);
    } else {
        return success;
    }
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

/// Processes the transfer_sol example's u64 amount payload via System Program CPI.
pub fn zxcaml_transfer_sol_process(arena: *Arena, input: [*]const u8, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len != 8) return 1;

    const input_mut: [*]u8 = @constCast(input);
    var cursor: usize = 0;
    const account_count = readU64Raw(input_mut, &cursor);
    if (account_count < 3) return 1;

    var infos: [3]SolAccountInfo = undefined;
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[0]);
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[1]);
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[2]);
    if (infos[0].is_signer == 0) return 1;
    if (infos[0].is_writable == 0) return 1;
    if (infos[1].is_writable == 0) return 1;

    const system_program_id: Pubkey = [_]u8{0} ** 32;
    if (!pubkeyEq(infos[2].key, &system_program_id)) return 1;

    const amount = readU64LeSlice(instruction_data[0..8]);
    if (amount == 0) return 1;

    var data: [12]u8 = undefined;
    writeSystemTransferData(data[0..], amount);

    var program_id = infos[2].key.*;
    var metas = [_]SolAccountMeta{
        .{ .pubkey = infos[0].key, .is_writable = 1, .is_signer = 1 },
        .{ .pubkey = infos[1].key, .is_writable = 1, .is_signer = 0 },
    };
    const instruction = SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
    return invoke(&instruction, infos[0..]);
}

/// Processes the vault example's deposit/withdraw instruction against parsed account views.
pub fn zxcaml_vault_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    _ = input;
    if (views.len < 3) return 1;
    if (instruction_data.len == 0) return 1;
    if (!views[0].is_signer) return 1;

    const system_program_id: Pubkey = [_]u8{0} ** 32;
    if (!pubkeyEq(views[2].key, &system_program_id)) return 1;
    if (!pubkeyEq(views[1].owner, &system_program_id)) return 1;

    return switch (instruction_data[0]) {
        0 => zxcamlVaultDeposit(views, instruction_data),
        1 => zxcamlVaultWithdraw(views),
        else => 1,
    };
}

fn zxcamlVaultDeposit(views: []account.AccountView, instruction_data: []const u8) u64 {
    if (instruction_data.len < 9) return 1;
    if (views[1].lamportsValue() != 0) return 1;
    const amount = readU64LeSlice(instruction_data[1..9]);
    if (amount == 0) return 1;

    var data: [12]u8 = undefined;
    writeSystemTransferData(data[0..], amount);

    var program_id = views[2].key.*;
    var metas = [_]SolAccountMeta{
        .{ .pubkey = views[0].key, .is_writable = 1, .is_signer = 1 },
        .{ .pubkey = views[1].key, .is_writable = 1, .is_signer = 0 },
    };
    const instruction = SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
    var infos = [_]SolAccountInfo{
        accountInfoFromView(views[0]),
        accountInfoFromView(views[1]),
        accountInfoFromView(views[2]),
    };
    return invoke(&instruction, infos[0..]);
}

fn zxcamlVaultWithdraw(views: []account.AccountView) u64 {
    const amount = views[1].lamportsValue();
    if (amount == 0) return 1;

    var data: [12]u8 = undefined;
    writeSystemTransferData(data[0..], amount);

    var program_id = views[2].key.*;
    var metas = [_]SolAccountMeta{
        .{ .pubkey = views[1].key, .is_writable = 1, .is_signer = 1 },
        .{ .pubkey = views[0].key, .is_writable = 1, .is_signer = 0 },
    };
    const instruction = SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
    var infos = [_]SolAccountInfo{
        accountInfoFromView(views[1]),
        accountInfoFromView(views[0]),
        accountInfoFromView(views[2]),
    };

    var vault_seed: [5]u8 = undefined;
    vault_seed[0] = 'v';
    vault_seed[1] = 'a';
    vault_seed[2] = 'u';
    vault_seed[3] = 'l';
    vault_seed[4] = 't';
    var owner_seed = views[0].key.*;
    var c_seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(vault_seed[0..]),
        SolSignerSeed.fromSlice(owner_seed[0..]),
    };
    var seed_groups = [_]SolSignerSeedsC{.{ .addr = c_seeds[0..].ptr, .len = c_seeds.len }};
    return sol_invoke_signed_c(&instruction, infos[0..], seed_groups[0..]);
}

fn readU64LeSlice(bytes: []const u8) u64 {
    return @as(u64, bytes[0]) |
        (@as(u64, bytes[1]) << 8) |
        (@as(u64, bytes[2]) << 16) |
        (@as(u64, bytes[3]) << 24) |
        (@as(u64, bytes[4]) << 32) |
        (@as(u64, bytes[5]) << 40) |
        (@as(u64, bytes[6]) << 48) |
        (@as(u64, bytes[7]) << 56);
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
    cursor.* = std.mem.alignForward(usize, cursor.*, 16);
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
    if (comptime is_bpf) {
        const syscall: SolCreateProgramAddressFn = @ptrFromInt(sol_create_program_address_address);
        return syscall(seeds.ptr, seeds.len, program_id, out);
    }
    return createProgramAddressHosted(seeds, program_id, out);
}

/// Finds a valid program address and bump seed for a seed prefix.
pub inline fn sol_try_find_program_address(seeds: []const SolSignerSeed, program_id: *const Pubkey, out: *Pubkey, bump_seed: *u8) u64 {
    if (comptime is_bpf) {
        const syscall: SolTryFindProgramAddressFn = @ptrFromInt(sol_try_find_program_address_address);
        return syscall(seeds.ptr, seeds.len, program_id, out, bump_seed);
    }
    return tryFindProgramAddressHosted(seeds, program_id, out, bump_seed);
}

/// Stores return data for the current instruction.
pub inline fn sol_set_return_data(data: []const u8) void {
    if (comptime is_bpf) {
        const syscall: SolSetReturnDataFn = @ptrFromInt(sol_set_return_data_address);
        syscall(data.ptr, data.len);
    } else {
        hosted_return_data_len = @min(data.len, hosted_return_data.len);
        @memcpy(hosted_return_data[0..hosted_return_data_len], data[0..hosted_return_data_len]);
    }
}

/// Copies return data into `out` and writes the producing program id.
pub inline fn sol_get_return_data(out: []u8, program_id: *Pubkey) u64 {
    if (comptime is_bpf) {
        const syscall: SolGetReturnDataFn = @ptrFromInt(sol_get_return_data_address);
        return syscall(out.ptr, out.len, program_id);
    }
    const copy_len = @min(out.len, hosted_return_data_len);
    @memcpy(out[0..copy_len], hosted_return_data[0..copy_len]);
    program_id.* = hosted_return_program_id;
    return hosted_return_data_len;
}

/// Returns return data as an arena-owned byte slice for generated code.
pub inline fn sol_get_return_data_alloc(arena: *Arena) []const u8 {
    var scratch: [return_data_capacity]u8 = undefined;
    var program_id: Pubkey = undefined;
    const total_len = sol_get_return_data(scratch[0..], &program_id);
    const copy_len = @min(total_len, scratch.len);
    const out = arena.alloc(u8, copy_len) catch unreachable;
    @memcpy(out, scratch[0..copy_len]);
    return out;
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
