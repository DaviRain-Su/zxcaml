const std = @import("std");
pub const account_mod = @import("../account/root.zig");
pub const program_error = @import("../program_error/root.zig");
pub const sysvar = @import("../sysvar/root.zig");
pub const pubkey = @import("../pubkey/root.zig");
pub const stdlib = std;

pub const AccountInfo = account_mod.AccountInfo;
pub const ProgramError = program_error.ProgramError;
