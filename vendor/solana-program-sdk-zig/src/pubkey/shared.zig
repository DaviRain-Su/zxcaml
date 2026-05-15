const std = @import("std");
pub const bpf = @import("../bpf.zig");

/// Number of bytes in a pubkey
pub const PUBKEY_BYTES: usize = 32;

/// Public key type — 32 byte array
pub const Pubkey = [PUBKEY_BYTES]u8;

/// Maximum number of seeds for PDA derivation
pub const MAX_SEEDS: usize = 16;

/// Maximum length of a seed for PDA derivation
pub const MAX_SEED_LEN: usize = 32;

/// Base58 alphabet (Bitcoin).
pub const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Base58 decode table: maps ASCII code to value, 255 = invalid.
pub const BASE58_DECODE_TABLE = blk: {
    var table: [256]u8 = undefined;
    @memset(&table, 255);
    for (BASE58_ALPHABET, 0..) |c, i| {
        table[c] = @intCast(i);
    }
    break :blk table;
};
