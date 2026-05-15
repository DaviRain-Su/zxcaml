//! SPL Associated Token Account program ID constant.
//!
//! Source: <https://github.com/solana-program/associated-token-account>

const std = @import("std");
const sol = @import("solana_program_sdk");

const Pubkey = sol.Pubkey;

/// Associated Token Account program ID.
///
/// `ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL`
pub const PROGRAM_ID: Pubkey = sol.spl_associated_token_account_id;

test "PROGRAM_ID matches canonical ATA program id" {
    const canonical = sol.pubkey.comptimeFromBase58(
        "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL",
    );

    try std.testing.expectEqualSlices(u8, &canonical, &PROGRAM_ID);
    try std.testing.expectEqualSlices(u8, &sol.spl_associated_token_account_id, &PROGRAM_ID);
}
