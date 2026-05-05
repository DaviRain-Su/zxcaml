//! Shared helpers for program-specific runtime entrypoints.

const std = @import("std");
const cpi = @import("../cpi.zig");

const Pubkey = cpi.Pubkey;
const SolAccountInfo = cpi.SolAccountInfo;

pub fn isZeroPubkeyBytes(bytes: []const u8) bool {
    if (bytes.len != 32) return false;
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

pub fn isSystemProgramKey(key: *const Pubkey) bool {
    for (key.*) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

pub fn isTokenProgramKey(key: *const Pubkey) bool {
    return key[0] == 0x06 and key[1] == 0xdd and key[2] == 0xf6 and key[3] == 0xe1 and
        key[4] == 0xd7 and key[5] == 0x65 and key[6] == 0xa1 and key[7] == 0x93 and
        key[8] == 0xd9 and key[9] == 0xcb and key[10] == 0xe1 and key[11] == 0x46 and
        key[12] == 0xce and key[13] == 0xeb and key[14] == 0x79 and key[15] == 0xac and
        key[16] == 0x1c and key[17] == 0xb4 and key[18] == 0x85 and key[19] == 0xed and
        key[20] == 0x5f and key[21] == 0x5b and key[22] == 0x37 and key[23] == 0x91 and
        key[24] == 0x3a and key[25] == 0x8c and key[26] == 0xf5 and key[27] == 0x85 and
        key[28] == 0x7e and key[29] == 0xff and key[30] == 0x00 and key[31] == 0xa9;
}

pub fn writeU64Le(out: []u8, value: u64) void {
    var remaining = value;
    for (out[0..8]) |*byte| {
        byte.* = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
}

pub fn readU64LeSlice(bytes: []const u8) u64 {
    return @as(u64, bytes[0]) |
        (@as(u64, bytes[1]) << 8) |
        (@as(u64, bytes[2]) << 16) |
        (@as(u64, bytes[3]) << 24) |
        (@as(u64, bytes[4]) << 32) |
        (@as(u64, bytes[5]) << 40) |
        (@as(u64, bytes[6]) << 48) |
        (@as(u64, bytes[7]) << 56);
}

pub fn programIdFromInput(input: [*]const u8) *const Pubkey {
    const input_mut: [*]u8 = @constCast(input);
    var cursor: usize = 0;
    const account_count = readU64Raw(input_mut, &cursor);
    var info: SolAccountInfo = undefined;
    for (0..@intCast(account_count)) |_| {
        parseAccountInfoUnchecked(input_mut, &cursor, &info);
    }
    const instruction_data_len = readU64Raw(input_mut, &cursor);
    cursor += @intCast(instruction_data_len);
    return @ptrCast(input_mut + cursor);
}

pub fn writeSystemTransferData(out: []u8, amount: u64) void {
    out[0] = 2;
    out[1] = 0;
    out[2] = 0;
    out[3] = 0;
    out[4] = @intCast(amount & 0xff);
    out[5] = @intCast((amount >> 8) & 0xff);
    out[6] = @intCast((amount >> 16) & 0xff);
    out[7] = @intCast((amount >> 24) & 0xff);
    out[8] = @intCast((amount >> 32) & 0xff);
    out[9] = @intCast((amount >> 40) & 0xff);
    out[10] = @intCast((amount >> 48) & 0xff);
    out[11] = @intCast((amount >> 56) & 0xff);
}

pub fn pubkeyEq(lhs: *const Pubkey, rhs: *const Pubkey) bool {
    return std.mem.eql(u8, lhs[0..], rhs[0..]);
}

pub inline fn readU64Raw(input: [*]const u8, cursor: *usize) u64 {
    const start = cursor.*;
    cursor.* += 8;
    return @as(u64, input[start]) |
        (@as(u64, input[start + 1]) << 8) |
        (@as(u64, input[start + 2]) << 16) |
        (@as(u64, input[start + 3]) << 24) |
        (@as(u64, input[start + 4]) << 32) |
        (@as(u64, input[start + 5]) << 40) |
        (@as(u64, input[start + 6]) << 48) |
        (@as(u64, input[start + 7]) << 56);
}

pub inline fn parseAccountInfoUnchecked(input: [*]u8, cursor: *usize, out: *SolAccountInfo) void {
    _ = input[cursor.*];
    cursor.* += 1;
    const is_signer = input[cursor.*];
    cursor.* += 1;
    const is_writable = input[cursor.*];
    cursor.* += 1;
    const executable = input[cursor.*];
    cursor.* += 1;
    cursor.* += 4;
    const key: *const Pubkey = @ptrCast(input + cursor.*);
    cursor.* += 32;
    const owner: *const Pubkey = @ptrCast(input + cursor.*);
    cursor.* += 32;
    const lamports: *align(1) u64 = @ptrCast(input + cursor.*);
    cursor.* += @sizeOf(u64);
    const data_len = readU64Raw(input, cursor);
    const data = (input + cursor.*)[0..@intCast(data_len)];
    cursor.* += @intCast(data_len);
    cursor.* += 10 * 1024;
    cursor.* = std.mem.alignForward(usize, cursor.*, 8);
    const rent_epoch: *align(1) u64 = @ptrCast(input + cursor.*);
    cursor.* += @sizeOf(u64);

    out.* = .{
        .key = key,
        .lamports = lamports,
        .data_len = data.len,
        .data = data.ptr,
        .owner = owner,
        .rent_epoch = rent_epoch.*,
        .is_signer = is_signer,
        .is_writable = is_writable,
        .executable = executable,
    };
}
