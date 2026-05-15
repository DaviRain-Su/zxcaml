pub const std = @import("std");
pub const pubkey = @import("../pubkey/root.zig");
pub const program_error = @import("../program_error/root.zig");
pub const bpf = @import("../bpf.zig");

pub const Pubkey = pubkey.Pubkey;
pub const ProgramError = program_error.ProgramError;
pub const ProgramResult = program_error.ProgramResult;

/// Maximum number of seeds for PDA derivation.
pub const MAX_SEEDS: usize = 16;

/// Maximum length of a seed for PDA derivation.
pub const MAX_SEED_LEN: usize = 32;

/// PDA computation result.
pub const ProgramDerivedAddress = struct {
    address: Pubkey,
    bump_seed: u8,
};

pub extern fn sol_create_program_address(
    seeds_ptr: [*]const []const u8,
    seeds_len: u64,
    program_id_ptr: *const Pubkey,
    address_ptr: *Pubkey,
) callconv(.c) u64;

pub extern fn sol_try_find_program_address(
    seeds_ptr: [*]const []const u8,
    seeds_len: u64,
    program_id_ptr: *const Pubkey,
    address_ptr: *Pubkey,
    bump_seed_ptr: *u8,
) callconv(.c) u64;
