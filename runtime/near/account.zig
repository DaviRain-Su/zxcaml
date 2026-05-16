//! Minimal NEAR account shim for the no-storage adapter MVP.
//!
//! RESPONSIBILITIES:
//! - Provide the `AccountView` type required by the shared generated entrypoint ABI.
//! - Keep NEAR builds free from Solana account parsing/runtime helpers.
//! - Remain empty until a later target-specific account model is introduced.

pub const AccountView = struct {};
