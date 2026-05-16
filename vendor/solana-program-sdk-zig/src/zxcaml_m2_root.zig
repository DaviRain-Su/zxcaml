//! Narrow import root for ZxCaml's M2 syscall/sysvar migration.
//!
//! The upstream package root pulls in broad host-only helper/test surfaces
//! that the current direct `solana-zig` flow does not tolerate. This file
//! keeps the M2 adapter boundary on the small set of vendor modules needed by
//! ZxCaml's syscall/crypto/sysvar migration.

pub const hash = @import("crypto/hash.zig");
pub const secp256k1_recover = @import("crypto/secp256k1_recover.zig");
pub const clock = @import("clock.zig");
pub const rent = @import("rent.zig");
pub const compute_budget = @import("compute_budget.zig");
pub const account = @import("account/root.zig");
pub const cpi = @import("cpi/root.zig");
pub const entrypoint = @import("entrypoint/root.zig");
pub const pda = @import("pda/root.zig");
pub const program_error = @import("program_error/root.zig");
