const builtin = @import("builtin");
pub const std = @import("std");
pub const pubkey = @import("../pubkey/root.zig");
pub const cpi = @import("../cpi/root.zig");

pub const Pubkey = pubkey.Pubkey;

/// Owned account meta, identical layout to `cpi.AccountMeta` so the
/// runtime can write directly into a `[]AccountMeta` array.
pub const AccountMeta = cpi.AccountMeta;

pub const is_solana = builtin.os.tag == .freestanding and builtin.cpu.arch == .bpfel;
