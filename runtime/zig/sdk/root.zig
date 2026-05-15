//! Vendored Solana SDK adapter shell.
//!
//! This root exposes the committed vendored `solana-program-sdk-zig` packages
//! through a single named module so generated/runtime entry shims can validate
//! import resolution without changing existing runtime behavior.

pub const solana_program_sdk = @import("solana_program_sdk");
pub const solana_codec = @import("solana_codec");
pub const spl_token = @import("spl_token");
pub const spl_ata = @import("spl_ata");
pub const solana_system = @import("solana_system");
pub const spl_memo = @import("spl_memo");
