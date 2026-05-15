//! `solana_codec` — shared Solana byte-codec primitives.
//!
//! This package keeps the common encodings allocation-free and explicit:
//! shortvec lengths, Borsh primitives/strings/bytes, and bincode-style
//! COption layouts used by SPL account state.

const std = @import("std");
const sol = @import("solana_program_sdk");

pub const Pubkey = sol.Pubkey;
pub const PUBKEY_BYTES = sol.PUBKEY_BYTES;
pub const MAX_SHORTVEC_VALUE: usize = std.math.maxInt(u16);

pub const Error = error{
    BufferTooSmall,
    InputTooShort,
    LengthOverflow,
    NonCanonicalShortVec,
    InvalidCOptionTag,
};

pub const ReadUsize = struct {
    value: usize,
    len: usize,
};

pub const ReadSlice = struct {
    value: []const u8,
    len: usize,
};

pub const COptionPubkey = struct {
    value: ?Pubkey,
    len: usize,
};

pub const COptionU64 = struct {
    value: ?u64,
    len: usize,
};

pub const BincodeOptionU64 = struct {
    value: ?u64,
    len: usize,
};

pub const BincodeOptionI64 = struct {
    value: ?i64,
    len: usize,
};

pub const BincodeOptionPubkey = struct {
    value: ?Pubkey,
    len: usize,
};

pub const BorshOptionU64 = struct {
    value: ?u64,
    len: usize,
};

pub fn ReadInt(comptime T: type) type {
    return struct {
        value: T,
        len: usize,
    };
}

pub fn shortVecLen(value: usize) Error!usize {
    if (value > MAX_SHORTVEC_VALUE) return error.LengthOverflow;

    var n = value;
    var len: usize = 1;
    while (n >= 0x80) : (len += 1) {
        n >>= 7;
    }
    return len;
}

pub fn writeShortVec(value: usize, out: []u8) Error!usize {
    const needed = try shortVecLen(value);
    if (out.len < needed) return error.BufferTooSmall;

    var n = value;
    var pos: usize = 0;
    while (true) {
        var byte: u8 = @intCast(n & 0x7f);
        n >>= 7;
        if (n != 0) byte |= 0x80;
        out[pos] = byte;
        pos += 1;
        if (n == 0) return pos;
    }
}

pub fn readShortVec(input: []const u8) Error!ReadUsize {
    var result: usize = 0;
    var shift: u6 = 0;

    for (input[0..@min(input.len, 3)], 0..) |byte, index| {
        result |= (@as(usize, byte & 0x7f) << shift);
        if ((byte & 0x80) == 0) {
            const len = index + 1;
            if (result > MAX_SHORTVEC_VALUE) return error.LengthOverflow;
            if ((try shortVecLen(result)) != len) return error.NonCanonicalShortVec;
            return .{ .value = result, .len = len };
        }
        shift += 7;
    }

    if (input.len < 3) return error.InputTooShort;
    return error.LengthOverflow;
}

pub fn borshStringLen(value: []const u8) Error!usize {
    return borshBytesLen(value);
}

pub fn writeBorshString(out: []u8, value: []const u8) Error!usize {
    return writeBorshBytes(out, value);
}

pub fn readBorshString(input: []const u8) Error!ReadSlice {
    return readBorshBytes(input);
}

pub fn bincodeStringLen(value: []const u8) Error!usize {
    if (value.len > std.math.maxInt(u64)) return error.LengthOverflow;
    return 8 + value.len;
}

pub fn writeBincodeString(out: []u8, value: []const u8) Error!usize {
    const needed = try bincodeStringLen(value);
    if (out.len < needed) return error.BufferTooSmall;

    std.mem.writeInt(u64, out[0..8], @intCast(value.len), .little);
    @memcpy(out[8..][0..value.len], value);
    return needed;
}

pub fn readBincodeString(input: []const u8) Error!ReadSlice {
    if (input.len < 8) return error.InputTooShort;
    const len = std.mem.readInt(u64, input[0..8], .little);
    if (len > std.math.maxInt(usize)) return error.LengthOverflow;
    const end = 8 + @as(usize, @intCast(len));
    if (input.len < end) return error.InputTooShort;
    return .{ .value = input[8..end], .len = end };
}

pub fn writeBincodeLen(out: []u8, len: usize) Error!usize {
    if (len > std.math.maxInt(u64)) return error.LengthOverflow;
    return writeBincodeU64(out, @intCast(len));
}

pub fn readBincodeLen(input: []const u8) Error!ReadUsize {
    const decoded = try readBincodeU64(input);
    if (decoded.value > std.math.maxInt(usize)) return error.LengthOverflow;
    return .{ .value = @intCast(decoded.value), .len = decoded.len };
}

pub fn writeBincodeU32(out: []u8, value: u32) Error!usize {
    return writeInt(u32, out, value);
}

pub fn readBincodeU32(input: []const u8) Error!ReadInt(u32) {
    return readInt(u32, input);
}

pub fn writeBincodeU64(out: []u8, value: u64) Error!usize {
    return writeInt(u64, out, value);
}

pub fn readBincodeU64(input: []const u8) Error!ReadInt(u64) {
    return readInt(u64, input);
}

pub fn writeBincodeI64(out: []u8, value: i64) Error!usize {
    return writeInt(i64, out, value);
}

pub fn readBincodeI64(input: []const u8) Error!ReadInt(i64) {
    return readInt(i64, input);
}

pub fn writeBincodeOptionU64(out: []u8, value: ?u64) Error!usize {
    if (out.len < 1) return error.BufferTooSmall;
    out[0] = if (value != null) 1 else 0;
    if (value) |n| {
        return 1 + try writeBincodeU64(out[1..], n);
    }
    return 1;
}

pub fn readBincodeOptionU64(input: []const u8) Error!BincodeOptionU64 {
    if (input.len < 1) return error.InputTooShort;
    return switch (input[0]) {
        0 => .{ .value = null, .len = 1 },
        1 => blk: {
            const decoded = try readBincodeU64(input[1..]);
            break :blk .{ .value = decoded.value, .len = 1 + decoded.len };
        },
        else => error.InvalidCOptionTag,
    };
}

pub fn writeBincodeOptionI64(out: []u8, value: ?i64) Error!usize {
    if (out.len < 1) return error.BufferTooSmall;
    out[0] = if (value != null) 1 else 0;
    if (value) |n| {
        return 1 + try writeBincodeI64(out[1..], n);
    }
    return 1;
}

pub fn readBincodeOptionI64(input: []const u8) Error!BincodeOptionI64 {
    if (input.len < 1) return error.InputTooShort;
    return switch (input[0]) {
        0 => .{ .value = null, .len = 1 },
        1 => blk: {
            const decoded = try readBincodeI64(input[1..]);
            break :blk .{ .value = decoded.value, .len = 1 + decoded.len };
        },
        else => error.InvalidCOptionTag,
    };
}

pub fn writeBincodeOptionPubkey(out: []u8, value: ?*const Pubkey) Error!usize {
    if (out.len < 1) return error.BufferTooSmall;
    out[0] = if (value != null) 1 else 0;
    if (value) |pubkey| {
        if (out.len < 1 + PUBKEY_BYTES) return error.BufferTooSmall;
        @memcpy(out[1..][0..PUBKEY_BYTES], pubkey);
        return 1 + PUBKEY_BYTES;
    }
    return 1;
}

pub fn readBincodeOptionPubkey(input: []const u8) Error!BincodeOptionPubkey {
    if (input.len < 1) return error.InputTooShort;
    return switch (input[0]) {
        0 => .{ .value = null, .len = 1 },
        1 => blk: {
            if (input.len < 1 + PUBKEY_BYTES) return error.InputTooShort;
            var pubkey: Pubkey = undefined;
            @memcpy(pubkey[0..], input[1..][0..PUBKEY_BYTES]);
            break :blk .{ .value = pubkey, .len = 1 + PUBKEY_BYTES };
        },
        else => error.InvalidCOptionTag,
    };
}

pub fn writeVarintU64(out: []u8, value: u64) Error!usize {
    var n = value;
    var cursor: usize = 0;
    while (true) {
        if (cursor >= out.len) return error.BufferTooSmall;
        var byte: u8 = @intCast(n & 0x7f);
        n >>= 7;
        if (n != 0) byte |= 0x80;
        out[cursor] = byte;
        cursor += 1;
        if (n == 0) return cursor;
    }
}

pub fn borshBytesLen(value: []const u8) Error!usize {
    if (value.len > std.math.maxInt(u32)) return error.LengthOverflow;
    return 4 + value.len;
}

pub fn writeBorshBytes(out: []u8, value: []const u8) Error!usize {
    const needed = try borshBytesLen(value);
    if (out.len < needed) return error.BufferTooSmall;

    std.mem.writeInt(u32, out[0..4], @intCast(value.len), .little);
    @memcpy(out[4..][0..value.len], value);
    return needed;
}

pub fn readBorshBytes(input: []const u8) Error!ReadSlice {
    if (input.len < 4) return error.InputTooShort;
    const len = std.mem.readInt(u32, input[0..4], .little);
    const end = 4 + @as(usize, len);
    if (input.len < end) return error.InputTooShort;
    return .{ .value = input[4..end], .len = end };
}

pub fn writeBorshBool(out: []u8, value: bool) Error!usize {
    if (out.len < 1) return error.BufferTooSmall;
    out[0] = if (value) 1 else 0;
    return 1;
}

pub fn readBorshBool(input: []const u8) Error!ReadInt(bool) {
    if (input.len < 1) return error.InputTooShort;
    return .{ .value = input[0] != 0, .len = 1 };
}

pub fn writeBorshU8(out: []u8, value: u8) Error!usize {
    if (out.len < 1) return error.BufferTooSmall;
    out[0] = value;
    return 1;
}

pub fn readBorshU8(input: []const u8) Error!ReadInt(u8) {
    if (input.len < 1) return error.InputTooShort;
    return .{ .value = input[0], .len = 1 };
}

pub fn writeBorshU16(out: []u8, value: u16) Error!usize {
    return writeInt(u16, out, value);
}

pub fn readBorshU16(input: []const u8) Error!ReadInt(u16) {
    return readInt(u16, input);
}

pub fn writeBorshU32(out: []u8, value: u32) Error!usize {
    return writeInt(u32, out, value);
}

pub fn readBorshU32(input: []const u8) Error!ReadInt(u32) {
    return readInt(u32, input);
}

pub fn writeBorshU64(out: []u8, value: u64) Error!usize {
    return writeInt(u64, out, value);
}

pub fn readBorshU64(input: []const u8) Error!ReadInt(u64) {
    return readInt(u64, input);
}

pub fn borshOptionU64Len(value: ?u64) usize {
    return if (value == null) 1 else 1 + @sizeOf(u64);
}

pub fn writeBorshOptionU64(out: []u8, value: ?u64) Error!usize {
    const needed = borshOptionU64Len(value);
    if (out.len < needed) return error.BufferTooSmall;

    out[0] = if (value != null) 1 else 0;
    if (value) |n| {
        _ = try writeBorshU64(out[1..], n);
    }
    return needed;
}

pub fn readBorshOptionU64(input: []const u8) Error!BorshOptionU64 {
    if (input.len < 1) return error.InputTooShort;
    return switch (input[0]) {
        0 => .{ .value = null, .len = 1 },
        1 => blk: {
            const decoded = try readBorshU64(input[1..]);
            break :blk .{ .value = decoded.value, .len = 1 + decoded.len };
        },
        else => error.InvalidCOptionTag,
    };
}

pub fn writeCOptionPubkey(out: []u8, value: ?*const Pubkey) Error!usize {
    const payload_len = 4 + PUBKEY_BYTES;
    if (out.len < payload_len) return error.BufferTooSmall;

    if (value) |pubkey| {
        std.mem.writeInt(u32, out[0..4], 1, .little);
        @memcpy(out[4..][0..PUBKEY_BYTES], pubkey);
    } else {
        std.mem.writeInt(u32, out[0..4], 0, .little);
        @memset(out[4..][0..PUBKEY_BYTES], 0);
    }
    return payload_len;
}

pub fn readCOptionPubkey(input: []const u8) Error!COptionPubkey {
    const payload_len = 4 + PUBKEY_BYTES;
    if (input.len < payload_len) return error.InputTooShort;

    const tag = std.mem.readInt(u32, input[0..4], .little);
    return readCOptionPubkeyParts(tag, &input[4..][0..PUBKEY_BYTES].*);
}

pub fn readCOptionPubkeyParts(tag: u32, payload: *const Pubkey) Error!COptionPubkey {
    return switch (tag) {
        0 => .{ .value = null, .len = 4 + PUBKEY_BYTES },
        1 => .{ .value = payload.*, .len = 4 + PUBKEY_BYTES },
        else => error.InvalidCOptionTag,
    };
}

pub fn writeCOptionU64(out: []u8, value: ?u64) Error!usize {
    const payload_len = 4 + @sizeOf(u64);
    if (out.len < payload_len) return error.BufferTooSmall;

    if (value) |n| {
        std.mem.writeInt(u32, out[0..4], 1, .little);
        std.mem.writeInt(u64, out[4..][0..8], n, .little);
    } else {
        std.mem.writeInt(u32, out[0..4], 0, .little);
        @memset(out[4..][0..8], 0);
    }
    return payload_len;
}

pub fn readCOptionU64(input: []const u8) Error!COptionU64 {
    const payload_len = 4 + @sizeOf(u64);
    if (input.len < payload_len) return error.InputTooShort;

    const tag = std.mem.readInt(u32, input[0..4], .little);
    const payload = std.mem.readInt(u64, input[4..][0..8], .little);
    return readCOptionU64Parts(tag, payload);
}

pub fn readCOptionU64Parts(tag: u32, payload: u64) Error!COptionU64 {
    return switch (tag) {
        0 => .{ .value = null, .len = 4 + @sizeOf(u64) },
        1 => .{ .value = payload, .len = 4 + @sizeOf(u64) },
        else => error.InvalidCOptionTag,
    };
}

fn writeInt(comptime T: type, out: []u8, value: T) Error!usize {
    if (out.len < @sizeOf(T)) return error.BufferTooSmall;
    std.mem.writeInt(T, out[0..@sizeOf(T)], value, .little);
    return @sizeOf(T);
}

fn readInt(comptime T: type, input: []const u8) Error!ReadInt(T) {
    if (input.len < @sizeOf(T)) return error.InputTooShort;
    return .{
        .value = std.mem.readInt(T, input[0..@sizeOf(T)], .little),
        .len = @sizeOf(T),
    };
}

test "shortvec canonical encodes and decodes Solana compact lengths" {
    var buf: [3]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 1), try writeShortVec(0, &buf));
    try std.testing.expectEqualSlices(u8, &.{0x00}, buf[0..1]);

    try std.testing.expectEqual(@as(usize, 1), try writeShortVec(127, &buf));
    try std.testing.expectEqualSlices(u8, &.{0x7f}, buf[0..1]);

    try std.testing.expectEqual(@as(usize, 2), try writeShortVec(128, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, buf[0..2]);

    try std.testing.expectEqual(@as(usize, 3), try writeShortVec(65535, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0x03 }, buf[0..3]);

    const decoded = try readShortVec(&.{ 0x80, 0x01 });
    try std.testing.expectEqual(@as(usize, 128), decoded.value);
    try std.testing.expectEqual(@as(usize, 2), decoded.len);

    try std.testing.expectError(error.NonCanonicalShortVec, readShortVec(&.{ 0x80, 0x00 }));
    try std.testing.expectError(error.LengthOverflow, writeShortVec(65536, &buf));
}

test "Borsh primitive and byte helpers are little-endian and bounded" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 8), try writeBorshU64(&buf, 0x0102030405060708));
    try std.testing.expectEqualSlices(u8, &.{ 8, 7, 6, 5, 4, 3, 2, 1 }, buf[0..8]);
    const u64_read = try readBorshU64(buf[0..8]);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), u64_read.value);

    try std.testing.expectEqual(@as(usize, 9), borshOptionU64Len(5));
    try std.testing.expectEqual(@as(usize, 9), try writeBorshOptionU64(&buf, 5));
    try std.testing.expectEqualSlices(u8, &.{ 1, 5, 0, 0, 0, 0, 0, 0, 0 }, buf[0..9]);
    const some_u64 = try readBorshOptionU64(buf[0..9]);
    try std.testing.expectEqual(@as(?u64, 5), some_u64.value);
    try std.testing.expectEqual(@as(usize, 9), some_u64.len);

    try std.testing.expectEqual(@as(usize, 1), borshOptionU64Len(null));
    try std.testing.expectEqual(@as(usize, 1), try writeBorshOptionU64(&buf, null));
    const none_u64 = try readBorshOptionU64(buf[0..1]);
    try std.testing.expect(none_u64.value == null);
    try std.testing.expectEqual(@as(usize, 1), none_u64.len);
    try std.testing.expectError(error.InvalidCOptionTag, readBorshOptionU64(&.{2}));

    try std.testing.expectEqual(@as(usize, 1), try writeBorshBool(&buf, true));
    const bool_read = try readBorshBool(buf[0..1]);
    try std.testing.expect(bool_read.value);

    const written = try writeBorshBytes(&buf, "abc");
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 'a', 'b', 'c' }, buf[0..written]);
    const bytes = try readBorshBytes(buf[0..written]);
    try std.testing.expectEqualStrings("abc", bytes.value);
    try std.testing.expectEqual(@as(usize, 7), bytes.len);

    try std.testing.expectError(error.BufferTooSmall, writeBorshString(buf[0..3], "x"));
    try std.testing.expectError(error.InputTooShort, readBorshBytes(&.{ 4, 0, 0, 0, 'x' }));
}

test "bincode string helpers use u64 little-endian length prefix" {
    var buf: [16]u8 = undefined;

    const written = try writeBincodeString(&buf, "seed");
    try std.testing.expectEqual(@as(usize, 12), written);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 0, 0, 0, 0, 0, 0 }, buf[0..8]);
    try std.testing.expectEqualSlices(u8, "seed", buf[8..12]);

    const decoded = try readBincodeString(buf[0..written]);
    try std.testing.expectEqualStrings("seed", decoded.value);
    try std.testing.expectEqual(@as(usize, 12), decoded.len);

    try std.testing.expectError(error.BufferTooSmall, writeBincodeString(buf[0..8], "x"));
    try std.testing.expectError(error.InputTooShort, readBincodeString(buf[0..7]));
    try std.testing.expectError(error.InputTooShort, readBincodeString(&.{ 4, 0, 0, 0, 0, 0, 0, 0, 'x' }));
}

test "bincode primitive option and varint helpers match Solana serde layouts" {
    var buf: [1 + PUBKEY_BYTES]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 8), try writeBincodeLen(&buf, 3));
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 0, 0, 0, 0 }, buf[0..8]);
    const len = try readBincodeLen(buf[0..8]);
    try std.testing.expectEqual(@as(usize, 3), len.value);

    try std.testing.expectEqual(@as(usize, 4), try writeBincodeU32(&buf, 0x01020304));
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, buf[0..4]);
    const u32_read = try readBincodeU32(buf[0..4]);
    try std.testing.expectEqual(@as(u32, 0x01020304), u32_read.value);

    try std.testing.expectEqual(@as(usize, 9), try writeBincodeOptionU64(&buf, 90));
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
    try std.testing.expectEqual(@as(u64, 90), std.mem.readInt(u64, buf[1..9], .little));
    const some_u64 = try readBincodeOptionU64(buf[0..9]);
    try std.testing.expectEqual(@as(?u64, 90), some_u64.value);

    try std.testing.expectEqual(@as(usize, 1), try writeBincodeOptionU64(&buf, null));
    const none_u64 = try readBincodeOptionU64(buf[0..1]);
    try std.testing.expect(none_u64.value == null);

    try std.testing.expectEqual(@as(usize, 9), try writeBincodeOptionI64(&buf, -5));
    const some_i64 = try readBincodeOptionI64(buf[0..9]);
    try std.testing.expectEqual(@as(?i64, -5), some_i64.value);

    const pubkey: Pubkey = .{0x6b} ** PUBKEY_BYTES;
    try std.testing.expectEqual(@as(usize, 33), try writeBincodeOptionPubkey(&buf, &pubkey));
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
    try std.testing.expectEqualSlices(u8, &pubkey, buf[1..33]);
    const some_pubkey = try readBincodeOptionPubkey(buf[0..33]);
    try std.testing.expect(some_pubkey.value != null);
    try std.testing.expectEqualSlices(u8, &pubkey, &some_pubkey.value.?);

    try std.testing.expectEqual(@as(usize, 1), try writeBincodeOptionPubkey(&buf, null));
    const none_pubkey = try readBincodeOptionPubkey(buf[0..1]);
    try std.testing.expect(none_pubkey.value == null);
    try std.testing.expectError(error.InputTooShort, readBincodeOptionPubkey(&.{1}));
    try std.testing.expectError(error.InvalidCOptionTag, readBincodeOptionPubkey(&.{2}));

    try std.testing.expectEqual(@as(usize, 1), try writeVarintU64(&buf, 0));
    try std.testing.expectEqualSlices(u8, &.{0}, buf[0..1]);
    try std.testing.expectEqual(@as(usize, 1), try writeVarintU64(&buf, 127));
    try std.testing.expectEqualSlices(u8, &.{127}, buf[0..1]);
    try std.testing.expectEqual(@as(usize, 2), try writeVarintU64(&buf, 128));
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, buf[0..2]);
}

test "COption Pubkey matches SPL bincode layout" {
    const pubkey: Pubkey = .{0xab} ** PUBKEY_BYTES;
    var buf: [4 + PUBKEY_BYTES]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 36), try writeCOptionPubkey(&buf, &pubkey));
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, buf[0..4]);
    try std.testing.expectEqualSlices(u8, &pubkey, buf[4..]);

    const some = try readCOptionPubkey(&buf);
    try std.testing.expect(some.value != null);
    try std.testing.expectEqualSlices(u8, &pubkey, &some.value.?);
    const some_parts = try readCOptionPubkeyParts(1, &pubkey);
    try std.testing.expectEqualSlices(u8, &pubkey, &some_parts.value.?);

    try std.testing.expectEqual(@as(usize, 36), try writeCOptionPubkey(&buf, null));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, buf[0..4]);
    try std.testing.expectEqualSlices(u8, &(.{0} ** PUBKEY_BYTES), buf[4..]);

    std.mem.writeInt(u32, buf[0..4], 2, .little);
    try std.testing.expectError(error.InvalidCOptionTag, readCOptionPubkey(&buf));
    try std.testing.expectError(error.InvalidCOptionTag, readCOptionPubkeyParts(2, &pubkey));
}

test "COption u64 matches bincode little-endian layout" {
    var buf: [12]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 12), try writeCOptionU64(&buf, 500));
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0xf4, 0x01, 0, 0, 0, 0, 0, 0 }, &buf);

    const some = try readCOptionU64(&buf);
    try std.testing.expectEqual(@as(?u64, 500), some.value);
    const some_parts = try readCOptionU64Parts(1, 500);
    try std.testing.expectEqual(@as(?u64, 500), some_parts.value);

    try std.testing.expectEqual(@as(usize, 12), try writeCOptionU64(&buf, null));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &buf);
    const none = try readCOptionU64(&buf);
    try std.testing.expect(none.value == null);
    try std.testing.expectError(error.InvalidCOptionTag, readCOptionU64Parts(2, 0));
}

test "public surface guards" {
    try std.testing.expectEqual(@as(usize, 32), PUBKEY_BYTES);
    try std.testing.expect(@hasDecl(@This(), "writeShortVec"));
    try std.testing.expect(@hasDecl(@This(), "writeBorshString"));
    try std.testing.expect(@hasDecl(@This(), "writeBorshOptionU64"));
    try std.testing.expect(@hasDecl(@This(), "writeBincodeString"));
    try std.testing.expect(@hasDecl(@This(), "writeBincodeU64"));
    try std.testing.expect(@hasDecl(@This(), "writeBincodeOptionI64"));
    try std.testing.expect(@hasDecl(@This(), "writeBincodeOptionPubkey"));
    try std.testing.expect(@hasDecl(@This(), "writeVarintU64"));
    try std.testing.expect(@hasDecl(@This(), "writeCOptionPubkey"));
    try std.testing.expect(@hasDecl(@This(), "readCOptionPubkeyParts"));
    try std.testing.expect(@hasDecl(@This(), "readCOptionU64Parts"));
}
