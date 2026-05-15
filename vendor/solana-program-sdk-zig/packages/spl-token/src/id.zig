//! SPL Token program ID constants.
//!
//! Two on-chain programs share the same instruction layout for the
//! "classic" fungible operations (Transfer / MintTo / Burn /
//! CloseAccount / TransferChecked / …): the original SPL Token
//! program and Token-2022. Token-2022 layers extensions on top, but
//! every helper in this package targets the shared subset and so
//! works against either program — just pass the correct
//! `token_program` account at the call site.
//!
//! Source: <https://github.com/solana-program/token>

const sol = @import("solana_program_sdk");

const Pubkey = sol.Pubkey;

/// SPL Token program ID (classic v1).
///
/// `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`
pub const PROGRAM_ID: Pubkey = sol.pubkey.comptimeFromBase58(
    "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
);

/// SPL Token-2022 program ID. Backwards-compatible with the classic
/// instruction layout for the fungible-token subset this package
/// exposes — Token-2022's additions are extension-only.
///
/// `TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb`
pub const PROGRAM_ID_2022: Pubkey = sol.pubkey.comptimeFromBase58(
    "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
);

/// Canonical wrapped-SOL / native mint address.
///
/// `So11111111111111111111111111111111111111112`
pub const NATIVE_MINT: Pubkey = sol.pubkey.comptimeFromBase58(
    "So11111111111111111111111111111111111111112",
);
