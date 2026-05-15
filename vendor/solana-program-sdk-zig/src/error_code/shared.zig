const std = @import("std");
const program_error = @import("../program_error/root.zig");

pub const ProgramError = program_error.ProgramError;
pub const customError = program_error.customError;
pub const errorToU64 = program_error.errorToU64;
pub const CUSTOM_ZERO = program_error.CUSTOM_ZERO;
pub const INVALID_ARGUMENT = program_error.INVALID_ARGUMENT;
pub const MISSING_REQUIRED_SIGNATURES = program_error.MISSING_REQUIRED_SIGNATURES;
pub const stdlib = std;
