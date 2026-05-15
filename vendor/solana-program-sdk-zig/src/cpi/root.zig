//! Cross-Program Invocation (CPI)
//!
//! This module owns the low-level invoke surface used by the higher-level
//! program wrappers (`sol.system.*`, `spl_token.cpi.*`, etc.):
//!
//! - `AccountMeta` / `Instruction` describe the callee-visible instruction.
//! - `Seed` / `Signer` model PDA signer proofs in the exact syscall layout.
//! - `CpiAccountStaging` and `stageDynamicAccountsWithPubkeys(...)` let
//!   callers build account-meta / runtime-account arrays in caller-owned scratch.
//! - `invoke*` helpers forward to the runtime with the minimal amount of
//!   marshaling the syscall ABI requires.
//!
//! `CpiAccountInfo` already matches the Solana C ABI, so the hot path stays
//! pointer-based: no allocation, no heap-backed conversion layer.
//!
//! Physical layout:
//! - `shared.zig` — common imports / aliases
//! - `instruction.zig` — `AccountMeta` and `Instruction` helpers
//! - `seeds.zig` — raw PDA `Seed` / `Signer` types and `seedPack`
//! - `staging.zig` — caller-buffer-backed staging helpers
//! - `invoke.zig` — syscall-backed CPI entrypoints
//! - `return_data.zig` — CPI return-data helpers
//!
//! The public API stays flattened as `sol.cpi.*`.

const std = @import("std");
const shared = @import("shared.zig");
const account = shared.account;
const Pubkey = shared.Pubkey;
const CpiAccountInfo = shared.CpiAccountInfo;
const invoke_mod = @import("invoke.zig");
const return_mod = @import("return_data.zig");

/// Instruction-description types used for CPI call construction.
pub const AccountMeta = @import("instruction.zig").AccountMeta;
pub const Instruction = @import("instruction.zig").Instruction;

/// PDA signer seed primitives in syscall-ready layout.
pub const Seed = @import("seeds.zig").Seed;
pub const Signer = @import("seeds.zig").Signer;
pub const seedPack = @import("seeds.zig").seedPack;

/// Caller-buffer-backed account staging helpers.
pub const stageDynamicAccountsWithPubkeys = @import("staging.zig").stageDynamicAccountsWithPubkeys;
pub const CpiAccountStaging = @import("staging.zig").CpiAccountStaging;

/// Runtime invoke limits and syscall-backed entrypoints.
pub const MAX_CPI_SIGNERS = invoke_mod.MAX_CPI_SIGNERS;
pub const MAX_CPI_SEEDS_PER_SIGNER = invoke_mod.MAX_CPI_SEEDS_PER_SIGNER;
pub const invoke = invoke_mod.invoke;
pub const invokeRaw = invoke_mod.invokeRaw;
pub const invokeSigned = invoke_mod.invokeSigned;
pub const invokeSignedRaw = invoke_mod.invokeSignedRaw;
pub const invokeSignedSingle = invoke_mod.invokeSignedSingle;

/// CPI return-data helpers.
pub const setReturnData = return_mod.setReturnData;
pub const getReturnData = return_mod.getReturnData;

// =============================================================================
// Tests
// =============================================================================
//
// AccountMeta layout is asserted at comptime above.
// CpiAccountInfo size is asserted at comptime in the account module.

test "cpi: AccountMeta.init sets bytes correctly" {
    const key: Pubkey = .{0} ** 32;
    const m = AccountMeta.init(&key, true, false);
    try std.testing.expectEqual(@as(u8, 1), m.is_writable);
    try std.testing.expectEqual(@as(u8, 0), m.is_signer);
}

test "cpi: AccountMeta convenience constructors set correct flag bytes" {
    const key: Pubkey = .{42} ** 32;

    const ro = AccountMeta.readonly(&key);
    try std.testing.expectEqual(@as(u8, 0), ro.is_writable);
    try std.testing.expectEqual(@as(u8, 0), ro.is_signer);

    const w = AccountMeta.writable(&key);
    try std.testing.expectEqual(@as(u8, 1), w.is_writable);
    try std.testing.expectEqual(@as(u8, 0), w.is_signer);

    const s = AccountMeta.signer(&key);
    try std.testing.expectEqual(@as(u8, 0), s.is_writable);
    try std.testing.expectEqual(@as(u8, 1), s.is_signer);

    const sw = AccountMeta.signerWritable(&key);
    try std.testing.expectEqual(@as(u8, 1), sw.is_writable);
    try std.testing.expectEqual(@as(u8, 1), sw.is_signer);

    // All constructors point at the same key.
    try std.testing.expectEqual(&key, ro.pubkey);
    try std.testing.expectEqual(&key, sw.pubkey);
}

test "cpi: Instruction.init builds the struct in one call" {
    const key: Pubkey = .{1} ** 32;
    const metas = [_]AccountMeta{AccountMeta.signer(&key)};
    const data = [_]u8{ 0x01, 0x02, 0x03 };

    const ix = Instruction.init(&key, &metas, &data);

    try std.testing.expectEqual(&key, ix.program_id);
    try std.testing.expectEqual(@as(usize, 1), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 3), ix.data.len);
    try std.testing.expectEqual(@as(u8, 0x02), ix.data[1]);
}

test "cpi: Seed.from / fromByte / fromPubkey produce identical layout" {
    const slice = "vault";
    const s1 = Seed.from(slice);
    try std.testing.expectEqual(@intFromPtr(slice.ptr), s1.addr);
    try std.testing.expectEqual(@as(u64, slice.len), s1.len);

    const b: u8 = 254;
    const s2 = Seed.fromByte(&b);
    try std.testing.expectEqual(@intFromPtr(&b), s2.addr);
    try std.testing.expectEqual(@as(u64, 1), s2.len);

    const pk: Pubkey = .{42} ** 32;
    const s3 = Seed.fromPubkey(&pk);
    try std.testing.expectEqual(@intFromPtr(&pk), s3.addr);
    try std.testing.expectEqual(@as(u64, 32), s3.len);
}

test "cpi: seedPack coerces common seed shapes" {
    const bump_seed = [_]u8{7};
    const pk: Pubkey = .{9} ** 32;
    const seeds = seedPack(.{ "vault", &pk, &bump_seed, &bump_seed[0] });

    try std.testing.expectEqual(@as(usize, 4), seeds.len);
    try std.testing.expectEqual(@as(u64, 5), seeds[0].len);
    try std.testing.expectEqual(@as(u64, 32), seeds[1].len);
    try std.testing.expectEqual(@as(u64, 1), seeds[2].len);
    try std.testing.expectEqual(@as(u64, 1), seeds[3].len);
    try std.testing.expectEqual(@intFromPtr(&pk), seeds[1].addr);
}

test "cpi: stageDynamicAccountsWithPubkeys preserves order" {
    var raw_a: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0x11} ** 32,
        .owner = .{0x21} ** 32,
        .lamports = 1,
        .data_len = 0,
    };
    var raw_b: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0x12} ** 32,
        .owner = .{0x22} ** 32,
        .lamports = 2,
        .data_len = 0,
    };
    var raw_c: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0x13} ** 32,
        .owner = .{0x23} ** 32,
        .lamports = 3,
        .data_len = 0,
    };
    var raw_program: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 1,
        ._padding = .{0} ** 4,
        .key = .{0x14} ** 32,
        .owner = .{0x24} ** 32,
        .lamports = 4,
        .data_len = 0,
    };

    const fixed = [_]CpiAccountInfo{CpiAccountInfo.fromPtr(&raw_a)};
    const dynamic = [_]CpiAccountInfo{ CpiAccountInfo.fromPtr(&raw_b), CpiAccountInfo.fromPtr(&raw_c) };
    const trailing = [_]CpiAccountInfo{CpiAccountInfo.fromPtr(&raw_program)};

    var pubkeys: [2]Pubkey = undefined;
    var accounts: [4]CpiAccountInfo = undefined;
    const staged = try stageDynamicAccountsWithPubkeys(
        fixed.len,
        trailing.len,
        fixed,
        &dynamic,
        trailing,
        pubkeys[0..],
        accounts[0..],
    );

    try std.testing.expectEqual(@as(usize, 2), staged.dynamic_pubkeys.len);
    try std.testing.expectEqual(@as(usize, 4), staged.runtime_accounts.len);
    try std.testing.expectEqualSlices(u8, raw_b.key[0..], staged.dynamic_pubkeys[0][0..]);
    try std.testing.expectEqualSlices(u8, raw_c.key[0..], staged.dynamic_pubkeys[1][0..]);
    try std.testing.expectEqualSlices(u8, raw_a.key[0..], staged.runtime_accounts[0].key()[0..]);
    try std.testing.expectEqualSlices(u8, raw_b.key[0..], staged.runtime_accounts[1].key()[0..]);
    try std.testing.expectEqualSlices(u8, raw_c.key[0..], staged.runtime_accounts[2].key()[0..]);
    try std.testing.expectEqualSlices(u8, raw_program.key[0..], staged.runtime_accounts[3].key()[0..]);
}

test "cpi: CpiAccountStaging keeps aligned prefixes and resets for reuse" {
    var raw_a: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0x21} ** 32,
        .owner = .{0x31} ** 32,
        .lamports = 5,
        .data_len = 0,
    };
    var raw_program: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 1,
        ._padding = .{0} ** 4,
        .key = .{0x99} ** 32,
        .owner = .{0x41} ** 32,
        .lamports = 9,
        .data_len = 0,
    };

    var metas: [2]AccountMeta = undefined;
    var infos: [2]CpiAccountInfo = undefined;
    var staging = CpiAccountStaging.init(metas[0..], infos[0..]);

    try std.testing.expectEqual(@as(usize, 0), staging.accountMetas().len);
    try std.testing.expectEqual(@as(usize, 0), staging.accountInfos().len);

    try staging.appendAccount(CpiAccountInfo.fromPtr(&raw_a));
    try staging.appendProgram(CpiAccountInfo.fromPtr(&raw_program));
    try std.testing.expectEqual(@as(usize, 1), staging.accountMetas().len);
    try std.testing.expectEqual(@as(usize, 2), staging.accountInfos().len);
    try std.testing.expectEqual(@intFromPtr(&raw_a.key), @intFromPtr(staging.accountMetas()[0].pubkey));
    try std.testing.expectEqual(@intFromPtr(&raw_a.lamports), @intFromPtr(staging.accountInfos()[0].lamports_ptr));
    try std.testing.expectEqual(@intFromPtr(&raw_program.key), @intFromPtr(staging.accountInfos()[1].key()));

    staging.reset();
    try std.testing.expectEqual(@as(usize, 0), staging.accountMetas().len);
    try std.testing.expectEqual(@as(usize, 0), staging.accountInfos().len);

    try staging.appendProgram(CpiAccountInfo.fromPtr(&raw_program));
    try std.testing.expectEqual(@as(usize, 0), staging.accountMetas().len);
    try std.testing.expectEqual(@as(usize, 1), staging.accountInfos().len);
}

test "cpi: CpiAccountStaging capacity failures leave lengths unchanged" {
    var raw_a: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0x11} ** 32,
        .owner = .{0x22} ** 32,
        .lamports = 1,
        .data_len = 0,
    };
    var raw_b: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0x12} ** 32,
        .owner = .{0x23} ** 32,
        .lamports = 2,
        .data_len = 0,
    };
    var raw_program: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 1,
        ._padding = .{0} ** 4,
        .key = .{0x13} ** 32,
        .owner = .{0x24} ** 32,
        .lamports = 3,
        .data_len = 0,
    };

    var metas: [1]AccountMeta = undefined;
    var infos: [2]CpiAccountInfo = undefined;
    var staging = CpiAccountStaging.init(metas[0..], infos[0..]);

    try staging.appendAccount(CpiAccountInfo.fromPtr(&raw_a));
    try std.testing.expectEqual(@as(usize, 1), staging.accountMetas().len);
    try std.testing.expectEqual(@as(usize, 1), staging.accountInfos().len);

    try std.testing.expectError(
        error.InvalidArgument,
        staging.appendAccount(CpiAccountInfo.fromPtr(&raw_b)),
    );
    try std.testing.expectEqual(@as(usize, 1), staging.accountMetas().len);
    try std.testing.expectEqual(@as(usize, 1), staging.accountInfos().len);
    try std.testing.expectEqual(@intFromPtr(&raw_a.key), @intFromPtr(staging.accountMetas()[0].pubkey));

    try staging.appendProgram(CpiAccountInfo.fromPtr(&raw_program));
    try std.testing.expectEqual(@as(usize, 2), staging.accountInfos().len);
    try std.testing.expectError(
        error.InvalidArgument,
        staging.appendProgram(CpiAccountInfo.fromPtr(&raw_program)),
    );
    try std.testing.expectEqual(@as(usize, 1), staging.accountMetas().len);
    try std.testing.expectEqual(@as(usize, 2), staging.accountInfos().len);
}

test "cpi: CpiAccountStaging checked vs unchecked staging names are explicit" {
    var raw: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0x44} ** 32,
        .owner = .{0x55} ** 32,
        .lamports = 4,
        .data_len = 0,
    };

    var metas: [1]AccountMeta = undefined;
    var infos: [1]CpiAccountInfo = undefined;
    var staging = CpiAccountStaging.init(metas[0..], infos[0..]);
    const info = CpiAccountInfo.fromPtr(&raw);

    try std.testing.expectError(
        error.InvalidArgument,
        staging.appendMetaInfo(AccountMeta.writable(info.key()), info),
    );
    try std.testing.expectEqual(@as(usize, 0), staging.accountMetas().len);
    try std.testing.expectEqual(@as(usize, 0), staging.accountInfos().len);

    try staging.appendMetaInfoUnchecked(AccountMeta.writable(info.key()), info);
    try std.testing.expectEqual(@as(usize, 1), staging.accountMetas().len);
    try std.testing.expectEqual(@as(usize, 1), staging.accountInfos().len);
}

test "cpi: CpiAccountStaging instruction uses explicit program account and keeps order" {
    var raw_a: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0xa1} ** 32,
        .owner = .{0xb1} ** 32,
        .lamports = 11,
        .data_len = 0,
    };
    var raw_b: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0xa2} ** 32,
        .owner = .{0xb2} ** 32,
        .lamports = 12,
        .data_len = 0,
    };
    var raw_program: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 1,
        ._padding = .{0} ** 4,
        .key = .{0xa3} ** 32,
        .owner = .{0xb3} ** 32,
        .lamports = 13,
        .data_len = 0,
    };

    var metas: [2]AccountMeta = undefined;
    var infos: [3]CpiAccountInfo = undefined;
    var staging = CpiAccountStaging.init(metas[0..], infos[0..]);

    try staging.appendAccount(CpiAccountInfo.fromPtr(&raw_a));
    try staging.appendAccount(CpiAccountInfo.fromPtr(&raw_b));
    try staging.appendProgram(CpiAccountInfo.fromPtr(&raw_program));

    const data = [_]u8{ 0xaa, 0xbb, 0xcc };
    const ix = staging.instructionFromProgram(CpiAccountInfo.fromPtr(&raw_program), &data);

    try std.testing.expectEqual(@intFromPtr(&raw_program.key), @intFromPtr(ix.program_id));
    try std.testing.expectEqual(@as(usize, 2), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 3), staging.accountInfos().len);
    try std.testing.expectEqual(@intFromPtr(&raw_a.key), @intFromPtr(ix.accounts[0].pubkey));
    try std.testing.expectEqual(@intFromPtr(&raw_a.key), @intFromPtr(staging.accountInfos()[0].key()));
    try std.testing.expectEqual(ix.accounts[0].is_signer, @as(u8, @intFromBool(staging.accountInfos()[0].isSigner())));
    try std.testing.expectEqual(ix.accounts[0].is_writable, @as(u8, @intFromBool(staging.accountInfos()[0].isWritable())));
    try std.testing.expectEqual(@intFromPtr(&raw_b.key), @intFromPtr(ix.accounts[1].pubkey));
    try std.testing.expectEqual(@intFromPtr(&raw_b.key), @intFromPtr(staging.accountInfos()[1].key()));
    try std.testing.expectEqual(@intFromPtr(&raw_program.key), @intFromPtr(staging.accountInfos()[2].key()));
}
