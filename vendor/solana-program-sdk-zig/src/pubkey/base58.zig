const std = @import("std");
const shared = @import("shared.zig");
const Pubkey = shared.Pubkey;
const PUBKEY_BYTES = shared.PUBKEY_BYTES;
const BASE58_ALPHABET = shared.BASE58_ALPHABET;
const BASE58_DECODE_TABLE = shared.BASE58_DECODE_TABLE;

/// Compile-time Base58 decode
pub fn comptimeFromBase58(comptime encoded: []const u8) Pubkey {
    return comptime blk: {
        var result: Pubkey = .{0} ** PUBKEY_BYTES;
        // Decode base58 to big integer
        var num: u256 = 0;
        for (encoded) |c| {
            const digit = BASE58_DECODE_TABLE[c];
            if (digit == 255) {
                @compileError("Invalid Base58 character: " ++ .{c});
            }
            num = num * 58 + digit;
        }

        // Convert to bytes (big endian)
        var i: usize = PUBKEY_BYTES;
        while (i > 0) : (i -= 1) {
            result[i - 1] = @truncate(num);
            num >>= 8;
        }

        if (num != 0) {
            @compileError("Base58 string too long for Pubkey");
        }

        break :blk result;
    };
}

/// Runtime Base58 encode
pub fn encodeBase58(bytes: *const Pubkey, out: *[44]u8) usize {
    // Count leading zeros
    var leading_zeros: usize = 0;
    while (leading_zeros < PUBKEY_BYTES and bytes[leading_zeros] == 0) : (leading_zeros += 1) {}

    var num: u256 = 0;
    for (bytes) |b| {
        num = (num << 8) | b;
    }

    var i: usize = 0;

    // Output leading '1's for each leading zero byte
    while (i < leading_zeros) : (i += 1) {
        out[i] = '1';
    }

    if (num == 0) {
        return i;
    }

    const start = i;
    while (num > 0) : (i += 1) {
        out[i] = BASE58_ALPHABET[@intCast(num % 58)];
        num /= 58;
    }

    // Reverse the non-leading-zero part
    var j = start;
    var k = i - 1;
    while (j < k) {
        const tmp = out[j];
        out[j] = out[k];
        out[k] = tmp;
        j += 1;
        k -= 1;
    }

    return i;
}
