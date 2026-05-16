//! Canonical grouped imports for the normalized runtime layout.

pub const core = @import("core.zig");
pub const solana = @import("solana.zig");
pub const shims = @import("shims.zig");
pub const sdk = @import("vendored_sdk");
pub const programs = @import("programs/root.zig");
