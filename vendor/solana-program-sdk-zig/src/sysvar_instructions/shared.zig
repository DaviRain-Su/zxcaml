const std = @import("std");
pub const pubkey = @import("../pubkey/root.zig");
pub const account_mod = @import("../account/root.zig");
pub const program_error = @import("../program_error/root.zig");
pub const sysvar = @import("../sysvar/root.zig");

pub const Pubkey = pubkey.Pubkey;
pub const AccountInfo = account_mod.AccountInfo;
pub const ProgramError = program_error.ProgramError;

/// Re-export the sysvar ID for convenience.
pub const ID = sysvar.INSTRUCTIONS_ID;

pub fn readU16LE(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}
