//! Canonical grouped imports for the Solana-facing runtime surface.

pub const account = @import("account.zig");
pub const cpi = @import("cpi.zig");
pub const spl_token = @import("spl_token.zig");
pub const syscalls = @import("syscalls.zig");
pub const sysvar = @import("sysvar.zig");

pub const AccountView = account.AccountView;
pub const Pubkey = cpi.Pubkey;
