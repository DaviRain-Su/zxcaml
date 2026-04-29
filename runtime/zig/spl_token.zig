//! SPL Token runtime helpers for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Encode SPL Token Transfer instruction data without heap allocation.
//! - Parse canonical SPL Token account state into zero-copy pubkey views.
//! - Provide the canonical SPL Token program id and Transfer account metas.

const std = @import("std");
const Arena = @import("arena.zig").Arena;
const cpi = @import("cpi.zig");

/// 32-byte Solana public key.
pub const Pubkey = cpi.Pubkey;

/// Length of a Solana public key in bytes.
pub const pubkey_len: usize = 32;
/// SPL Token Transfer instruction discriminator.
pub const transfer_discriminator: u8 = 3;
/// SPL Token Transfer instruction data length: one u8 discriminator plus u64 amount.
pub const transfer_instruction_data_len: usize = 9;
/// Canonical packed SPL Token account length.
pub const token_account_len: usize = 165;
const max_cpi_account_infos: usize = 4;
const pre_original_data_len_padding: usize = 4;
const max_permitted_data_increase: usize = 10 * 1024;
const account_alignment: usize = 8;

/// Canonical SPL Token program id as base58 for diagnostics and tests.
pub const program_id_base58 = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";

/// Canonical SPL Token program id bytes for `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`.
pub const program_id: Pubkey = .{
    0x06, 0xdd, 0xf6, 0xe1, 0xd7, 0x65, 0xa1, 0x93,
    0xd9, 0xcb, 0xe1, 0x46, 0xce, 0xeb, 0x79, 0xac,
    0x1c, 0xb4, 0x85, 0xed, 0x5f, 0x5b, 0x37, 0x91,
    0x3a, 0x8c, 0xf5, 0x85, 0x7e, 0xff, 0x00, 0xa9,
};

/// Errors returned by SPL Token runtime helpers.
pub const Error = error{
    OutputTooShort,
    TruncatedInput,
    InvalidOptionTag,
};

/// Zero-copy view over the canonical SPL Token account state.
pub const TokenAccountView = struct {
    mint: *const Pubkey,
    owner: *const Pubkey,
    amount: u64,
    delegate: ?*const Pubkey,
    state: u8,
    is_native: ?u64,
    delegated_amount: u64,
    close_authority: ?*const Pubkey,
};

/// Writes the canonical SPL Token program id into a caller-owned stack or arena buffer.
pub inline fn writeProgramId(out: *Pubkey) void {
    out.* = .{
        0x06, 0xdd, 0xf6, 0xe1, 0xd7, 0x65, 0xa1, 0x93,
        0xd9, 0xcb, 0xe1, 0x46, 0xce, 0xeb, 0x79, 0xac,
        0x1c, 0xb4, 0x85, 0xed, 0x5f, 0x5b, 0x37, 0x91,
        0x3a, 0x8c, 0xf5, 0x85, 0x7e, 0xff, 0x00, 0xa9,
    };
}

/// Writes an SPL Token program id from either raw bytes or the canonical base58 text.
pub fn writeProgramIdFromBytes(out: *Pubkey, bytes: []const u8) bool {
    if (bytes.len == pubkey_len) {
        @memcpy(out[0..], bytes[0..pubkey_len]);
        return true;
    }
    if (bytes.len == program_id_base58.len) {
        writeProgramId(out);
        return true;
    }
    return false;
}

/// Encodes SPL Token Transfer instruction data into a fixed-size array.
pub fn encodeTransfer(amount: u64) [transfer_instruction_data_len]u8 {
    var out: [transfer_instruction_data_len]u8 = undefined;
    _ = encodeTransferInto(out[0..], amount) catch unreachable;
    return out;
}

/// Encodes SPL Token Transfer instruction data into `out` and returns the written prefix.
pub fn encodeTransferInto(out: []u8, amount: u64) Error![]const u8 {
    if (out.len < transfer_instruction_data_len) return error.OutputTooShort;
    out[0] = transfer_discriminator;
    writeU64Le(out[1..transfer_instruction_data_len], amount);
    return out[0..transfer_instruction_data_len];
}

/// Builds account metas for Transfer: source writable, destination writable, authority signer.
pub fn transferAccountMetas(source: *const Pubkey, destination: *const Pubkey, authority: *const Pubkey) [3]cpi.SolAccountMeta {
    return .{
        .{ .pubkey = source, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = destination, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = authority, .is_writable = 0, .is_signer = 1 },
    };
}

/// Parses the first three input accounts and invokes SPL Token Transfer for one token.
pub inline fn zxcaml_transfer_one(arena: *Arena, input: [*]const u8) u64 {
    _ = arena;
    const input_mut: [*]u8 = @constCast(input);
    var cursor: usize = 0;
    const account_count = readU64Raw(input_mut, &cursor);
    if (account_count < 3) return 1;

    var infos: [max_cpi_account_infos]cpi.SolAccountInfo = undefined;
    const info_count: usize = @min(@as(usize, @intCast(account_count)), infos.len);
    for (infos[0..info_count]) |*info| {
        parseAccountInfoNoGrowth(input_mut, &cursor, info);
    }
    var token_program_id: Pubkey = undefined;
    writeProgramId(&token_program_id);
    var source_key = infos[0].key.*;
    var destination_key = infos[1].key.*;
    var authority_key = infos[2].key.*;
    var metas = transferAccountMetas(&source_key, &destination_key, &authority_key);
    var data = encodeTransfer(1);
    const instruction = cpi.SolInstruction.fromSlices(&token_program_id, metas[0..], data[0..]);
    var empty_seed_groups: [1]cpi.SolSignerSeedsC = undefined;
    return cpi.sol_invoke_signed_c(&instruction, infos[0..info_count], empty_seed_groups[0..0]);
}

/// Parses canonical packed SPL Token account data.
pub fn parseTokenAccount(data: []const u8) Error!TokenAccountView {
    if (data.len < token_account_len) return error.TruncatedInput;
    var cursor: usize = 0;

    const mint = try readPubkeyPtr(data, &cursor);
    const owner = try readPubkeyPtr(data, &cursor);
    const amount = try readU64(data, &cursor);
    const delegate = try readPubkeyOption(data, &cursor);
    const state = data[cursor];
    cursor += 1;
    const is_native = try readU64Option(data, &cursor);
    const delegated_amount = try readU64(data, &cursor);
    const close_authority = try readPubkeyOption(data, &cursor);

    return .{
        .mint = mint,
        .owner = owner,
        .amount = amount,
        .delegate = delegate,
        .state = state,
        .is_native = is_native,
        .delegated_amount = delegated_amount,
        .close_authority = close_authority,
    };
}

fn readPubkeyPtr(data: []const u8, cursor: *usize) Error!*const Pubkey {
    if (data.len -| cursor.* < pubkey_len) return error.TruncatedInput;
    const ptr: *const Pubkey = @ptrCast(data.ptr + cursor.*);
    cursor.* += pubkey_len;
    return ptr;
}

inline fn parseAccountInfoNoGrowth(input: [*]u8, cursor: *usize, out: *cpi.SolAccountInfo) void {
    _ = input[cursor.*];
    cursor.* += 1;
    const is_signer = input[cursor.*];
    cursor.* += 1;
    const is_writable = input[cursor.*];
    cursor.* += 1;
    const executable = input[cursor.*];
    cursor.* += 1;
    cursor.* += pre_original_data_len_padding;
    const key: *const Pubkey = @ptrCast(input + cursor.*);
    cursor.* += pubkey_len;
    const owner: *const Pubkey = @ptrCast(input + cursor.*);
    cursor.* += pubkey_len;
    const lamports: *align(1) u64 = @ptrCast(input + cursor.*);
    cursor.* += @sizeOf(u64);
    const data_len = readU64Raw(input, cursor);
    const data = (input + cursor.*)[0..@intCast(data_len)];
    cursor.* += @intCast(data_len);
    cursor.* += max_permitted_data_increase;
    cursor.* = std.mem.alignForward(usize, cursor.*, account_alignment);
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

inline fn readU64Raw(input: [*]const u8, cursor: *usize) u64 {
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

fn readPubkeyOption(data: []const u8, cursor: *usize) Error!?*const Pubkey {
    const tag = try readU32(data, cursor);
    const value = try readPubkeyPtr(data, cursor);
    return switch (tag) {
        0 => null,
        1 => value,
        else => error.InvalidOptionTag,
    };
}

fn readU64Option(data: []const u8, cursor: *usize) Error!?u64 {
    const tag = try readU32(data, cursor);
    const value = try readU64(data, cursor);
    return switch (tag) {
        0 => null,
        1 => value,
        else => error.InvalidOptionTag,
    };
}

fn readU32(data: []const u8, cursor: *usize) Error!u32 {
    if (data.len -| cursor.* < @sizeOf(u32)) return error.TruncatedInput;
    const bytes = data[cursor.*..][0..@sizeOf(u32)];
    cursor.* += @sizeOf(u32);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readU64(data: []const u8, cursor: *usize) Error!u64 {
    if (data.len -| cursor.* < @sizeOf(u64)) return error.TruncatedInput;
    const bytes = data[cursor.*..][0..@sizeOf(u64)];
    cursor.* += @sizeOf(u64);
    return readU64Le(bytes);
}

fn readU64Le(bytes: []const u8) u64 {
    var out: u64 = 0;
    for (bytes[0..@sizeOf(u64)], 0..) |byte, shift_index| {
        out |= @as(u64, byte) << @intCast(shift_index * 8);
    }
    return out;
}

fn writeU64Le(out: []u8, value: u64) void {
    var remaining = value;
    for (out[0..@sizeOf(u64)]) |*byte| {
        byte.* = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
}

fn writeU32Le(out: []u8, value: u32) void {
    var remaining = value;
    for (out[0..@sizeOf(u32)]) |*byte| {
        byte.* = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
}

test "SPL Token program id matches Tokenkeg bytes" {
    try std.testing.expectEqualStrings(program_id_base58, "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
    try std.testing.expectEqual(@as(usize, pubkey_len), program_id.len);
    try std.testing.expectEqual(@as(u8, 0x06), program_id[0]);
    try std.testing.expectEqual(@as(u8, 0xdd), program_id[1]);
    try std.testing.expectEqual(@as(u8, 0xa9), program_id[31]);

    var copied: Pubkey = undefined;
    writeProgramId(&copied);
    try std.testing.expectEqualSlices(u8, &program_id, &copied);

    var from_base58: Pubkey = undefined;
    try std.testing.expect(writeProgramIdFromBytes(&from_base58, program_id_base58));
    try std.testing.expectEqualSlices(u8, &program_id, &from_base58);
    try std.testing.expect(writeProgramIdFromBytes(&from_base58, &program_id));
    try std.testing.expectEqualSlices(u8, &program_id, &from_base58);
    try std.testing.expect(!writeProgramIdFromBytes(&from_base58, "not-token"));
}

test "SPL Token Transfer instruction encoding is discriminator plus u64 little endian" {
    const encoded = encodeTransfer(0x0102_0304_0506_0708);
    try std.testing.expectEqual(@as(usize, 9), encoded.len);
    try std.testing.expectEqualSlices(u8, &.{ 3, 8, 7, 6, 5, 4, 3, 2, 1 }, &encoded);

    var out: [9]u8 = undefined;
    const written = try encodeTransferInto(out[0..], 500);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0xf4, 0x01, 0, 0, 0, 0, 0, 0 }, written);
    try std.testing.expectError(error.OutputTooShort, encodeTransferInto(out[0..8], 1));
}

test "SPL Token Transfer account metas use source destination authority flags" {
    var source: Pubkey = [_]u8{1} ** pubkey_len;
    var destination: Pubkey = [_]u8{2} ** pubkey_len;
    var authority: Pubkey = [_]u8{3} ** pubkey_len;

    const metas = transferAccountMetas(&source, &destination, &authority);
    try std.testing.expectEqual(@as(usize, 3), metas.len);
    try std.testing.expect(metas[0].pubkey == &source);
    try std.testing.expectEqual(@as(u8, 1), metas[0].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[0].is_signer);
    try std.testing.expect(metas[1].pubkey == &destination);
    try std.testing.expectEqual(@as(u8, 1), metas[1].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[1].is_signer);
    try std.testing.expect(metas[2].pubkey == &authority);
    try std.testing.expectEqual(@as(u8, 0), metas[2].is_writable);
    try std.testing.expectEqual(@as(u8, 1), metas[2].is_signer);
}

test "SPL Token account parser extracts mint owner amount and options" {
    var data = [_]u8{0} ** token_account_len;
    var cursor: usize = 0;
    for (data[cursor..][0..pubkey_len], 0..) |*byte, index| byte.* = @intCast(0x10 + index);
    const mint_offset = cursor;
    cursor += pubkey_len;
    for (data[cursor..][0..pubkey_len], 0..) |*byte, index| byte.* = @intCast(0x80 + index);
    const owner_offset = cursor;
    cursor += pubkey_len;
    writeU64Le(data[cursor..][0..@sizeOf(u64)], 123_456);
    cursor += @sizeOf(u64);
    writeU32Le(data[cursor..][0..@sizeOf(u32)], 1);
    cursor += @sizeOf(u32);
    for (data[cursor..][0..pubkey_len]) |*byte| byte.* = 0xaa;
    const delegate_offset = cursor;
    cursor += pubkey_len;
    data[cursor] = 1;
    cursor += 1;
    writeU32Le(data[cursor..][0..@sizeOf(u32)], 1);
    cursor += @sizeOf(u32);
    writeU64Le(data[cursor..][0..@sizeOf(u64)], 2_039_280);
    cursor += @sizeOf(u64);
    writeU64Le(data[cursor..][0..@sizeOf(u64)], 77);
    cursor += @sizeOf(u64);
    writeU32Le(data[cursor..][0..@sizeOf(u32)], 1);
    cursor += @sizeOf(u32);
    for (data[cursor..][0..pubkey_len]) |*byte| byte.* = 0xbb;
    const close_authority_offset = cursor;

    const parsed = try parseTokenAccount(data[0..]);
    try std.testing.expectEqual(@as(usize, mint_offset), @intFromPtr(parsed.mint) - @intFromPtr(&data));
    try std.testing.expectEqual(@as(usize, owner_offset), @intFromPtr(parsed.owner) - @intFromPtr(&data));
    try std.testing.expectEqual(@as(u64, 123_456), parsed.amount);
    try std.testing.expectEqual(@as(u8, 0x10), parsed.mint[0]);
    try std.testing.expectEqual(@as(u8, 0x9f), parsed.owner[31]);
    try std.testing.expect(parsed.delegate != null);
    try std.testing.expectEqual(@as(usize, delegate_offset), @intFromPtr(parsed.delegate.?) - @intFromPtr(&data));
    try std.testing.expectEqual(@as(u8, 1), parsed.state);
    try std.testing.expectEqual(@as(u64, 2_039_280), parsed.is_native.?);
    try std.testing.expectEqual(@as(u64, 77), parsed.delegated_amount);
    try std.testing.expect(parsed.close_authority != null);
    try std.testing.expectEqual(@as(usize, close_authority_offset), @intFromPtr(parsed.close_authority.?) - @intFromPtr(&data));
}

test "SPL Token account parser rejects malformed buffers" {
    var short = [_]u8{0} ** (token_account_len - 1);
    try std.testing.expectError(error.TruncatedInput, parseTokenAccount(short[0..]));

    var invalid_option = [_]u8{0} ** token_account_len;
    const cursor: usize = pubkey_len + pubkey_len + @sizeOf(u64);
    writeU32Le(invalid_option[cursor..][0..@sizeOf(u32)], 2);
    try std.testing.expectError(error.InvalidOptionTag, parseTokenAccount(invalid_option[0..]));
}
