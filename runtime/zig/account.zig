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
    InvalidDuplicateAccount,
    AccountCountOverflow,
    OutOfMemory,
};

const pre_original_data_len_padding = 4;
const account_alignment = 8;
const max_permitted_data_increase = 10 * 1024;
const pubkey_len = 32;
const not_duplicate_account: u8 = 0xff;
const RawAccount = extern struct {
    borrow_state: u8,
    is_signer: u8,
    is_writable: u8,
    is_executable: u8,
    padding: [4]u8,
    key: [pubkey_len]u8,
    owner: [pubkey_len]u8,
    lamports: u64,
    data_len: u64,
};

/// Parses serialized accounts from a bounded, mutable Solana input buffer.
pub fn parseAccounts(arena: *Arena, input: []u8) ParseError![]AccountView {
    var cursor: usize = 0;
    const account_count_u64 = try readU64(input, &cursor);
    if (account_count_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;

    const accounts = arena.alloc(AccountView, @intCast(account_count_u64)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.AccountCountOverflow,
    };
    for (accounts, 0..) |*account, index| {
        account.* = try parseOneBounded(accounts[0..index], input, &cursor);
    }

    return accounts;
}

/// Parses serialized accounts from Solana's raw entrypoint pointer.
pub fn parseAccountsFromPtr(arena: *Arena, input: [*]const u8) ParseError![]AccountView {
    var accounts: []AccountView = undefined;
    try parseAccountsFromPtrInto(arena, input, &accounts);
    return accounts;
}

/// Reads the serialized account count from Solana's raw entrypoint pointer.
pub fn accountCountFromPtr(input: [*]const u8) ParseError!usize {
    var cursor: usize = 0;
    const account_count_u64 = readU64Unchecked(input, &cursor);
    if (account_count_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    return @intCast(account_count_u64);
}

/// Parses accounts from an entrypoint pointer into `out`, avoiding large BPF returns.
pub fn parseAccountsFromPtrInto(arena: *Arena, input: [*]const u8, out: *[]AccountView) ParseError!void {
    const input_mut: [*]u8 = @constCast(input);
    var cursor: usize = 0;
    const account_count_u64 = readU64Unchecked(input_mut, &cursor);
    if (account_count_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    const account_count: usize = @intCast(account_count_u64);

    const accounts = try allocAccountViews(arena, account_count);
    for (accounts, 0..) |*account, index| {
        parseOneUncheckedInto(accounts[0..index], input_mut, &cursor, account) catch |err| return err;
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
    for (accounts, 0..) |*account, index| {
        parseOneUncheckedInto(accounts[0..index], input_mut, &cursor, account) catch |err| return err;
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

fn parseOneBounded(resolved: []const AccountView, input: []u8, cursor: *usize) ParseError!AccountView {
    if (input.len -| cursor.* < 1) return error.TruncatedInput;
    const dup_info = input[cursor.*];
    cursor.* += 1;
    if (dup_info != not_duplicate_account) {
        if (dup_info >= resolved.len) return error.InvalidDuplicateAccount;
        try consumeZeroPadding(input, cursor, 7);
        return resolved[dup_info];
    }

    if (input.len -| cursor.* < 3) return error.TruncatedInput;
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

fn parseOneUncheckedInto(resolved: []const AccountView, input: [*]u8, cursor: *usize, out: *AccountView) ParseError!void {
    const account_ptr: *RawAccount = @ptrCast(@alignCast(input + cursor.*));
    if (account_ptr.borrow_state != not_duplicate_account) {
        if (account_ptr.borrow_state >= resolved.len) return error.InvalidDuplicateAccount;
        cursor.* += @sizeOf(u64);
        out.* = resolved[account_ptr.borrow_state];
        return;
    }

    const data_len_u64 = account_ptr.data_len;
    if (data_len_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    const data_len: usize = @intCast(data_len_u64);

    out.is_signer = account_ptr.is_signer != 0;
    out.is_writable = account_ptr.is_writable != 0;
    out.executable = account_ptr.is_executable != 0;
    out.key = &account_ptr.key;
    out.owner = &account_ptr.owner;
    out.lamports = @ptrCast(&account_ptr.lamports);
    out.data = (@as([*]u8, @ptrCast(account_ptr)) + @sizeOf(RawAccount))[0..data_len];

    cursor.* += @sizeOf(RawAccount) + data_len;
    cursor.* += max_permitted_data_increase;
    cursor.* = std.mem.alignForward(usize, cursor.*, account_alignment);
    out.rent_epoch = @ptrCast(@alignCast(input + cursor.*));
    cursor.* += @sizeOf(u64);
}

fn skipOneBounded(input: []const u8, cursor: *usize) ParseError!void {
    if (input.len -| cursor.* < 1) return error.TruncatedInput;
    const dup_info = input[cursor.*];
    cursor.* += 1;
    if (dup_info != not_duplicate_account) {
        try consumeZeroPadding(input, cursor, 7);
        return;
    }

    try skipBytes(input, cursor, 3); // signer/writable/executable flags.
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
    const account_ptr: *const RawAccount = @ptrCast(@alignCast(input + cursor.*));
    if (account_ptr.borrow_state != not_duplicate_account) {
        cursor.* += @sizeOf(u64);
        return;
    }

    cursor.* += @sizeOf(RawAccount);
    const data_len_u64 = account_ptr.data_len;
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

fn writeDuplicateAccount(buf: []u8, cursor: *usize, dup_index: u8) void {
    buf[cursor.*] = dup_index;
    cursor.* += 1;
    writeZeroes(buf, cursor, 7);
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

test "account parser preserves duplicate marker aliasing for bounded and raw entrypoint inputs" {
    var input = [_]u8{0} ** 24_000;
    var cursor: usize = 0;
    writeU64(&input, &cursor, 3);

    input[cursor] = not_duplicate_account;
    input[cursor + 1] = 1;
    input[cursor + 2] = 1;
    input[cursor + 3] = 0;
    cursor += 4;
    writeZeroes(&input, &cursor, pre_original_data_len_padding);
    writePubkey(&input, &cursor, 0x44);
    writePubkey(&input, &cursor, 0x88);
    writeU64(&input, &cursor, 41);
    writeU64(&input, &cursor, 4);
    input[cursor] = 1;
    input[cursor + 1] = 2;
    input[cursor + 2] = 3;
    input[cursor + 3] = 4;
    cursor += 4;
    writeZeroes(&input, &cursor, max_permitted_data_increase);
    const first_aligned = std.mem.alignForward(usize, cursor, account_alignment);
    writeZeroes(&input, &cursor, first_aligned - cursor);
    writeU64(&input, &cursor, 777);

    writeDuplicateAccount(&input, &cursor, 0);

    input[cursor] = not_duplicate_account;
    input[cursor + 1] = 0;
    input[cursor + 2] = 0;
    input[cursor + 3] = 1;
    cursor += 4;
    writeZeroes(&input, &cursor, pre_original_data_len_padding);
    writePubkey(&input, &cursor, 0x11);
    writePubkey(&input, &cursor, 0x22);
    writeU64(&input, &cursor, 99);
    writeU64(&input, &cursor, 0);
    writeZeroes(&input, &cursor, max_permitted_data_increase);
    const third_aligned = std.mem.alignForward(usize, cursor, account_alignment);
    writeZeroes(&input, &cursor, third_aligned - cursor);
    writeU64(&input, &cursor, 888);

    writeU64(&input, &cursor, 3);
    input[cursor] = 0xaa;
    input[cursor + 1] = 0xbb;
    input[cursor + 2] = 0xcc;
    cursor += 3;
    writePubkey(&input, &cursor, 0x55);

    var arena_buf: [768]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&arena_buf);
    const accounts = try parseAccounts(&arena, input[0..cursor]);
    try std.testing.expectEqual(@as(usize, 3), accounts.len);
    try std.testing.expectEqual(@intFromPtr(accounts[0].lamports), @intFromPtr(accounts[1].lamports));
    try std.testing.expectEqual(@intFromPtr(accounts[0].data.ptr), @intFromPtr(accounts[1].data.ptr));
    try std.testing.expectEqual(@intFromPtr(accounts[0].owner), @intFromPtr(accounts[1].owner));
    try std.testing.expectEqual(@intFromPtr(accounts[0].rent_epoch), @intFromPtr(accounts[1].rent_epoch));
    accounts[0].lamports.* = 52;
    accounts[0].data[1] = 9;
    try std.testing.expectEqual(@as(u64, 52), accounts[1].lamportsValue());
    try std.testing.expectEqual(@as(u8, 9), accounts[1].data[1]);
    try std.testing.expectEqual(@as(u64, 777), accounts[1].rentEpochValue());
    try std.testing.expectEqual(@as(u64, 99), accounts[2].lamportsValue());

    arena.reset();
    var raw_accounts: []AccountView = undefined;
    try parseAccountsFromPtrInto(&arena, @ptrCast(&input), &raw_accounts);
    try std.testing.expectEqual(@as(usize, 3), raw_accounts.len);
    try std.testing.expectEqual(@intFromPtr(raw_accounts[0].lamports), @intFromPtr(raw_accounts[1].lamports));
    try std.testing.expectEqual(@intFromPtr(raw_accounts[0].data.ptr), @intFromPtr(raw_accounts[1].data.ptr));
    raw_accounts[0].lamports.* = 61;
    raw_accounts[0].data[0] = 7;
    try std.testing.expectEqual(@as(u64, 61), raw_accounts[1].lamportsValue());
    try std.testing.expectEqual(@as(u8, 7), raw_accounts[1].data[0]);
}

test "instruction data parser skips duplicate account markers safely" {
    var input = [_]u8{0} ** 24_000;
    var cursor: usize = 0;
    writeU64(&input, &cursor, 2);

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

    writeDuplicateAccount(&input, &cursor, 0);

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
    try std.testing.expectEqualSlices(u8, instruction_data, try parseInstructionDataFromPtr(@ptrCast(&input)));
}

test "entrypoint account parser rejects malformed duplicate markers and oversized fixed storage explicitly" {
    var malformed = [_]u8{0} ** 64;
    var malformed_cursor: usize = 0;
    writeU64(&malformed, &malformed_cursor, 1);
    writeDuplicateAccount(&malformed, &malformed_cursor, 0);

    var arena_buf: [256]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&arena_buf);
    try std.testing.expectError(error.InvalidDuplicateAccount, parseAccounts(&arena, malformed[0..malformed_cursor]));
    arena.reset();
    var ptr_accounts: []AccountView = undefined;
    try std.testing.expectError(
        error.InvalidDuplicateAccount,
        parseAccountsFromPtrInto(&arena, @ptrCast(malformed[0..malformed_cursor].ptr), &ptr_accounts),
    );

    var many = [_]u8{0} ** 220_000;
    var many_cursor: usize = 0;
    writeU64(&many, &many_cursor, 17);
    for (0..17) |index| {
        many[many_cursor] = not_duplicate_account;
        many[many_cursor + 1] = @intFromBool(index == 0);
        many[many_cursor + 2] = 1;
        many[many_cursor + 3] = 0;
        many_cursor += 4;
        writeZeroes(&many, &many_cursor, pre_original_data_len_padding);
        writePubkey(&many, &many_cursor, @intCast(0x20 + index));
        writePubkey(&many, &many_cursor, @intCast(0x80 + index));
        writeU64(&many, &many_cursor, @intCast(index));
        writeU64(&many, &many_cursor, 0);
        writeZeroes(&many, &many_cursor, max_permitted_data_increase);
        const slot_aligned = std.mem.alignForward(usize, many_cursor, account_alignment);
        writeZeroes(&many, &many_cursor, slot_aligned - many_cursor);
        writeU64(&many, &many_cursor, @intCast(100 + index));
    }
    writeU64(&many, &many_cursor, 0);
    writePubkey(&many, &many_cursor, 0x01);

    var storage: [16]AccountView = undefined;
    try std.testing.expectError(
        error.AccountCountOverflow,
        parseAccountsFromPtrIntoStorage(@ptrCast(&many), storage[0..], &ptr_accounts),
    );
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
