//! SPL Token instruction builders — dual-target.
//!
//! This module is the byte-level half of the package. It stays close to the
//! upstream SPL Token interface: one helper per instruction, explicit account
//! order, explicit payload layout, caller-owned scratch.
//!
//! Each builder returns a `sol.cpi.Instruction` referencing caller-provided
//! `AccountMeta` scratch. The resulting value is valid for both on-chain CPI
//! (`sol.cpi.invoke(&ix, ...)`) and off-chain transaction construction.
//!
//! Reference: <https://github.com/solana-program/token/blob/main/program/src/instruction.rs>
//!
//! ## Single source of truth: `Spec`
//!
//! Every instruction is described by a comptime `Spec` value that pins down the
//! *three* protocol numbers the wire format is built from:
//!
//! - discriminant byte
//! - number of `AccountMeta`s
//! - payload byte count
//!
//! Both the builder signatures and the CPI wrapper scratch buffers derive their
//! array lengths from these specs (via `metasArray(spec)` /
//! `dataArray(spec)`), so the constants live in exactly one place.
//!
//! A `comptime` audit block at the bottom of this file re-derives the canonical
//! numbers from first principles (1-byte disc + named field sizes) and
//! `@compileError`s if any spec drifts.

const std = @import("std");
const sol = @import("solana_program_sdk");
const codec = @import("solana_codec");
const id = @import("id.zig");
const state = @import("state.zig");

const Pubkey = sol.Pubkey;
const AccountMeta = sol.cpi.AccountMeta;
const Instruction = sol.cpi.Instruction;

/// SPL Token instruction discriminants.
///
/// Unlike the upstream Rust interface, Zig's `enum(u8)` cannot carry payload
/// fields directly, so this type models the opcode space only. The associated
/// payload/account semantics live in the per-instruction builders below, and
/// each variant is documented here to keep the top-level instruction catalog
/// easy to scan.
pub const TokenInstruction = enum(u8) {
    /// `InitializeMint { decimals, mint_authority, freeze_authority }`.
    ///
    /// Legacy mint initializer: writable mint account + Rent sysvar account;
    /// authorities are carried in instruction data.
    initialize_mint = 0,

    /// `InitializeAccount`.
    ///
    /// Legacy token-account initializer: writable account + mint + owner +
    /// Rent sysvar accounts.
    initialize_account = 1,

    /// `InitializeMultisig { m }`.
    ///
    /// Legacy multisig initializer: writable multisig account + Rent sysvar +
    /// `N` readonly signer pubkeys.
    initialize_multisig = 2,

    /// `Transfer { amount }`.
    transfer = 3,

    /// `Approve { amount }`.
    approve = 4,

    /// `Revoke`.
    revoke = 5,

    /// `SetAuthority { authority_type, new_authority }`.
    set_authority = 6,

    /// `MintTo { amount }`.
    mint_to = 7,

    /// `Burn { amount }`.
    burn = 8,

    /// `CloseAccount`.
    close_account = 9,

    /// `FreezeAccount`.
    freeze_account = 10,

    /// `ThawAccount`.
    thaw_account = 11,

    /// `TransferChecked { amount, decimals }`.
    transfer_checked = 12,

    /// `ApproveChecked { amount, decimals }`.
    approve_checked = 13,

    /// `MintToChecked { amount, decimals }`.
    mint_to_checked = 14,

    /// `BurnChecked { amount, decimals }`.
    burn_checked = 15,

    /// `InitializeAccount2 { owner }`.
    ///
    /// Owner moves into instruction data; Rent sysvar is still an account.
    initialize_account2 = 16,

    /// `SyncNative`.
    sync_native = 17,

    /// `InitializeAccount3 { owner }`.
    ///
    /// Owner moves into instruction data and the Rent sysvar account is no
    /// longer required.
    initialize_account3 = 18,

    /// `InitializeMultisig2 { m }`.
    ///
    /// Modern multisig initializer without the Rent sysvar account.
    initialize_multisig2 = 19,

    /// `InitializeMint2 { decimals, mint_authority, freeze_authority }`.
    ///
    /// Modern mint initializer without the Rent sysvar account.
    initialize_mint2 = 20,

    /// `GetAccountDataSize`.
    ///
    /// Returns a little-endian `u64` via `sol_get_return_data`.
    get_account_data_size = 21,

    /// `InitializeImmutableOwner`.
    initialize_immutable_owner = 22,

    /// `AmountToUiAmount { amount }`.
    ///
    /// Returns a UTF-8 UI amount string via `sol_get_return_data`.
    amount_to_ui_amount = 23,

    /// `UiAmountToAmount { ui_amount }`.
    ///
    /// Returns a little-endian `u64` via `sol_get_return_data`.
    ui_amount_to_amount = 24,

    /// `Batch`.
    ///
    /// Pinocchio / p-token-style envelope of concatenated child instructions.
    batch = 255,
};

/// SPL Token authority kinds accepted by `SetAuthority`.
pub const AuthorityType = enum(u8) {
    /// Mint authority (`Mint.mint_authority`).
    MintTokens = 0,
    /// Freeze authority (`Mint.freeze_authority`).
    FreezeAccount = 1,
    /// Token-account owner authority.
    AccountOwner = 2,
    /// Token-account close authority.
    CloseAccount = 3,
};

pub const MIN_SIGNERS: usize = 1;
pub const MAX_SIGNERS: usize = state.MULTISIG_SIGNER_MAX;

pub const MultisigInstructionError = error{
    InvalidMultisigSignerCount,
    InvalidMultisigThreshold,
};

pub const BatchEntry = struct {
    accounts: []const AccountMeta,
    data: []const u8,
};

pub const BatchInstructionError = error{
    IncorrectProgramId,
    NestedBatchInstruction,
    TooManyAccounts,
    InstructionDataTooLong,
    ScratchTooSmall,
    IntegerOverflow,
};

// =============================================================================
// Spec — single source of truth per instruction.
// =============================================================================

/// Per-instruction wire-format spec. All three fields are part of
/// the on-chain protocol — change them only if upstream SPL Token
/// changes its layout.
///
/// Consumers should read these as `transfer_spec.accounts_len` /
/// `.data_len` rather than re-deriving the numbers; the comptime
/// audit block at the bottom of this file verifies each spec
/// against the canonical 1-byte-disc + field-byte-count formula.
pub const Spec = struct {
    /// First byte of the wire-format `data` buffer.
    disc: TokenInstruction,
    /// Number of `AccountMeta`s the instruction's metas slice
    /// carries (NOT counting the token-program account itself,
    /// which is appended to the CPI `accounts` slice separately).
    accounts_len: usize,
    /// Total `data` length in bytes (1 discriminator + payload).
    data_len: usize,
};

pub const initialize_mint_spec: Spec = .{ .disc = .initialize_mint, .accounts_len = 2, .data_len = 1 + 1 + 32 + 4 + 32 };
pub const initialize_account_spec: Spec = .{ .disc = .initialize_account, .accounts_len = 4, .data_len = 1 };
pub const initialize_multisig_spec: Spec = .{ .disc = .initialize_multisig, .accounts_len = 2, .data_len = 1 + 1 };
pub const transfer_spec: Spec = .{ .disc = .transfer, .accounts_len = 3, .data_len = 1 + 8 };
pub const approve_spec: Spec = .{ .disc = .approve, .accounts_len = 3, .data_len = 1 + 8 };
pub const revoke_spec: Spec = .{ .disc = .revoke, .accounts_len = 2, .data_len = 1 };
pub const set_authority_none_data_len: usize = 1 + 1 + 1;
pub const set_authority_spec: Spec = .{
    .disc = .set_authority,
    .accounts_len = 2,
    .data_len = set_authority_none_data_len + @sizeOf(Pubkey),
};
pub const freeze_account_spec: Spec = .{ .disc = .freeze_account, .accounts_len = 3, .data_len = 1 };
pub const thaw_account_spec: Spec = .{ .disc = .thaw_account, .accounts_len = 3, .data_len = 1 };
pub const transfer_checked_spec: Spec = .{ .disc = .transfer_checked, .accounts_len = 4, .data_len = 1 + 8 + 1 };
pub const approve_checked_spec: Spec = .{ .disc = .approve_checked, .accounts_len = 4, .data_len = 1 + 8 + 1 };
pub const mint_to_spec: Spec = .{ .disc = .mint_to, .accounts_len = 3, .data_len = 1 + 8 };
pub const mint_to_checked_spec: Spec = .{ .disc = .mint_to_checked, .accounts_len = 3, .data_len = 1 + 8 + 1 };
pub const burn_spec: Spec = .{ .disc = .burn, .accounts_len = 3, .data_len = 1 + 8 };
pub const burn_checked_spec: Spec = .{ .disc = .burn_checked, .accounts_len = 3, .data_len = 1 + 8 + 1 };
pub const close_account_spec: Spec = .{ .disc = .close_account, .accounts_len = 3, .data_len = 1 };
pub const initialize_account2_spec: Spec = .{ .disc = .initialize_account2, .accounts_len = 3, .data_len = 1 + 32 };
pub const sync_native_spec: Spec = .{ .disc = .sync_native, .accounts_len = 1, .data_len = 1 };
pub const initialize_account3_spec: Spec = .{ .disc = .initialize_account3, .accounts_len = 2, .data_len = 1 + 32 };
pub const initialize_multisig2_spec: Spec = .{ .disc = .initialize_multisig2, .accounts_len = 1, .data_len = 1 + 1 };
pub const initialize_mint2_spec: Spec = .{ .disc = .initialize_mint2, .accounts_len = 1, .data_len = 1 + 1 + 32 + 4 + 32 };
pub const get_account_data_size_spec: Spec = .{ .disc = .get_account_data_size, .accounts_len = 1, .data_len = 1 };
pub const initialize_immutable_owner_spec: Spec = .{ .disc = .initialize_immutable_owner, .accounts_len = 1, .data_len = 1 };
pub const amount_to_ui_amount_spec: Spec = .{ .disc = .amount_to_ui_amount, .accounts_len = 1, .data_len = 1 + 8 };
pub const ui_amount_to_amount_prefix_len: usize = 1;

/// Builder/wrapper-side helper: typed scratch-array sizes derived
/// from a `Spec`. Using the function form means every call site
/// reads `metasArray(transfer_spec)` instead of a bare `[3]`, so
/// rebinding the spec to a different instruction propagates.
/// Return the exact `AccountMeta` array type required by `spec`.
pub fn metasArray(comptime spec: Spec) type {
    return [spec.accounts_len]AccountMeta;
}

/// Return the exact instruction-data array type required by `spec`.
pub fn dataArray(comptime spec: Spec) type {
    return [spec.data_len]u8;
}

/// Return the exact `AccountMeta` array type required for a homogeneous
/// Batch whose children all share `spec` and whose count is `child_count`.
///
/// Example: two `transfer_checked_spec` children need
/// `transfer_checked_spec.accounts_len * 2` metas.
pub fn batchMetasArray(comptime spec: Spec, comptime child_count: usize) type {
    return [spec.accounts_len * child_count]AccountMeta;
}

/// Return the exact instruction-data array type required for a homogeneous
/// Batch whose children all share `spec` and whose count is `child_count`.
///
/// Wire format: `1` batch discriminator byte plus, for each child,
/// `1` byte for account count, `1` byte for payload length, and the child
/// payload itself.
pub fn batchDataArray(comptime spec: Spec, comptime child_count: usize) type {
    return [1 + child_count * (2 + spec.data_len)]u8;
}

/// Return an `AccountMeta` array large enough for a multisig instruction
/// with `base_accounts_len` fixed accounts plus up to `MAX_SIGNERS` extras.
pub fn multisigMetasArray(comptime base_accounts_len: usize) type {
    return [base_accounts_len + MAX_SIGNERS]AccountMeta;
}

/// Compute the total encoded byte length for `UiAmountToAmount`,
/// including the 1-byte discriminant.
pub fn uiAmountToAmountLen(ui_amount: []const u8) ?usize {
    return std.math.add(usize, ui_amount_to_amount_prefix_len, ui_amount.len) catch null;
}

/// Utility helper that mirrors the upstream `is_valid_signer_index` check.
pub inline fn isValidSignerIndex(index: usize) bool {
    return index >= MIN_SIGNERS and index <= MAX_SIGNERS;
}

// =============================================================================
// Comptime audit — re-derive each spec from first principles.
//
// If the SPL Token protocol ever adds a field, the canonical
// formula here will disagree with the spec's `data_len` constant
// and the build will fail with a precise message — no silent
// misencoding shipping to the cluster.
// =============================================================================

comptime {
    const PUBKEY_LEN: usize = 32;
    const COPTION_PUBKEY_LEN: usize = 4 + PUBKEY_LEN; // bincode COption<Pubkey>
    const AMOUNT_LEN: usize = 8;
    const DECIMALS_LEN: usize = 1;
    const AUTHORITY_TYPE_LEN: usize = 1;
    const COMPACT_OPTION_TAG_LEN: usize = 1;
    const DISC_LEN: usize = 1;

    // Each tuple = ( spec , expected accounts , expected payload-byte sum )
    const audits = .{
        .{ initialize_mint_spec, 2, DECIMALS_LEN + PUBKEY_LEN + COPTION_PUBKEY_LEN },
        .{ initialize_account_spec, 4, 0 },
        .{ initialize_multisig_spec, 2, 1 },
        .{ transfer_spec, 3, AMOUNT_LEN },
        .{ approve_spec, 3, AMOUNT_LEN },
        .{ revoke_spec, 2, 0 },
        .{ set_authority_spec, 2, AUTHORITY_TYPE_LEN + COMPACT_OPTION_TAG_LEN + PUBKEY_LEN },
        .{ freeze_account_spec, 3, 0 },
        .{ thaw_account_spec, 3, 0 },
        .{ transfer_checked_spec, 4, AMOUNT_LEN + DECIMALS_LEN },
        .{ approve_checked_spec, 4, AMOUNT_LEN + DECIMALS_LEN },
        .{ mint_to_spec, 3, AMOUNT_LEN },
        .{ mint_to_checked_spec, 3, AMOUNT_LEN + DECIMALS_LEN },
        .{ burn_spec, 3, AMOUNT_LEN },
        .{ burn_checked_spec, 3, AMOUNT_LEN + DECIMALS_LEN },
        .{ close_account_spec, 3, 0 },
        .{ initialize_account2_spec, 3, PUBKEY_LEN },
        .{ sync_native_spec, 1, 0 },
        .{ initialize_account3_spec, 2, PUBKEY_LEN },
        .{ initialize_multisig2_spec, 1, 1 },
        .{ initialize_mint2_spec, 1, DECIMALS_LEN + PUBKEY_LEN + COPTION_PUBKEY_LEN },
        .{ get_account_data_size_spec, 1, 0 },
        .{ initialize_immutable_owner_spec, 1, 0 },
        .{ amount_to_ui_amount_spec, 1, AMOUNT_LEN },
    };

    for (audits) |a| {
        const spec: Spec = a[0];
        const want_accounts: usize = a[1];
        const want_payload: usize = a[2];
        const want_data = DISC_LEN + want_payload;
        if (spec.accounts_len != want_accounts) {
            @compileError(std.fmt.comptimePrint(
                "spl-token spec drift: {s} accounts_len={d} but protocol says {d}",
                .{ @tagName(spec.disc), spec.accounts_len, want_accounts },
            ));
        }
        if (spec.data_len != want_data) {
            @compileError(std.fmt.comptimePrint(
                "spl-token spec drift: {s} data_len={d} but protocol says {d}={d}+payload({d})",
                .{ @tagName(spec.disc), spec.data_len, want_data, DISC_LEN, want_payload },
            ));
        }
    }
}

// =============================================================================
// Comptime instruction-data builders — one extern struct per shape.
// =============================================================================

const AmountIx = sol.instruction.comptimeInstructionData(
    u8,
    extern struct { amount: u64 align(1) },
);

// `align(1)` on every field prevents the extern struct from
// inserting trailing padding to round its size up to the largest
// field's alignment — without it `sizeOf({u64, u8}) == 16`, and we
// need the on-the-wire layout to be exactly 9 bytes.
const AmountDecimalsIx = sol.instruction.comptimeInstructionData(
    u8,
    extern struct { amount: u64 align(1), decimals: u8 },
);

const InitMintIx = sol.instruction.comptimeInstructionData(
    u8,
    extern struct {
        decimals: u8,
        mint_authority: Pubkey align(1),
        freeze_authority_tag: u32 align(1),
        freeze_authority: Pubkey align(1),
    },
);

const InitAccount3Ix = sol.instruction.comptimeInstructionData(
    u8,
    extern struct { owner: Pubkey align(1) },
);

// Sanity-check: the comptime-builder byte counts agree with the
// matching specs. Without this, the two layers could drift silently
// (spec says 10, builder writes 17 because someone forgot
// `align(1)`). The audit fires *before* the build emits any
// program code.
comptime {
    std.debug.assert(MAX_SIGNERS == state.MULTISIG_SIGNER_MAX);
    std.debug.assert(AmountIx.bytes == transfer_spec.data_len);
    std.debug.assert(InitMintIx.bytes == initialize_mint_spec.data_len);
    std.debug.assert(AmountIx.bytes == approve_spec.data_len);
    std.debug.assert(AmountIx.bytes == mint_to_spec.data_len);
    std.debug.assert(AmountIx.bytes == burn_spec.data_len);
    std.debug.assert(AmountIx.bytes == amount_to_ui_amount_spec.data_len);
    std.debug.assert(InitAccount3Ix.bytes == initialize_account2_spec.data_len);
    std.debug.assert(AmountDecimalsIx.bytes == transfer_checked_spec.data_len);
    std.debug.assert(AmountDecimalsIx.bytes == approve_checked_spec.data_len);
    std.debug.assert(AmountDecimalsIx.bytes == mint_to_checked_spec.data_len);
    std.debug.assert(AmountDecimalsIx.bytes == burn_checked_spec.data_len);
    std.debug.assert(InitAccount3Ix.bytes == initialize_account3_spec.data_len);
}

fn writeInstructionCOptionPubkey(out: []u8, value: ?*const Pubkey) void {
    _ = codec.writeCOptionPubkey(out, value) catch unreachable;
}

inline fn validateMultisigSignerCount(signer_pubkeys: []const Pubkey) MultisigInstructionError!void {
    if (signer_pubkeys.len < 1 or signer_pubkeys.len > MAX_SIGNERS) {
        return error.InvalidMultisigSignerCount;
    }
}

inline fn validateMultisigThreshold(
    threshold: u8,
    signer_pubkeys: []const Pubkey,
) MultisigInstructionError!void {
    try validateMultisigSignerCount(signer_pubkeys);
    if (threshold == 0 or threshold > signer_pubkeys.len) {
        return error.InvalidMultisigThreshold;
    }
}

fn appendReadonlySignerMetas(
    metas: []AccountMeta,
    start_index: usize,
    signer_pubkeys: []const Pubkey,
) MultisigInstructionError![]const AccountMeta {
    try validateMultisigSignerCount(signer_pubkeys);
    for (signer_pubkeys, 0..) |_, i| {
        metas[start_index + i] = AccountMeta.signer(&signer_pubkeys[i]);
    }
    return metas[0 .. start_index + signer_pubkeys.len];
}

fn appendReadonlyMetas(
    metas: []AccountMeta,
    start_index: usize,
    signer_pubkeys: []const Pubkey,
) MultisigInstructionError![]const AccountMeta {
    try validateMultisigSignerCount(signer_pubkeys);
    for (signer_pubkeys, 0..) |_, i| {
        metas[start_index + i] = AccountMeta.readonly(&signer_pubkeys[i]);
    }
    return metas[0 .. start_index + signer_pubkeys.len];
}

/// Reborrow an `Instruction` as a lightweight `BatchEntry`.
pub inline fn asBatchEntry(ix: Instruction) BatchEntry {
    return .{ .accounts = ix.accounts, .data = ix.data };
}

fn validateBatchEntry(entry: BatchEntry) BatchInstructionError!void {
    if (entry.accounts.len > std.math.maxInt(u8)) return error.TooManyAccounts;
    if (entry.data.len > std.math.maxInt(u8)) return error.InstructionDataTooLong;
    if (entry.data.len > 0 and entry.data[0] == @intFromEnum(TokenInstruction.batch)) {
        return error.NestedBatchInstruction;
    }
}

/// Compute the flattened account-meta count required by `batch(entries...)`.
pub fn batchEntriesAccountsLen(entries: []const BatchEntry) BatchInstructionError!usize {
    var total: usize = 0;
    for (entries) |entry| {
        try validateBatchEntry(entry);
        total = std.math.add(usize, total, entry.accounts.len) catch return error.IntegerOverflow;
    }
    return total;
}

/// Compute the total encoded data length required by `batch(entries...)`.
pub fn batchEntriesDataLen(entries: []const BatchEntry) BatchInstructionError!usize {
    var total: usize = 1;
    for (entries) |entry| {
        try validateBatchEntry(entry);
        total = std.math.add(usize, total, 2) catch return error.IntegerOverflow;
        total = std.math.add(usize, total, entry.data.len) catch return error.IntegerOverflow;
    }
    return total;
}

/// Build a `Batch` instruction for `program_id` from prevalidated
/// `BatchEntry` values.
pub fn batchEntriesForProgram(
    program_id: *const Pubkey,
    entries: []const BatchEntry,
    metas: []AccountMeta,
    data: []u8,
) BatchInstructionError!Instruction {
    const accounts_len = try batchEntriesAccountsLen(entries);
    const data_len = try batchEntriesDataLen(entries);
    if (metas.len < accounts_len or data.len < data_len) return error.ScratchTooSmall;

    data[0] = @intFromEnum(TokenInstruction.batch);

    var meta_offset: usize = 0;
    var data_offset: usize = 1;
    for (entries) |entry| {
        data[data_offset] = @intCast(entry.accounts.len);
        data[data_offset + 1] = @intCast(entry.data.len);
        data_offset += 2;

        @memcpy(metas[meta_offset..][0..entry.accounts.len], entry.accounts);
        @memcpy(data[data_offset..][0..entry.data.len], entry.data);

        meta_offset += entry.accounts.len;
        data_offset += entry.data.len;
    }

    return .{
        .program_id = program_id,
        .accounts = metas[0..accounts_len],
        .data = data[0..data_len],
    };
}

/// Build a `Batch` instruction for `program_id` from child
/// `Instruction` values that already target that program.
pub fn batchForProgram(
    program_id: *const Pubkey,
    children: []const Instruction,
    metas: []AccountMeta,
    data: []u8,
) BatchInstructionError!Instruction {
    var total_accounts: usize = 0;
    var total_data: usize = 1;
    for (children) |child| {
        if (!sol.pubkey.pubkeyEq(child.program_id, program_id)) return error.IncorrectProgramId;
        try validateBatchEntry(asBatchEntry(child));
        total_accounts = std.math.add(usize, total_accounts, child.accounts.len) catch return error.IntegerOverflow;
        total_data = std.math.add(usize, total_data, 2) catch return error.IntegerOverflow;
        total_data = std.math.add(usize, total_data, child.data.len) catch return error.IntegerOverflow;
    }
    if (metas.len < total_accounts or data.len < total_data) return error.ScratchTooSmall;

    data[0] = @intFromEnum(TokenInstruction.batch);

    var meta_offset: usize = 0;
    var data_offset: usize = 1;
    for (children) |child| {
        data[data_offset] = @intCast(child.accounts.len);
        data[data_offset + 1] = @intCast(child.data.len);
        data_offset += 2;

        @memcpy(metas[meta_offset..][0..child.accounts.len], child.accounts);
        @memcpy(data[data_offset..][0..child.data.len], child.data);

        meta_offset += child.accounts.len;
        data_offset += child.data.len;
    }

    return .{
        .program_id = program_id,
        .accounts = metas[0..total_accounts],
        .data = data[0..total_data],
    };
}

/// Build a classic-SPL-Token `Batch` instruction from child
/// `Instruction` values.
pub fn batch(
    children: []const Instruction,
    metas: []AccountMeta,
    data: []u8,
) BatchInstructionError!Instruction {
    return batchForProgram(&id.PROGRAM_ID, children, metas, data);
}

// =============================================================================
// Account-meta wiring — every instruction below documents its
// expected meta order and lets the caller hand us scratch storage
// so the builders are allocation-free.
// =============================================================================

/// `InitializeMint { decimals, mint_authority, freeze_authority }` —
/// discriminant 0.
///
/// Accounts expected by this instruction (in order):
///   0. mint account — writable
///   1. rent sysvar  — readonly
pub fn initializeMint(
    mint: *const Pubkey,
    decimals: u8,
    mint_authority: *const Pubkey,
    freeze_authority: ?*const Pubkey,
    metas: *metasArray(initialize_mint_spec),
    data: *dataArray(initialize_mint_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.initialize_mint);
    data[1] = decimals;
    @memcpy(data[2..34], mint_authority);
    writeInstructionCOptionPubkey(data[34..70], freeze_authority);
    metas[0] = AccountMeta.writable(mint);
    metas[1] = AccountMeta.readonly(&sol.rent_id);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `InitializeAccount` — discriminant 1.
///
/// Accounts expected by this instruction (in order):
///   0. account — writable
///   1. mint    — readonly
///   2. owner   — readonly
///   3. rent    — readonly
pub fn initializeAccount(
    account: *const Pubkey,
    mint: *const Pubkey,
    owner: *const Pubkey,
    metas: *metasArray(initialize_account_spec),
    data: *dataArray(initialize_account_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.initialize_account);
    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.readonly(mint);
    metas[2] = AccountMeta.readonly(owner);
    metas[3] = AccountMeta.readonly(&sol.rent_id);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `InitializeMultisig { m }` — discriminant 2.
///
/// Accounts expected by this instruction (in order):
///   0. multisig account — writable
///   1. rent sysvar      — readonly
///   2+. signer pubkeys  — readonly, caller order
pub fn initializeMultisig(
    multisig: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    threshold: u8,
    metas: *multisigMetasArray(initialize_multisig_spec.accounts_len),
    data: *dataArray(initialize_multisig_spec),
) MultisigInstructionError!Instruction {
    try validateMultisigThreshold(threshold, signer_pubkeys);
    data[0] = @intFromEnum(TokenInstruction.initialize_multisig);
    data[1] = threshold;
    metas[0] = AccountMeta.writable(multisig);
    metas[1] = AccountMeta.readonly(&sol.rent_id);
    const accounts = try appendReadonlyMetas(metas, 2, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `Transfer { amount }` — discriminant 3.
///
/// Accounts expected by this instruction (in order):
///   0. source       — writable
///   1. destination  — writable
///   2. authority    — signer
pub fn transfer(
    source: *const Pubkey,
    destination: *const Pubkey,
    authority: *const Pubkey,
    amount: u64,
    /// Caller-owned scratch — must be sized exactly to
    /// `transfer_spec.accounts_len` / `.data_len`. Both arrays are
    /// declared via `metasArray(transfer_spec)` /
    /// `dataArray(transfer_spec)` so the type checker rejects any
    /// caller whose buffer doesn't match the on-chain protocol.
    metas: *metasArray(transfer_spec),
    data: *dataArray(transfer_spec),
) Instruction {
    data.* = AmountIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.transfer),
        .{ .amount = amount },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.writable(destination);
    metas[2] = AccountMeta.signer(authority);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `Transfer { amount }` with a multisig authority.
///
/// Accounts expected by this instruction (in order):
///   0. source              — writable
///   1. destination         — writable
///   2. multisig authority  — readonly
///   3+. signer pubkeys     — readonly signers, caller order
pub fn transferMultisig(
    source: *const Pubkey,
    destination: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    amount: u64,
    metas: *multisigMetasArray(transfer_spec.accounts_len),
    data: *dataArray(transfer_spec),
) MultisigInstructionError!Instruction {
    data.* = AmountIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.transfer),
        .{ .amount = amount },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.writable(destination);
    metas[2] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 3, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `TransferChecked { amount, decimals }` — discriminant 12.
///
/// Accounts expected by this instruction (in order):
///   0. source       — writable
///   1. mint         — readonly  (decimals checked against this)
///   2. destination  — writable
///   3. authority    — signer
pub fn transferChecked(
    source: *const Pubkey,
    mint: *const Pubkey,
    destination: *const Pubkey,
    authority: *const Pubkey,
    amount: u64,
    decimals: u8,
    metas: *metasArray(transfer_checked_spec),
    data: *dataArray(transfer_checked_spec),
) Instruction {
    data.* = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.transfer_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.readonly(mint);
    metas[2] = AccountMeta.writable(destination);
    metas[3] = AccountMeta.signer(authority);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `TransferChecked { amount, decimals }` with a multisig authority.
pub fn transferCheckedMultisig(
    source: *const Pubkey,
    mint: *const Pubkey,
    destination: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    amount: u64,
    decimals: u8,
    metas: *multisigMetasArray(transfer_checked_spec.accounts_len),
    data: *dataArray(transfer_checked_spec),
) MultisigInstructionError!Instruction {
    data.* = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.transfer_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.readonly(mint);
    metas[2] = AccountMeta.writable(destination);
    metas[3] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 4, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `Approve { amount }` — discriminant 4.
///
/// Accounts expected by this instruction (in order):
///   0. source    — writable
///   1. delegate  — readonly
///   2. owner     — signer
pub fn approve(
    source: *const Pubkey,
    delegate: *const Pubkey,
    owner: *const Pubkey,
    amount: u64,
    metas: *metasArray(approve_spec),
    data: *dataArray(approve_spec),
) Instruction {
    data.* = AmountIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.approve),
        .{ .amount = amount },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.readonly(delegate);
    metas[2] = AccountMeta.signer(owner);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `Approve { amount }` with a multisig owner authority.
pub fn approveMultisig(
    source: *const Pubkey,
    delegate: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    amount: u64,
    metas: *multisigMetasArray(approve_spec.accounts_len),
    data: *dataArray(approve_spec),
) MultisigInstructionError!Instruction {
    data.* = AmountIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.approve),
        .{ .amount = amount },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.readonly(delegate);
    metas[2] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 3, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `ApproveChecked { amount, decimals }` — discriminant 13.
///
/// Accounts expected by this instruction (in order):
///   0. source    — writable
///   1. mint      — readonly
///   2. delegate  — readonly
///   3. owner     — signer
pub fn approveChecked(
    source: *const Pubkey,
    mint: *const Pubkey,
    delegate: *const Pubkey,
    owner: *const Pubkey,
    amount: u64,
    decimals: u8,
    metas: *metasArray(approve_checked_spec),
    data: *dataArray(approve_checked_spec),
) Instruction {
    data.* = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.approve_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.readonly(mint);
    metas[2] = AccountMeta.readonly(delegate);
    metas[3] = AccountMeta.signer(owner);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `ApproveChecked { amount, decimals }` with a multisig owner authority.
pub fn approveCheckedMultisig(
    source: *const Pubkey,
    mint: *const Pubkey,
    delegate: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    amount: u64,
    decimals: u8,
    metas: *multisigMetasArray(approve_checked_spec.accounts_len),
    data: *dataArray(approve_checked_spec),
) MultisigInstructionError!Instruction {
    data.* = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.approve_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.readonly(mint);
    metas[2] = AccountMeta.readonly(delegate);
    metas[3] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 4, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `Revoke` — discriminant 5.
///
/// Accounts expected by this instruction (in order):
///   0. source    — writable
///   1. owner     — signer
pub fn revoke(
    source: *const Pubkey,
    owner: *const Pubkey,
    metas: *metasArray(revoke_spec),
    data: *dataArray(revoke_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.revoke);
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.signer(owner);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `Revoke` with a multisig owner authority.
pub fn revokeMultisig(
    source: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    metas: *multisigMetasArray(revoke_spec.accounts_len),
    data: *dataArray(revoke_spec),
) MultisigInstructionError!Instruction {
    data[0] = @intFromEnum(TokenInstruction.revoke);
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 2, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `SetAuthority { authority_type, new_authority }` —
/// discriminant 6.
///
/// Accounts expected by this instruction (in order):
///   0. mint_or_account    — writable
///   1. current_authority  — signer
///
/// The wire-format uses the compact instruction-level option used
/// by classic SPL Token:
///   * `Some(pubkey)` => `[6, authority_type, 1, pubkey(32)]`
///   * `None`         => `[6, authority_type, 0]`
///
/// `data` is sized for the longest form (35 bytes), but the
/// returned instruction slice shrinks to 3 bytes when
/// `new_authority` is `null`.
pub fn setAuthority(
    mint_or_account: *const Pubkey,
    current_authority: *const Pubkey,
    authority_type: AuthorityType,
    new_authority: ?*const Pubkey,
    metas: *metasArray(set_authority_spec),
    data: *dataArray(set_authority_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.set_authority);
    data[1] = @intFromEnum(authority_type);

    const data_len = if (new_authority) |authority| blk: {
        data[2] = 1;
        @memcpy(data[3..set_authority_spec.data_len], authority);
        break :blk set_authority_spec.data_len;
    } else blk: {
        data[2] = 0;
        break :blk set_authority_none_data_len;
    };

    metas[0] = AccountMeta.writable(mint_or_account);
    metas[1] = AccountMeta.signer(current_authority);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data[0..data_len],
    };
}

/// `SetAuthority` with a multisig current authority.
pub fn setAuthorityMultisig(
    mint_or_account: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    authority_type: AuthorityType,
    new_authority: ?*const Pubkey,
    metas: *multisigMetasArray(set_authority_spec.accounts_len),
    data: *dataArray(set_authority_spec),
) MultisigInstructionError!Instruction {
    data[0] = @intFromEnum(TokenInstruction.set_authority);
    data[1] = @intFromEnum(authority_type);

    const data_len = if (new_authority) |authority| blk: {
        data[2] = 1;
        @memcpy(data[3..set_authority_spec.data_len], authority);
        break :blk set_authority_spec.data_len;
    } else blk: {
        data[2] = 0;
        break :blk set_authority_none_data_len;
    };

    metas[0] = AccountMeta.writable(mint_or_account);
    metas[1] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 2, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data[0..data_len],
    };
}

/// `FreezeAccount` — discriminant 10.
///
/// Accounts expected by this instruction (in order):
///   0. account            — writable
///   1. mint               — readonly
///   2. freeze_authority   — signer
pub fn freezeAccount(
    account: *const Pubkey,
    mint: *const Pubkey,
    freeze_authority: *const Pubkey,
    metas: *metasArray(freeze_account_spec),
    data: *dataArray(freeze_account_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.freeze_account);
    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.readonly(mint);
    metas[2] = AccountMeta.signer(freeze_authority);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `FreezeAccount` with a multisig freeze authority.
pub fn freezeAccountMultisig(
    account: *const Pubkey,
    mint: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    metas: *multisigMetasArray(freeze_account_spec.accounts_len),
    data: *dataArray(freeze_account_spec),
) MultisigInstructionError!Instruction {
    data[0] = @intFromEnum(TokenInstruction.freeze_account);
    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.readonly(mint);
    metas[2] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 3, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `ThawAccount` — discriminant 11.
///
/// Accounts expected by this instruction (in order):
///   0. account            — writable
///   1. mint               — readonly
///   2. freeze_authority   — signer
pub fn thawAccount(
    account: *const Pubkey,
    mint: *const Pubkey,
    freeze_authority: *const Pubkey,
    metas: *metasArray(thaw_account_spec),
    data: *dataArray(thaw_account_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.thaw_account);
    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.readonly(mint);
    metas[2] = AccountMeta.signer(freeze_authority);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `ThawAccount` with a multisig freeze authority.
pub fn thawAccountMultisig(
    account: *const Pubkey,
    mint: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    metas: *multisigMetasArray(thaw_account_spec.accounts_len),
    data: *dataArray(thaw_account_spec),
) MultisigInstructionError!Instruction {
    data[0] = @intFromEnum(TokenInstruction.thaw_account);
    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.readonly(mint);
    metas[2] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 3, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `MintTo { amount }` — discriminant 7.
///
/// Accounts expected by this instruction (in order):
///   0. mint                — writable
///   1. destination account — writable
///   2. mint authority      — signer
pub fn mintTo(
    mint: *const Pubkey,
    destination: *const Pubkey,
    authority: *const Pubkey,
    amount: u64,
    metas: *metasArray(mint_to_spec),
    data: *dataArray(mint_to_spec),
) Instruction {
    data.* = AmountIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.mint_to),
        .{ .amount = amount },
    );
    metas[0] = AccountMeta.writable(mint);
    metas[1] = AccountMeta.writable(destination);
    metas[2] = AccountMeta.signer(authority);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `MintTo { amount }` with a multisig mint authority.
pub fn mintToMultisig(
    mint: *const Pubkey,
    destination: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    amount: u64,
    metas: *multisigMetasArray(mint_to_spec.accounts_len),
    data: *dataArray(mint_to_spec),
) MultisigInstructionError!Instruction {
    data.* = AmountIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.mint_to),
        .{ .amount = amount },
    );
    metas[0] = AccountMeta.writable(mint);
    metas[1] = AccountMeta.writable(destination);
    metas[2] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 3, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `MintToChecked { amount, decimals }` — discriminant 14. Same
/// account order as `mintTo`, additional decimals safety check.
pub fn mintToChecked(
    mint: *const Pubkey,
    destination: *const Pubkey,
    authority: *const Pubkey,
    amount: u64,
    decimals: u8,
    metas: *metasArray(mint_to_checked_spec),
    data: *dataArray(mint_to_checked_spec),
) Instruction {
    data.* = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.mint_to_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    metas[0] = AccountMeta.writable(mint);
    metas[1] = AccountMeta.writable(destination);
    metas[2] = AccountMeta.signer(authority);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `MintToChecked { amount, decimals }` with a multisig mint authority.
pub fn mintToCheckedMultisig(
    mint: *const Pubkey,
    destination: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    amount: u64,
    decimals: u8,
    metas: *multisigMetasArray(mint_to_checked_spec.accounts_len),
    data: *dataArray(mint_to_checked_spec),
) MultisigInstructionError!Instruction {
    data.* = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.mint_to_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    metas[0] = AccountMeta.writable(mint);
    metas[1] = AccountMeta.writable(destination);
    metas[2] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 3, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `Burn { amount }` — discriminant 8.
///
/// Accounts expected by this instruction (in order):
///   0. source    — writable
///   1. mint      — writable
///   2. authority — signer
pub fn burn(
    source: *const Pubkey,
    mint: *const Pubkey,
    authority: *const Pubkey,
    amount: u64,
    metas: *metasArray(burn_spec),
    data: *dataArray(burn_spec),
) Instruction {
    data.* = AmountIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.burn),
        .{ .amount = amount },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.writable(mint);
    metas[2] = AccountMeta.signer(authority);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `Burn { amount }` with a multisig owner/delegate authority.
pub fn burnMultisig(
    source: *const Pubkey,
    mint: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    amount: u64,
    metas: *multisigMetasArray(burn_spec.accounts_len),
    data: *dataArray(burn_spec),
) MultisigInstructionError!Instruction {
    data.* = AmountIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.burn),
        .{ .amount = amount },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.writable(mint);
    metas[2] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 3, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `BurnChecked { amount, decimals }` — discriminant 15.
pub fn burnChecked(
    source: *const Pubkey,
    mint: *const Pubkey,
    authority: *const Pubkey,
    amount: u64,
    decimals: u8,
    metas: *metasArray(burn_checked_spec),
    data: *dataArray(burn_checked_spec),
) Instruction {
    data.* = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.burn_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.writable(mint);
    metas[2] = AccountMeta.signer(authority);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `BurnChecked { amount, decimals }` with a multisig owner/delegate authority.
pub fn burnCheckedMultisig(
    source: *const Pubkey,
    mint: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    amount: u64,
    decimals: u8,
    metas: *multisigMetasArray(burn_checked_spec.accounts_len),
    data: *dataArray(burn_checked_spec),
) MultisigInstructionError!Instruction {
    data.* = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.burn_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    metas[0] = AccountMeta.writable(source);
    metas[1] = AccountMeta.writable(mint);
    metas[2] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 3, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `CloseAccount` — discriminant 9.
///
/// Accounts expected by this instruction (in order):
///   0. account   — writable (the token account being closed)
///   1. destination — writable (where the rent lamports go)
///   2. authority   — signer  (close authority or owner)
pub fn closeAccount(
    account: *const Pubkey,
    destination: *const Pubkey,
    authority: *const Pubkey,
    metas: *metasArray(close_account_spec),
    data: *dataArray(close_account_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.close_account);
    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.writable(destination);
    metas[2] = AccountMeta.signer(authority);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `CloseAccount` with a multisig close authority or owner.
pub fn closeAccountMultisig(
    account: *const Pubkey,
    destination: *const Pubkey,
    multisig_authority: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    metas: *multisigMetasArray(close_account_spec.accounts_len),
    data: *dataArray(close_account_spec),
) MultisigInstructionError!Instruction {
    data[0] = @intFromEnum(TokenInstruction.close_account);
    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.writable(destination);
    metas[2] = AccountMeta.readonly(multisig_authority);
    const accounts = try appendReadonlySignerMetas(metas, 3, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `SyncNative` — discriminant 17.
///
/// Accounts expected by this instruction (in order):
///   0. native token account — writable
pub fn syncNative(
    account: *const Pubkey,
    metas: *metasArray(sync_native_spec),
    data: *dataArray(sync_native_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.sync_native);
    metas[0] = AccountMeta.writable(account);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `InitializeAccount2 { owner }` — discriminant 16.
///
/// Accounts expected by this instruction (in order):
///   0. account — writable
///   1. mint    — readonly
///   2. rent    — readonly
///
/// Mirrors the upstream interface variant where the owner pubkey is carried in
/// instruction data but the Rent sysvar is still supplied as an account.
pub fn initializeAccount2(
    account: *const Pubkey,
    mint: *const Pubkey,
    owner: *const Pubkey,
    metas: *metasArray(initialize_account2_spec),
    data: *dataArray(initialize_account2_spec),
) Instruction {
    data.* = InitAccount3Ix.initWithDiscriminant(
        @intFromEnum(TokenInstruction.initialize_account2),
        .{ .owner = owner.* },
    );
    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.readonly(mint);
    metas[2] = AccountMeta.readonly(&sol.rent_id);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `InitializeAccount3 { owner }` — discriminant 18.
///
/// Accounts expected by this instruction (in order):
///   0. account — writable
///   1. mint    — readonly
///
/// (`Account3` skips the rent sysvar and the separate "owner"
/// account that `InitializeAccount` requires.)
pub fn initializeAccount3(
    account: *const Pubkey,
    mint: *const Pubkey,
    owner: *const Pubkey,
    metas: *metasArray(initialize_account3_spec),
    data: *dataArray(initialize_account3_spec),
) Instruction {
    data.* = InitAccount3Ix.initWithDiscriminant(
        @intFromEnum(TokenInstruction.initialize_account3),
        .{ .owner = owner.* },
    );
    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.readonly(mint);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `InitializeMultisig2 { m }` — discriminant 19.
///
/// Accounts expected by this instruction (in order):
///   0. multisig account — writable
///   1+. signer pubkeys  — readonly, caller order
///
/// `threshold` must satisfy `1 <= threshold <= signer_pubkeys.len <= 11`.
pub fn initializeMultisig2(
    multisig: *const Pubkey,
    signer_pubkeys: []const Pubkey,
    threshold: u8,
    metas: *multisigMetasArray(initialize_multisig2_spec.accounts_len),
    data: *dataArray(initialize_multisig2_spec),
) MultisigInstructionError!Instruction {
    try validateMultisigThreshold(threshold, signer_pubkeys);
    data[0] = @intFromEnum(TokenInstruction.initialize_multisig2);
    data[1] = threshold;
    metas[0] = AccountMeta.writable(multisig);
    const accounts = try appendReadonlyMetas(metas, 1, signer_pubkeys);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = accounts,
        .data = data,
    };
}

/// `InitializeMint2 { decimals, mint_authority, freeze_authority }`
/// — discriminant 20.
///
/// Account metas: just the mint account itself (writable). Pass
/// `null` for `freeze_authority` to leave it disabled.
///
/// Body layout: `[disc(1), decimals(1), mint_auth(32),
/// freeze_tag(4 LE), freeze_pk(32)]`. When `freeze_authority` is
/// `null`, `freeze_tag` is zero and the 32 freeze-pubkey bytes are
/// zero-padding (still part of the on-the-wire payload — `Mint2`
/// always reads the fixed 67 bytes).
pub fn initializeMint2(
    mint: *const Pubkey,
    decimals: u8,
    mint_authority: *const Pubkey,
    freeze_authority: ?*const Pubkey,
    metas: *metasArray(initialize_mint2_spec),
    data: *dataArray(initialize_mint2_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.initialize_mint2);
    data[1] = decimals;
    @memcpy(data[2..34], mint_authority);
    writeInstructionCOptionPubkey(data[34..70], freeze_authority);
    metas[0] = AccountMeta.writable(mint);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `GetAccountDataSize` — discriminant 21.
///
/// Accounts expected by this instruction (in order):
///   0. mint — readonly
pub fn getAccountDataSize(
    mint: *const Pubkey,
    metas: *metasArray(get_account_data_size_spec),
    data: *dataArray(get_account_data_size_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.get_account_data_size);
    metas[0] = AccountMeta.readonly(mint);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `InitializeImmutableOwner` — discriminant 22.
///
/// Accounts expected by this instruction (in order):
///   0. account — writable
pub fn initializeImmutableOwner(
    account: *const Pubkey,
    metas: *metasArray(initialize_immutable_owner_spec),
    data: *dataArray(initialize_immutable_owner_spec),
) Instruction {
    data[0] = @intFromEnum(TokenInstruction.initialize_immutable_owner);
    metas[0] = AccountMeta.writable(account);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `AmountToUiAmount { amount }` — discriminant 23.
///
/// Accounts expected by this instruction (in order):
///   0. mint — readonly
pub fn amountToUiAmount(
    mint: *const Pubkey,
    amount: u64,
    metas: *metasArray(amount_to_ui_amount_spec),
    data: *dataArray(amount_to_ui_amount_spec),
) Instruction {
    data.* = AmountIx.initWithDiscriminant(
        @intFromEnum(TokenInstruction.amount_to_ui_amount),
        .{ .amount = amount },
    );
    metas[0] = AccountMeta.readonly(mint);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data,
    };
}

/// `UiAmountToAmount { ui_amount }` — discriminant 24.
///
/// Accounts expected by this instruction (in order):
///   0. mint — readonly
pub fn uiAmountToAmount(
    mint: *const Pubkey,
    ui_amount: []const u8,
    metas: *metasArray(get_account_data_size_spec),
    data: []u8,
) !Instruction {
    const data_len = uiAmountToAmountLen(ui_amount) orelse return error.InvalidArgument;
    if (data.len < data_len) return error.InvalidArgument;

    data[0] = @intFromEnum(TokenInstruction.ui_amount_to_amount);
    @memcpy(data[1..data_len], ui_amount);
    metas[0] = AccountMeta.readonly(mint);
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = metas,
        .data = data[0..data_len],
    };
}

// =============================================================================
// Tests — byte-level fidelity vs. canonical Rust encoding.
// =============================================================================

fn expectMeta(
    actual: AccountMeta,
    expected_key: *const Pubkey,
    expected_writable: u8,
    expected_signer: u8,
) !void {
    try std.testing.expectEqual(expected_key, actual.pubkey);
    try std.testing.expectEqual(expected_writable, actual.is_writable);
    try std.testing.expectEqual(expected_signer, actual.is_signer);
}

fn expectReadonlySignerTail(
    actual: []const AccountMeta,
    start_index: usize,
    signer_pubkeys: []const Pubkey,
) !void {
    try std.testing.expectEqual(start_index + signer_pubkeys.len, actual.len);
    for (signer_pubkeys, 0..) |_, i| {
        try expectMeta(actual[start_index + i], &signer_pubkeys[i], 0, 1);
    }
}

fn expectReadonlyTail(
    actual: []const AccountMeta,
    start_index: usize,
    signer_pubkeys: []const Pubkey,
) !void {
    try std.testing.expectEqual(start_index + signer_pubkeys.len, actual.len);
    for (signer_pubkeys, 0..) |_, i| {
        try expectMeta(actual[start_index + i], &signer_pubkeys[i], 0, 0);
    }
}

fn signerPubkeys(comptime count: usize, start: u8) [count]Pubkey {
    var keys: [count]Pubkey = undefined;
    inline for (0..count) |i| {
        keys[i] = .{@as(u8, start + @as(u8, @intCast(i)))} ** 32;
    }
    return keys;
}

test "v0.3 authority/freeze/native specs and discriminants stay canonical" {
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(TokenInstruction.approve));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(TokenInstruction.revoke));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(TokenInstruction.set_authority));
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(TokenInstruction.freeze_account));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(TokenInstruction.thaw_account));
    try std.testing.expectEqual(@as(u8, 13), @intFromEnum(TokenInstruction.approve_checked));
    try std.testing.expectEqual(@as(u8, 17), @intFromEnum(TokenInstruction.sync_native));
    try std.testing.expectEqual(@as(u8, 19), @intFromEnum(TokenInstruction.initialize_multisig2));
    try std.testing.expectEqual(@as(u8, 21), @intFromEnum(TokenInstruction.get_account_data_size));
    try std.testing.expectEqual(@as(u8, 22), @intFromEnum(TokenInstruction.initialize_immutable_owner));
    try std.testing.expectEqual(@as(u8, 23), @intFromEnum(TokenInstruction.amount_to_ui_amount));
    try std.testing.expectEqual(@as(u8, 24), @intFromEnum(TokenInstruction.ui_amount_to_amount));
    try std.testing.expectEqual(@as(u8, 255), @intFromEnum(TokenInstruction.batch));

    try std.testing.expectEqual(@as(usize, 3), approve_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 9), approve_spec.data_len);
    try std.testing.expectEqual(@as(usize, 2), revoke_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 1), revoke_spec.data_len);
    try std.testing.expectEqual(@as(usize, 2), set_authority_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 35), set_authority_spec.data_len);
    try std.testing.expectEqual(@as(usize, 3), set_authority_none_data_len);
    try std.testing.expectEqual(@as(usize, 3), freeze_account_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 1), freeze_account_spec.data_len);
    try std.testing.expectEqual(@as(usize, 3), thaw_account_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 1), thaw_account_spec.data_len);
    try std.testing.expectEqual(@as(usize, 4), approve_checked_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 10), approve_checked_spec.data_len);
    try std.testing.expectEqual(@as(usize, 1), sync_native_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 1), sync_native_spec.data_len);
    try std.testing.expectEqual(@as(usize, 1), initialize_multisig2_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 2), initialize_multisig2_spec.data_len);
    try std.testing.expectEqual(@as(usize, 1), get_account_data_size_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 1), get_account_data_size_spec.data_len);
    try std.testing.expectEqual(@as(usize, 1), initialize_immutable_owner_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 1), initialize_immutable_owner_spec.data_len);
    try std.testing.expectEqual(@as(usize, 1), amount_to_ui_amount_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 9), amount_to_ui_amount_spec.data_len);
    try std.testing.expectEqual(@as(usize, 1), ui_amount_to_amount_prefix_len);
}

test "AuthorityType is canonical" {
    const cases = [_]struct {
        authority_type: AuthorityType,
        value: u8,
    }{
        .{ .authority_type = .MintTokens, .value = 0 },
        .{ .authority_type = .FreezeAccount, .value = 1 },
        .{ .authority_type = .AccountOwner, .value = 2 },
        .{ .authority_type = .CloseAccount, .value = 3 },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case.value, @intFromEnum(case.authority_type));
    }
}

test "transfer: 9-byte body with correct discriminant + LE amount" {
    const a: Pubkey = .{1} ** 32;
    const b: Pubkey = .{2} ** 32;
    const c: Pubkey = .{3} ** 32;
    var metas: [3]AccountMeta = undefined;
    var data: [9]u8 = undefined;
    const ix = transfer(&a, &b, &c, 12345, &metas, &data);

    try std.testing.expectEqual(@as(u8, 3), data[0]);
    try std.testing.expectEqual(@as(u64, 12345), std.mem.readInt(u64, data[1..9], .little));
    try std.testing.expectEqual(@as(usize, 3), ix.accounts.len);
    // metas: source writable; dest writable; authority signer
    try std.testing.expectEqual(@as(u8, 1), ix.accounts[0].is_writable);
    try std.testing.expectEqual(@as(u8, 0), ix.accounts[0].is_signer);
    try std.testing.expectEqual(@as(u8, 1), ix.accounts[1].is_writable);
    try std.testing.expectEqual(@as(u8, 0), ix.accounts[2].is_writable);
    try std.testing.expectEqual(@as(u8, 1), ix.accounts[2].is_signer);
    try std.testing.expectEqualSlices(u8, &id.PROGRAM_ID, ix.program_id);
}

test "transferChecked: 10-byte body" {
    const a: Pubkey = .{1} ** 32;
    const m: Pubkey = .{4} ** 32;
    const b: Pubkey = .{2} ** 32;
    const c: Pubkey = .{3} ** 32;
    var metas: [4]AccountMeta = undefined;
    var data: [10]u8 = undefined;
    _ = transferChecked(&a, &m, &b, &c, 999, 6, &metas, &data);

    try std.testing.expectEqual(@as(u8, 12), data[0]);
    try std.testing.expectEqual(@as(u64, 999), std.mem.readInt(u64, data[1..9], .little));
    try std.testing.expectEqual(@as(u8, 6), data[9]);
    // mint must be readonly (no writable, no signer)
    try std.testing.expectEqual(@as(u8, 0), metas[1].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[1].is_signer);
}

test "approve: canonical single-authority metas, LE amount, default program id, and caller scratch" {
    const source: Pubkey = .{0x11} ** 32;
    const delegate: Pubkey = .{0x22} ** 32;
    const owner: Pubkey = .{0x33} ** 32;
    var metas: metasArray(approve_spec) = undefined;
    var data: dataArray(approve_spec) = undefined;
    const ix = approve(&source, &delegate, &owner, 0x0807_0605_0403_0201, &metas, &data);

    try std.testing.expectEqual(@as(usize, 3), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 9), ix.data.len);
    try std.testing.expectEqual(@as(u8, 4), data[0]);
    try std.testing.expectEqual(@as(u64, 0x0807_0605_0403_0201), std.mem.readInt(u64, data[1..9], .little));
    try std.testing.expectEqual(&id.PROGRAM_ID, ix.program_id);
    try expectMeta(ix.accounts[0], &source, 1, 0);
    try expectMeta(ix.accounts[1], &delegate, 0, 0);
    try expectMeta(ix.accounts[2], &owner, 0, 1);
    try std.testing.expectEqual(@intFromPtr(&metas[0]), @intFromPtr(ix.accounts.ptr));
    try std.testing.expectEqual(@intFromPtr(&data[0]), @intFromPtr(ix.data.ptr));
}

test "approveChecked: canonical metas, amount/decimals encoding, default program id, and caller scratch" {
    const source: Pubkey = .{0x44} ** 32;
    const mint: Pubkey = .{0x55} ** 32;
    const delegate: Pubkey = .{0x66} ** 32;
    const owner: Pubkey = .{0x77} ** 32;
    var metas: metasArray(approve_checked_spec) = undefined;
    var data: dataArray(approve_checked_spec) = undefined;
    const ix = approveChecked(&source, &mint, &delegate, &owner, 999, 6, &metas, &data);

    try std.testing.expectEqual(@as(usize, 4), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 10), ix.data.len);
    try std.testing.expectEqual(@as(u8, 13), data[0]);
    try std.testing.expectEqual(@as(u64, 999), std.mem.readInt(u64, data[1..9], .little));
    try std.testing.expectEqual(@as(u8, 6), data[9]);
    try std.testing.expectEqual(&id.PROGRAM_ID, ix.program_id);
    try expectMeta(ix.accounts[0], &source, 1, 0);
    try expectMeta(ix.accounts[1], &mint, 0, 0);
    try expectMeta(ix.accounts[2], &delegate, 0, 0);
    try expectMeta(ix.accounts[3], &owner, 0, 1);
    try std.testing.expectEqual(@intFromPtr(&metas[0]), @intFromPtr(ix.accounts.ptr));
    try std.testing.expectEqual(@intFromPtr(&data[0]), @intFromPtr(ix.data.ptr));
}

test "revoke: canonical single-authority metas, default program id, and caller scratch" {
    const source: Pubkey = .{0x88} ** 32;
    const owner: Pubkey = .{0x99} ** 32;
    var metas: metasArray(revoke_spec) = undefined;
    var data: dataArray(revoke_spec) = undefined;
    const ix = revoke(&source, &owner, &metas, &data);

    try std.testing.expectEqual(@as(usize, 2), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), ix.data.len);
    try std.testing.expectEqual(@as(u8, 5), data[0]);
    try std.testing.expectEqual(&id.PROGRAM_ID, ix.program_id);
    try expectMeta(ix.accounts[0], &source, 1, 0);
    try expectMeta(ix.accounts[1], &owner, 0, 1);
    try std.testing.expectEqual(@intFromPtr(&metas[0]), @intFromPtr(ix.accounts.ptr));
    try std.testing.expectEqual(@intFromPtr(&data[0]), @intFromPtr(ix.data.ptr));
}

test "setAuthority: all AuthorityType variants encode compact Some/None forms with canonical metas" {
    const mint_or_account: Pubkey = .{0xA1} ** 32;
    const current_authority: Pubkey = .{0xB2} ** 32;
    const new_authority: Pubkey = .{0xC3} ** 32;
    const cases = [_]AuthorityType{
        .MintTokens,
        .FreezeAccount,
        .AccountOwner,
        .CloseAccount,
    };

    inline for (cases) |authority_type| {
        var some_metas: metasArray(set_authority_spec) = undefined;
        var some_data: dataArray(set_authority_spec) = undefined;
        const some_ix = setAuthority(
            &mint_or_account,
            &current_authority,
            authority_type,
            &new_authority,
            &some_metas,
            &some_data,
        );

        try std.testing.expectEqual(@as(usize, 2), some_ix.accounts.len);
        try std.testing.expectEqual(@as(usize, 35), some_ix.data.len);
        try std.testing.expectEqual(@as(u8, 6), some_data[0]);
        try std.testing.expectEqual(@intFromEnum(authority_type), some_data[1]);
        try std.testing.expectEqual(@as(u8, 1), some_data[2]);
        try std.testing.expectEqualSlices(u8, &new_authority, some_data[3..35]);
        try std.testing.expectEqual(&id.PROGRAM_ID, some_ix.program_id);
        try expectMeta(some_ix.accounts[0], &mint_or_account, 1, 0);
        try expectMeta(some_ix.accounts[1], &current_authority, 0, 1);
        try std.testing.expectEqual(@intFromPtr(&some_metas[0]), @intFromPtr(some_ix.accounts.ptr));
        try std.testing.expectEqual(@intFromPtr(&some_data[0]), @intFromPtr(some_ix.data.ptr));

        var none_metas: metasArray(set_authority_spec) = undefined;
        var none_data: dataArray(set_authority_spec) = undefined;
        const none_ix = setAuthority(
            &mint_or_account,
            &current_authority,
            authority_type,
            null,
            &none_metas,
            &none_data,
        );

        try std.testing.expectEqual(@as(usize, 2), none_ix.accounts.len);
        try std.testing.expectEqual(@as(usize, 3), none_ix.data.len);
        try std.testing.expectEqual(@as(u8, 6), none_data[0]);
        try std.testing.expectEqual(@intFromEnum(authority_type), none_data[1]);
        try std.testing.expectEqual(@as(u8, 0), none_data[2]);
        try std.testing.expectEqual(&id.PROGRAM_ID, none_ix.program_id);
        try expectMeta(none_ix.accounts[0], &mint_or_account, 1, 0);
        try expectMeta(none_ix.accounts[1], &current_authority, 0, 1);
        try std.testing.expectEqual(@intFromPtr(&none_metas[0]), @intFromPtr(none_ix.accounts.ptr));
        try std.testing.expectEqual(@intFromPtr(&none_data[0]), @intFromPtr(none_ix.data.ptr));
    }
}

test "freezeAccount and thawAccount: canonical data, metas, program id, and caller scratch" {
    const account: Pubkey = .{0xD4} ** 32;
    const mint: Pubkey = .{0xE5} ** 32;
    const freeze_authority: Pubkey = .{0xF6} ** 32;

    var freeze_metas: metasArray(freeze_account_spec) = undefined;
    var freeze_data: dataArray(freeze_account_spec) = undefined;
    const freeze_ix = freezeAccount(&account, &mint, &freeze_authority, &freeze_metas, &freeze_data);

    try std.testing.expectEqual(@as(usize, 3), freeze_ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), freeze_ix.data.len);
    try std.testing.expectEqual(@as(u8, 10), freeze_data[0]);
    try std.testing.expectEqual(&id.PROGRAM_ID, freeze_ix.program_id);
    try expectMeta(freeze_ix.accounts[0], &account, 1, 0);
    try expectMeta(freeze_ix.accounts[1], &mint, 0, 0);
    try expectMeta(freeze_ix.accounts[2], &freeze_authority, 0, 1);
    try std.testing.expectEqual(@intFromPtr(&freeze_metas[0]), @intFromPtr(freeze_ix.accounts.ptr));
    try std.testing.expectEqual(@intFromPtr(&freeze_data[0]), @intFromPtr(freeze_ix.data.ptr));

    var thaw_metas: metasArray(thaw_account_spec) = undefined;
    var thaw_data: dataArray(thaw_account_spec) = undefined;
    const thaw_ix = thawAccount(&account, &mint, &freeze_authority, &thaw_metas, &thaw_data);

    try std.testing.expectEqual(@as(usize, 3), thaw_ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), thaw_ix.data.len);
    try std.testing.expectEqual(@as(u8, 11), thaw_data[0]);
    try std.testing.expectEqual(&id.PROGRAM_ID, thaw_ix.program_id);
    try expectMeta(thaw_ix.accounts[0], &account, 1, 0);
    try expectMeta(thaw_ix.accounts[1], &mint, 0, 0);
    try expectMeta(thaw_ix.accounts[2], &freeze_authority, 0, 1);
    try std.testing.expectEqual(@intFromPtr(&thaw_metas[0]), @intFromPtr(thaw_ix.accounts.ptr));
    try std.testing.expectEqual(@intFromPtr(&thaw_data[0]), @intFromPtr(thaw_ix.data.ptr));
}

test "mintTo / burn / closeAccount discriminants" {
    const a: Pubkey = .{1} ** 32;
    const b: Pubkey = .{2} ** 32;
    const c: Pubkey = .{3} ** 32;

    var metas: [3]AccountMeta = undefined;
    var data9: [9]u8 = undefined;
    _ = mintTo(&a, &b, &c, 7, &metas, &data9);
    try std.testing.expectEqual(@as(u8, 7), data9[0]);

    _ = burn(&a, &b, &c, 8, &metas, &data9);
    try std.testing.expectEqual(@as(u8, 8), data9[0]);

    var data1: [1]u8 = undefined;
    _ = closeAccount(&a, &b, &c, &metas, &data1);
    try std.testing.expectEqual(@as(u8, 9), data1[0]);
}

test "initializeMint: Some-vs-None freeze authority encoding and rent sysvar meta" {
    const m: Pubkey = .{0x10} ** 32;
    const auth: Pubkey = .{0x21} ** 32;
    const fa: Pubkey = .{0x32} ** 32;
    var metas: [2]AccountMeta = undefined;
    var data: dataArray(initialize_mint_spec) = undefined;

    _ = initializeMint(&m, 9, &auth, &fa, &metas, &data);
    try std.testing.expectEqual(@as(u8, 0), data[0]);
    try std.testing.expectEqual(@as(u8, 9), data[1]);
    try std.testing.expectEqualSlices(u8, &auth, data[2..34]);
    try std.testing.expectEqual(state.COPTION_SOME, std.mem.readInt(u32, data[34..38], .little));
    try std.testing.expectEqualSlices(u8, &fa, data[38..70]);
    try expectMeta(metas[0], &m, 1, 0);
    try expectMeta(metas[1], &sol.rent_id, 0, 0);

    _ = initializeMint(&m, 0, &auth, null, &metas, &data);
    try std.testing.expectEqual(state.COPTION_NONE, std.mem.readInt(u32, data[34..38], .little));
    for (data[38..70]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "initializeMint2: Some-vs-None freeze authority encoding" {
    const m: Pubkey = .{0x11} ** 32;
    const auth: Pubkey = .{0x22} ** 32;
    const fa: Pubkey = .{0x33} ** 32;
    var metas: [1]AccountMeta = undefined;
    var data: dataArray(initialize_mint2_spec) = undefined;

    _ = initializeMint2(&m, 9, &auth, &fa, &metas, &data);
    try std.testing.expectEqual(@as(u8, 20), data[0]);
    try std.testing.expectEqual(@as(u8, 9), data[1]);
    try std.testing.expectEqual(state.COPTION_SOME, std.mem.readInt(u32, data[34..38], .little));
    try std.testing.expectEqualSlices(u8, &fa, data[38..70]);

    _ = initializeMint2(&m, 0, &auth, null, &metas, &data);
    try std.testing.expectEqual(state.COPTION_NONE, std.mem.readInt(u32, data[34..38], .little));
    for (data[38..70]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "syncNative: single writable account and 1-byte body" {
    const account: Pubkey = .{0xAB} ** 32;
    var metas: [1]AccountMeta = undefined;
    var data: [1]u8 = undefined;
    const ix = syncNative(&account, &metas, &data);
    try std.testing.expectEqual(&id.PROGRAM_ID, ix.program_id);
    try std.testing.expectEqual(@as(usize, 1), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), ix.data.len);
    try std.testing.expectEqual(@as(u8, 17), data[0]);
    try expectMeta(ix.accounts[0], &account, 1, 0);
}

test "initializeAccount: canonical metas and empty body" {
    const acct: Pubkey = .{0xA8} ** 32;
    const mint: Pubkey = .{0xB9} ** 32;
    const owner: Pubkey = .{0xCA} ** 32;
    var metas: [4]AccountMeta = undefined;
    var data: [1]u8 = undefined;
    _ = initializeAccount(&acct, &mint, &owner, &metas, &data);
    try std.testing.expectEqual(@as(u8, 1), data[0]);
    try expectMeta(metas[0], &acct, 1, 0);
    try expectMeta(metas[1], &mint, 0, 0);
    try expectMeta(metas[2], &owner, 0, 0);
    try expectMeta(metas[3], &sol.rent_id, 0, 0);
}

test "initializeAccount2: 33-byte body carries owner pubkey and rent sysvar meta" {
    const acct: Pubkey = .{0xA9} ** 32;
    const mint: Pubkey = .{0xBA} ** 32;
    const owner: Pubkey = .{0xCB} ** 32;
    var metas: [3]AccountMeta = undefined;
    var data: [33]u8 = undefined;
    _ = initializeAccount2(&acct, &mint, &owner, &metas, &data);
    try std.testing.expectEqual(@as(u8, 16), data[0]);
    try std.testing.expectEqualSlices(u8, &owner, data[1..33]);
    try expectMeta(metas[0], &acct, 1, 0);
    try expectMeta(metas[1], &mint, 0, 0);
    try expectMeta(metas[2], &sol.rent_id, 0, 0);
}

test "initializeAccount3: 33-byte body carries owner pubkey" {
    const acct: Pubkey = .{0xAA} ** 32;
    const mint: Pubkey = .{0xBB} ** 32;
    const owner: Pubkey = .{0xCC} ** 32;
    var metas: [2]AccountMeta = undefined;
    var data: [33]u8 = undefined;
    _ = initializeAccount3(&acct, &mint, &owner, &metas, &data);
    try std.testing.expectEqual(@as(u8, 18), data[0]);
    try std.testing.expectEqualSlices(u8, &owner, data[1..33]);
}

test "utility helpers: canonical metas and data encodings" {
    const mint: Pubkey = .{0xAD} ** 32;
    const account: Pubkey = .{0xBE} ** 32;

    var size_metas: metasArray(get_account_data_size_spec) = undefined;
    var size_data: dataArray(get_account_data_size_spec) = undefined;
    const size_ix = getAccountDataSize(&mint, &size_metas, &size_data);
    try std.testing.expectEqual(&id.PROGRAM_ID, size_ix.program_id);
    try std.testing.expectEqual(@as(usize, 1), size_ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), size_ix.data.len);
    try std.testing.expectEqual(@as(u8, 21), size_ix.data[0]);
    try expectMeta(size_ix.accounts[0], &mint, 0, 0);

    var immutable_metas: metasArray(initialize_immutable_owner_spec) = undefined;
    var immutable_data: dataArray(initialize_immutable_owner_spec) = undefined;
    const immutable_ix = initializeImmutableOwner(&account, &immutable_metas, &immutable_data);
    try std.testing.expectEqual(@as(u8, 22), immutable_ix.data[0]);
    try expectMeta(immutable_ix.accounts[0], &account, 1, 0);

    var amount_metas: metasArray(amount_to_ui_amount_spec) = undefined;
    var amount_data: dataArray(amount_to_ui_amount_spec) = undefined;
    const amount_ix = amountToUiAmount(&mint, 1234, &amount_metas, &amount_data);
    try std.testing.expectEqual(@as(u8, 23), amount_ix.data[0]);
    try std.testing.expectEqual(@as(u64, 1234), std.mem.readInt(u64, amount_ix.data[1..9], .little));
    try expectMeta(amount_ix.accounts[0], &mint, 0, 0);

    var ui_metas: metasArray(get_account_data_size_spec) = undefined;
    var ui_data: [32]u8 = undefined;
    const ui_ix = try uiAmountToAmount(&mint, "12.34", &ui_metas, ui_data[0..]);
    try std.testing.expectEqual(@as(u8, 24), ui_ix.data[0]);
    try std.testing.expectEqualStrings("12.34", ui_ix.data[1..]);
    try expectMeta(ui_ix.accounts[0], &mint, 0, 0);
    try std.testing.expectEqual(@as(usize, 6), uiAmountToAmountLen("12.34").?);
    try std.testing.expectError(error.InvalidArgument, uiAmountToAmount(&mint, "12.34", &ui_metas, ui_data[0..5]));
}

test "isValidSignerIndex: mirrors upstream signer bounds" {
    try std.testing.expect(!isValidSignerIndex(0));
    try std.testing.expect(isValidSignerIndex(1));
    try std.testing.expect(isValidSignerIndex(MAX_SIGNERS));
    try std.testing.expect(!isValidSignerIndex(MAX_SIGNERS + 1));
}

test "initializeMultisig: canonical data/metas, rent sysvar, caller scratch, and threshold bounds" {
    const multisig: Pubkey = .{0xD0} ** 32;

    inline for (.{ 1, MAX_SIGNERS }) |signer_count| {
        const threshold: u8 = @intCast(signer_count);
        const signers = signerPubkeys(signer_count, 0x30);
        var metas: multisigMetasArray(initialize_multisig_spec.accounts_len) = undefined;
        var data: dataArray(initialize_multisig_spec) = undefined;
        const ix = try initializeMultisig(&multisig, &signers, threshold, &metas, &data);

        try std.testing.expectEqual(@as(usize, 2 + signer_count), ix.accounts.len);
        try std.testing.expectEqual(@as(usize, 2), ix.data.len);
        try std.testing.expectEqual(@as(u8, 2), data[0]);
        try std.testing.expectEqual(threshold, data[1]);
        try std.testing.expectEqual(&id.PROGRAM_ID, ix.program_id);
        try expectMeta(ix.accounts[0], &multisig, 1, 0);
        try expectMeta(ix.accounts[1], &sol.rent_id, 0, 0);
        try expectReadonlyTail(ix.accounts, 2, &signers);
        try std.testing.expectEqual(@intFromPtr(&metas[0]), @intFromPtr(ix.accounts.ptr));
        try std.testing.expectEqual(@intFromPtr(&data[0]), @intFromPtr(ix.data.ptr));
    }

    const one_signer = signerPubkeys(1, 0x61);
    const too_many_signers = signerPubkeys(MAX_SIGNERS + 1, 0x71);
    var metas: multisigMetasArray(initialize_multisig_spec.accounts_len) = undefined;
    var data: dataArray(initialize_multisig_spec) = undefined;
    const no_signers = [_]Pubkey{};

    try std.testing.expectError(
        error.InvalidMultisigSignerCount,
        initializeMultisig(&multisig, &no_signers, 1, &metas, &data),
    );
    try std.testing.expectError(
        error.InvalidMultisigSignerCount,
        initializeMultisig(&multisig, &too_many_signers, 1, &metas, &data),
    );
    try std.testing.expectError(
        error.InvalidMultisigThreshold,
        initializeMultisig(&multisig, &one_signer, 0, &metas, &data),
    );
    try std.testing.expectError(
        error.InvalidMultisigThreshold,
        initializeMultisig(&multisig, &one_signer, 2, &metas, &data),
    );
}

test "initializeMultisig2: canonical data/metas, caller scratch, and threshold bounds" {
    const multisig: Pubkey = .{0xD1} ** 32;

    inline for (.{ 1, MAX_SIGNERS }) |signer_count| {
        const threshold: u8 = @intCast(signer_count);
        const signers = signerPubkeys(signer_count, 0x40);
        var metas: multisigMetasArray(initialize_multisig2_spec.accounts_len) = undefined;
        var data: dataArray(initialize_multisig2_spec) = undefined;
        const ix = try initializeMultisig2(&multisig, &signers, threshold, &metas, &data);

        try std.testing.expectEqual(@as(usize, 1 + signer_count), ix.accounts.len);
        try std.testing.expectEqual(@as(usize, 2), ix.data.len);
        try std.testing.expectEqual(@as(u8, 19), data[0]);
        try std.testing.expectEqual(threshold, data[1]);
        try std.testing.expectEqual(&id.PROGRAM_ID, ix.program_id);
        try expectMeta(ix.accounts[0], &multisig, 1, 0);
        try expectReadonlyTail(ix.accounts, 1, &signers);
        try std.testing.expectEqual(@intFromPtr(&metas[0]), @intFromPtr(ix.accounts.ptr));
        try std.testing.expectEqual(@intFromPtr(&data[0]), @intFromPtr(ix.data.ptr));
    }

    const one_signer = signerPubkeys(1, 0x60);
    const too_many_signers = signerPubkeys(MAX_SIGNERS + 1, 0x70);
    var metas: multisigMetasArray(initialize_multisig2_spec.accounts_len) = undefined;
    var data: dataArray(initialize_multisig2_spec) = undefined;
    const no_signers = [_]Pubkey{};

    try std.testing.expectError(
        error.InvalidMultisigSignerCount,
        initializeMultisig2(&multisig, &no_signers, 1, &metas, &data),
    );
    try std.testing.expectError(
        error.InvalidMultisigSignerCount,
        initializeMultisig2(&multisig, &too_many_signers, 1, &metas, &data),
    );
    try std.testing.expectError(
        error.InvalidMultisigThreshold,
        initializeMultisig2(&multisig, &one_signer, 0, &metas, &data),
    );
    try std.testing.expectError(
        error.InvalidMultisigThreshold,
        initializeMultisig2(&multisig, &one_signer, 2, &metas, &data),
    );
}

test "batch scratch helpers size homogeneous envelopes correctly" {
    const metas: batchMetasArray(transfer_checked_spec, 2) = undefined;
    const data: batchDataArray(transfer_checked_spec, 2) = undefined;

    try std.testing.expectEqual(@as(usize, transfer_checked_spec.accounts_len * 2), metas.len);
    try std.testing.expectEqual(@as(usize, 1 + 2 * (2 + transfer_checked_spec.data_len)), data.len);
}

test "batch: concatenates child metas/data and rejects nested batches" {
    const source: Pubkey = .{0xE1} ** 32;
    const mint: Pubkey = .{0xE2} ** 32;
    const destination: Pubkey = .{0xE3} ** 32;
    const authority: Pubkey = .{0xE4} ** 32;

    var child_a_metas: metasArray(transfer_checked_spec) = undefined;
    var child_a_data: dataArray(transfer_checked_spec) = undefined;
    const child_a = transferChecked(
        &source,
        &mint,
        &destination,
        &authority,
        55,
        6,
        &child_a_metas,
        &child_a_data,
    );

    var child_b_metas: metasArray(transfer_checked_spec) = undefined;
    var child_b_data: dataArray(transfer_checked_spec) = undefined;
    const child_b = transferChecked(
        &source,
        &mint,
        &destination,
        &authority,
        66,
        6,
        &child_b_metas,
        &child_b_data,
    );

    const children = [_]Instruction{ child_a, child_b };
    var batch_metas: [transfer_checked_spec.accounts_len * children.len]AccountMeta = undefined;
    var batch_data: [1 + children.len * (2 + transfer_checked_spec.data_len)]u8 = undefined;
    const ix = try batch(&children, batch_metas[0..], batch_data[0..]);

    try std.testing.expectEqual(&id.PROGRAM_ID, ix.program_id);
    try std.testing.expectEqual(@as(usize, 8), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 25), ix.data.len);
    try std.testing.expectEqual(@as(u8, 255), ix.data[0]);
    try std.testing.expectEqual(@as(u8, 4), ix.data[1]);
    try std.testing.expectEqual(@as(u8, 10), ix.data[2]);
    try std.testing.expectEqualSlices(u8, child_a.data, ix.data[3..13]);
    try std.testing.expectEqual(@as(u8, 4), ix.data[13]);
    try std.testing.expectEqual(@as(u8, 10), ix.data[14]);
    try std.testing.expectEqualSlices(u8, child_b.data, ix.data[15..25]);

    try expectMeta(ix.accounts[0], &source, 1, 0);
    try expectMeta(ix.accounts[1], &mint, 0, 0);
    try expectMeta(ix.accounts[2], &destination, 1, 0);
    try expectMeta(ix.accounts[3], &authority, 0, 1);
    try expectMeta(ix.accounts[4], &source, 1, 0);
    try expectMeta(ix.accounts[5], &mint, 0, 0);
    try expectMeta(ix.accounts[6], &destination, 1, 0);
    try expectMeta(ix.accounts[7], &authority, 0, 1);

    var nested_metas: [transfer_checked_spec.accounts_len]AccountMeta = undefined;
    var nested_data: [1 + 2 + transfer_checked_spec.data_len]u8 = undefined;
    const nested = try batch(&.{child_a}, nested_metas[0..], nested_data[0..]);
    var reject_metas: [transfer_checked_spec.accounts_len]AccountMeta = undefined;
    var reject_data: [1 + 2 + (1 + 2 + transfer_checked_spec.data_len)]u8 = undefined;
    try std.testing.expectError(
        error.NestedBatchInstruction,
        batch(&.{nested}, reject_metas[0..], reject_data[0..]),
    );
}

test "batch: enforces child bounds, program ids, and scratch sizing" {
    const source: Pubkey = .{0xF1} ** 32;
    const mint: Pubkey = .{0xF2} ** 32;
    const destination: Pubkey = .{0xF3} ** 32;
    const authority: Pubkey = .{0xF4} ** 32;

    var child_metas: metasArray(transfer_checked_spec) = undefined;
    var child_data: dataArray(transfer_checked_spec) = undefined;
    const child = transferChecked(
        &source,
        &mint,
        &destination,
        &authority,
        77,
        6,
        &child_metas,
        &child_data,
    );

    var too_small_metas: [transfer_checked_spec.accounts_len - 1]AccountMeta = undefined;
    var exact_data: [1 + 2 + transfer_checked_spec.data_len]u8 = undefined;
    try std.testing.expectError(
        error.ScratchTooSmall,
        batch(&.{child}, too_small_metas[0..], exact_data[0..]),
    );

    const wrong_program: Pubkey = .{0xFA} ** 32;
    const wrong_child = Instruction{ .program_id = &wrong_program, .accounts = child.accounts, .data = child.data };
    var metas_ok: [transfer_checked_spec.accounts_len]AccountMeta = undefined;
    try std.testing.expectError(
        error.IncorrectProgramId,
        batch(&.{wrong_child}, metas_ok[0..], exact_data[0..]),
    );

    var too_many_accounts: [256]AccountMeta = undefined;
    for (&too_many_accounts) |*meta| meta.* = AccountMeta.readonly(&source);
    const large_accounts_child = Instruction{
        .program_id = &id.PROGRAM_ID,
        .accounts = &too_many_accounts,
        .data = child.data,
    };
    var large_accounts_scratch: [256]AccountMeta = undefined;
    var large_accounts_data: [1 + 2 + transfer_checked_spec.data_len]u8 = undefined;
    try std.testing.expectError(
        error.TooManyAccounts,
        batch(&.{large_accounts_child}, large_accounts_scratch[0..], large_accounts_data[0..]),
    );

    const huge_data = [_]u8{0xAB} ** 256;
    const large_data_child = Instruction{
        .program_id = &id.PROGRAM_ID,
        .accounts = child.accounts,
        .data = &huge_data,
    };
    try std.testing.expectError(
        error.InstructionDataTooLong,
        batch(&.{large_data_child}, metas_ok[0..], exact_data[0..]),
    );
}

test "v0.2 explicit multisig builders preserve data and signer order" {
    const source: Pubkey = .{0x11} ** 32;
    const mint: Pubkey = .{0x12} ** 32;
    const delegate: Pubkey = .{0x13} ** 32;
    const owner: Pubkey = .{0x14} ** 32;
    const multisig_authority: Pubkey = .{0x15} ** 32;
    const account: Pubkey = .{0x16} ** 32;
    const new_authority: Pubkey = .{0x17} ** 32;

    inline for (.{ 1, MAX_SIGNERS }) |signer_count| {
        const signers = signerPubkeys(signer_count, 0x80);

        var approve_single_metas: metasArray(approve_spec) = undefined;
        var approve_single_data: dataArray(approve_spec) = undefined;
        const approve_single = approve(&source, &delegate, &owner, 55, &approve_single_metas, &approve_single_data);
        var approve_multi_metas: multisigMetasArray(approve_spec.accounts_len) = undefined;
        var approve_multi_data: dataArray(approve_spec) = undefined;
        const approve_multi = try approveMultisig(
            &source,
            &delegate,
            &multisig_authority,
            &signers,
            55,
            &approve_multi_metas,
            &approve_multi_data,
        );
        try std.testing.expectEqualSlices(u8, approve_single.data, approve_multi.data);
        try expectMeta(approve_multi.accounts[0], &source, 1, 0);
        try expectMeta(approve_multi.accounts[1], &delegate, 0, 0);
        try expectMeta(approve_multi.accounts[2], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(approve_multi.accounts, 3, &signers);
        try std.testing.expectEqual(@intFromPtr(&approve_multi_metas[0]), @intFromPtr(approve_multi.accounts.ptr));
        try std.testing.expectEqual(@intFromPtr(&approve_multi_data[0]), @intFromPtr(approve_multi.data.ptr));

        var approve_checked_single_metas: metasArray(approve_checked_spec) = undefined;
        var approve_checked_single_data: dataArray(approve_checked_spec) = undefined;
        const approve_checked_single = approveChecked(
            &source,
            &mint,
            &delegate,
            &owner,
            56,
            6,
            &approve_checked_single_metas,
            &approve_checked_single_data,
        );
        var approve_checked_multi_metas: multisigMetasArray(approve_checked_spec.accounts_len) = undefined;
        var approve_checked_multi_data: dataArray(approve_checked_spec) = undefined;
        const approve_checked_multi = try approveCheckedMultisig(
            &source,
            &mint,
            &delegate,
            &multisig_authority,
            &signers,
            56,
            6,
            &approve_checked_multi_metas,
            &approve_checked_multi_data,
        );
        try std.testing.expectEqualSlices(u8, approve_checked_single.data, approve_checked_multi.data);
        try expectMeta(approve_checked_multi.accounts[0], &source, 1, 0);
        try expectMeta(approve_checked_multi.accounts[1], &mint, 0, 0);
        try expectMeta(approve_checked_multi.accounts[2], &delegate, 0, 0);
        try expectMeta(approve_checked_multi.accounts[3], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(approve_checked_multi.accounts, 4, &signers);

        var revoke_single_metas: metasArray(revoke_spec) = undefined;
        var revoke_single_data: dataArray(revoke_spec) = undefined;
        const revoke_single = revoke(&source, &owner, &revoke_single_metas, &revoke_single_data);
        var revoke_multi_metas: multisigMetasArray(revoke_spec.accounts_len) = undefined;
        var revoke_multi_data: dataArray(revoke_spec) = undefined;
        const revoke_multi = try revokeMultisig(
            &source,
            &multisig_authority,
            &signers,
            &revoke_multi_metas,
            &revoke_multi_data,
        );
        try std.testing.expectEqualSlices(u8, revoke_single.data, revoke_multi.data);
        try expectMeta(revoke_multi.accounts[0], &source, 1, 0);
        try expectMeta(revoke_multi.accounts[1], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(revoke_multi.accounts, 2, &signers);

        var set_auth_some_single_metas: metasArray(set_authority_spec) = undefined;
        var set_auth_some_single_data: dataArray(set_authority_spec) = undefined;
        const set_auth_some_single = setAuthority(
            &account,
            &owner,
            .FreezeAccount,
            &new_authority,
            &set_auth_some_single_metas,
            &set_auth_some_single_data,
        );
        var set_auth_some_multi_metas: multisigMetasArray(set_authority_spec.accounts_len) = undefined;
        var set_auth_some_multi_data: dataArray(set_authority_spec) = undefined;
        const set_auth_some_multi = try setAuthorityMultisig(
            &account,
            &multisig_authority,
            &signers,
            .FreezeAccount,
            &new_authority,
            &set_auth_some_multi_metas,
            &set_auth_some_multi_data,
        );
        try std.testing.expectEqualSlices(u8, set_auth_some_single.data, set_auth_some_multi.data);
        try expectMeta(set_auth_some_multi.accounts[0], &account, 1, 0);
        try expectMeta(set_auth_some_multi.accounts[1], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(set_auth_some_multi.accounts, 2, &signers);

        var set_auth_none_single_metas: metasArray(set_authority_spec) = undefined;
        var set_auth_none_single_data: dataArray(set_authority_spec) = undefined;
        const set_auth_none_single = setAuthority(
            &account,
            &owner,
            .CloseAccount,
            null,
            &set_auth_none_single_metas,
            &set_auth_none_single_data,
        );
        var set_auth_none_multi_metas: multisigMetasArray(set_authority_spec.accounts_len) = undefined;
        var set_auth_none_multi_data: dataArray(set_authority_spec) = undefined;
        const set_auth_none_multi = try setAuthorityMultisig(
            &account,
            &multisig_authority,
            &signers,
            .CloseAccount,
            null,
            &set_auth_none_multi_metas,
            &set_auth_none_multi_data,
        );
        try std.testing.expectEqualSlices(u8, set_auth_none_single.data, set_auth_none_multi.data);
        try std.testing.expectEqual(@as(usize, 3), set_auth_none_multi.data.len);

        var freeze_single_metas: metasArray(freeze_account_spec) = undefined;
        var freeze_single_data: dataArray(freeze_account_spec) = undefined;
        const freeze_single = freezeAccount(&account, &mint, &owner, &freeze_single_metas, &freeze_single_data);
        var freeze_multi_metas: multisigMetasArray(freeze_account_spec.accounts_len) = undefined;
        var freeze_multi_data: dataArray(freeze_account_spec) = undefined;
        const freeze_multi = try freezeAccountMultisig(
            &account,
            &mint,
            &multisig_authority,
            &signers,
            &freeze_multi_metas,
            &freeze_multi_data,
        );
        try std.testing.expectEqualSlices(u8, freeze_single.data, freeze_multi.data);
        try expectMeta(freeze_multi.accounts[0], &account, 1, 0);
        try expectMeta(freeze_multi.accounts[1], &mint, 0, 0);
        try expectMeta(freeze_multi.accounts[2], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(freeze_multi.accounts, 3, &signers);

        var thaw_single_metas: metasArray(thaw_account_spec) = undefined;
        var thaw_single_data: dataArray(thaw_account_spec) = undefined;
        const thaw_single = thawAccount(&account, &mint, &owner, &thaw_single_metas, &thaw_single_data);
        var thaw_multi_metas: multisigMetasArray(thaw_account_spec.accounts_len) = undefined;
        var thaw_multi_data: dataArray(thaw_account_spec) = undefined;
        const thaw_multi = try thawAccountMultisig(
            &account,
            &mint,
            &multisig_authority,
            &signers,
            &thaw_multi_metas,
            &thaw_multi_data,
        );
        try std.testing.expectEqualSlices(u8, thaw_single.data, thaw_multi.data);
        try expectMeta(thaw_multi.accounts[0], &account, 1, 0);
        try expectMeta(thaw_multi.accounts[1], &mint, 0, 0);
        try expectMeta(thaw_multi.accounts[2], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(thaw_multi.accounts, 3, &signers);
    }
}

test "existing authority-based multisig builders preserve data and signer order" {
    const source: Pubkey = .{0x21} ** 32;
    const destination: Pubkey = .{0x22} ** 32;
    const mint: Pubkey = .{0x23} ** 32;
    const authority: Pubkey = .{0x24} ** 32;
    const multisig_authority: Pubkey = .{0x25} ** 32;
    const account: Pubkey = .{0x26} ** 32;

    inline for (.{ 1, MAX_SIGNERS }) |signer_count| {
        const signers = signerPubkeys(signer_count, 0xA0);

        var transfer_single_metas: metasArray(transfer_spec) = undefined;
        var transfer_single_data: dataArray(transfer_spec) = undefined;
        const transfer_single = transfer(
            &source,
            &destination,
            &authority,
            101,
            &transfer_single_metas,
            &transfer_single_data,
        );
        var transfer_multi_metas: multisigMetasArray(transfer_spec.accounts_len) = undefined;
        var transfer_multi_data: dataArray(transfer_spec) = undefined;
        const transfer_multi = try transferMultisig(
            &source,
            &destination,
            &multisig_authority,
            &signers,
            101,
            &transfer_multi_metas,
            &transfer_multi_data,
        );
        try std.testing.expectEqualSlices(u8, transfer_single.data, transfer_multi.data);
        try expectMeta(transfer_multi.accounts[0], &source, 1, 0);
        try expectMeta(transfer_multi.accounts[1], &destination, 1, 0);
        try expectMeta(transfer_multi.accounts[2], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(transfer_multi.accounts, 3, &signers);

        var transfer_checked_single_metas: metasArray(transfer_checked_spec) = undefined;
        var transfer_checked_single_data: dataArray(transfer_checked_spec) = undefined;
        const transfer_checked_single = transferChecked(
            &source,
            &mint,
            &destination,
            &authority,
            102,
            6,
            &transfer_checked_single_metas,
            &transfer_checked_single_data,
        );
        var transfer_checked_multi_metas: multisigMetasArray(transfer_checked_spec.accounts_len) = undefined;
        var transfer_checked_multi_data: dataArray(transfer_checked_spec) = undefined;
        const transfer_checked_multi = try transferCheckedMultisig(
            &source,
            &mint,
            &destination,
            &multisig_authority,
            &signers,
            102,
            6,
            &transfer_checked_multi_metas,
            &transfer_checked_multi_data,
        );
        try std.testing.expectEqualSlices(u8, transfer_checked_single.data, transfer_checked_multi.data);
        try expectMeta(transfer_checked_multi.accounts[0], &source, 1, 0);
        try expectMeta(transfer_checked_multi.accounts[1], &mint, 0, 0);
        try expectMeta(transfer_checked_multi.accounts[2], &destination, 1, 0);
        try expectMeta(transfer_checked_multi.accounts[3], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(transfer_checked_multi.accounts, 4, &signers);

        var mint_to_single_metas: metasArray(mint_to_spec) = undefined;
        var mint_to_single_data: dataArray(mint_to_spec) = undefined;
        const mint_to_single = mintTo(&mint, &destination, &authority, 103, &mint_to_single_metas, &mint_to_single_data);
        var mint_to_multi_metas: multisigMetasArray(mint_to_spec.accounts_len) = undefined;
        var mint_to_multi_data: dataArray(mint_to_spec) = undefined;
        const mint_to_multi = try mintToMultisig(
            &mint,
            &destination,
            &multisig_authority,
            &signers,
            103,
            &mint_to_multi_metas,
            &mint_to_multi_data,
        );
        try std.testing.expectEqualSlices(u8, mint_to_single.data, mint_to_multi.data);
        try expectMeta(mint_to_multi.accounts[0], &mint, 1, 0);
        try expectMeta(mint_to_multi.accounts[1], &destination, 1, 0);
        try expectMeta(mint_to_multi.accounts[2], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(mint_to_multi.accounts, 3, &signers);

        var mint_to_checked_single_metas: metasArray(mint_to_checked_spec) = undefined;
        var mint_to_checked_single_data: dataArray(mint_to_checked_spec) = undefined;
        const mint_to_checked_single = mintToChecked(
            &mint,
            &destination,
            &authority,
            104,
            6,
            &mint_to_checked_single_metas,
            &mint_to_checked_single_data,
        );
        var mint_to_checked_multi_metas: multisigMetasArray(mint_to_checked_spec.accounts_len) = undefined;
        var mint_to_checked_multi_data: dataArray(mint_to_checked_spec) = undefined;
        const mint_to_checked_multi = try mintToCheckedMultisig(
            &mint,
            &destination,
            &multisig_authority,
            &signers,
            104,
            6,
            &mint_to_checked_multi_metas,
            &mint_to_checked_multi_data,
        );
        try std.testing.expectEqualSlices(u8, mint_to_checked_single.data, mint_to_checked_multi.data);
        try expectMeta(mint_to_checked_multi.accounts[0], &mint, 1, 0);
        try expectMeta(mint_to_checked_multi.accounts[1], &destination, 1, 0);
        try expectMeta(mint_to_checked_multi.accounts[2], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(mint_to_checked_multi.accounts, 3, &signers);

        var burn_single_metas: metasArray(burn_spec) = undefined;
        var burn_single_data: dataArray(burn_spec) = undefined;
        const burn_single = burn(&source, &mint, &authority, 105, &burn_single_metas, &burn_single_data);
        var burn_multi_metas: multisigMetasArray(burn_spec.accounts_len) = undefined;
        var burn_multi_data: dataArray(burn_spec) = undefined;
        const burn_multi = try burnMultisig(
            &source,
            &mint,
            &multisig_authority,
            &signers,
            105,
            &burn_multi_metas,
            &burn_multi_data,
        );
        try std.testing.expectEqualSlices(u8, burn_single.data, burn_multi.data);
        try expectMeta(burn_multi.accounts[0], &source, 1, 0);
        try expectMeta(burn_multi.accounts[1], &mint, 1, 0);
        try expectMeta(burn_multi.accounts[2], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(burn_multi.accounts, 3, &signers);

        var burn_checked_single_metas: metasArray(burn_checked_spec) = undefined;
        var burn_checked_single_data: dataArray(burn_checked_spec) = undefined;
        const burn_checked_single = burnChecked(
            &source,
            &mint,
            &authority,
            106,
            6,
            &burn_checked_single_metas,
            &burn_checked_single_data,
        );
        var burn_checked_multi_metas: multisigMetasArray(burn_checked_spec.accounts_len) = undefined;
        var burn_checked_multi_data: dataArray(burn_checked_spec) = undefined;
        const burn_checked_multi = try burnCheckedMultisig(
            &source,
            &mint,
            &multisig_authority,
            &signers,
            106,
            6,
            &burn_checked_multi_metas,
            &burn_checked_multi_data,
        );
        try std.testing.expectEqualSlices(u8, burn_checked_single.data, burn_checked_multi.data);
        try expectMeta(burn_checked_multi.accounts[0], &source, 1, 0);
        try expectMeta(burn_checked_multi.accounts[1], &mint, 1, 0);
        try expectMeta(burn_checked_multi.accounts[2], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(burn_checked_multi.accounts, 3, &signers);

        var close_single_metas: metasArray(close_account_spec) = undefined;
        var close_single_data: dataArray(close_account_spec) = undefined;
        const close_single = closeAccount(&account, &destination, &authority, &close_single_metas, &close_single_data);
        var close_multi_metas: multisigMetasArray(close_account_spec.accounts_len) = undefined;
        var close_multi_data: dataArray(close_account_spec) = undefined;
        const close_multi = try closeAccountMultisig(
            &account,
            &destination,
            &multisig_authority,
            &signers,
            &close_multi_metas,
            &close_multi_data,
        );
        try std.testing.expectEqualSlices(u8, close_single.data, close_multi.data);
        try expectMeta(close_multi.accounts[0], &account, 1, 0);
        try expectMeta(close_multi.accounts[1], &destination, 1, 0);
        try expectMeta(close_multi.accounts[2], &multisig_authority, 0, 0);
        try expectReadonlySignerTail(close_multi.accounts, 3, &signers);
        try std.testing.expectEqual(@intFromPtr(&close_multi_metas[0]), @intFromPtr(close_multi.accounts.ptr));
        try std.testing.expectEqual(@intFromPtr(&close_multi_data[0]), @intFromPtr(close_multi.data.ptr));
    }
}

test "multisig signer count bounds are enforced for explicit builder APIs" {
    const source: Pubkey = .{0x31} ** 32;
    const destination: Pubkey = .{0x32} ** 32;
    const delegate: Pubkey = .{0x33} ** 32;
    const multisig_authority: Pubkey = .{0x34} ** 32;
    const no_signers = [_]Pubkey{};
    const too_many_signers = signerPubkeys(MAX_SIGNERS + 1, 0xB0);

    var approve_metas: multisigMetasArray(approve_spec.accounts_len) = undefined;
    var approve_data: dataArray(approve_spec) = undefined;
    try std.testing.expectError(
        error.InvalidMultisigSignerCount,
        approveMultisig(
            &source,
            &delegate,
            &multisig_authority,
            &no_signers,
            1,
            &approve_metas,
            &approve_data,
        ),
    );
    try std.testing.expectError(
        error.InvalidMultisigSignerCount,
        approveMultisig(
            &source,
            &delegate,
            &multisig_authority,
            &too_many_signers,
            1,
            &approve_metas,
            &approve_data,
        ),
    );

    var transfer_metas: multisigMetasArray(transfer_spec.accounts_len) = undefined;
    var transfer_data: dataArray(transfer_spec) = undefined;
    try std.testing.expectError(
        error.InvalidMultisigSignerCount,
        transferMultisig(
            &source,
            &destination,
            &multisig_authority,
            &no_signers,
            1,
            &transfer_metas,
            &transfer_data,
        ),
    );
    try std.testing.expectError(
        error.InvalidMultisigSignerCount,
        transferMultisig(
            &source,
            &destination,
            &multisig_authority,
            &too_many_signers,
            1,
            &transfer_metas,
            &transfer_data,
        ),
    );
}
