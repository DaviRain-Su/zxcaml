//! `spl-token` — Zig client for the SPL Token program.
//!
//! This package is organized around the same core idea as
//! `pinocchio-token`: give on-chain programs a compact, explicit,
//! low-overhead way to invoke SPL Token instructions.
//!
//! The Zig version extends that model into a dual-target package:
//!
//! - `cpi` — on-chain CPI wrappers
//! - `instruction` — off-chain / generic instruction builders
//! - `state` — zero-copy account layouts and fast-path field readers
//! - `return_data` — utility-instruction return-data decoders
//! - `ui_amount` — local zero-allocation UI amount helpers
//! - `token_error` — classic custom-error parity helpers
//!
//! Works against both classic SPL Token and Token-2022 — pass the
//! appropriate `token_program` account to the CPI wrappers, or use
//! the `PROGRAM_ID` / `PROGRAM_ID_2022` constants when building
//! transactions off-chain.
//!
//! ## On-chain
//!
//! ```zig
//! const spl_token = @import("spl_token");
//!
//! fn transfer_handler(ctx: *sol.InstructionContext) sol.ProgramResult {
//!     const a = try ctx.parseAccountsWith(.{
//!         .{ "token_program", .{} },
//!         .{ "source",        .{} },
//!         .{ "destination",   .{} },
//!         .{ "authority",     .{ .is_signer = true } },
//!     });
//!     const amount = ctx.readIx(u64, 0);
//!     try spl_token.cpi.transfer(
//!         a.token_program.toCpiInfo(),
//!         a.source.toCpiInfo(),
//!         a.destination.toCpiInfo(),
//!         a.authority.toCpiInfo(),
//!         amount,
//!     );
//! }
//! ```
//!
//! ## Off-chain
//!
//! ```zig
//! var metas: [3]sol.cpi.AccountMeta = undefined;
//! var data: [9]u8 = undefined;
//! const ix = spl_token.instruction.transfer(
//!     &source_pubkey, &dest_pubkey, &authority_pubkey, 100,
//!     &metas, &data,
//! );
//! ```

const sol = @import("solana_program_sdk");

/// Program IDs and mint constants.
pub const id = @import("id.zig");
/// Classic SPL Token custom-error helpers.
pub const token_error = @import("error.zig");
/// Zero-copy account layouts and fast-path field readers.
pub const state = @import("state.zig");
/// Allocation-free instruction builders.
pub const instruction = @import("instruction.zig");
/// Decoders for utility-instruction return data.
pub const return_data = @import("return_data.zig");
/// Local zero-allocation UI-amount formatting/parsing helpers.
pub const ui_amount = @import("ui_amount.zig");
/// On-chain CPI wrappers.
pub const cpi = @import("cpi.zig");

/// Classic SPL Token program ID.
pub const PROGRAM_ID = id.PROGRAM_ID;
/// Token-2022 program ID.
pub const PROGRAM_ID_2022 = id.PROGRAM_ID_2022;
/// Canonical wrapped-SOL / native mint address.
pub const NATIVE_MINT = id.NATIVE_MINT;

pub const TokenError = token_error.TokenError;
pub const TokenErrorSet = token_error.Error;

pub const Mint = state.Mint;
pub const Account = state.Account;
pub const Multisig = state.Multisig;
pub const AccountState = state.AccountState;
pub const MINT_LEN = state.MINT_LEN;
pub const ACCOUNT_LEN = state.ACCOUNT_LEN;
pub const MULTISIG_LEN = state.MULTISIG_LEN;
pub const MULTISIG_SIGNER_MAX = state.MULTISIG_SIGNER_MAX;
pub const ACCOUNT_MINT_OFFSET = state.ACCOUNT_MINT_OFFSET;
pub const ACCOUNT_OWNER_OFFSET = state.ACCOUNT_OWNER_OFFSET;

pub const TokenInstruction = instruction.TokenInstruction;
pub const MIN_SIGNERS = instruction.MIN_SIGNERS;
pub const MAX_SIGNERS = instruction.MAX_SIGNERS;

pub inline fn isNativeMint(mint: *const sol.Pubkey) bool {
    return sol.pubkey.pubkeyEq(mint, &NATIVE_MINT);
}

/// Upstream `spl-token-interface` parity helper: validates the classic SPL
/// Token program ID.
pub inline fn checkProgramAccount(program_id: *const sol.Pubkey) sol.ProgramResult {
    if (!sol.pubkey.pubkeyEqComptime(program_id, PROGRAM_ID)) {
        return error.IncorrectProgramId;
    }
}

/// `true` when `account_data` has the canonical SPL Token account length.
pub inline fn validAccountData(account_data: []const u8) bool {
    return state.validAccountData(account_data);
}

/// Fast-path unpack of a token-account mint pubkey after length validation.
pub inline fn unpackAccountMintUnchecked(account_data: []const u8) *const sol.Pubkey {
    return state.unpackAccountMintUnchecked(account_data);
}

/// Fast-path unpack of a token-account owner pubkey after length validation.
pub inline fn unpackAccountOwnerUnchecked(account_data: []const u8) *const sol.Pubkey {
    return state.unpackAccountOwnerUnchecked(account_data);
}

/// Upstream-style signer-count validator (`1 <= index <= 11`).
pub inline fn isValidSignerIndex(index: usize) bool {
    return instruction.isValidSignerIndex(index);
}

/// Decode a classic SPL Token custom error code into `TokenError`.
pub inline fn parseTokenError(code: u32) sol.ProgramError!TokenError {
    return token_error.tryFrom(code);
}

/// Render a classic SPL Token custom error as the canonical message string.
pub inline fn tokenErrorToStr(err: TokenError) []const u8 {
    return token_error.toStr(err);
}

test "spl-token: interface parity helpers" {
    const std = @import("std");

    try checkProgramAccount(&PROGRAM_ID);
    try std.testing.expectError(error.IncorrectProgramId, checkProgramAccount(&PROGRAM_ID_2022));
    try std.testing.expectEqual(@as(usize, 1), MIN_SIGNERS);
    try std.testing.expectEqual(MULTISIG_SIGNER_MAX, MAX_SIGNERS);
    try std.testing.expect(isValidSignerIndex(MIN_SIGNERS));
    try std.testing.expect(isValidSignerIndex(MAX_SIGNERS));
    try std.testing.expect(!isValidSignerIndex(0));
    try std.testing.expect(!isValidSignerIndex(MAX_SIGNERS + 1));
    try std.testing.expectEqual(.AccountFrozen, try parseTokenError(17));
    try std.testing.expectEqualStrings(
        "Error: Account is frozen",
        tokenErrorToStr(.AccountFrozen),
    );

    var account_buf: [ACCOUNT_LEN]u8 = [_]u8{0} ** ACCOUNT_LEN;
    @memset(account_buf[ACCOUNT_MINT_OFFSET .. ACCOUNT_MINT_OFFSET + sol.PUBKEY_BYTES], 0x11);
    @memset(account_buf[ACCOUNT_OWNER_OFFSET .. ACCOUNT_OWNER_OFFSET + sol.PUBKEY_BYTES], 0x22);

    try std.testing.expect(validAccountData(account_buf[0..]));
    try std.testing.expect(!validAccountData(account_buf[0 .. ACCOUNT_LEN - 1]));
    try std.testing.expectEqualSlices(u8, &([_]u8{0x11} ** 32), unpackAccountMintUnchecked(account_buf[0..])[0..]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x22} ** 32), unpackAccountOwnerUnchecked(account_buf[0..])[0..]);
}

test {
    @import("std").testing.refAllDecls(@This());
}
