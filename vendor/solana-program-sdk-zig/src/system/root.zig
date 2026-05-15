//! System Program CPI wrappers
//!
//! High-level Zig API for common System Program operations.
//!
//! Physical layout:
//! - `shared.zig` — wire-format constants, payloads, and local helpers
//! - `create.zig` — plain account-creation helpers
//! - `core.zig` — signer-required core ops (`transfer` / `assign` / `allocate`)
//! - `rent_helpers.zig` — rent-aware / comptime-rent convenience helpers
//! - `seeded.zig` — `*WithSeed` instruction families
//! - `nonce.zig` — durable nonce creation and maintenance helpers
//!
//! The public API stays flattened as `sol.system.*` even though the
//! implementation now lives under `src/system/`.
//!
//! ⚠️ WARNING (Zig 0.16 BPF): Always use stack copies for Program IDs.
//! Module-scope const arrays may be placed at invalid low addresses.

const std = @import("std");
const shared = @import("shared.zig");
const account_mod = shared.account_mod;
const cpi = shared.cpi;
const Pubkey = shared.Pubkey;
const MAX_SEED_LEN = shared.MAX_SEED_LEN;
const CreateAccountPayload = shared.CreateAccountPayload;
const TransferPayload = shared.TransferPayload;
const NonceAuthorityPayload = shared.NonceAuthorityPayload;
const fixedIxData = shared.fixedIxData;
const discriminantOnlyData = shared.discriminantOnlyData;

const create_mod = @import("create.zig");
const core_mod = @import("core.zig");
const rent_helpers_mod = @import("rent_helpers.zig");
const seeded_mod = @import("seeded.zig");
const nonce_mod = @import("nonce.zig");

/// System instruction discriminants and stable program constants.
pub const SystemInstruction = shared.SystemInstruction;
pub const SYSTEM_PROGRAM_ID = shared.SYSTEM_PROGRAM_ID;
pub const NONCE_STATE_SIZE = shared.NONCE_STATE_SIZE;

/// Plain account-creation helpers.
pub const createAccount = create_mod.createAccount;
pub const createAccountSigned = create_mod.createAccountSigned;
pub const createAccountSignedRaw = create_mod.createAccountSignedRaw;
pub const createAccountSignedSingle = create_mod.createAccountSignedSingle;

/// Core signer-required System instructions.
pub const transfer = core_mod.transfer;
pub const transferSigned = core_mod.transferSigned;
pub const transferSignedSingle = core_mod.transferSignedSingle;
pub const assign = core_mod.assign;
pub const assignSigned = core_mod.assignSigned;
pub const assignSignedSingle = core_mod.assignSignedSingle;
pub const allocate = core_mod.allocate;
pub const allocateSigned = core_mod.allocateSigned;
pub const allocateSignedSingle = core_mod.allocateSignedSingle;

/// Rent-aware account-creation convenience helpers.
pub const CreateRentExemptArgs = rent_helpers_mod.CreateRentExemptArgs;
pub const createRentExempt = rent_helpers_mod.createRentExempt;
pub const createRentExemptComptime = rent_helpers_mod.createRentExemptComptime;
pub const createRentExemptComptimeRaw = rent_helpers_mod.createRentExemptComptimeRaw;
pub const createRentExemptComptimeSingle = rent_helpers_mod.createRentExemptComptimeSingle;
pub const createRentExemptRaw = rent_helpers_mod.createRentExemptRaw;

/// Seed-derived account helpers (`*WithSeed`).
pub const createAccountWithSeed = seeded_mod.createAccountWithSeed;
pub const createAccountWithSeedSigned = seeded_mod.createAccountWithSeedSigned;
pub const createAccountWithSeedSignedSingle = seeded_mod.createAccountWithSeedSignedSingle;
pub const assignWithSeed = seeded_mod.assignWithSeed;
pub const assignWithSeedSigned = seeded_mod.assignWithSeedSigned;
pub const assignWithSeedSignedSingle = seeded_mod.assignWithSeedSignedSingle;
pub const allocateWithSeed = seeded_mod.allocateWithSeed;
pub const allocateWithSeedSigned = seeded_mod.allocateWithSeedSigned;
pub const allocateWithSeedSignedSingle = seeded_mod.allocateWithSeedSignedSingle;
pub const transferWithSeed = seeded_mod.transferWithSeed;
pub const transferWithSeedSigned = seeded_mod.transferWithSeedSigned;
pub const transferWithSeedSignedSingle = seeded_mod.transferWithSeedSignedSingle;

/// Durable nonce helpers, including PDA-signed authority variants.
pub const initializeNonceAccount = nonce_mod.initializeNonceAccount;
pub const createNonceAccount = nonce_mod.createNonceAccount;
pub const createNonceAccountSigned = nonce_mod.createNonceAccountSigned;
pub const createNonceAccountSignedRaw = nonce_mod.createNonceAccountSignedRaw;
pub const createNonceAccountSignedSingle = nonce_mod.createNonceAccountSignedSingle;
pub const createNonceAccountWithSeed = nonce_mod.createNonceAccountWithSeed;
pub const createNonceAccountWithSeedSigned = nonce_mod.createNonceAccountWithSeedSigned;
pub const createNonceAccountWithSeedSignedSingle = nonce_mod.createNonceAccountWithSeedSignedSingle;
pub const advanceNonceAccount = nonce_mod.advanceNonceAccount;
pub const advanceNonceAccountSigned = nonce_mod.advanceNonceAccountSigned;
pub const advanceNonceAccountSignedSingle = nonce_mod.advanceNonceAccountSignedSingle;
pub const withdrawNonceAccount = nonce_mod.withdrawNonceAccount;
pub const withdrawNonceAccountSigned = nonce_mod.withdrawNonceAccountSigned;
pub const withdrawNonceAccountSignedSingle = nonce_mod.withdrawNonceAccountSignedSingle;
pub const authorizeNonceAccount = nonce_mod.authorizeNonceAccount;
pub const authorizeNonceAccountSigned = nonce_mod.authorizeNonceAccountSigned;
pub const authorizeNonceAccountSignedSingle = nonce_mod.authorizeNonceAccountSignedSingle;
pub const upgradeNonceAccount = nonce_mod.upgradeNonceAccount;

// =============================================================================
// Tests
// =============================================================================

test "system: SYSTEM_PROGRAM_ID is all zero" {
    const expected: Pubkey = .{0} ** 32;
    try std.testing.expectEqual(expected, SYSTEM_PROGRAM_ID);
}

test "system: instruction data format" {
    const ix_data = fixedIxData(SystemInstruction.CreateAccount, CreateAccountPayload, .{ .lamports = 500, .space = 128, .owner = .{3} ** 32 });

    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ix_data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 500), std.mem.readInt(u64, ix_data[4..12], .little));
    try std.testing.expectEqual(@as(u64, 128), std.mem.readInt(u64, ix_data[12..20], .little));
    const expected_owner: Pubkey = .{3} ** 32;
    try std.testing.expectEqual(expected_owner, ix_data[20..52].*);
}

test "system: transfer instruction data" {
    const ix_data = fixedIxData(SystemInstruction.Transfer, TransferPayload, .{ .lamports = 100 });

    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, ix_data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 100), std.mem.readInt(u64, ix_data[4..12], .little));
}

test "system: nonce instruction data formats" {
    const authority: Pubkey = .{7} ** 32;

    const initialize_data = fixedIxData(SystemInstruction.InitializeNonceAccount, NonceAuthorityPayload, .{ .authority = authority });
    try std.testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, initialize_data[0..4], .little));
    try std.testing.expectEqual(authority, initialize_data[4..36].*);

    const withdraw_data = fixedIxData(SystemInstruction.WithdrawNonceAccount, TransferPayload, .{ .lamports = 42 });
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, withdraw_data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, withdraw_data[4..12], .little));

    const authorize_data = fixedIxData(SystemInstruction.AuthorizeNonceAccount, NonceAuthorityPayload, .{ .authority = authority });
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, authorize_data[0..4], .little));
    try std.testing.expectEqual(authority, authorize_data[4..36].*);

    const advance_data = discriminantOnlyData(SystemInstruction.AdvanceNonceAccount);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, advance_data[0..4], .little));

    const upgrade_data = discriminantOnlyData(SystemInstruction.UpgradeNonceAccount);
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, upgrade_data[0..4], .little));
}

test "system: seed-based helpers reject too-long seeds before CPI" {
    var account_acc: account_mod.Account = .{
        .borrow_state = account_mod.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{1} ** 32,
        .owner = .{2} ** 32,
        .lamports = 1_000,
        .data_len = 0,
    };
    var base_acc: account_mod.Account = .{
        .borrow_state = account_mod.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{3} ** 32,
        .owner = .{4} ** 32,
        .lamports = 1_000,
        .data_len = 0,
    };
    var to_acc: account_mod.Account = .{
        .borrow_state = account_mod.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{5} ** 32,
        .owner = .{6} ** 32,
        .lamports = 1_000,
        .data_len = 0,
    };
    var system_acc: account_mod.Account = .{
        .borrow_state = account_mod.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 1,
        ._padding = .{0} ** 4,
        .key = SYSTEM_PROGRAM_ID,
        .owner = .{0} ** 32,
        .lamports = 1_000,
        .data_len = 0,
    };

    const account_info = account_mod.AccountInfo{ .raw = &account_acc };
    const base_info = account_mod.AccountInfo{ .raw = &base_acc };
    const to_info = account_mod.AccountInfo{ .raw = &to_acc };
    const system_program_info = account_mod.AccountInfo{ .raw = &system_acc };

    const account = account_info.toCpiInfo();
    const base = base_info.toCpiInfo();
    const to = to_info.toCpiInfo();
    const system_program = system_program_info.toCpiInfo();
    const too_long = [_]u8{0} ** (MAX_SEED_LEN + 1);
    const owner: Pubkey = .{9} ** 32;

    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        createAccountWithSeed(account, to, system_program, base.key(), &too_long, 1, 1, &owner),
    );
    const bump_seed = [_]u8{1};
    const signer = cpi.Signer.from(&cpi.seedPack(.{ "base", &bump_seed }));
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        createAccountWithSeedSigned(account, to, system_program, base.key(), &too_long, 1, 1, &owner, &.{signer}),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        createAccountWithSeedSignedSingle(account, to, system_program, base.key(), &too_long, 1, 1, &owner, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        createNonceAccountWithSeed(account, to, base, base, system_program, base.key(), &too_long, &owner, 1),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        createNonceAccountWithSeedSigned(account, to, base, base, system_program, base.key(), &too_long, &owner, 1, &.{signer}),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        createNonceAccountWithSeedSignedSingle(account, to, base, base, system_program, base.key(), &too_long, &owner, 1, .{ "base", &bump_seed }),
    );

    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        assignWithSeed(account, base, system_program, &too_long, &owner),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        assignWithSeedSigned(account, base, system_program, &too_long, &owner, &.{signer}),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        assignWithSeedSignedSingle(account, base, system_program, &too_long, &owner, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        allocateWithSeed(account, base, system_program, &too_long, 1, &owner),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        allocateWithSeedSigned(account, base, system_program, &too_long, 1, &owner, &.{signer}),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        allocateWithSeedSignedSingle(account, base, system_program, &too_long, 1, &owner, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        transferWithSeed(account, base, to, system_program, &too_long, &owner, 1),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        transferWithSeedSigned(account, base, to, system_program, &too_long, &owner, 1, &.{signer}),
    );
    try std.testing.expectError(
        error.MaxSeedLengthExceeded,
        transferWithSeedSignedSingle(account, base, to, system_program, &too_long, &owner, 1, .{ "base", &bump_seed }),
    );
}

test "system: signed wrappers return InvalidArgument on host" {
    var account_acc: account_mod.Account = .{
        .borrow_state = account_mod.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{1} ** 32,
        .owner = .{2} ** 32,
        .lamports = 1_000,
        .data_len = 0,
    };
    var to_acc: account_mod.Account = .{
        .borrow_state = account_mod.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{3} ** 32,
        .owner = .{4} ** 32,
        .lamports = 1_000,
        .data_len = 0,
    };
    var sysvar_acc: account_mod.Account = .{
        .borrow_state = account_mod.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{7} ** 32,
        .owner = .{8} ** 32,
        .lamports = 1_000,
        .data_len = 0,
    };
    var system_acc: account_mod.Account = .{
        .borrow_state = account_mod.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 1,
        ._padding = .{0} ** 4,
        .key = SYSTEM_PROGRAM_ID,
        .owner = .{0} ** 32,
        .lamports = 1_000,
        .data_len = 0,
    };

    const account = (account_mod.AccountInfo{ .raw = &account_acc }).toCpiInfo();
    const to = (account_mod.AccountInfo{ .raw = &to_acc }).toCpiInfo();
    const sysvar = (account_mod.AccountInfo{ .raw = &sysvar_acc }).toCpiInfo();
    const system_program = (account_mod.AccountInfo{ .raw = &system_acc }).toCpiInfo();
    const owner: Pubkey = .{9} ** 32;
    const bump_seed = [_]u8{1};
    const signer = cpi.Signer.from(&cpi.seedPack(.{ "base", &bump_seed }));

    try std.testing.expectError(
        error.InvalidArgument,
        transferSigned(account, to, system_program, 1, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        transferSignedSingle(account, to, system_program, 1, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        assignSigned(account, system_program, &owner, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        assignSignedSingle(account, system_program, &owner, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        allocateSigned(account, system_program, 1, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        allocateSignedSingle(account, system_program, 1, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        createAccountWithSeedSigned(account, to, system_program, account.key(), "seed", 1, 1, &owner, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        createAccountWithSeedSignedSingle(account, to, system_program, account.key(), "seed", 1, 1, &owner, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        createNonceAccountSigned(account, to, sysvar, sysvar, system_program, &owner, 1, &.{&.{ "base", &bump_seed }}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        createNonceAccountSignedRaw(account, to, sysvar, sysvar, system_program, &owner, 1, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        createNonceAccountSignedSingle(account, to, sysvar, sysvar, system_program, &owner, 1, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        createNonceAccountWithSeedSigned(account, to, sysvar, sysvar, system_program, account.key(), "seed", &owner, 1, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        createNonceAccountWithSeedSignedSingle(account, to, sysvar, sysvar, system_program, account.key(), "seed", &owner, 1, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        advanceNonceAccountSigned(account, sysvar, account, system_program, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        advanceNonceAccountSignedSingle(account, sysvar, account, system_program, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        withdrawNonceAccountSigned(account, to, sysvar, sysvar, account, system_program, 1, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        withdrawNonceAccountSignedSingle(account, to, sysvar, sysvar, account, system_program, 1, .{ "base", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        authorizeNonceAccountSigned(account, account, system_program, &owner, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        authorizeNonceAccountSignedSingle(account, account, system_program, &owner, .{ "base", &bump_seed }),
    );
}

test "system: nonce state size matches Solana ABI" {
    try std.testing.expectEqual(@as(u64, 80), NONCE_STATE_SIZE);
}

test "system: SystemInstruction discriminant values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(SystemInstruction.CreateAccount));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(SystemInstruction.Assign));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(SystemInstruction.Transfer));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(SystemInstruction.CreateAccountWithSeed));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(SystemInstruction.AdvanceNonceAccount));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(SystemInstruction.WithdrawNonceAccount));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(SystemInstruction.InitializeNonceAccount));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(SystemInstruction.AuthorizeNonceAccount));
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(SystemInstruction.Allocate));
    try std.testing.expectEqual(@as(u32, 9), @intFromEnum(SystemInstruction.AllocateWithSeed));
    try std.testing.expectEqual(@as(u32, 10), @intFromEnum(SystemInstruction.AssignWithSeed));
    try std.testing.expectEqual(@as(u32, 11), @intFromEnum(SystemInstruction.TransferWithSeed));
    try std.testing.expectEqual(@as(u32, 12), @intFromEnum(SystemInstruction.UpgradeNonceAccount));
}
