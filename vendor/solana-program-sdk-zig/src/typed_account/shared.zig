pub const std = @import("std");
pub const account_mod = @import("../account/root.zig");
pub const discriminator = @import("../discriminator.zig");
pub const program_error = @import("../program_error/root.zig");

pub const AccountInfo = account_mod.AccountInfo;
pub const ProgramError = program_error.ProgramError;
pub const DISCRIMINATOR_LEN = discriminator.DISCRIMINATOR_LEN;
