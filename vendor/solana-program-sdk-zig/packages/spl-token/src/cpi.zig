//! On-chain CPI wrappers around the SPL Token program.
//!
//! This is the runtime half of the package. If `instruction.zig` is the byte
//! encoder, `cpi.zig` is the part that stages runtime accounts and actually
//! performs the invoke.
//!
//! The wrappers are intentionally thin: they keep the upstream account order
//! visible, stage their metas / instruction bytes on the stack, derive the
//! `Instruction.program_id` from the caller-supplied
//! `token_program: CpiAccountInfo` (so the same wrapper works against classic
//! SPL Token and Token-2022), and forward to the runtime
//! `sol_invoke_signed_c` syscall.
//!
//! All wrappers expose both an unsigned variant (`transfer`, `mintTo`, …) and
//! a `*Signed` variant for PDA-derived authority signing. The most common 1-PDA
//! case also gets `*SignedSingle` helpers, which route through
//! `sol.cpi.invokeSignedSingle` and skip the raw `Signer` boilerplate at the
//! call site while keeping the low-CU fast path.

const std = @import("std");
const sol = @import("solana_program_sdk");
const instruction = @import("instruction.zig");

const Pubkey = sol.Pubkey;
const CpiAccountInfo = sol.CpiAccountInfo;
const AccountMeta = sol.cpi.AccountMeta;
const Instruction = sol.cpi.Instruction;
const Signer = sol.cpi.Signer;
const ProgramError = sol.ProgramError;
const ProgramResult = sol.ProgramResult;
const MAX_SIGNERS = instruction.MAX_SIGNERS;
const BatchEntry = instruction.BatchEntry;

// Pull the per-instruction wire-format specs into scope. The
// builders' signatures already enforce that any local scratch
// buffer must match the spec's `accounts_len` / `data_len` — so
// re-typing the array shapes via `metasArray(spec)` /
// `dataArray(spec)` keeps the wrappers honest by construction
// (change the spec, every call site moves with it).
const metasArray = instruction.metasArray;
const dataArray = instruction.dataArray;

const AmountIx = sol.instruction.comptimeInstructionData(
    u8,
    extern struct { amount: u64 align(1) },
);

const AmountDecimalsIx = sol.instruction.comptimeInstructionData(
    u8,
    extern struct { amount: u64 align(1), decimals: u8 },
);

const MultisigSignerMetaKind = enum {
    signer,
    readonly,
};

/// Make a `cpi.Instruction` carry the caller-supplied program ID
/// instead of the comptime classic-SPL-Token ID — necessary so the
/// same wrappers work against Token-2022.
inline fn rebrand(ix: Instruction, program_id: *const Pubkey) Instruction {
    return .{ .program_id = program_id, .accounts = ix.accounts, .data = ix.data };
}

inline fn mapBatchInstructionError(err: instruction.BatchInstructionError) ProgramError {
    return switch (err) {
        error.IncorrectProgramId => error.IncorrectProgramId,
        error.NestedBatchInstruction,
        error.TooManyAccounts,
        error.InstructionDataTooLong,
        error.ScratchTooSmall,
        error.IntegerOverflow,
        => error.InvalidArgument,
    };
}

inline fn validateSignerInfoCount(signer_infos: []const CpiAccountInfo) ProgramResult {
    if (signer_infos.len < 1 or signer_infos.len > MAX_SIGNERS) {
        return error.InvalidArgument;
    }
}

inline fn validateSignerInfoThreshold(
    signer_infos: []const CpiAccountInfo,
    threshold: u8,
) ProgramResult {
    try validateSignerInfoCount(signer_infos);
    if (threshold == 0 or threshold > signer_infos.len) {
        return error.InvalidArgument;
    }
}

fn signerPubkeysFromInfos(
    signer_infos: []const CpiAccountInfo,
    out: *[MAX_SIGNERS]Pubkey,
) ProgramError![]const Pubkey {
    if (signer_infos.len < 1 or signer_infos.len > MAX_SIGNERS) {
        return error.InvalidArgument;
    }
    for (signer_infos, 0..) |signer, i| {
        out[i] = signer.key().*;
    }
    return out[0..signer_infos.len];
}

fn multisigMetasAndRuntimeAccounts(
    comptime base_accounts_len: usize,
    comptime fixed_len: usize,
    comptime signer_meta_kind: MultisigSignerMetaKind,
    fixed_accounts: [fixed_len]CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    token_program: CpiAccountInfo,
    metas_out: *instruction.multisigMetasArray(base_accounts_len),
    accounts_out: *[fixed_len + MAX_SIGNERS + 1]CpiAccountInfo,
) ProgramError!struct {
    instruction_accounts: []const AccountMeta,
    runtime_accounts: []const CpiAccountInfo,
} {
    try validateSignerInfoCount(signer_infos);

    for (fixed_accounts, 0..) |info, i| {
        accounts_out[i] = info;
    }
    for (signer_infos, 0..) |info, i| {
        metas_out[base_accounts_len + i] = switch (signer_meta_kind) {
            .signer => AccountMeta.signer(info.key()),
            .readonly => AccountMeta.readonly(info.key()),
        };
        accounts_out[fixed_len + i] = info;
    }
    accounts_out[fixed_len + signer_infos.len] = token_program;

    return .{
        .instruction_accounts = metas_out[0 .. base_accounts_len + signer_infos.len],
        .runtime_accounts = accounts_out[0 .. fixed_len + signer_infos.len + 1],
    };
}

fn stageBatchRuntimeAccounts(
    required_child_accounts: usize,
    child_runtime_accounts: []const CpiAccountInfo,
    token_program: CpiAccountInfo,
    invoke_accounts_out: []CpiAccountInfo,
) ProgramError![]const CpiAccountInfo {
    if (child_runtime_accounts.len != required_child_accounts) return error.InvalidArgument;
    if (invoke_accounts_out.len < child_runtime_accounts.len + 1) return error.InvalidArgument;

    @memcpy(invoke_accounts_out[0..child_runtime_accounts.len], child_runtime_accounts);
    invoke_accounts_out[child_runtime_accounts.len] = token_program;
    return invoke_accounts_out[0 .. child_runtime_accounts.len + 1];
}

inline fn validatePreparedBatchRuntimeAccounts(
    required_child_accounts: usize,
    invoke_accounts: []const CpiAccountInfo,
    token_program: CpiAccountInfo,
) ProgramError!void {
    if (invoke_accounts.len != required_child_accounts + 1) return error.InvalidArgument;
    if (!sol.pubkey.pubkeyEq(invoke_accounts[invoke_accounts.len - 1].key(), token_program.key())) {
        return error.InvalidArgument;
    }
}

/// Return the exact child-runtime-account array type required for a
/// homogeneous Batch whose children all share `spec` and whose count is
/// `child_count`.
pub fn batchChildRuntimeAccountsArray(comptime spec: instruction.Spec, comptime child_count: usize) type {
    return [spec.accounts_len * child_count]CpiAccountInfo;
}

/// Return the exact invoke-account array type required for a homogeneous
/// Batch whose children all share `spec` and whose count is `child_count`.
///
/// This includes the trailing token-program account required by
/// `batch(...)` / `batchPrepared(...)`.
pub fn batchInvokeAccountsArray(comptime spec: instruction.Spec, comptime child_count: usize) type {
    return [spec.accounts_len * child_count + 1]CpiAccountInfo;
}

// =============================================================================
// Transfer
// =============================================================================

/// Invoke `Transfer { amount }` via CPI.
/// Runtime accounts: source, destination, authority, token program.
pub fn transfer(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
) ProgramResult {
    var metas: metasArray(instruction.transfer_spec) = undefined;
    var data: dataArray(instruction.transfer_spec) = undefined;
    const ix = rebrand(
        instruction.transfer(source.key(), destination.key(), authority.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ source, destination, authority, token_program });
}

/// Signed-authority variant of `transfer`; runtime accounts match `transfer`.
pub fn transferSigned(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.transfer_spec) = undefined;
    var data: dataArray(instruction.transfer_spec) = undefined;
    const ix = rebrand(
        instruction.transfer(source.key(), destination.key(), authority.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ source, destination, authority, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `transferSigned`.
pub inline fn transferSignedSingle(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.transfer_spec) = undefined;
    var data: dataArray(instruction.transfer_spec) = undefined;
    const ix = rebrand(
        instruction.transfer(source.key(), destination.key(), authority.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ source, destination, authority, token_program },
        signer_seeds,
    );
}

/// Invoke `Transfer { amount }` with a multisig authority.
/// Runtime accounts: source, destination, multisig authority, signer accounts..., token program.
pub fn transferMultisig(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    destination: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    amount: u64,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.transfer_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(source.key());
    metas[1] = AccountMeta.writable(destination.key());
    metas[2] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.transfer_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.transfer_spec.accounts_len,
        instruction.transfer_spec.accounts_len,
        .signer,
        .{ source, destination, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.transfer_spec) = AmountIx.initWithDiscriminant(
        @intFromEnum(instruction.TokenInstruction.transfer),
        .{ .amount = amount },
    );
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

// =============================================================================
// TransferChecked
// =============================================================================

/// Invoke `TransferChecked { amount, decimals }` via CPI.
/// Runtime accounts: source, mint, destination, authority, token program.
pub fn transferChecked(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    decimals: u8,
) ProgramResult {
    var metas: metasArray(instruction.transfer_checked_spec) = undefined;
    var data: dataArray(instruction.transfer_checked_spec) = undefined;
    const ix = rebrand(
        instruction.transferChecked(
            source.key(),
            mint.key(),
            destination.key(),
            authority.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(
        &ix,
        &[_]CpiAccountInfo{ source, mint, destination, authority, token_program },
    );
}

/// Signed-authority variant of `transferChecked`.
pub fn transferCheckedSigned(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    decimals: u8,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.transfer_checked_spec) = undefined;
    var data: dataArray(instruction.transfer_checked_spec) = undefined;
    const ix = rebrand(
        instruction.transferChecked(
            source.key(),
            mint.key(),
            destination.key(),
            authority.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ source, mint, destination, authority, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `transferCheckedSigned`.
pub inline fn transferCheckedSignedSingle(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    decimals: u8,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.transfer_checked_spec) = undefined;
    var data: dataArray(instruction.transfer_checked_spec) = undefined;
    const ix = rebrand(
        instruction.transferChecked(
            source.key(),
            mint.key(),
            destination.key(),
            authority.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ source, mint, destination, authority, token_program },
        signer_seeds,
    );
}

/// Invoke `TransferChecked` with a multisig authority.
pub fn transferCheckedMultisig(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    amount: u64,
    decimals: u8,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.transfer_checked_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(source.key());
    metas[1] = AccountMeta.readonly(mint.key());
    metas[2] = AccountMeta.writable(destination.key());
    metas[3] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.transfer_checked_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.transfer_checked_spec.accounts_len,
        instruction.transfer_checked_spec.accounts_len,
        .signer,
        .{ source, mint, destination, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.transfer_checked_spec) = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(instruction.TokenInstruction.transfer_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

// =============================================================================
// Approve / Revoke / SetAuthority / Freeze / Thaw
// =============================================================================

/// Invoke `Approve { amount }` via CPI.
pub fn approve(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    delegate: CpiAccountInfo,
    owner: CpiAccountInfo,
    amount: u64,
) ProgramResult {
    var metas: metasArray(instruction.approve_spec) = undefined;
    var data: dataArray(instruction.approve_spec) = undefined;
    const ix = rebrand(
        instruction.approve(source.key(), delegate.key(), owner.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ source, delegate, owner, token_program });
}

/// Signed-authority variant of `approve`.
pub fn approveSigned(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    delegate: CpiAccountInfo,
    owner: CpiAccountInfo,
    amount: u64,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.approve_spec) = undefined;
    var data: dataArray(instruction.approve_spec) = undefined;
    const ix = rebrand(
        instruction.approve(source.key(), delegate.key(), owner.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ source, delegate, owner, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `approveSigned`.
pub inline fn approveSignedSingle(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    delegate: CpiAccountInfo,
    owner: CpiAccountInfo,
    amount: u64,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.approve_spec) = undefined;
    var data: dataArray(instruction.approve_spec) = undefined;
    const ix = rebrand(
        instruction.approve(source.key(), delegate.key(), owner.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ source, delegate, owner, token_program },
        signer_seeds,
    );
}

/// Invoke `Approve` with a multisig authority.
pub fn approveMultisig(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    delegate: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    amount: u64,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.approve_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(source.key());
    metas[1] = AccountMeta.readonly(delegate.key());
    metas[2] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.approve_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.approve_spec.accounts_len,
        instruction.approve_spec.accounts_len,
        .signer,
        .{ source, delegate, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.approve_spec) = AmountIx.initWithDiscriminant(
        @intFromEnum(instruction.TokenInstruction.approve),
        .{ .amount = amount },
    );
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

/// Invoke `ApproveChecked { amount, decimals }` via CPI.
pub fn approveChecked(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    delegate: CpiAccountInfo,
    owner: CpiAccountInfo,
    amount: u64,
    decimals: u8,
) ProgramResult {
    var metas: metasArray(instruction.approve_checked_spec) = undefined;
    var data: dataArray(instruction.approve_checked_spec) = undefined;
    const ix = rebrand(
        instruction.approveChecked(
            source.key(),
            mint.key(),
            delegate.key(),
            owner.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(
        &ix,
        &[_]CpiAccountInfo{ source, mint, delegate, owner, token_program },
    );
}

/// Signed-authority variant of `approveChecked`.
pub fn approveCheckedSigned(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    delegate: CpiAccountInfo,
    owner: CpiAccountInfo,
    amount: u64,
    decimals: u8,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.approve_checked_spec) = undefined;
    var data: dataArray(instruction.approve_checked_spec) = undefined;
    const ix = rebrand(
        instruction.approveChecked(
            source.key(),
            mint.key(),
            delegate.key(),
            owner.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ source, mint, delegate, owner, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `approveCheckedSigned`.
pub inline fn approveCheckedSignedSingle(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    delegate: CpiAccountInfo,
    owner: CpiAccountInfo,
    amount: u64,
    decimals: u8,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.approve_checked_spec) = undefined;
    var data: dataArray(instruction.approve_checked_spec) = undefined;
    const ix = rebrand(
        instruction.approveChecked(
            source.key(),
            mint.key(),
            delegate.key(),
            owner.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ source, mint, delegate, owner, token_program },
        signer_seeds,
    );
}

/// Invoke `ApproveChecked` with a multisig authority.
pub fn approveCheckedMultisig(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    delegate: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    amount: u64,
    decimals: u8,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.approve_checked_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(source.key());
    metas[1] = AccountMeta.readonly(mint.key());
    metas[2] = AccountMeta.readonly(delegate.key());
    metas[3] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.approve_checked_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.approve_checked_spec.accounts_len,
        instruction.approve_checked_spec.accounts_len,
        .signer,
        .{ source, mint, delegate, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.approve_checked_spec) = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(instruction.TokenInstruction.approve_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

/// Invoke `Revoke` via CPI.
pub fn revoke(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    owner: CpiAccountInfo,
) ProgramResult {
    var metas: metasArray(instruction.revoke_spec) = undefined;
    var data: dataArray(instruction.revoke_spec) = undefined;
    const ix = rebrand(
        instruction.revoke(source.key(), owner.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ source, owner, token_program });
}

/// Signed-authority variant of `revoke`.
pub fn revokeSigned(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    owner: CpiAccountInfo,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.revoke_spec) = undefined;
    var data: dataArray(instruction.revoke_spec) = undefined;
    const ix = rebrand(
        instruction.revoke(source.key(), owner.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ source, owner, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `revokeSigned`.
pub inline fn revokeSignedSingle(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    owner: CpiAccountInfo,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.revoke_spec) = undefined;
    var data: dataArray(instruction.revoke_spec) = undefined;
    const ix = rebrand(
        instruction.revoke(source.key(), owner.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ source, owner, token_program },
        signer_seeds,
    );
}

/// Invoke `Revoke` with a multisig authority.
pub fn revokeMultisig(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.revoke_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(source.key());
    metas[1] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.revoke_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.revoke_spec.accounts_len,
        instruction.revoke_spec.accounts_len,
        .signer,
        .{ source, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.revoke_spec) = .{@intFromEnum(instruction.TokenInstruction.revoke)};
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

/// Invoke `SetAuthority` via CPI.
pub fn setAuthority(
    token_program: CpiAccountInfo,
    target: CpiAccountInfo,
    current_authority: CpiAccountInfo,
    authority_type: instruction.AuthorityType,
    new_authority: ?*const Pubkey,
) ProgramResult {
    var metas: metasArray(instruction.set_authority_spec) = undefined;
    var data: dataArray(instruction.set_authority_spec) = undefined;
    const ix = rebrand(
        instruction.setAuthority(
            target.key(),
            current_authority.key(),
            authority_type,
            new_authority,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(
        &ix,
        &[_]CpiAccountInfo{ target, current_authority, token_program },
    );
}

/// Signed-authority variant of `setAuthority`.
pub fn setAuthoritySigned(
    token_program: CpiAccountInfo,
    target: CpiAccountInfo,
    current_authority: CpiAccountInfo,
    authority_type: instruction.AuthorityType,
    new_authority: ?*const Pubkey,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.set_authority_spec) = undefined;
    var data: dataArray(instruction.set_authority_spec) = undefined;
    const ix = rebrand(
        instruction.setAuthority(
            target.key(),
            current_authority.key(),
            authority_type,
            new_authority,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ target, current_authority, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `setAuthoritySigned`.
pub inline fn setAuthoritySignedSingle(
    token_program: CpiAccountInfo,
    target: CpiAccountInfo,
    current_authority: CpiAccountInfo,
    authority_type: instruction.AuthorityType,
    new_authority: ?*const Pubkey,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.set_authority_spec) = undefined;
    var data: dataArray(instruction.set_authority_spec) = undefined;
    const ix = rebrand(
        instruction.setAuthority(
            target.key(),
            current_authority.key(),
            authority_type,
            new_authority,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ target, current_authority, token_program },
        signer_seeds,
    );
}

/// Invoke `SetAuthority` with a multisig authority.
pub fn setAuthorityMultisig(
    token_program: CpiAccountInfo,
    target: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    authority_type: instruction.AuthorityType,
    new_authority: ?*const Pubkey,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.set_authority_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(target.key());
    metas[1] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.set_authority_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.set_authority_spec.accounts_len,
        instruction.set_authority_spec.accounts_len,
        .signer,
        .{ target, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    var data: dataArray(instruction.set_authority_spec) = undefined;
    data[0] = @intFromEnum(instruction.TokenInstruction.set_authority);
    data[1] = @intFromEnum(authority_type);
    const data_slice = if (new_authority) |authority| blk: {
        data[2] = 1;
        @memcpy(data[3..instruction.set_authority_spec.data_len], authority);
        break :blk data[0..instruction.set_authority_spec.data_len];
    } else blk: {
        data[2] = 0;
        break :blk data[0..instruction.set_authority_none_data_len];
    };

    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, data_slice);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

/// Invoke `FreezeAccount` via CPI.
pub fn freezeAccount(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    freeze_authority: CpiAccountInfo,
) ProgramResult {
    var metas: metasArray(instruction.freeze_account_spec) = undefined;
    var data: dataArray(instruction.freeze_account_spec) = undefined;
    const ix = rebrand(
        instruction.freezeAccount(
            account.key(),
            mint.key(),
            freeze_authority.key(),
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(
        &ix,
        &[_]CpiAccountInfo{ account, mint, freeze_authority, token_program },
    );
}

/// Signed-authority variant of `freezeAccount`.
pub fn freezeAccountSigned(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    freeze_authority: CpiAccountInfo,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.freeze_account_spec) = undefined;
    var data: dataArray(instruction.freeze_account_spec) = undefined;
    const ix = rebrand(
        instruction.freezeAccount(
            account.key(),
            mint.key(),
            freeze_authority.key(),
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ account, mint, freeze_authority, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `freezeAccountSigned`.
pub inline fn freezeAccountSignedSingle(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    freeze_authority: CpiAccountInfo,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.freeze_account_spec) = undefined;
    var data: dataArray(instruction.freeze_account_spec) = undefined;
    const ix = rebrand(
        instruction.freezeAccount(
            account.key(),
            mint.key(),
            freeze_authority.key(),
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ account, mint, freeze_authority, token_program },
        signer_seeds,
    );
}

/// Invoke `FreezeAccount` with a multisig authority.
pub fn freezeAccountMultisig(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.freeze_account_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(account.key());
    metas[1] = AccountMeta.readonly(mint.key());
    metas[2] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.freeze_account_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.freeze_account_spec.accounts_len,
        instruction.freeze_account_spec.accounts_len,
        .signer,
        .{ account, mint, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.freeze_account_spec) = .{@intFromEnum(instruction.TokenInstruction.freeze_account)};
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

/// Invoke `ThawAccount` via CPI.
pub fn thawAccount(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    freeze_authority: CpiAccountInfo,
) ProgramResult {
    var metas: metasArray(instruction.thaw_account_spec) = undefined;
    var data: dataArray(instruction.thaw_account_spec) = undefined;
    const ix = rebrand(
        instruction.thawAccount(account.key(), mint.key(), freeze_authority.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(
        &ix,
        &[_]CpiAccountInfo{ account, mint, freeze_authority, token_program },
    );
}

/// Signed-authority variant of `thawAccount`.
pub fn thawAccountSigned(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    freeze_authority: CpiAccountInfo,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.thaw_account_spec) = undefined;
    var data: dataArray(instruction.thaw_account_spec) = undefined;
    const ix = rebrand(
        instruction.thawAccount(account.key(), mint.key(), freeze_authority.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ account, mint, freeze_authority, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `thawAccountSigned`.
pub inline fn thawAccountSignedSingle(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    freeze_authority: CpiAccountInfo,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.thaw_account_spec) = undefined;
    var data: dataArray(instruction.thaw_account_spec) = undefined;
    const ix = rebrand(
        instruction.thawAccount(account.key(), mint.key(), freeze_authority.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ account, mint, freeze_authority, token_program },
        signer_seeds,
    );
}

/// Invoke `ThawAccount` with a multisig authority.
pub fn thawAccountMultisig(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.thaw_account_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(account.key());
    metas[1] = AccountMeta.readonly(mint.key());
    metas[2] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.thaw_account_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.thaw_account_spec.accounts_len,
        instruction.thaw_account_spec.accounts_len,
        .signer,
        .{ account, mint, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.thaw_account_spec) = .{@intFromEnum(instruction.TokenInstruction.thaw_account)};
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

// =============================================================================
// MintTo
// =============================================================================

/// Invoke `MintTo { amount }` via CPI.
pub fn mintTo(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
) ProgramResult {
    var metas: metasArray(instruction.mint_to_spec) = undefined;
    var data: dataArray(instruction.mint_to_spec) = undefined;
    const ix = rebrand(
        instruction.mintTo(mint.key(), destination.key(), authority.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ mint, destination, authority, token_program });
}

/// Signed-authority variant of `mintTo`.
pub fn mintToSigned(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.mint_to_spec) = undefined;
    var data: dataArray(instruction.mint_to_spec) = undefined;
    const ix = rebrand(
        instruction.mintTo(mint.key(), destination.key(), authority.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ mint, destination, authority, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `mintToSigned`.
pub inline fn mintToSignedSingle(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.mint_to_spec) = undefined;
    var data: dataArray(instruction.mint_to_spec) = undefined;
    const ix = rebrand(
        instruction.mintTo(mint.key(), destination.key(), authority.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ mint, destination, authority, token_program },
        signer_seeds,
    );
}

/// Invoke `MintToChecked { amount, decimals }` via CPI.
pub fn mintToChecked(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    decimals: u8,
) ProgramResult {
    var metas: metasArray(instruction.mint_to_checked_spec) = undefined;
    var data: dataArray(instruction.mint_to_checked_spec) = undefined;
    const ix = rebrand(
        instruction.mintToChecked(
            mint.key(),
            destination.key(),
            authority.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ mint, destination, authority, token_program });
}

/// Signed-authority variant of `mintToChecked`.
pub fn mintToCheckedSigned(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    decimals: u8,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.mint_to_checked_spec) = undefined;
    var data: dataArray(instruction.mint_to_checked_spec) = undefined;
    const ix = rebrand(
        instruction.mintToChecked(
            mint.key(),
            destination.key(),
            authority.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ mint, destination, authority, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `mintToCheckedSigned`.
pub inline fn mintToCheckedSignedSingle(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    decimals: u8,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.mint_to_checked_spec) = undefined;
    var data: dataArray(instruction.mint_to_checked_spec) = undefined;
    const ix = rebrand(
        instruction.mintToChecked(
            mint.key(),
            destination.key(),
            authority.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ mint, destination, authority, token_program },
        signer_seeds,
    );
}

/// Invoke `MintTo` with a multisig mint authority.
pub fn mintToMultisig(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    amount: u64,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.mint_to_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(mint.key());
    metas[1] = AccountMeta.writable(destination.key());
    metas[2] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.mint_to_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.mint_to_spec.accounts_len,
        instruction.mint_to_spec.accounts_len,
        .signer,
        .{ mint, destination, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.mint_to_spec) = AmountIx.initWithDiscriminant(
        @intFromEnum(instruction.TokenInstruction.mint_to),
        .{ .amount = amount },
    );
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

/// Invoke `MintToChecked` with a multisig mint authority.
pub fn mintToCheckedMultisig(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    destination: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    amount: u64,
    decimals: u8,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.mint_to_checked_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(mint.key());
    metas[1] = AccountMeta.writable(destination.key());
    metas[2] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.mint_to_checked_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.mint_to_checked_spec.accounts_len,
        instruction.mint_to_checked_spec.accounts_len,
        .signer,
        .{ mint, destination, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.mint_to_checked_spec) = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(instruction.TokenInstruction.mint_to_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

// =============================================================================
// Burn
// =============================================================================

/// Invoke `Burn { amount }` via CPI.
pub fn burn(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
) ProgramResult {
    var metas: metasArray(instruction.burn_spec) = undefined;
    var data: dataArray(instruction.burn_spec) = undefined;
    const ix = rebrand(
        instruction.burn(source.key(), mint.key(), authority.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ source, mint, authority, token_program });
}

/// Signed-authority variant of `burn`.
pub fn burnSigned(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.burn_spec) = undefined;
    var data: dataArray(instruction.burn_spec) = undefined;
    const ix = rebrand(
        instruction.burn(source.key(), mint.key(), authority.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ source, mint, authority, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `burnSigned`.
pub inline fn burnSignedSingle(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.burn_spec) = undefined;
    var data: dataArray(instruction.burn_spec) = undefined;
    const ix = rebrand(
        instruction.burn(source.key(), mint.key(), authority.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ source, mint, authority, token_program },
        signer_seeds,
    );
}

/// Invoke `BurnChecked { amount, decimals }` via CPI.
pub fn burnChecked(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    decimals: u8,
) ProgramResult {
    var metas: metasArray(instruction.burn_checked_spec) = undefined;
    var data: dataArray(instruction.burn_checked_spec) = undefined;
    const ix = rebrand(
        instruction.burnChecked(
            source.key(),
            mint.key(),
            authority.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ source, mint, authority, token_program });
}

/// Signed-authority variant of `burnChecked`.
pub fn burnCheckedSigned(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    decimals: u8,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.burn_checked_spec) = undefined;
    var data: dataArray(instruction.burn_checked_spec) = undefined;
    const ix = rebrand(
        instruction.burnChecked(
            source.key(),
            mint.key(),
            authority.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ source, mint, authority, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `burnCheckedSigned`.
pub inline fn burnCheckedSignedSingle(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    authority: CpiAccountInfo,
    amount: u64,
    decimals: u8,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.burn_checked_spec) = undefined;
    var data: dataArray(instruction.burn_checked_spec) = undefined;
    const ix = rebrand(
        instruction.burnChecked(
            source.key(),
            mint.key(),
            authority.key(),
            amount,
            decimals,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ source, mint, authority, token_program },
        signer_seeds,
    );
}

/// Invoke `Burn` with a multisig authority.
pub fn burnMultisig(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    amount: u64,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.burn_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(source.key());
    metas[1] = AccountMeta.writable(mint.key());
    metas[2] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.burn_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.burn_spec.accounts_len,
        instruction.burn_spec.accounts_len,
        .signer,
        .{ source, mint, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.burn_spec) = AmountIx.initWithDiscriminant(
        @intFromEnum(instruction.TokenInstruction.burn),
        .{ .amount = amount },
    );
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

/// Invoke `BurnChecked` with a multisig authority.
pub fn burnCheckedMultisig(
    token_program: CpiAccountInfo,
    source: CpiAccountInfo,
    mint: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    amount: u64,
    decimals: u8,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.burn_checked_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(source.key());
    metas[1] = AccountMeta.writable(mint.key());
    metas[2] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.burn_checked_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.burn_checked_spec.accounts_len,
        instruction.burn_checked_spec.accounts_len,
        .signer,
        .{ source, mint, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.burn_checked_spec) = AmountDecimalsIx.initWithDiscriminant(
        @intFromEnum(instruction.TokenInstruction.burn_checked),
        .{ .amount = amount, .decimals = decimals },
    );
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

// =============================================================================
// CloseAccount
// =============================================================================

/// Invoke `CloseAccount` via CPI.
pub fn closeAccount(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
) ProgramResult {
    var metas: metasArray(instruction.close_account_spec) = undefined;
    var data: dataArray(instruction.close_account_spec) = undefined;
    const ix = rebrand(
        instruction.closeAccount(account.key(), destination.key(), authority.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ account, destination, authority, token_program });
}

/// Signed-authority variant of `closeAccount`.
pub fn closeAccountSigned(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    signers: []const Signer,
) ProgramResult {
    var metas: metasArray(instruction.close_account_spec) = undefined;
    var data: dataArray(instruction.close_account_spec) = undefined;
    const ix = rebrand(
        instruction.closeAccount(account.key(), destination.key(), authority.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ account, destination, authority, token_program },
        signers,
    );
}

/// Single-signer-seeds fast path for `closeAccountSigned`.
pub inline fn closeAccountSignedSingle(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    destination: CpiAccountInfo,
    authority: CpiAccountInfo,
    signer_seeds: anytype,
) ProgramResult {
    var metas: metasArray(instruction.close_account_spec) = undefined;
    var data: dataArray(instruction.close_account_spec) = undefined;
    const ix = rebrand(
        instruction.closeAccount(account.key(), destination.key(), authority.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ account, destination, authority, token_program },
        signer_seeds,
    );
}

/// Invoke `CloseAccount` with a multisig authority.
pub fn closeAccountMultisig(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    destination: CpiAccountInfo,
    multisig_authority: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
) ProgramResult {
    var metas: instruction.multisigMetasArray(instruction.close_account_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(account.key());
    metas[1] = AccountMeta.writable(destination.key());
    metas[2] = AccountMeta.readonly(multisig_authority.key());

    var accounts: [instruction.close_account_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.close_account_spec.accounts_len,
        instruction.close_account_spec.accounts_len,
        .signer,
        .{ account, destination, multisig_authority },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.close_account_spec) = .{@intFromEnum(instruction.TokenInstruction.close_account)};
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

/// Invoke the SPL Token batch instruction.
///
/// High-level / ergonomic path for Batch CPI.
///
/// `entries` is the logical child-instruction list. `child_runtime_accounts`
/// must be the fully-flattened child-account list in the same order as the
/// concatenated `AccountMeta`s across every entry. `invoke_accounts_out`
/// provides caller-owned scratch with room for all child accounts plus the
/// token-program account appended at the end.
///
/// If the caller already owns the exact prepared invoke-account slice, prefer
/// `batchPrepared` / `batchPreparedSigned` / `batchPreparedSignedSingle` to
/// skip SDK-side runtime-account staging.
/// Invoke the pinocchio-style `Batch` instruction via CPI.
pub fn batch(
    token_program: CpiAccountInfo,
    entries: []const BatchEntry,
    child_runtime_accounts: []const CpiAccountInfo,
    invoke_accounts_out: []CpiAccountInfo,
    metas: []AccountMeta,
    data: []u8,
) ProgramResult {
    const ix = instruction.batchEntriesForProgram(token_program.key(), entries, metas, data) catch |err| {
        return mapBatchInstructionError(err);
    };
    const invoke_accounts = try stageBatchRuntimeAccounts(
        ix.accounts.len,
        child_runtime_accounts,
        token_program,
        invoke_accounts_out,
    );
    try sol.cpi.invokeRaw(&ix, invoke_accounts);
}

/// Signed-authority variant of `batch`.
/// Ergonomic default when the caller wants SDK-side invoke-account staging.
pub fn batchSigned(
    token_program: CpiAccountInfo,
    entries: []const BatchEntry,
    child_runtime_accounts: []const CpiAccountInfo,
    invoke_accounts_out: []CpiAccountInfo,
    metas: []AccountMeta,
    data: []u8,
    signers: []const Signer,
) ProgramResult {
    const ix = instruction.batchEntriesForProgram(token_program.key(), entries, metas, data) catch |err| {
        return mapBatchInstructionError(err);
    };
    const invoke_accounts = try stageBatchRuntimeAccounts(
        ix.accounts.len,
        child_runtime_accounts,
        token_program,
        invoke_accounts_out,
    );
    try sol.cpi.invokeSignedRaw(&ix, invoke_accounts, signers);
}

/// Single-signer-seeds fast path for `batchSigned`.
/// Ergonomic default for the common 1-PDA case.
pub inline fn batchSignedSingle(
    token_program: CpiAccountInfo,
    entries: []const BatchEntry,
    child_runtime_accounts: []const CpiAccountInfo,
    invoke_accounts_out: []CpiAccountInfo,
    metas: []AccountMeta,
    data: []u8,
    signer_seeds: anytype,
) ProgramResult {
    const ix = instruction.batchEntriesForProgram(token_program.key(), entries, metas, data) catch |err| {
        return mapBatchInstructionError(err);
    };
    const invoke_accounts = try stageBatchRuntimeAccounts(
        ix.accounts.len,
        child_runtime_accounts,
        token_program,
        invoke_accounts_out,
    );
    try sol.cpi.invokeSignedSingle(&ix, invoke_accounts, signer_seeds);
}

/// Lower-level fast path for `batch` when the caller already has the fully
/// flattened runtime-account slice prepared with `token_program` appended last.
///
/// Use this when the caller is optimizing hot paths and can cheaply retain or
/// reconstruct the exact invoke-account ordering itself. This avoids the local
/// SDK-side runtime-account staging step that `batch` performs.
pub inline fn batchPrepared(
    token_program: CpiAccountInfo,
    entries: []const BatchEntry,
    invoke_accounts: []const CpiAccountInfo,
    metas: []AccountMeta,
    data: []u8,
) ProgramResult {
    const ix = instruction.batchEntriesForProgram(token_program.key(), entries, metas, data) catch |err| {
        return mapBatchInstructionError(err);
    };
    try validatePreparedBatchRuntimeAccounts(ix.accounts.len, invoke_accounts, token_program);
    try sol.cpi.invokeRaw(&ix, invoke_accounts);
}

/// Signed-authority variant of `batchPrepared`.
/// Lower-overhead path when the caller already owns the prepared invoke slice.
pub inline fn batchPreparedSigned(
    token_program: CpiAccountInfo,
    entries: []const BatchEntry,
    invoke_accounts: []const CpiAccountInfo,
    metas: []AccountMeta,
    data: []u8,
    signers: []const Signer,
) ProgramResult {
    const ix = instruction.batchEntriesForProgram(token_program.key(), entries, metas, data) catch |err| {
        return mapBatchInstructionError(err);
    };
    try validatePreparedBatchRuntimeAccounts(ix.accounts.len, invoke_accounts, token_program);
    try sol.cpi.invokeSignedRaw(&ix, invoke_accounts, signers);
}

/// Single-signer-seeds fast path for `batchPreparedSigned`.
/// Lowest-overhead local API for the common 1-PDA prepared-Batch case.
pub inline fn batchPreparedSignedSingle(
    token_program: CpiAccountInfo,
    entries: []const BatchEntry,
    invoke_accounts: []const CpiAccountInfo,
    metas: []AccountMeta,
    data: []u8,
    signer_seeds: anytype,
) ProgramResult {
    const ix = instruction.batchEntriesForProgram(token_program.key(), entries, metas, data) catch |err| {
        return mapBatchInstructionError(err);
    };
    try validatePreparedBatchRuntimeAccounts(ix.accounts.len, invoke_accounts, token_program);
    try sol.cpi.invokeSignedSingle(&ix, invoke_accounts, signer_seeds);
}

/// Invoke `SyncNative` via CPI.
pub fn syncNative(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
) ProgramResult {
    var metas: metasArray(instruction.sync_native_spec) = undefined;
    var data: dataArray(instruction.sync_native_spec) = undefined;
    const ix = rebrand(
        instruction.syncNative(account.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ account, token_program });
}

// =============================================================================
// Utility / return-data helpers.
// =============================================================================

/// Invoke `GetAccountDataSize`; read the answer from `sol.cpi.getReturnData(...)`.
pub fn getAccountDataSize(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
) ProgramResult {
    var metas: metasArray(instruction.get_account_data_size_spec) = undefined;
    var data: dataArray(instruction.get_account_data_size_spec) = undefined;
    const ix = rebrand(
        instruction.getAccountDataSize(mint.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ mint, token_program });
}

/// Invoke `InitializeImmutableOwner` via CPI.
pub fn initializeImmutableOwner(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
) ProgramResult {
    var metas: metasArray(instruction.initialize_immutable_owner_spec) = undefined;
    var data: dataArray(instruction.initialize_immutable_owner_spec) = undefined;
    const ix = rebrand(
        instruction.initializeImmutableOwner(account.key(), &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ account, token_program });
}

/// Invoke `AmountToUiAmount`; read the UTF-8 result from `sol.cpi.getReturnData(...)`.
pub fn amountToUiAmount(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    amount: u64,
) ProgramResult {
    var metas: metasArray(instruction.amount_to_ui_amount_spec) = undefined;
    var data: dataArray(instruction.amount_to_ui_amount_spec) = undefined;
    const ix = rebrand(
        instruction.amountToUiAmount(mint.key(), amount, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ mint, token_program });
}

/// Invoke `UiAmountToAmount`; read the little-endian `u64` result from `sol.cpi.getReturnData(...)`.
pub fn uiAmountToAmount(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    ui_amount: []const u8,
    data: []u8,
) ProgramResult {
    var metas: metasArray(instruction.get_account_data_size_spec) = undefined;
    const ix = rebrand(
        try instruction.uiAmountToAmount(mint.key(), ui_amount, &metas, data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ mint, token_program });
}

// =============================================================================
// Initialize* — typically used at mint/account creation time.
// =============================================================================

/// Invoke legacy `InitializeMint` via CPI.
pub fn initializeMint(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    rent_sysvar: CpiAccountInfo,
    decimals: u8,
    mint_authority: *const Pubkey,
    freeze_authority: ?*const Pubkey,
) ProgramResult {
    var metas: metasArray(instruction.initialize_mint_spec) = undefined;
    var data: dataArray(instruction.initialize_mint_spec) = undefined;
    const ix = rebrand(
        instruction.initializeMint(mint.key(), decimals, mint_authority, freeze_authority, &metas, &data),
        token_program.key(),
    );
    metas[1] = AccountMeta.readonly(rent_sysvar.key());
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ mint, rent_sysvar, token_program });
}

/// Invoke legacy `InitializeAccount` via CPI.
pub fn initializeAccount(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    owner: CpiAccountInfo,
    rent_sysvar: CpiAccountInfo,
) ProgramResult {
    var metas: metasArray(instruction.initialize_account_spec) = undefined;
    var data: dataArray(instruction.initialize_account_spec) = undefined;
    const ix = rebrand(
        instruction.initializeAccount(account.key(), mint.key(), owner.key(), &metas, &data),
        token_program.key(),
    );
    metas[3] = AccountMeta.readonly(rent_sysvar.key());
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ account, mint, owner, rent_sysvar, token_program });
}

/// Invoke `InitializeAccount2` via CPI.
pub fn initializeAccount2(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    rent_sysvar: CpiAccountInfo,
    owner: *const Pubkey,
) ProgramResult {
    var metas: metasArray(instruction.initialize_account2_spec) = undefined;
    var data: dataArray(instruction.initialize_account2_spec) = undefined;
    const ix = rebrand(
        instruction.initializeAccount2(account.key(), mint.key(), owner, &metas, &data),
        token_program.key(),
    );
    metas[2] = AccountMeta.readonly(rent_sysvar.key());
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ account, mint, rent_sysvar, token_program });
}

/// Invoke `InitializeAccount3` via CPI.
pub fn initializeAccount3(
    token_program: CpiAccountInfo,
    account: CpiAccountInfo,
    mint: CpiAccountInfo,
    owner: *const Pubkey,
) ProgramResult {
    var metas: metasArray(instruction.initialize_account3_spec) = undefined;
    var data: dataArray(instruction.initialize_account3_spec) = undefined;
    const ix = rebrand(
        instruction.initializeAccount3(account.key(), mint.key(), owner, &metas, &data),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ account, mint, token_program });
}

/// Invoke `InitializeMint2` via CPI.
pub fn initializeMint2(
    token_program: CpiAccountInfo,
    mint: CpiAccountInfo,
    decimals: u8,
    mint_authority: *const Pubkey,
    freeze_authority: ?*const Pubkey,
) ProgramResult {
    var metas: metasArray(instruction.initialize_mint2_spec) = undefined;
    var data: dataArray(instruction.initialize_mint2_spec) = undefined;
    const ix = rebrand(
        instruction.initializeMint2(
            mint.key(),
            decimals,
            mint_authority,
            freeze_authority,
            &metas,
            &data,
        ),
        token_program.key(),
    );
    try sol.cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ mint, token_program });
}

/// Invoke legacy `InitializeMultisig` via CPI.
pub fn initializeMultisig(
    token_program: CpiAccountInfo,
    multisig: CpiAccountInfo,
    rent_sysvar: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    threshold: u8,
) ProgramResult {
    try validateSignerInfoThreshold(signer_infos, threshold);

    var metas: instruction.multisigMetasArray(instruction.initialize_multisig_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(multisig.key());
    metas[1] = AccountMeta.readonly(rent_sysvar.key());

    var accounts: [instruction.initialize_multisig_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.initialize_multisig_spec.accounts_len,
        instruction.initialize_multisig_spec.accounts_len,
        .readonly,
        .{ multisig, rent_sysvar },
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.initialize_multisig_spec) = .{
        @intFromEnum(instruction.TokenInstruction.initialize_multisig),
        threshold,
    };
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

/// Invoke `InitializeMultisig2` via CPI.
pub fn initializeMultisig2(
    token_program: CpiAccountInfo,
    multisig: CpiAccountInfo,
    signer_infos: []const CpiAccountInfo,
    threshold: u8,
) ProgramResult {
    try validateSignerInfoThreshold(signer_infos, threshold);

    var metas: instruction.multisigMetasArray(instruction.initialize_multisig2_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(multisig.key());

    var accounts: [instruction.initialize_multisig2_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.initialize_multisig2_spec.accounts_len,
        instruction.initialize_multisig2_spec.accounts_len,
        .readonly,
        .{multisig},
        signer_infos,
        token_program,
        &metas,
        &accounts,
    );

    const data: dataArray(instruction.initialize_multisig2_spec) = .{
        @intFromEnum(instruction.TokenInstruction.initialize_multisig2),
        threshold,
    };
    const ix = Instruction.fromCpiAccount(token_program, staged.instruction_accounts, &data);
    try sol.cpi.invokeRaw(&ix, staged.runtime_accounts);
}

const TestAccount = extern struct {
    raw: sol.account.Account,
    data: [8]u8 = .{0} ** 8,
};

fn testAccount(
    key: Pubkey,
    owner: Pubkey,
    signer: bool,
    writable: bool,
    executable: bool,
) TestAccount {
    return .{
        .raw = .{
            .borrow_state = sol.account.NOT_BORROWED,
            .is_signer = @intFromBool(signer),
            .is_writable = @intFromBool(writable),
            .is_executable = @intFromBool(executable),
            ._padding = .{0} ** 4,
            .key = key,
            .owner = owner,
            .lamports = 0,
            .data_len = 8,
        },
    };
}

fn testCpiInfo(acc: *sol.account.Account) CpiAccountInfo {
    const info = sol.account.AccountInfo{ .raw = acc };
    return info.toCpiInfo();
}

test "spl-token cpi: public v0.3 wrapper decls exist" {
    inline for ([_][]const u8{
        "approve",
        "approveSigned",
        "approveSignedSingle",
        "approveMultisig",
        "approveChecked",
        "approveCheckedSigned",
        "approveCheckedSignedSingle",
        "approveCheckedMultisig",
        "revoke",
        "revokeSigned",
        "revokeSignedSingle",
        "revokeMultisig",
        "setAuthority",
        "setAuthoritySigned",
        "setAuthoritySignedSingle",
        "setAuthorityMultisig",
        "freezeAccount",
        "freezeAccountSigned",
        "freezeAccountSignedSingle",
        "freezeAccountMultisig",
        "thawAccount",
        "thawAccountSigned",
        "thawAccountSignedSingle",
        "thawAccountMultisig",
        "initializeMint",
        "initializeAccount",
        "initializeAccount2",
        "initializeAccount3",
        "initializeMint2",
        "initializeMultisig",
        "initializeMultisig2",
        "transferMultisig",
        "transferCheckedMultisig",
        "mintToMultisig",
        "mintToCheckedMultisig",
        "burnMultisig",
        "burnCheckedMultisig",
        "closeAccountMultisig",
        "batchChildRuntimeAccountsArray",
        "batchInvokeAccountsArray",
        "batch",
        "batchSigned",
        "batchSignedSingle",
        "batchPrepared",
        "batchPreparedSigned",
        "batchPreparedSignedSingle",
        "syncNative",
        "getAccountDataSize",
        "initializeImmutableOwner",
        "amountToUiAmount",
        "uiAmountToAmount",
    }) |name| {
        try std.testing.expect(@hasDecl(@This(), name));
    }
}

test "spl-token cpi: batch runtime scratch helpers size homogeneous envelopes correctly" {
    const child_accounts: batchChildRuntimeAccountsArray(instruction.transfer_checked_spec, 2) = undefined;
    const invoke_accounts: batchInvokeAccountsArray(instruction.transfer_checked_spec, 2) = undefined;

    try std.testing.expectEqual(@as(usize, instruction.transfer_checked_spec.accounts_len * 2), child_accounts.len);
    try std.testing.expectEqual(@as(usize, instruction.transfer_checked_spec.accounts_len * 2 + 1), invoke_accounts.len);
}

test "spl-token cpi: multisig staging keeps signer metas and runtime accounts aligned" {
    var source_account = testAccount(.{0x21} ** 32, .{0x81} ** 32, false, true, false);
    var delegate_account = testAccount(.{0x22} ** 32, .{0x82} ** 32, false, false, false);
    var multisig_account = testAccount(.{0x23} ** 32, .{0x83} ** 32, false, false, false);
    var signer_a_account = testAccount(.{0x24} ** 32, .{0x84} ** 32, true, false, false);
    var signer_b_account = testAccount(.{0x25} ** 32, .{0x85} ** 32, true, false, false);
    var token_program_account = testAccount(.{0x26} ** 32, .{0x86} ** 32, false, false, true);

    const source = testCpiInfo(&source_account.raw);
    const delegate = testCpiInfo(&delegate_account.raw);
    const multisig = testCpiInfo(&multisig_account.raw);
    const signer_a = testCpiInfo(&signer_a_account.raw);
    const signer_b = testCpiInfo(&signer_b_account.raw);
    const token_program = testCpiInfo(&token_program_account.raw);

    var metas: instruction.multisigMetasArray(instruction.approve_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(source.key());
    metas[1] = AccountMeta.readonly(delegate.key());
    metas[2] = AccountMeta.readonly(multisig.key());

    var infos: [instruction.approve_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.approve_spec.accounts_len,
        instruction.approve_spec.accounts_len,
        .signer,
        .{ source, delegate, multisig },
        &.{ signer_a, signer_b },
        token_program,
        &metas,
        &infos,
    );

    try std.testing.expectEqual(@as(usize, 5), staged.instruction_accounts.len);
    try std.testing.expectEqual(@as(usize, 6), staged.runtime_accounts.len);
    try std.testing.expectEqualSlices(u8, signer_a.key(), staged.instruction_accounts[3].pubkey);
    try std.testing.expectEqual(@as(u8, 1), staged.instruction_accounts[3].is_signer);
    try std.testing.expectEqual(@as(u8, 0), staged.instruction_accounts[3].is_writable);
    try std.testing.expectEqualSlices(u8, signer_b.key(), staged.instruction_accounts[4].pubkey);
    try std.testing.expectEqual(@as(u8, 1), staged.instruction_accounts[4].is_signer);
    try std.testing.expectEqual(@as(u8, 0), staged.instruction_accounts[4].is_writable);
    try std.testing.expectEqualSlices(u8, source.key(), staged.runtime_accounts[0].key());
    try std.testing.expectEqualSlices(u8, delegate.key(), staged.runtime_accounts[1].key());
    try std.testing.expectEqualSlices(u8, multisig.key(), staged.runtime_accounts[2].key());
    try std.testing.expectEqualSlices(u8, signer_a.key(), staged.runtime_accounts[3].key());
    try std.testing.expectEqualSlices(u8, signer_b.key(), staged.runtime_accounts[4].key());
    try std.testing.expectEqualSlices(u8, token_program.key(), staged.runtime_accounts[5].key());
}

test "spl-token cpi: readonly multisig staging keeps non-signer metas aligned" {
    var multisig_account = testAccount(.{0x27} ** 32, .{0x87} ** 32, false, true, false);
    var signer_a_account = testAccount(.{0x28} ** 32, .{0x88} ** 32, false, false, false);
    var signer_b_account = testAccount(.{0x29} ** 32, .{0x89} ** 32, false, false, false);
    var token_program_account = testAccount(.{0x2A} ** 32, .{0x8A} ** 32, false, false, true);

    const multisig = testCpiInfo(&multisig_account.raw);
    const signer_a = testCpiInfo(&signer_a_account.raw);
    const signer_b = testCpiInfo(&signer_b_account.raw);
    const token_program = testCpiInfo(&token_program_account.raw);

    var metas: instruction.multisigMetasArray(instruction.initialize_multisig2_spec.accounts_len) = undefined;
    metas[0] = AccountMeta.writable(multisig.key());

    var infos: [instruction.initialize_multisig2_spec.accounts_len + MAX_SIGNERS + 1]CpiAccountInfo = undefined;
    const staged = try multisigMetasAndRuntimeAccounts(
        instruction.initialize_multisig2_spec.accounts_len,
        instruction.initialize_multisig2_spec.accounts_len,
        .readonly,
        .{multisig},
        &.{ signer_a, signer_b },
        token_program,
        &metas,
        &infos,
    );

    try std.testing.expectEqual(@as(usize, 3), staged.instruction_accounts.len);
    try std.testing.expectEqual(@as(u8, 0), staged.instruction_accounts[1].is_signer);
    try std.testing.expectEqual(@as(u8, 0), staged.instruction_accounts[1].is_writable);
    try std.testing.expectEqualSlices(u8, signer_a.key(), staged.instruction_accounts[1].pubkey);
    try std.testing.expectEqualSlices(u8, signer_b.key(), staged.instruction_accounts[2].pubkey);
    try std.testing.expectEqual(@as(usize, 4), staged.runtime_accounts.len);
    try std.testing.expectEqualSlices(u8, token_program.key(), staged.runtime_accounts[3].key());
}

test "spl-token cpi: batch rebrands callee and preserves flattened runtime account order" {
    var source_account = testAccount(.{0x30} ** 32, .{0x90} ** 32, false, true, false);
    var mint_account = testAccount(.{0x31} ** 32, .{0x91} ** 32, false, false, false);
    var destination_account = testAccount(.{0x32} ** 32, .{0x92} ** 32, false, true, false);
    var authority_account = testAccount(.{0x33} ** 32, .{0x93} ** 32, true, false, false);
    var token_program_account = testAccount(sol.spl_token_2022_program_id, .{0x94} ** 32, false, false, true);

    const source = testCpiInfo(&source_account.raw);
    const mint = testCpiInfo(&mint_account.raw);
    const destination = testCpiInfo(&destination_account.raw);
    const authority = testCpiInfo(&authority_account.raw);
    const token_program = testCpiInfo(&token_program_account.raw);

    var child_a_metas: metasArray(instruction.transfer_checked_spec) = undefined;
    var child_a_data: dataArray(instruction.transfer_checked_spec) = undefined;
    const child_a = instruction.transferChecked(
        source.key(),
        mint.key(),
        destination.key(),
        authority.key(),
        11,
        6,
        &child_a_metas,
        &child_a_data,
    );

    var child_b_metas: metasArray(instruction.transfer_checked_spec) = undefined;
    var child_b_data: dataArray(instruction.transfer_checked_spec) = undefined;
    const child_b = instruction.transferChecked(
        source.key(),
        mint.key(),
        destination.key(),
        authority.key(),
        22,
        6,
        &child_b_metas,
        &child_b_data,
    );

    const entries = [_]BatchEntry{
        instruction.asBatchEntry(child_a),
        instruction.asBatchEntry(child_b),
    };
    var batch_metas: [instruction.transfer_checked_spec.accounts_len * entries.len]AccountMeta = undefined;
    var batch_data: [1 + entries.len * (2 + instruction.transfer_checked_spec.data_len)]u8 = undefined;
    const ix = try instruction.batchEntriesForProgram(
        token_program.key(),
        &entries,
        batch_metas[0..],
        batch_data[0..],
    );

    try std.testing.expectEqual(token_program.key(), ix.program_id);
    try std.testing.expectEqual(@as(usize, 8), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 25), ix.data.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(instruction.TokenInstruction.batch)), ix.data[0]);

    var invoke_accounts_buf: [instruction.transfer_checked_spec.accounts_len * entries.len + 1]CpiAccountInfo = undefined;
    const invoke_accounts = try stageBatchRuntimeAccounts(
        ix.accounts.len,
        &.{
            source,
            mint,
            destination,
            authority,
            source,
            mint,
            destination,
            authority,
        },
        token_program,
        invoke_accounts_buf[0..],
    );
    try std.testing.expectEqual(@as(usize, 9), invoke_accounts.len);
    try std.testing.expectEqualSlices(u8, source.key(), invoke_accounts[0].key());
    try std.testing.expectEqualSlices(u8, authority.key(), invoke_accounts[3].key());
    try std.testing.expectEqualSlices(u8, source.key(), invoke_accounts[4].key());
    try std.testing.expectEqualSlices(u8, authority.key(), invoke_accounts[7].key());
    try std.testing.expectEqualSlices(u8, token_program.key(), invoke_accounts[8].key());
}

test "spl-token cpi: batch runtime staging rejects account-count mismatches" {
    var source_account = testAccount(.{0x36} ** 32, .{0x99} ** 32, false, true, false);
    var mint_account = testAccount(.{0x37} ** 32, .{0x9A} ** 32, false, false, false);
    var destination_account = testAccount(.{0x38} ** 32, .{0x9B} ** 32, false, true, false);
    var authority_account = testAccount(.{0x39} ** 32, .{0x9C} ** 32, true, false, false);
    var token_program_account = testAccount(.{0x3A} ** 32, .{0x9D} ** 32, false, false, true);

    const source = testCpiInfo(&source_account.raw);
    const mint = testCpiInfo(&mint_account.raw);
    const destination = testCpiInfo(&destination_account.raw);
    const authority = testCpiInfo(&authority_account.raw);
    const token_program = testCpiInfo(&token_program_account.raw);

    var out: [5]CpiAccountInfo = undefined;
    try std.testing.expectError(
        error.InvalidArgument,
        stageBatchRuntimeAccounts(4, &.{ source, mint, destination }, token_program, out[0..]),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        stageBatchRuntimeAccounts(4, &.{ source, mint, destination, authority }, token_program, out[0..4]),
    );
}

test "spl-token cpi: initializeMint rebrands callee and preserves rent sysvar ordering" {
    var mint_account = testAccount(.{0x2A} ** 32, .{0x8A} ** 32, false, true, false);
    var rent_account = testAccount(sol.rent_id, .{0x8B} ** 32, false, false, false);
    var token_program_account = testAccount(sol.spl_token_2022_program_id, .{0x8C} ** 32, false, false, true);

    const mint = testCpiInfo(&mint_account.raw);
    const rent_sysvar = testCpiInfo(&rent_account.raw);
    const token_program = testCpiInfo(&token_program_account.raw);
    const mint_authority: Pubkey = .{0x8D} ** 32;
    const freeze_authority: Pubkey = .{0x8E} ** 32;

    var metas: metasArray(instruction.initialize_mint_spec) = undefined;
    var data: dataArray(instruction.initialize_mint_spec) = undefined;
    const ix = rebrand(
        instruction.initializeMint(mint.key(), 6, &mint_authority, &freeze_authority, &metas, &data),
        token_program.key(),
    );
    metas[1] = AccountMeta.readonly(rent_sysvar.key());

    try std.testing.expectEqual(token_program.key(), ix.program_id);
    try std.testing.expectEqual(@as(usize, 2), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 70), ix.data.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(instruction.TokenInstruction.initialize_mint)), ix.data[0]);
    try std.testing.expectEqual(@as(u8, 6), ix.data[1]);
    try std.testing.expectEqualSlices(u8, mint.key(), ix.accounts[0].pubkey);
    try std.testing.expectEqualSlices(u8, rent_sysvar.key(), ix.accounts[1].pubkey);
}

test "spl-token cpi: initializeAccount rebrands callee and preserves owner/rent ordering" {
    var account_account = testAccount(.{0x2B} ** 32, .{0x8B} ** 32, false, true, false);
    var mint_account = testAccount(.{0x2C} ** 32, .{0x8C} ** 32, false, false, false);
    var owner_account = testAccount(.{0x2D} ** 32, .{0x8D} ** 32, false, false, false);
    var rent_account = testAccount(sol.rent_id, .{0x8E} ** 32, false, false, false);
    var token_program_account = testAccount(sol.spl_token_2022_program_id, .{0x8F} ** 32, false, false, true);

    const account = testCpiInfo(&account_account.raw);
    const mint = testCpiInfo(&mint_account.raw);
    const owner = testCpiInfo(&owner_account.raw);
    const rent_sysvar = testCpiInfo(&rent_account.raw);
    const token_program = testCpiInfo(&token_program_account.raw);

    var metas: metasArray(instruction.initialize_account_spec) = undefined;
    var data: dataArray(instruction.initialize_account_spec) = undefined;
    const ix = rebrand(
        instruction.initializeAccount(account.key(), mint.key(), owner.key(), &metas, &data),
        token_program.key(),
    );
    metas[3] = AccountMeta.readonly(rent_sysvar.key());

    try std.testing.expectEqual(token_program.key(), ix.program_id);
    try std.testing.expectEqual(@as(usize, 4), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), ix.data.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(instruction.TokenInstruction.initialize_account)), ix.data[0]);
    try std.testing.expectEqualSlices(u8, account.key(), ix.accounts[0].pubkey);
    try std.testing.expectEqualSlices(u8, mint.key(), ix.accounts[1].pubkey);
    try std.testing.expectEqualSlices(u8, owner.key(), ix.accounts[2].pubkey);
    try std.testing.expectEqualSlices(u8, rent_sysvar.key(), ix.accounts[3].pubkey);
}

test "spl-token cpi: syncNative rebrands callee and preserves single runtime account order" {
    var wrapped_account = testAccount(.{0x30} ** 32, .{0x90} ** 32, false, true, false);
    var token_program_account = testAccount(sol.spl_token_2022_program_id, .{0x91} ** 32, false, false, true);

    const wrapped = testCpiInfo(&wrapped_account.raw);
    const token_program = testCpiInfo(&token_program_account.raw);

    var metas: metasArray(instruction.sync_native_spec) = undefined;
    var data: dataArray(instruction.sync_native_spec) = undefined;
    const ix = rebrand(
        instruction.syncNative(wrapped.key(), &metas, &data),
        token_program.key(),
    );

    try std.testing.expectEqual(token_program.key(), ix.program_id);
    try std.testing.expectEqual(@as(usize, 1), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), ix.data.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(instruction.TokenInstruction.sync_native)), ix.data[0]);
    try std.testing.expectEqualSlices(u8, wrapped.key(), ix.accounts[0].pubkey);
}

test "spl-token cpi: initializeAccount2 rebrands callee and preserves rent sysvar ordering" {
    var account_account = testAccount(.{0x2D} ** 32, .{0x8D} ** 32, false, true, false);
    var mint_account = testAccount(.{0x2E} ** 32, .{0x8E} ** 32, false, false, false);
    var rent_account = testAccount(sol.rent_id, .{0x8F} ** 32, false, false, false);
    var token_program_account = testAccount(sol.spl_token_2022_program_id, .{0x90} ** 32, false, false, true);

    const account = testCpiInfo(&account_account.raw);
    const mint = testCpiInfo(&mint_account.raw);
    const rent_sysvar = testCpiInfo(&rent_account.raw);
    const token_program = testCpiInfo(&token_program_account.raw);
    const owner: Pubkey = .{0x91} ** 32;

    var metas: metasArray(instruction.initialize_account2_spec) = undefined;
    var data: dataArray(instruction.initialize_account2_spec) = undefined;
    data = sol.instruction.comptimeInstructionData(
        u8,
        extern struct { owner: Pubkey align(1) },
    ).initWithDiscriminant(
        @intFromEnum(instruction.TokenInstruction.initialize_account2),
        .{ .owner = owner },
    );
    metas[0] = AccountMeta.writable(account.key());
    metas[1] = AccountMeta.readonly(mint.key());
    metas[2] = AccountMeta.readonly(rent_sysvar.key());
    const ix = Instruction.fromCpiAccount(token_program, &metas, &data);

    try std.testing.expectEqual(token_program.key(), ix.program_id);
    try std.testing.expectEqual(@as(usize, 3), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 33), ix.data.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(instruction.TokenInstruction.initialize_account2)), ix.data[0]);
    try std.testing.expectEqualSlices(u8, &owner, ix.data[1..33]);
    try std.testing.expectEqualSlices(u8, account.key(), ix.accounts[0].pubkey);
    try std.testing.expectEqualSlices(u8, mint.key(), ix.accounts[1].pubkey);
    try std.testing.expectEqualSlices(u8, rent_sysvar.key(), ix.accounts[2].pubkey);
}

test "spl-token cpi: initializeMultisig rebrands callee and preserves rent/signer order" {
    var multisig_account = testAccount(.{0x30} ** 32, .{0x90} ** 32, false, true, false);
    var rent_account = testAccount(sol.rent_id, .{0x91} ** 32, false, false, false);
    var signer_a_account = testAccount(.{0x32} ** 32, .{0x92} ** 32, false, false, false);
    var signer_b_account = testAccount(.{0x33} ** 32, .{0x93} ** 32, false, false, false);
    var token_program_account = testAccount(sol.spl_token_2022_program_id, .{0x94} ** 32, false, false, true);

    const multisig = testCpiInfo(&multisig_account.raw);
    const rent_sysvar = testCpiInfo(&rent_account.raw);
    const signer_a = testCpiInfo(&signer_a_account.raw);
    const signer_b = testCpiInfo(&signer_b_account.raw);
    const token_program = testCpiInfo(&token_program_account.raw);

    var signer_pubkeys_buf: [MAX_SIGNERS]Pubkey = undefined;
    const signer_pubkeys = try signerPubkeysFromInfos(&.{ signer_a, signer_b }, &signer_pubkeys_buf);
    var metas: instruction.multisigMetasArray(instruction.initialize_multisig_spec.accounts_len) = undefined;
    var data: dataArray(instruction.initialize_multisig_spec) = undefined;
    const ix = rebrand(
        try instruction.initializeMultisig(multisig.key(), signer_pubkeys, 2, &metas, &data),
        token_program.key(),
    );
    metas[1] = AccountMeta.readonly(rent_sysvar.key());

    try std.testing.expectEqual(token_program.key(), ix.program_id);
    try std.testing.expectEqual(@as(usize, 4), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 2), ix.data.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(instruction.TokenInstruction.initialize_multisig)), ix.data[0]);
    try std.testing.expectEqual(@as(u8, 2), ix.data[1]);
    try std.testing.expectEqualSlices(u8, multisig.key(), ix.accounts[0].pubkey);
    try std.testing.expectEqualSlices(u8, rent_sysvar.key(), ix.accounts[1].pubkey);
    try std.testing.expectEqualSlices(u8, signer_a.key(), ix.accounts[2].pubkey);
    try std.testing.expectEqualSlices(u8, signer_b.key(), ix.accounts[3].pubkey);
}

test "spl-token cpi: initializeMultisig2 rebrands callee and preserves signer order" {
    var multisig_account = testAccount(.{0x31} ** 32, .{0x91} ** 32, false, true, false);
    var signer_a_account = testAccount(.{0x32} ** 32, .{0x92} ** 32, false, false, false);
    var signer_b_account = testAccount(.{0x33} ** 32, .{0x93} ** 32, false, false, false);
    var token_program_account = testAccount(sol.spl_token_2022_program_id, .{0x94} ** 32, false, false, true);

    const multisig = testCpiInfo(&multisig_account.raw);
    const signer_a = testCpiInfo(&signer_a_account.raw);
    const signer_b = testCpiInfo(&signer_b_account.raw);
    const token_program = testCpiInfo(&token_program_account.raw);

    var signer_pubkeys_buf: [MAX_SIGNERS]Pubkey = undefined;
    const signer_pubkeys = try signerPubkeysFromInfos(&.{ signer_a, signer_b }, &signer_pubkeys_buf);
    var metas: instruction.multisigMetasArray(instruction.initialize_multisig2_spec.accounts_len) = undefined;
    var data: dataArray(instruction.initialize_multisig2_spec) = undefined;
    const ix = rebrand(
        try instruction.initializeMultisig2(multisig.key(), signer_pubkeys, 2, &metas, &data),
        token_program.key(),
    );

    try std.testing.expectEqual(token_program.key(), ix.program_id);
    try std.testing.expectEqual(@as(usize, 3), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 2), ix.data.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(instruction.TokenInstruction.initialize_multisig2)), ix.data[0]);
    try std.testing.expectEqual(@as(u8, 2), ix.data[1]);
    try std.testing.expectEqualSlices(u8, multisig.key(), ix.accounts[0].pubkey);
    try std.testing.expectEqualSlices(u8, signer_a.key(), ix.accounts[1].pubkey);
    try std.testing.expectEqualSlices(u8, signer_b.key(), ix.accounts[2].pubkey);
}

test "spl-token cpi: initializeMultisig helpers reject invalid signer counts and thresholds" {
    var token_program_account = testAccount(sol.spl_token_2022_program_id, .{0x95} ** 32, false, false, true);
    var multisig_account = testAccount(.{0x34} ** 32, .{0x96} ** 32, false, true, false);
    var rent_account = testAccount(sol.rent_id, .{0x97} ** 32, false, false, false);
    var signer_account = testAccount(.{0x35} ** 32, .{0x98} ** 32, false, false, false);

    const token_program = testCpiInfo(&token_program_account.raw);
    const multisig = testCpiInfo(&multisig_account.raw);
    const rent_sysvar = testCpiInfo(&rent_account.raw);
    const signer = testCpiInfo(&signer_account.raw);

    try std.testing.expectError(error.InvalidArgument, initializeMultisig(token_program, multisig, rent_sysvar, &.{}, 1));
    try std.testing.expectError(error.InvalidArgument, initializeMultisig(token_program, multisig, rent_sysvar, &.{signer}, 0));
    try std.testing.expectError(error.InvalidArgument, initializeMultisig(token_program, multisig, rent_sysvar, &.{signer}, 2));
    try std.testing.expectError(error.InvalidArgument, initializeMultisig2(token_program, multisig, &.{}, 1));
    try std.testing.expectError(error.InvalidArgument, initializeMultisig2(token_program, multisig, &.{signer}, 0));
    try std.testing.expectError(error.InvalidArgument, initializeMultisig2(token_program, multisig, &.{signer}, 2));
}

test "spl-token cpi: SignedSingle wrappers compile and use host fallback" {
    var token_program_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 1,
        ._padding = .{0} ** 4,
        .key = sol.spl_token_program_id,
        .owner = .{0} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var source_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{1} ** 32,
        .owner = .{2} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var mint_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{3} ** 32,
        .owner = .{4} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var destination_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{5} ** 32,
        .owner = .{6} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var authority_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{7} ** 32,
        .owner = .{8} ** 32,
        .lamports = 0,
        .data_len = 0,
    };

    const token_program = testCpiInfo(&token_program_acc);
    const source = testCpiInfo(&source_acc);
    const mint = testCpiInfo(&mint_acc);
    const destination = testCpiInfo(&destination_acc);
    const authority = testCpiInfo(&authority_acc);
    const bump_seed = [_]u8{255};

    try std.testing.expectError(
        error.InvalidArgument,
        transferSignedSingle(token_program, source, destination, authority, 1, .{ "vault", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        transferCheckedSignedSingle(token_program, source, mint, destination, authority, 1, 6, .{ "vault", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        approveSignedSingle(token_program, source, destination, authority, 1, .{ "approve", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        approveCheckedSignedSingle(token_program, source, mint, destination, authority, 1, 6, .{ "approve_checked", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        revokeSignedSingle(token_program, source, authority, .{ "revoke", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        setAuthoritySignedSingle(
            token_program,
            source,
            authority,
            .AccountOwner,
            destination.key(),
            .{ "set_authority", &bump_seed },
        ),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        freezeAccountSignedSingle(token_program, source, mint, authority, .{ "freeze", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        thawAccountSignedSingle(token_program, source, mint, authority, .{ "thaw", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        mintToSignedSingle(token_program, mint, destination, authority, 1, .{ "mint", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        mintToCheckedSignedSingle(token_program, mint, destination, authority, 1, 6, .{ "mint", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        burnSignedSingle(token_program, source, mint, authority, 1, .{ "burn", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        burnCheckedSignedSingle(token_program, source, mint, authority, 1, 6, .{ "burn", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        closeAccountSignedSingle(token_program, source, destination, authority, .{ "close", &bump_seed }),
    );

    var batch_child_metas: metasArray(instruction.transfer_spec) = undefined;
    var batch_child_data: dataArray(instruction.transfer_spec) = undefined;
    const batch_child = instruction.transfer(
        source.key(),
        destination.key(),
        authority.key(),
        1,
        &batch_child_metas,
        &batch_child_data,
    );
    const batch_entries = [_]BatchEntry{instruction.asBatchEntry(batch_child)};
    var batch_metas: [instruction.transfer_spec.accounts_len]AccountMeta = undefined;
    var batch_data: [1 + 2 + instruction.transfer_spec.data_len]u8 = undefined;
    var batch_accounts: [instruction.transfer_spec.accounts_len + 1]CpiAccountInfo = undefined;

    try std.testing.expectError(
        error.InvalidArgument,
        batchSignedSingle(
            token_program,
            &batch_entries,
            &.{ source, destination, authority },
            batch_accounts[0..],
            batch_metas[0..],
            batch_data[0..],
            .{ "batch", &bump_seed },
        ),
    );
}

test "spl-token cpi: utility wrappers use host fallback" {
    var token_program_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 1,
        ._padding = .{0} ** 4,
        .key = sol.spl_token_program_id,
        .owner = .{0} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var mint_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{41} ** 32,
        .owner = .{42} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var account_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{43} ** 32,
        .owner = .{44} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var rent_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = sol.rent_id,
        .owner = .{45} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var owner_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{46} ** 32,
        .owner = .{47} ** 32,
        .lamports = 0,
        .data_len = 0,
    };

    const token_program = testCpiInfo(&token_program_acc);
    const mint = testCpiInfo(&mint_acc);
    const account = testCpiInfo(&account_acc);
    const rent_sysvar = testCpiInfo(&rent_acc);
    const owner = testCpiInfo(&owner_acc);
    const owner_key: Pubkey = .{48} ** 32;
    var ui_data: [16]u8 = undefined;

    try std.testing.expectError(error.InvalidArgument, initializeMint(token_program, mint, rent_sysvar, 6, owner.key(), null));
    try std.testing.expectError(error.InvalidArgument, initializeAccount(token_program, account, mint, owner, rent_sysvar));
    try std.testing.expectError(error.InvalidArgument, initializeAccount2(token_program, account, mint, rent_sysvar, &owner_key));
    try std.testing.expectError(error.InvalidArgument, initializeMultisig(token_program, account, rent_sysvar, &.{owner}, 1));
    try std.testing.expectError(error.InvalidArgument, getAccountDataSize(token_program, mint));
    try std.testing.expectError(error.InvalidArgument, initializeImmutableOwner(token_program, account));
    try std.testing.expectError(error.InvalidArgument, amountToUiAmount(token_program, mint, 123));
    try std.testing.expectError(error.InvalidArgument, uiAmountToAmount(token_program, mint, "1.23", ui_data[0..]));
    try std.testing.expectError(error.InvalidArgument, uiAmountToAmount(token_program, mint, "way-too-long-ui-amount", ui_data[0..8]));
}

test "spl-token cpi: new signed raw wrappers use host fallback" {
    var token_program_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 1,
        ._padding = .{0} ** 4,
        .key = sol.spl_token_program_id,
        .owner = .{0} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var source_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{9} ** 32,
        .owner = .{10} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var mint_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{11} ** 32,
        .owner = .{12} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var destination_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{13} ** 32,
        .owner = .{14} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    var authority_acc: sol.account.Account = .{
        .borrow_state = sol.account.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{15} ** 32,
        .owner = .{16} ** 32,
        .lamports = 0,
        .data_len = 0,
    };

    const token_program = testCpiInfo(&token_program_acc);
    const source = testCpiInfo(&source_acc);
    const mint = testCpiInfo(&mint_acc);
    const destination = testCpiInfo(&destination_acc);
    const authority = testCpiInfo(&authority_acc);
    const seeds = [_]sol.cpi.Seed{ .from("vault"), .from(&[_]u8{254}) };
    const signer = sol.cpi.Signer.from(&seeds);

    try std.testing.expectError(
        error.InvalidArgument,
        mintToCheckedSigned(token_program, mint, destination, authority, 1, 6, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        approveSigned(token_program, source, destination, authority, 1, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        approveCheckedSigned(token_program, source, mint, destination, authority, 1, 6, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        revokeSigned(token_program, source, authority, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        setAuthoritySigned(token_program, source, authority, .CloseAccount, null, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        freezeAccountSigned(token_program, source, mint, authority, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        thawAccountSigned(token_program, source, mint, authority, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        burnSigned(token_program, source, mint, authority, 1, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        burnCheckedSigned(token_program, source, mint, authority, 1, 6, &.{signer}),
    );

    var batch_child_metas: metasArray(instruction.transfer_checked_spec) = undefined;
    var batch_child_data: dataArray(instruction.transfer_checked_spec) = undefined;
    const batch_child = instruction.transferChecked(
        source.key(),
        mint.key(),
        destination.key(),
        authority.key(),
        1,
        6,
        &batch_child_metas,
        &batch_child_data,
    );
    const batch_entries = [_]BatchEntry{instruction.asBatchEntry(batch_child)};
    var batch_metas: [instruction.transfer_checked_spec.accounts_len]AccountMeta = undefined;
    var batch_data: [1 + 2 + instruction.transfer_checked_spec.data_len]u8 = undefined;
    var batch_accounts: [instruction.transfer_checked_spec.accounts_len + 1]CpiAccountInfo = undefined;

    try std.testing.expectError(
        error.InvalidArgument,
        batch(
            token_program,
            &batch_entries,
            &.{ source, mint, destination, authority },
            batch_accounts[0..],
            batch_metas[0..],
            batch_data[0..],
        ),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        batchSigned(
            token_program,
            &batch_entries,
            &.{ source, mint, destination, authority },
            batch_accounts[0..],
            batch_metas[0..],
            batch_data[0..],
            &.{signer},
        ),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        batchPrepared(
            token_program,
            &batch_entries,
            &.{ source, mint, destination, authority, token_program },
            batch_metas[0..],
            batch_data[0..],
        ),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        batchPreparedSigned(
            token_program,
            &batch_entries,
            &.{ source, mint, destination, authority, token_program },
            batch_metas[0..],
            batch_data[0..],
            &.{signer},
        ),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        batchPreparedSignedSingle(
            token_program,
            &batch_entries,
            &.{ source, mint, destination, authority, token_program },
            batch_metas[0..],
            batch_data[0..],
            .{ "batch", &[_]u8{253} },
        ),
    );
}
