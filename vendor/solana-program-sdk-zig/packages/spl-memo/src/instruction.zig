//! SPL Memo instruction builder — dual-target.
//!
//! "Builder" means: it produces the raw byte representation of a memo
//! instruction without invoking anything. The result is a
//! `sol.cpi.Instruction` that can be:
//!
//!   - passed to `sol.cpi.invoke(...)` from on-chain code, **or**
//!   - serialised into a transaction by off-chain host code.
//!
//! The SPL Memo program defines a single instruction:
//!
//! ```text
//! instruction data : the UTF-8 memo string, no discriminator, no length prefix
//! accounts         : zero or more signer pubkeys whose signatures
//!                    will be enforced by the program
//! ```
//!
//! The program logs the memo via `sol_log_` and verifies every account
//! it received is a signer.
//!
//! Reference: <https://github.com/solana-program/memo/blob/main/program/src/lib.rs>

const sol = @import("solana_program_sdk");
const id = @import("id.zig");

const Pubkey = sol.Pubkey;
const AccountMeta = sol.cpi.AccountMeta;
const Instruction = sol.cpi.Instruction;

pub const Error = error{
    AccountMetaBufferTooSmall,
};

/// Build a memo instruction.
///
/// `message` is the UTF-8 string to log. The SPL Memo program does not
/// impose a length limit beyond what fits in a transaction, but
/// practical messages are kept short (most explorers truncate display
/// at ~566 bytes — the max that fits in a single tx alongside the
/// system-required overhead).
///
/// `signers` are the pubkeys that must co-sign this instruction. Each
/// will be added as a signer `AccountMeta`. Pass an empty slice for a
/// "pure log" memo with no signer enforcement.
///
/// Both `message` and `signers` are borrowed — the returned
/// `Instruction` references them. They must outlive the use of the
/// instruction (passing to `invoke`, serialising into a tx, etc).
///
/// Use the caller's `account_metas` buffer to hold the materialised
/// `AccountMeta`s; the slice length must equal `signers.len`. This
/// keeps the builder allocation-free in both on-chain and off-chain
/// contexts.
pub fn memo(
    message: []const u8,
    signers: []const *const Pubkey,
    account_metas: []AccountMeta,
) Instruction {
    std.debug.assert(account_metas.len == signers.len);
    for (signers, account_metas) |s, *meta| {
        meta.* = AccountMeta.signer(s);
    }
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = account_metas[0..signers.len],
        .data = message,
    };
}

/// Checked variant of `memo` for callers with dynamically sized signer
/// lists. Returns `AccountMetaBufferTooSmall` instead of relying on a
/// debug-only assertion when the caller-provided scratch is too short.
pub fn memoChecked(
    message: []const u8,
    signers: []const *const Pubkey,
    account_metas: []AccountMeta,
) Error!Instruction {
    if (account_metas.len < signers.len) return error.AccountMetaBufferTooSmall;
    return memo(message, signers, account_metas[0..signers.len]);
}

/// Convenience: no-signer memo. Returns an `Instruction` with an
/// empty accounts slice — the SPL Memo program will simply log the
/// message without enforcing any signatures.
pub fn memoNoSigners(message: []const u8) Instruction {
    return .{
        .program_id = &id.PROGRAM_ID,
        .accounts = &.{},
        .data = message,
    };
}

const std = @import("std");

test "memoNoSigners has empty accounts and correct program id" {
    const ix = memoNoSigners("hello");
    try std.testing.expect(ix.accounts.len == 0);
    try std.testing.expectEqualStrings("hello", ix.data);
    try std.testing.expectEqualSlices(u8, &id.PROGRAM_ID, ix.program_id);
}

test "memo wires signers into AccountMeta.signer entries" {
    const a: Pubkey = .{1} ** 32;
    const b: Pubkey = .{2} ** 32;
    var metas: [2]AccountMeta = undefined;
    const ix = memo("note", &.{ &a, &b }, &metas);
    try std.testing.expectEqual(@as(usize, 2), ix.accounts.len);
    try std.testing.expectEqual(@as(u8, 1), ix.accounts[0].is_signer);
    try std.testing.expectEqual(@as(u8, 0), ix.accounts[0].is_writable);
    try std.testing.expectEqual(@as(u8, 1), ix.accounts[1].is_signer);
    try std.testing.expectEqualSlices(u8, &a, ix.accounts[0].pubkey);
    try std.testing.expectEqualSlices(u8, &b, ix.accounts[1].pubkey);
}

test "memoChecked rejects undersized account meta scratch" {
    const a: Pubkey = .{1} ** 32;
    const b: Pubkey = .{2} ** 32;
    var metas: [1]AccountMeta = undefined;
    try std.testing.expectError(
        error.AccountMetaBufferTooSmall,
        memoChecked("note", &.{ &a, &b }, &metas),
    );
}

test "memoChecked accepts oversized scratch and slices output accounts" {
    const a: Pubkey = .{1} ** 32;
    var metas: [3]AccountMeta = undefined;
    const ix = try memoChecked("note", &.{&a}, &metas);
    try std.testing.expectEqual(@as(usize, 1), ix.accounts.len);
    try std.testing.expectEqual(@intFromPtr(&metas[0]), @intFromPtr(ix.accounts.ptr));
    try std.testing.expectEqualStrings("note", ix.data);
}
