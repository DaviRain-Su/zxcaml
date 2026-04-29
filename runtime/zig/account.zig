//! Solana account input-buffer parser for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Decode the BPF loader account serialization into arena-allocated views.
//! - Keep account keys, lamports, data, owners, and rent epochs zero-copy.
//! - Report malformed bounded test inputs with structured parse errors.

const std = @import("std");
const Arena = @import("arena.zig").Arena;
const syscalls = @import("syscalls.zig");

/// A zero-copy view over one serialized Solana account entry.
pub const AccountView = struct {
    is_signer: bool,
    is_writable: bool,
    executable: bool,
    key: *const [32]u8,
    lamports: *align(1) u64,
    data: []u8,
    owner: *const [32]u8,
    rent_epoch: *align(1) const u64,

    /// Reads the current lamports value from the input buffer.
    pub fn lamportsValue(self: AccountView) u64 {
        return self.lamports.*;
    }

    /// Reads the rent epoch value from the input buffer.
    pub fn rentEpochValue(self: AccountView) u64 {
        return self.rent_epoch.*;
    }
};

/// Errors returned while parsing a bounded account input buffer.
pub const ParseError = error{
    TruncatedInput,
    InvalidPadding,
    AccountCountOverflow,
    OutOfMemory,
};

const pre_original_data_len_padding = 4;
const account_alignment = 8;
const max_permitted_data_increase = 10 * 1024;
const pubkey_len = 32;
const not_duplicate_account: u8 = 0xff;

/// Parses serialized accounts from a bounded, mutable Solana input buffer.
pub fn parseAccounts(arena: *Arena, input: []u8) ParseError![]AccountView {
    var cursor: usize = 0;
    const account_count_u64 = try readU64(input, &cursor);
    if (account_count_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;

    const accounts = arena.alloc(AccountView, @intCast(account_count_u64)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.AccountCountOverflow,
    };
    for (accounts) |*account| {
        account.* = try parseOneBounded(input, &cursor);
    }

    return accounts;
}

/// Parses serialized accounts from Solana's raw entrypoint pointer.
pub fn parseAccountsFromPtr(arena: *Arena, input: [*]const u8) ParseError![]AccountView {
    var accounts: []AccountView = undefined;
    try parseAccountsFromPtrInto(arena, input, &accounts);
    return accounts;
}

/// Parses accounts from an entrypoint pointer into `out`, avoiding large BPF returns.
pub fn parseAccountsFromPtrInto(arena: *Arena, input: [*]const u8, out: *[]AccountView) ParseError!void {
    const input_mut: [*]u8 = @constCast(input);
    var cursor: usize = 0;
    const account_count_u64 = readU64Unchecked(input_mut, &cursor);
    if (account_count_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;

    const accounts = try allocAccountViews(arena, @intCast(account_count_u64));
    for (accounts) |*account| {
        parseOneUncheckedInto(input_mut, &cursor, account);
    }

    out.* = accounts;
}

/// Parses accounts from an entrypoint pointer into caller-provided storage.
pub fn parseAccountsFromPtrIntoStorage(input: [*]const u8, storage: []AccountView, out: *[]AccountView) ParseError!void {
    const input_mut: [*]u8 = @constCast(input);
    var cursor: usize = 0;
    const account_count_u64 = readU64Unchecked(input_mut, &cursor);
    if (account_count_u64 > storage.len) return error.AccountCountOverflow;
    const account_count: usize = @intCast(account_count_u64);

    const accounts = storage[0..account_count];
    for (accounts) |*account| {
        parseOneUncheckedInto(input_mut, &cursor, account);
    }

    out.* = accounts;
}

/// Parses instruction data from a bounded Solana input buffer after accounts.
pub fn parseInstructionData(input: []const u8) ParseError![]const u8 {
    var cursor: usize = 0;
    const account_count_u64 = try readU64(input, &cursor);
    if (account_count_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    const account_count: usize = @intCast(account_count_u64);

    for (0..account_count) |_| {
        try skipOneBounded(input, &cursor);
    }

    const data_len_u64 = try readU64(input, &cursor);
    if (data_len_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    const data_len: usize = @intCast(data_len_u64);
    if (data_len > input.len -| cursor) return error.TruncatedInput;
    const data_start = cursor;
    cursor += data_len;

    if (pubkey_len > input.len -| cursor) return error.TruncatedInput;
    return input[data_start..cursor];
}

/// Parses instruction data from Solana's raw entrypoint pointer after accounts.
pub fn parseInstructionDataFromPtr(input: [*]const u8) ParseError![]const u8 {
    var cursor: usize = 0;
    const account_count_u64 = readU64Unchecked(input, &cursor);
    if (account_count_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    const account_count: usize = @intCast(account_count_u64);

    for (0..account_count) |_| {
        try skipOneUnchecked(input, &cursor);
    }

    const data_len_u64 = readU64Unchecked(input, &cursor);
    if (data_len_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    const data_len: usize = @intCast(data_len_u64);
    const data = (input + cursor)[0..data_len];
    cursor += data_len;
    cursor += pubkey_len;
    return data;
}

/// Logs every serialized account key and lamport balance from Solana input.
pub inline fn logAccountsFromPtr(input: [*]const u8) void {
    var scratch: [1024]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&scratch);
    var accounts: []AccountView = undefined;
    parseAccountsFromPtrInto(&arena, input, &accounts) catch {
        return;
    };

    for (accounts) |account| {
        logPubkeyHex(account.key);
        syscalls.sol_log_64_(@bitCast(account.lamportsValue()), 0, 0, 0, 0);
    }
}

inline fn logPubkeyHex(key: *const [pubkey_len]u8) void {
    var key_hex: [pubkey_len * 2]u8 = undefined;
    for (key.*, 0..) |byte, index| {
        key_hex[index * 2] = nibbleToHex(byte >> 4);
        key_hex[index * 2 + 1] = nibbleToHex(byte & 0x0f);
    }
    syscalls.sol_log_(key_hex[0..]);
}

inline fn nibbleToHex(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + (nibble - 10);
}

fn parseOneBounded(input: []u8, cursor: *usize) ParseError!AccountView {
    if (input.len -| cursor.* < 4) return error.TruncatedInput;
    _ = input[cursor.*]; // dup_info: 0xff for a fresh account, otherwise duplicate index.
    cursor.* += 1;
    const is_signer = input[cursor.*] != 0;
    cursor.* += 1;
    const is_writable = input[cursor.*] != 0;
    cursor.* += 1;
    const executable = input[cursor.*] != 0;
    cursor.* += 1;

    try consumeZeroPadding(input, cursor, pre_original_data_len_padding);
    const key = try readPubkeyPtr(input, cursor);
    const owner = try readPubkeyPtr(input, cursor);
    const lamports = try readU64Ptr(input, cursor);
    const data_len_u64 = try readU64(input, cursor);
    if (data_len_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    const data_len: usize = @intCast(data_len_u64);
    if (data_len > input.len -| cursor.*) return error.TruncatedInput;
    const data_start = cursor.*;
    cursor.* += data_len;
    const data = input[data_start..cursor.*];

    if (max_permitted_data_increase > input.len -| cursor.*) return error.TruncatedInput;
    cursor.* += max_permitted_data_increase;
    try consumeAlignmentPadding(input, cursor, account_alignment);

    const rent_epoch = try readConstU64Ptr(input, cursor);

    return .{
        .is_signer = is_signer,
        .is_writable = is_writable,
        .executable = executable,
        .key = key,
        .lamports = lamports,
        .data = data,
        .owner = owner,
        .rent_epoch = rent_epoch,
    };
}

fn parseOneUncheckedInto(input: [*]u8, cursor: *usize, out: *AccountView) void {
    _ = input[cursor.*]; // dup_info: 0xff for a fresh account, otherwise duplicate index.
    cursor.* += 1;
    out.is_signer = input[cursor.*] != 0;
    cursor.* += 1;
    out.is_writable = input[cursor.*] != 0;
    cursor.* += 1;
    out.executable = input[cursor.*] != 0;
    cursor.* += 1;

    cursor.* += pre_original_data_len_padding;
    out.key = @ptrCast(input + cursor.*);
    cursor.* += pubkey_len;
    out.owner = @ptrCast(input + cursor.*);
    cursor.* += pubkey_len;
    out.lamports = @ptrCast(input + cursor.*);
    cursor.* += @sizeOf(u64);
    const data_len = readU64Unchecked(input, cursor);
    out.data = (input + cursor.*)[0..@intCast(data_len)];
    cursor.* += @intCast(data_len);
    cursor.* += max_permitted_data_increase;
    cursor.* = std.mem.alignForward(usize, cursor.*, account_alignment);

    out.rent_epoch = @ptrCast(input + cursor.*);
    cursor.* += @sizeOf(u64);
}

fn skipOneBounded(input: []const u8, cursor: *usize) ParseError!void {
    try skipBytes(input, cursor, 4); // dup_info + signer/writable/executable flags.
    try consumeZeroPadding(input, cursor, pre_original_data_len_padding);
    try skipBytes(input, cursor, pubkey_len);
    try skipBytes(input, cursor, pubkey_len);
    try skipBytes(input, cursor, @sizeOf(u64));

    const data_len_u64 = try readU64(input, cursor);
    if (data_len_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    const data_len: usize = @intCast(data_len_u64);
    try skipBytes(input, cursor, data_len);
    try skipBytes(input, cursor, max_permitted_data_increase);
    try consumeAlignmentPadding(input, cursor, account_alignment);
    try skipBytes(input, cursor, @sizeOf(u64));
}

fn skipOneUnchecked(input: [*]const u8, cursor: *usize) ParseError!void {
    cursor.* += 4 + pre_original_data_len_padding + pubkey_len + pubkey_len + @sizeOf(u64);
    const data_len_u64 = readU64Unchecked(input, cursor);
    if (data_len_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    cursor.* += @intCast(data_len_u64);
    cursor.* += max_permitted_data_increase;
    cursor.* = std.mem.alignForward(usize, cursor.*, account_alignment);
    cursor.* += @sizeOf(u64);
}

inline fn allocAccountViews(arena: *Arena, count: usize) ParseError![]AccountView {
    if (count > arena.buffer.len / @sizeOf(AccountView)) return error.OutOfMemory;

    const byte_count = @sizeOf(AccountView) * count;
    const base = @intFromPtr(arena.buffer.ptr);
    const aligned_addr = std.mem.alignForward(usize, base + arena.offset, @alignOf(AccountView));
    const start = aligned_addr - base;

    if (start > arena.buffer.len or byte_count > arena.buffer.len - start) return error.OutOfMemory;

    arena.offset = start + byte_count;
    const ptr: [*]AccountView = @ptrCast(@alignCast(arena.buffer.ptr + start));
    return ptr[0..count];
}

fn readU64(input: []const u8, cursor: *usize) ParseError!u64 {
    if (input.len -| cursor.* < @sizeOf(u64)) return error.TruncatedInput;
    const value = readU64At(input[cursor.*..][0..@sizeOf(u64)]);
    cursor.* += @sizeOf(u64);
    return value;
}

fn readU64Unchecked(input: [*]const u8, cursor: *usize) u64 {
    const value = readU64At((input + cursor.*)[0..@sizeOf(u64)]);
    cursor.* += @sizeOf(u64);
    return value;
}

fn readU64Ptr(input: []u8, cursor: *usize) ParseError!*align(1) u64 {
    if (input.len -| cursor.* < @sizeOf(u64)) return error.TruncatedInput;
    const ptr: *align(1) u64 = @ptrCast(input.ptr + cursor.*);
    cursor.* += @sizeOf(u64);
    return ptr;
}

fn readConstU64Ptr(input: []u8, cursor: *usize) ParseError!*align(1) const u64 {
    if (input.len -| cursor.* < @sizeOf(u64)) return error.TruncatedInput;
    const ptr: *align(1) const u64 = @ptrCast(input.ptr + cursor.*);
    cursor.* += @sizeOf(u64);
    return ptr;
}

fn readPubkeyPtr(input: []u8, cursor: *usize) ParseError!*const [pubkey_len]u8 {
    if (input.len -| cursor.* < pubkey_len) return error.TruncatedInput;
    const ptr: *const [pubkey_len]u8 = @ptrCast(input.ptr + cursor.*);
    cursor.* += pubkey_len;
    return ptr;
}

fn readU64At(bytes: []const u8) u64 {
    var out: u64 = 0;
    for (bytes[0..@sizeOf(u64)], 0..) |byte, shift_index| {
        out |= @as(u64, byte) << @intCast(shift_index * 8);
    }
    return out;
}

fn consumeZeroPadding(input: []const u8, cursor: *usize, count: usize) ParseError!void {
    if (count > input.len -| cursor.*) return error.TruncatedInput;
    for (input[cursor.*..][0..count]) |byte| {
        if (byte != 0) return error.InvalidPadding;
    }
    cursor.* += count;
}

fn consumeAlignmentPadding(input: []const u8, cursor: *usize, alignment: usize) ParseError!void {
    const aligned = std.mem.alignForward(usize, cursor.*, alignment);
    if (aligned > input.len) return error.TruncatedInput;
    for (input[cursor.*..aligned]) |byte| {
        if (byte != 0) return error.InvalidPadding;
    }
    cursor.* = aligned;
}

fn skipBytes(input: []const u8, cursor: *usize, count: usize) ParseError!void {
    if (count > input.len -| cursor.*) return error.TruncatedInput;
    cursor.* += count;
}

fn writeU64(buf: []u8, cursor: *usize, value: u64) void {
    var remaining = value;
    for (0..@sizeOf(u64)) |i| {
        buf[cursor.* + i] = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
    cursor.* += @sizeOf(u64);
}

fn writeZeroes(buf: []u8, cursor: *usize, count: usize) void {
    for (buf[cursor.*..][0..count]) |*byte| byte.* = 0;
    cursor.* += count;
}

fn writePubkey(buf: []u8, cursor: *usize, start: u8) void {
    for (buf[cursor.*..][0..pubkey_len], 0..) |*byte, i| {
        byte.* = start + @as(u8, @intCast(i));
    }
    cursor.* += pubkey_len;
}

test "golden account parser preserves serialized fields and zero-copy pointers" {
    var input = [_]u8{0} ** 24_000;
    var cursor: usize = 0;
    writeU64(&input, &cursor, 2);

    input[cursor] = not_duplicate_account;
    input[cursor + 1] = 1;
    input[cursor + 2] = 0;
    input[cursor + 3] = 1;
    cursor += 4;
    writeZeroes(&input, &cursor, pre_original_data_len_padding);
    const key0_offset = cursor;
    writePubkey(&input, &cursor, 0x10);
    const owner0_offset = cursor;
    writePubkey(&input, &cursor, 0x80);
    const lamports0_offset = cursor;
    writeU64(&input, &cursor, 500);
    writeU64(&input, &cursor, 3);
    const data0_offset = cursor;
    input[cursor] = 0xaa;
    input[cursor + 1] = 0xbb;
    input[cursor + 2] = 0xcc;
    cursor += 3;
    writeZeroes(&input, &cursor, max_permitted_data_increase);
    const data0_aligned = std.mem.alignForward(usize, cursor, account_alignment);
    writeZeroes(&input, &cursor, data0_aligned - cursor);
    const rent0_offset = cursor;
    writeU64(&input, &cursor, 77);

    input[cursor] = not_duplicate_account;
    input[cursor + 1] = 0;
    input[cursor + 2] = 1;
    input[cursor + 3] = 0;
    cursor += 4;
    writeZeroes(&input, &cursor, pre_original_data_len_padding);
    const key1_offset = cursor;
    writePubkey(&input, &cursor, 0x30);
    const owner1_offset = cursor;
    writePubkey(&input, &cursor, 0xa0);
    const lamports1_offset = cursor;
    writeU64(&input, &cursor, 900);
    writeU64(&input, &cursor, 0);
    const data1_offset = cursor;
    writeZeroes(&input, &cursor, max_permitted_data_increase);
    const data1_aligned = std.mem.alignForward(usize, cursor, account_alignment);
    writeZeroes(&input, &cursor, data1_aligned - cursor);
    writeU64(&input, &cursor, 88);

    var arena_buf: [512]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&arena_buf);
    const accounts = try parseAccounts(&arena, input[0..cursor]);

    try std.testing.expectEqual(@as(usize, 2), accounts.len);

    try std.testing.expect(accounts[0].is_signer);
    try std.testing.expect(!accounts[0].is_writable);
    try std.testing.expect(accounts[0].executable);
    try std.testing.expectEqual(@as(usize, key0_offset), @intFromPtr(accounts[0].key) - @intFromPtr(&input));
    try std.testing.expectEqual(@as(usize, lamports0_offset), @intFromPtr(accounts[0].lamports) - @intFromPtr(&input));
    try std.testing.expectEqual(@as(u64, 500), accounts[0].lamportsValue());
    try std.testing.expectEqual(@as(usize, data0_offset), @intFromPtr(accounts[0].data.ptr) - @intFromPtr(&input));
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc }, accounts[0].data);
    try std.testing.expectEqual(@as(usize, owner0_offset), @intFromPtr(accounts[0].owner) - @intFromPtr(&input));
    try std.testing.expectEqual(@as(usize, rent0_offset), @intFromPtr(accounts[0].rent_epoch) - @intFromPtr(&input));
    try std.testing.expectEqual(@as(u64, 77), accounts[0].rentEpochValue());
    try std.testing.expectEqual(@as(u8, 0x10), accounts[0].key[0]);
    try std.testing.expectEqual(@as(u8, 0x9f), accounts[0].owner[31]);

    try std.testing.expect(!accounts[1].is_signer);
    try std.testing.expect(accounts[1].is_writable);
    try std.testing.expect(!accounts[1].executable);
    try std.testing.expectEqual(@as(usize, key1_offset), @intFromPtr(accounts[1].key) - @intFromPtr(&input));
    try std.testing.expectEqual(@as(usize, lamports1_offset), @intFromPtr(accounts[1].lamports) - @intFromPtr(&input));
    try std.testing.expectEqual(@as(u64, 900), accounts[1].lamportsValue());
    try std.testing.expectEqual(@as(usize, data1_offset), @intFromPtr(accounts[1].data.ptr) - @intFromPtr(&input));
    try std.testing.expectEqual(@as(usize, 0), accounts[1].data.len);
    try std.testing.expectEqual(@as(usize, owner1_offset), @intFromPtr(accounts[1].owner) - @intFromPtr(&input));
    try std.testing.expectEqual(@as(u8, 0x30), accounts[1].key[0]);
    try std.testing.expectEqual(@as(u8, 0xbf), accounts[1].owner[31]);
    try std.testing.expect(arena.offset >= @sizeOf(AccountView) * accounts.len);

    arena.reset();
    var unchecked_accounts: []AccountView = undefined;
    try parseAccountsFromPtrInto(&arena, @ptrCast(&input), &unchecked_accounts);
    try std.testing.expectEqual(@as(usize, 2), unchecked_accounts.len);
    try std.testing.expect(unchecked_accounts[0].is_signer);
    try std.testing.expect(!unchecked_accounts[0].is_writable);
    try std.testing.expect(unchecked_accounts[0].executable);
    try std.testing.expectEqual(@as(u64, 500), unchecked_accounts[0].lamportsValue());
    try std.testing.expectEqual(@as(u8, 0x10), unchecked_accounts[0].key[0]);
    try std.testing.expect(!unchecked_accounts[1].is_signer);
    try std.testing.expect(unchecked_accounts[1].is_writable);
    try std.testing.expect(!unchecked_accounts[1].executable);
    try std.testing.expectEqual(@as(u64, 900), unchecked_accounts[1].lamportsValue());
    try std.testing.expectEqual(@as(u8, 0x30), unchecked_accounts[1].key[0]);
}

test "golden instruction data parser extracts bytes after accounts" {
    var input = [_]u8{0} ** 12_000;
    var cursor: usize = 0;
    writeU64(&input, &cursor, 1);

    input[cursor] = not_duplicate_account;
    input[cursor + 1] = 1;
    input[cursor + 2] = 1;
    input[cursor + 3] = 0;
    cursor += 4;
    writeZeroes(&input, &cursor, pre_original_data_len_padding);
    writePubkey(&input, &cursor, 0x10);
    writePubkey(&input, &cursor, 0x80);
    writeU64(&input, &cursor, 1234);
    writeU64(&input, &cursor, 2);
    input[cursor] = 0xde;
    input[cursor + 1] = 0xad;
    cursor += 2;
    writeZeroes(&input, &cursor, max_permitted_data_increase);
    const aligned = std.mem.alignForward(usize, cursor, account_alignment);
    writeZeroes(&input, &cursor, aligned - cursor);
    writeU64(&input, &cursor, 55);

    writeU64(&input, &cursor, 4);
    const instruction_data_offset = cursor;
    input[cursor] = 0xca;
    input[cursor + 1] = 0xfe;
    input[cursor + 2] = 0xba;
    input[cursor + 3] = 0xbe;
    cursor += 4;
    writePubkey(&input, &cursor, 0x40);

    const instruction_data = try parseInstructionData(input[0..cursor]);
    try std.testing.expectEqual(@as(usize, instruction_data_offset), @intFromPtr(instruction_data.ptr) - @intFromPtr(&input));
    try std.testing.expectEqualSlices(u8, &.{ 0xca, 0xfe, 0xba, 0xbe }, instruction_data);

    const unchecked_instruction_data = try parseInstructionDataFromPtr(@ptrCast(&input));
    try std.testing.expectEqualSlices(u8, instruction_data, unchecked_instruction_data);

    try std.testing.expectError(error.TruncatedInput, parseInstructionData(input[0 .. cursor - pubkey_len]));
}

test "account parser reports structured errors for malformed bounded inputs" {
    var short = [_]u8{0} ** 7;
    var arena_buf: [256]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&arena_buf);
    try std.testing.expectError(error.TruncatedInput, parseAccounts(&arena, short[0..]));

    var invalid_padding = [_]u8{0} ** 128;
    var cursor: usize = 0;
    writeU64(&invalid_padding, &cursor, 1);
    invalid_padding[cursor] = not_duplicate_account;
    invalid_padding[cursor + 1] = 1;
    invalid_padding[cursor + 2] = 1;
    invalid_padding[cursor + 3] = 0;
    cursor += 4;
    invalid_padding[cursor] = 0xff;
    arena.reset();
    try std.testing.expectError(error.InvalidPadding, parseAccounts(&arena, invalid_padding[0..]));
}
