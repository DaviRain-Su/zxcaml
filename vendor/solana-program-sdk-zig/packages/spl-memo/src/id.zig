//! SPL Memo program ID constants.
//!
//! Two versions of the Memo program exist on mainnet. Both are still
//! supported by wallets and indexers. v2 (the one with the obvious
//! `Memo...` base58 prefix) is the current default and what every new
//! integration should use.
//!
//! Source: <https://github.com/solana-program/memo>

const sol = @import("solana_program_sdk");

const Pubkey = sol.Pubkey;

/// SPL Memo v2 program ID — `MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr`.
///
/// This is the modern memo program. Use it unless you have a specific
/// reason to interact with v1 (which only existed for compatibility
/// with the very first Solana tooling).
pub const PROGRAM_ID: Pubkey = sol.pubkey.comptimeFromBase58(
    "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr",
);

/// SPL Memo v1 (legacy) — `Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo`.
///
/// Kept here only for cases where a program needs to recognise memo
/// log lines emitted before v2 was deployed. New code should not
/// invoke this program.
pub const PROGRAM_ID_V1: Pubkey = sol.pubkey.comptimeFromBase58(
    "Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo",
);
