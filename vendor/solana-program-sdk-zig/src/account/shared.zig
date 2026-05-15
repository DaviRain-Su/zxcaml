const std = @import("std");

pub const pubkey = @import("../pubkey/root.zig");
pub const program_error = @import("../program_error/root.zig");

pub const Pubkey = pubkey.Pubkey;
pub const ProgramError = program_error.ProgramError;

/// Value used to indicate that a serialized account is not a duplicate
pub const NON_DUP_MARKER: u8 = 0xFF;

/// Maximum permitted data increase per instruction
pub const MAX_PERMITTED_DATA_INCREASE: usize = 10 * 1024;

/// Maximum number of accounts that a transaction may process
pub const MAX_TX_ACCOUNTS: usize = 256;

/// BPF alignment for u128
pub const BPF_ALIGN_OF_U128: usize = 8;

/// Not borrowed state (all bits set)
pub const NOT_BORROWED: u8 = 0xFF;

/// Align a serialized runtime pointer to the next 8-byte boundary.
pub inline fn alignPointer(ptr: usize) usize {
    return (ptr + 7) & ~@as(usize, 7);
}

/// Direct mapping of Solana runtime account memory layout.
/// Data follows immediately in memory after this struct.
pub const Account = extern struct {
    borrow_state: u8,
    is_signer: u8,
    is_writable: u8,
    is_executable: u8,
    _padding: [4]u8,
    key: Pubkey,
    owner: Pubkey,
    lamports: u64,
    data_len: u64,
};
