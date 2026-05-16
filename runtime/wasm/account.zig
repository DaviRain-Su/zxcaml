//! Minimal generic WASM account shim for import-free pure-logic builds.
//!
//! RESPONSIBILITIES:
//! - Provide the `AccountView` type required by the shared generated entrypoint ABI.
//! - Avoid importing Solana parsing/runtime helpers into the generic WASM target.
//! - Stay intentionally tiny until a later target-specific host adapter exists.

pub const AccountView = struct {};
