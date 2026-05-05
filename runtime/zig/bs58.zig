//! Base58 runtime helpers for Solana public keys.
//!
//! Uses the Bitcoin/Solana alphabet and has no external dependencies.  General
//! encode/decode allocate their exact-size result; `encodePubkey32` is the
//! fixed-buffer 32-byte pubkey fast path and returns a NUL-padded `[44]u8`.

const std = @import("std");

/// Bitcoin/Solana Base58 alphabet.
pub const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Maximum Base58 length of a 32-byte Solana public key.
pub const pubkey32_encoded_len: usize = 44;

/// Errors returned by Base58 decoding.
pub const Error = error{
    InvalidCharacter,
};

const invalid_digit: u8 = 0xff;

/// Encodes arbitrary bytes into Base58 using `allocator`.
pub fn encode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len == 0) return allocator.alloc(u8, 0);

    var leading_zeroes: usize = 0;
    while (leading_zeroes < bytes.len and bytes[leading_zeroes] == 0) {
        leading_zeroes += 1;
    }

    const scratch_len = ((bytes.len - leading_zeroes) * 138 / 100) + 2;
    var digits = try allocator.alloc(u8, scratch_len);
    defer allocator.free(digits);
    @memset(digits, 0);

    var digit_count: usize = 0;
    for (bytes[leading_zeroes..]) |byte| {
        var carry: u32 = byte;
        var index: usize = 0;
        while (index < digit_count) : (index += 1) {
            carry += @as(u32, digits[index]) << 8;
            digits[index] = @intCast(carry % 58);
            carry /= 58;
        }
        while (carry > 0) {
            digits[digit_count] = @intCast(carry % 58);
            digit_count += 1;
            carry /= 58;
        }
    }

    const out_len = leading_zeroes + digit_count;
    var out = try allocator.alloc(u8, out_len);
    @memset(out[0..leading_zeroes], '1');
    for (0..digit_count) |offset| {
        out[leading_zeroes + offset] = alphabet[digits[digit_count - 1 - offset]];
    }
    return out;
}

/// Decodes Base58 text into bytes using `allocator`.
pub fn decode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return allocator.alloc(u8, 0);

    var leading_ones: usize = 0;
    while (leading_ones < text.len and text[leading_ones] == '1') {
        leading_ones += 1;
    }

    var bytes = try allocator.alloc(u8, text.len);
    defer allocator.free(bytes);
    @memset(bytes, 0);

    var byte_count: usize = 0;
    for (text[leading_ones..]) |char| {
        const digit = decodeDigit(char) orelse return error.InvalidCharacter;
        var carry: u32 = digit;
        var index: usize = 0;
        while (index < byte_count) : (index += 1) {
            carry += @as(u32, bytes[index]) * 58;
            bytes[index] = @intCast(carry & 0xff);
            carry >>= 8;
        }
        while (carry > 0) {
            bytes[byte_count] = @intCast(carry & 0xff);
            byte_count += 1;
            carry >>= 8;
        }
    }

    const out_len = leading_ones + byte_count;
    var out = try allocator.alloc(u8, out_len);
    @memset(out[0..leading_ones], 0);
    for (0..byte_count) |offset| {
        out[leading_ones + offset] = bytes[byte_count - 1 - offset];
    }
    return out;
}

/// Encodes one 32-byte Solana pubkey into a fixed 44-byte, NUL-padded buffer.
pub fn encodePubkey32(bytes: *const [32]u8) [44]u8 {
    var leading_zeroes: usize = 0;
    while (leading_zeroes < bytes.len and bytes[leading_zeroes] == 0) {
        leading_zeroes += 1;
    }

    var digits = [_]u8{0} ** pubkey32_encoded_len;
    var digit_count: usize = 0;
    for (bytes[leading_zeroes..]) |byte| {
        var carry: u32 = byte;
        var index: usize = 0;
        while (index < digit_count) : (index += 1) {
            carry += @as(u32, digits[index]) << 8;
            digits[index] = @intCast(carry % 58);
            carry /= 58;
        }
        while (carry > 0) {
            digits[digit_count] = @intCast(carry % 58);
            digit_count += 1;
            carry /= 58;
        }
    }

    var out = [_]u8{0} ** pubkey32_encoded_len;
    @memset(out[0..leading_zeroes], '1');
    for (0..digit_count) |offset| {
        out[leading_zeroes + offset] = alphabet[digits[digit_count - 1 - offset]];
    }
    return out;
}

fn decodeDigit(char: u8) ?u8 {
    const table = comptime makeDecodeTable();
    const digit = table[char];
    return if (digit == invalid_digit) null else digit;
}

fn makeDecodeTable() [256]u8 {
    var table = [_]u8{invalid_digit} ** 256;
    for (alphabet, 0..) |char, index| {
        table[char] = @intCast(index);
    }
    return table;
}

fn expectPubkey32Fixture(expected_text: []const u8, expected_bytes: *const [32]u8) !void {
    const allocator = std.testing.allocator;

    const decoded = try decode(allocator, expected_text);
    defer allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 32), decoded.len);
    try std.testing.expectEqualSlices(u8, expected_bytes, decoded);

    const encoded = try encode(allocator, expected_bytes);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(expected_text, encoded);

    const fixed = encodePubkey32(expected_bytes);
    try std.testing.expectEqualStrings(expected_text, fixed[0..expected_text.len]);
    for (fixed[expected_text.len..]) |padding| {
        try std.testing.expectEqual(@as(u8, 0), padding);
    }

    const round_trip = try decode(allocator, encoded);
    defer allocator.free(round_trip);
    try std.testing.expectEqualSlices(u8, expected_bytes, round_trip);
}

test "bs58 round-trips canonical Solana pubkey fixtures" {
    const zero_pubkey = [_]u8{0} ** 32;
    const ff_pubkey = [_]u8{0xff} ** 32;
    const token_program = [_]u8{
        0x06, 0xdd, 0xf6, 0xe1, 0xd7, 0x65, 0xa1, 0x93,
        0xd9, 0xcb, 0xe1, 0x46, 0xce, 0xeb, 0x79, 0xac,
        0x1c, 0xb4, 0x85, 0xed, 0x5f, 0x5b, 0x37, 0x91,
        0x3a, 0x8c, 0xf5, 0x85, 0x7e, 0xff, 0x00, 0xa9,
    };
    const associated_token_program = [_]u8{
        0x8c, 0x97, 0x25, 0x8f, 0x4e, 0x24, 0x89, 0xf1,
        0xbb, 0x3d, 0x10, 0x29, 0x14, 0x8e, 0x0d, 0x83,
        0x0b, 0x5a, 0x13, 0x99, 0xda, 0xff, 0x10, 0x84,
        0x04, 0x8e, 0x7b, 0xd8, 0xdb, 0xe9, 0xf8, 0x59,
    };

    try expectPubkey32Fixture("11111111111111111111111111111111", &zero_pubkey);
    try expectPubkey32Fixture("JEKNVnkbo3jma5nREBBJCDoXFVeKkD56V3xKrvRmWxFG", &ff_pubkey);
    try expectPubkey32Fixture("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA", &token_program);
    try expectPubkey32Fixture("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL", &associated_token_program);
}

test "bs58 rejects characters outside the Solana alphabet" {
    try std.testing.expectError(error.InvalidCharacter, decode(std.testing.allocator, "0OIl"));
}
