//! SVM sysvar account readers.
//!
//! Layout references (Solana 1.18+ SDK):
//! - `solana-program/src/sysvar/clock.rs` (`Clock`)
//! - `solana-program/src/sysvar/rent.rs` (`Rent`)
//! - `solana-program/src/sysvar/instructions.rs` (`Instructions`)
//! - `solana-program/src/sysvar/stake_history.rs` (`StakeHistory`)
//! - `solana-program/src/epoch_schedule.rs` (`EpochSchedule`)
//!
//! Sysvar account data is serialized field-by-field in little-endian order.
//! These readers do not cast from account bytes, so they are safe for
//! byte-aligned slices and for account data that is not naturally aligned.

const std = @import("std");
const vendored_sdk = @import("vendored_sdk");
const sol = vendored_sdk.solana_program_sdk;
const sdk_clock = sol.clock;
const sdk_rent = sol.rent;

pub const clock_account_data_len: usize = 40;
pub const rent_account_data_len: usize = 17;
pub const stake_history_len_prefix_len: usize = 8;
pub const stake_history_entry_len: usize = 32;
pub const epoch_schedule_account_data_len: usize = 33;
pub const pubkey_len: usize = 32;
pub const instruction_account_meta_len: usize = 1 + pubkey_len;
pub const max_instruction_accounts: usize = 256;

/// Solana Clock sysvar fields in SVM serialized order.
pub const Clock = extern struct {
    slot: u64 = 0,
    epoch_start_timestamp: i64 = 0,
    epoch: u64 = 0,
    leader_schedule_epoch: u64 = 0,
    unix_timestamp: i64 = 0,
};

/// Solana Rent sysvar fields in SVM serialized order.
pub const Rent = struct {
    lamports_per_byte_year: u64 = 0,
    exemption_threshold: f64 = 0,
    burn_percent: u8 = 0,
};

/// Header for the Instructions sysvar account.
///
/// `offsets` is the raw little-endian u16 offset table; use `offsetAt` to
/// decode an individual instruction start offset without assuming alignment.
pub const InstructionsHeader = struct {
    instruction_count: u16 = 0,
    offsets: []const u8 = &.{},

    pub fn offsetAt(self: InstructionsHeader, idx: u16) ?u16 {
        if (idx >= self.instruction_count) return null;
        const offset_index = @as(usize, idx) * @sizeOf(u16);
        if (offset_index + @sizeOf(u16) > self.offsets.len) return null;
        return std.mem.readInt(u16, self.offsets[offset_index..][0..@sizeOf(u16)], .little);
    }
};

/// Account metadata decoded from one serialized Instructions sysvar entry.
pub const AccountMeta = struct {
    pubkey: []const u8 = &.{},
    is_signer: bool = false,
    is_writable: bool = false,
};

/// Instruction view decoded from the Instructions sysvar.
///
/// The all-empty value is the error sentinel for malformed input and
/// out-of-bounds indexes. It lets BPF callers branch on empty `program_id` /
/// `accounts` / `data` instead of trapping.
pub const InstructionInfo = struct {
    program_id: []const u8 = &.{},
    accounts: []const AccountMeta = &.{},
    data: []const u8 = &.{},
};

var instruction_account_meta_buffer: [max_instruction_accounts]AccountMeta = undefined;

/// Stake activation amounts for one epoch in StakeHistory.
pub const StakeHistoryEntry = struct {
    effective: u64 = 0,
    activating: u64 = 0,
    deactivating: u64 = 0,
};

/// StakeHistory row paired with its epoch.
pub const StakeHistoryRecord = struct {
    epoch: u64 = 0,
    entry: StakeHistoryEntry = .{},
};

/// Cursor over the latest StakeHistory rows.
///
/// StakeHistory account entries are serialized oldest-first; Solana callers
/// conventionally ask for newest rows first. `latest` starts at the newest
/// available row and `readStakeHistory` advances backwards.
pub const StakeHistoryCursor = struct {
    next_index: usize = 0,
    remaining: usize = 0,

    pub fn latest(account_data: []const u8, latest_count: usize) StakeHistoryCursor {
        const available_count = stakeHistoryEntryCount(account_data);
        const remaining = @min(available_count, latest_count);
        return .{
            .next_index = available_count,
            .remaining = remaining,
        };
    }

    pub fn hasNext(self: StakeHistoryCursor) bool {
        return self.remaining > 0 and self.next_index > 0;
    }
};

/// Solana EpochSchedule sysvar fields in SVM serialized order.
pub const EpochSchedule = struct {
    slots_per_epoch: u64 = 0,
    leader_schedule_slot_offset: u64 = 0,
    warmup: bool = false,
    first_normal_epoch: u64 = 0,
    first_normal_slot: u64 = 0,
};

/// Reads a Clock sysvar account payload. Short data returns the zero value.
pub fn readClock(account_data: []const u8) Clock {
    if (account_data.len < clock_account_data_len) return .{};
    const raw: *align(1) const sdk_clock.Clock = @ptrCast(account_data.ptr);
    return .{
        .slot = raw.slot,
        .epoch_start_timestamp = raw.epoch_start_timestamp,
        .epoch = raw.epoch,
        .leader_schedule_epoch = raw.leader_schedule_epoch,
        .unix_timestamp = raw.unix_timestamp,
    };
}

/// Reads a Rent sysvar account payload. Short data returns the zero value.
pub fn readRent(account_data: []const u8) Rent {
    if (account_data.len < rent_account_data_len) return .{};
    const raw: *align(1) const sdk_rent.Rent.Data = @ptrCast(account_data.ptr);
    return .{
        .lamports_per_byte_year = raw.lamports_per_byte_year,
        .exemption_threshold = raw.exemption_threshold,
        .burn_percent = raw.burn_percent,
    };
}

/// Reads the Instructions sysvar header and raw per-instruction offset table.
/// Malformed account data returns the zero-value header.
pub fn readInstructionsHeader(account_data: []const u8) InstructionsHeader {
    const instruction_count = readU16Le(account_data, 0) orelse return .{};
    const offsets_len = @as(usize, instruction_count) * @sizeOf(u16);
    if (2 + offsets_len > account_data.len) return .{};
    return .{
        .instruction_count = instruction_count,
        .offsets = account_data[2 .. 2 + offsets_len],
    };
}

/// Reads an instruction by absolute transaction index from Instructions data.
/// Malformed input and out-of-bounds indexes return `InstructionInfo{}`.
pub fn readInstructionAt(account_data: []const u8, idx: usize) InstructionInfo {
    const header = readInstructionsHeader(account_data);
    if (header.instruction_count == 0 or idx >= header.instruction_count) return .{};
    const start = header.offsetAt(@intCast(idx)) orelse return .{};
    const min_instruction_start = 2 + (@as(usize, header.instruction_count) * @sizeOf(u16));
    var current = @as(usize, start);
    if (current < min_instruction_start or current > account_data.len) return .{};

    const account_count = readU16Advance(account_data, &current) orelse return .{};
    if (account_count > max_instruction_accounts) return .{};
    for (0..account_count) |account_index| {
        const flags = readU8Advance(account_data, &current) orelse return .{};
        const pubkey = readSliceAdvance(account_data, &current, pubkey_len) orelse return .{};
        instruction_account_meta_buffer[account_index] = .{
            .pubkey = pubkey,
            .is_signer = (flags & 0b0000_0001) != 0,
            .is_writable = (flags & 0b0000_0010) != 0,
        };
    }

    const program_id = readSliceAdvance(account_data, &current, pubkey_len) orelse return .{};
    const data_len = readU16Advance(account_data, &current) orelse return .{};
    const instruction_data = readSliceAdvance(account_data, &current, data_len) orelse return .{};
    return .{
        .program_id = program_id,
        .accounts = instruction_account_meta_buffer[0..account_count],
        .data = instruction_data,
    };
}

/// Creates a newest-first cursor for up to `latest_count` StakeHistory rows.
pub fn stakeHistoryCursor(account_data: []const u8, latest_count: usize) StakeHistoryCursor {
    return StakeHistoryCursor.latest(account_data, latest_count);
}

/// Reads the next newest StakeHistory row and advances `cursor` backwards.
/// Returns null when the cursor is exhausted or the target row is malformed.
pub fn readStakeHistory(account_data: []const u8, cursor: *StakeHistoryCursor) ?StakeHistoryRecord {
    if (!cursor.hasNext()) return null;
    cursor.next_index -= 1;
    cursor.remaining -= 1;
    return readStakeHistoryAt(account_data, cursor.next_index);
}

/// Reads EpochSchedule's packed 5-field payload.
/// Short data returns the zero value; `warmup` is true only for byte value 1.
pub fn readEpochSchedule(account_data: []const u8) EpochSchedule {
    if (account_data.len < epoch_schedule_account_data_len) return .{};
    return .{
        .slots_per_epoch = readU64Le(account_data, 0).?,
        .leader_schedule_slot_offset = readU64Le(account_data, 8).?,
        .warmup = account_data[16] == 1,
        .first_normal_epoch = readU64Le(account_data, 17).?,
        .first_normal_slot = readU64Le(account_data, 25).?,
    };
}

fn stakeHistoryEntryCount(account_data: []const u8) usize {
    const declared_count = readU64Le(account_data, 0) orelse return 0;
    const payload_len = account_data.len - stake_history_len_prefix_len;
    const available_count = payload_len / stake_history_entry_len;
    return @min(@as(usize, @intCast(declared_count)), available_count);
}

fn readStakeHistoryAt(account_data: []const u8, index: usize) ?StakeHistoryRecord {
    if (index >= stakeHistoryEntryCount(account_data)) return null;
    const offset = stake_history_len_prefix_len + (index * stake_history_entry_len);
    return .{
        .epoch = readU64Le(account_data, offset).?,
        .entry = .{
            .effective = readU64Le(account_data, offset + 8).?,
            .activating = readU64Le(account_data, offset + 16).?,
            .deactivating = readU64Le(account_data, offset + 24).?,
        },
    };
}

fn readU64Le(account_data: []const u8, offset: usize) ?u64 {
    if (offset + @sizeOf(u64) > account_data.len) return null;
    return std.mem.readInt(u64, account_data[offset..][0..@sizeOf(u64)], .little);
}

fn readU16Le(account_data: []const u8, offset: usize) ?u16 {
    if (offset + @sizeOf(u16) > account_data.len) return null;
    return std.mem.readInt(u16, account_data[offset..][0..@sizeOf(u16)], .little);
}

fn readU16Advance(account_data: []const u8, current: *usize) ?u16 {
    const value = readU16Le(account_data, current.*) orelse return null;
    current.* += @sizeOf(u16);
    return value;
}

fn readU8Advance(account_data: []const u8, current: *usize) ?u8 {
    if (current.* >= account_data.len) return null;
    const value = account_data[current.*];
    current.* += 1;
    return value;
}

fn readSliceAdvance(account_data: []const u8, current: *usize, len: usize) ?[]const u8 {
    if (current.* + len > account_data.len) return null;
    const value = account_data[current.* .. current.* + len];
    current.* += len;
    return value;
}

fn writeU64Le(out: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, out[offset..][0..@sizeOf(u64)], value, .little);
}

fn writeU16Le(out: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, out[offset..][0..@sizeOf(u16)], value, .little);
}

test "readClock parses happy path little-endian fields" {
    var data = [_]u8{0} ** clock_account_data_len;
    writeU64Le(&data, 0, 42);
    writeU64Le(&data, 8, @bitCast(@as(i64, -11)));
    writeU64Le(&data, 16, 7);
    writeU64Le(&data, 24, 8);
    writeU64Le(&data, 32, @bitCast(@as(i64, 1_700_000_000)));

    const clock = readClock(&data);
    try std.testing.expectEqual(@as(u64, 42), clock.slot);
    try std.testing.expectEqual(@as(i64, -11), clock.epoch_start_timestamp);
    try std.testing.expectEqual(@as(u64, 7), clock.epoch);
    try std.testing.expectEqual(@as(u64, 8), clock.leader_schedule_epoch);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), clock.unix_timestamp);
}

test "readRent parses happy path little-endian fields" {
    var data = [_]u8{0} ** rent_account_data_len;
    writeU64Le(&data, 0, 3_480);
    writeU64Le(&data, 8, @bitCast(@as(f64, 2.5)));
    data[16] = 50;

    const rent = readRent(&data);
    try std.testing.expectEqual(@as(u64, 3_480), rent.lamports_per_byte_year);
    try std.testing.expectEqual(@as(f64, 2.5), rent.exemption_threshold);
    try std.testing.expectEqual(@as(u8, 50), rent.burn_percent);
}

test "sysvar readers accept byte-aligned misaligned slices" {
    var storage = [_]u8{0xaa} ** (1 + clock_account_data_len + rent_account_data_len);
    const clock_data = storage[1 .. 1 + clock_account_data_len];
    writeU64Le(clock_data, 0, 99);
    writeU64Le(clock_data, 8, @bitCast(@as(i64, -5)));
    writeU64Le(clock_data, 16, 10);
    writeU64Le(clock_data, 24, 11);
    writeU64Le(clock_data, 32, @bitCast(@as(i64, 12)));

    const rent_data = storage[1 + clock_account_data_len ..];
    writeU64Le(rent_data, 0, 1_000);
    writeU64Le(rent_data, 8, @bitCast(@as(f64, 1.25)));
    rent_data[16] = 3;

    const clock = readClock(clock_data);
    const rent = readRent(rent_data);
    try std.testing.expectEqual(@as(u64, 99), clock.slot);
    try std.testing.expectEqual(@as(i64, -5), clock.epoch_start_timestamp);
    try std.testing.expectEqual(@as(u64, 1_000), rent.lamports_per_byte_year);
    try std.testing.expectEqual(@as(f64, 1.25), rent.exemption_threshold);
    try std.testing.expectEqual(@as(u8, 3), rent.burn_percent);
}

test "sysvar readers return zero values for out-of-bounds account data" {
    const short_clock = [_]u8{0x11} ** (clock_account_data_len - 1);
    const short_rent = [_]u8{0x22} ** (rent_account_data_len - 1);

    const clock = readClock(&short_clock);
    const rent = readRent(&short_rent);
    try std.testing.expectEqual(@as(u64, 0), clock.slot);
    try std.testing.expectEqual(@as(i64, 0), clock.unix_timestamp);
    try std.testing.expectEqual(@as(u64, 0), rent.lamports_per_byte_year);
    try std.testing.expectEqual(@as(f64, 0), rent.exemption_threshold);
    try std.testing.expectEqual(@as(u8, 0), rent.burn_percent);
}

test "sysvar readers preserve zero-initialized account data" {
    const clock_data = [_]u8{0} ** clock_account_data_len;
    const rent_data = [_]u8{0} ** rent_account_data_len;

    const clock = readClock(&clock_data);
    const rent = readRent(&rent_data);
    try std.testing.expectEqual(@as(u64, 0), clock.slot);
    try std.testing.expectEqual(@as(i64, 0), clock.epoch_start_timestamp);
    try std.testing.expectEqual(@as(u64, 0), clock.epoch);
    try std.testing.expectEqual(@as(u64, 0), clock.leader_schedule_epoch);
    try std.testing.expectEqual(@as(i64, 0), clock.unix_timestamp);
    try std.testing.expectEqual(@as(u64, 0), rent.lamports_per_byte_year);
    try std.testing.expectEqual(@as(f64, 0), rent.exemption_threshold);
    try std.testing.expectEqual(@as(u8, 0), rent.burn_percent);
}

fn appendU16(out: *std.ArrayList(u8), value: u16) !void {
    var bytes = [_]u8{0} ** @sizeOf(u16);
    writeU16Le(&bytes, 0, value);
    try out.appendSlice(std.testing.allocator, &bytes);
}

fn appendU64(out: *std.ArrayList(u8), value: u64) !void {
    var bytes = [_]u8{0} ** @sizeOf(u64);
    writeU64Le(&bytes, 0, value);
    try out.appendSlice(std.testing.allocator, &bytes);
}

fn appendPubkey(out: *std.ArrayList(u8), seed: u8) !void {
    var pubkey = [_]u8{0} ** pubkey_len;
    for (&pubkey, 0..) |*byte, index| byte.* = seed +% @as(u8, @intCast(index));
    try out.appendSlice(std.testing.allocator, &pubkey);
}

fn appendInstruction(
    out: *std.ArrayList(u8),
    account_flags: []const u8,
    account_pubkey_seeds: []const u8,
    program_seed: u8,
    instruction_data: []const u8,
) !void {
    try appendU16(out, @intCast(account_flags.len));
    for (account_flags, 0..) |flags, index| {
        try out.append(std.testing.allocator, flags);
        try appendPubkey(out, account_pubkey_seeds[index]);
    }
    try appendPubkey(out, program_seed);
    try appendU16(out, @intCast(instruction_data.len));
    try out.appendSlice(std.testing.allocator, instruction_data);
}

fn buildInstructionsSysvar(instruction_count: u16) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    try appendU16(&out, instruction_count);
    try out.appendNTimes(std.testing.allocator, 0, @as(usize, instruction_count) * @sizeOf(u16));
    return out;
}

fn appendStakeHistoryRecord(
    out: *std.ArrayList(u8),
    epoch: u64,
    effective: u64,
    activating: u64,
    deactivating: u64,
) !void {
    try appendU64(out, epoch);
    try appendU64(out, effective);
    try appendU64(out, activating);
    try appendU64(out, deactivating);
}

fn buildStakeHistorySysvar(records: []const StakeHistoryRecord) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    try appendU64(&out, @intCast(records.len));
    for (records) |record| {
        try appendStakeHistoryRecord(
            &out,
            record.epoch,
            record.entry.effective,
            record.entry.activating,
            record.entry.deactivating,
        );
    }
    return out;
}

test "readInstructionsHeader and readInstructionAt parse a single instruction" {
    var data = try buildInstructionsSysvar(1);
    defer data.deinit(std.testing.allocator);

    const offset0: u16 = @intCast(data.items.len);
    writeU16Le(data.items, 2, offset0);
    try appendInstruction(&data, &.{ 0b11, 0b01 }, &.{ 0x20, 0x40 }, 0x80, &.{ 9, 8, 7 });

    const header = readInstructionsHeader(data.items);
    try std.testing.expectEqual(@as(u16, 1), header.instruction_count);
    try std.testing.expectEqual(offset0, header.offsetAt(0).?);

    const info = readInstructionAt(data.items, 0);
    try std.testing.expectEqual(@as(usize, 32), info.program_id.len);
    try std.testing.expectEqual(@as(u8, 0x80), info.program_id[0]);
    try std.testing.expectEqual(@as(usize, 2), info.accounts.len);
    try std.testing.expectEqual(@as(u8, 0x20), info.accounts[0].pubkey[0]);
    try std.testing.expect(info.accounts[0].is_signer);
    try std.testing.expect(info.accounts[0].is_writable);
    try std.testing.expect(info.accounts[1].is_signer);
    try std.testing.expect(!info.accounts[1].is_writable);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7 }, info.data);
}

test "readInstructionAt parses multiple instructions through offset table" {
    var data = try buildInstructionsSysvar(2);
    defer data.deinit(std.testing.allocator);

    const offset0: u16 = @intCast(data.items.len);
    writeU16Le(data.items, 2, offset0);
    try appendInstruction(&data, &.{0b00}, &.{0x10}, 0x30, &.{1});

    const offset1: u16 = @intCast(data.items.len);
    writeU16Le(data.items, 4, offset1);
    try appendInstruction(&data, &.{0b10}, &.{0x50}, 0x70, &.{ 2, 3, 4, 5 });

    const header = readInstructionsHeader(data.items);
    try std.testing.expectEqual(@as(u16, 2), header.instruction_count);
    try std.testing.expectEqual(offset0, header.offsetAt(0).?);
    try std.testing.expectEqual(offset1, header.offsetAt(1).?);

    const first = readInstructionAt(data.items, 0);
    const second = readInstructionAt(data.items, 1);
    try std.testing.expectEqual(@as(u8, 0x30), first.program_id[0]);
    try std.testing.expectEqualSlices(u8, &.{1}, first.data);
    try std.testing.expectEqual(@as(u8, 0x70), second.program_id[0]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5 }, second.data);
    try std.testing.expect(!second.accounts[0].is_signer);
    try std.testing.expect(second.accounts[0].is_writable);
}

test "Instructions sysvar readers return sentinels for malformed lengths" {
    const malformed_header = [_]u8{ 1, 0, 4 };
    const header = readInstructionsHeader(&malformed_header);
    try std.testing.expectEqual(@as(u16, 0), header.instruction_count);

    var data = try buildInstructionsSysvar(1);
    defer data.deinit(std.testing.allocator);
    const offset0: u16 = @intCast(data.items.len);
    writeU16Le(data.items, 2, offset0);
    try appendU16(&data, 0);
    try appendPubkey(&data, 0xa0);
    try appendU16(&data, 4);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2 });

    const info = readInstructionAt(data.items, 0);
    try std.testing.expectEqual(@as(usize, 0), info.program_id.len);
    try std.testing.expectEqual(@as(usize, 0), info.accounts.len);
    try std.testing.expectEqual(@as(usize, 0), info.data.len);
}

test "readInstructionAt returns error sentinel for out-of-bounds index" {
    var data = try buildInstructionsSysvar(1);
    defer data.deinit(std.testing.allocator);
    const offset0: u16 = @intCast(data.items.len);
    writeU16Le(data.items, 2, offset0);
    try appendInstruction(&data, &.{}, &.{}, 0x44, &.{0xaa});

    const info = readInstructionAt(data.items, 9);
    try std.testing.expectEqual(@as(usize, 0), info.program_id.len);
    try std.testing.expectEqual(@as(usize, 0), info.accounts.len);
    try std.testing.expectEqual(@as(usize, 0), info.data.len);
}

test "readStakeHistory cursor returns latest entries newest first" {
    const records = [_]StakeHistoryRecord{
        .{ .epoch = 10, .entry = .{ .effective = 100, .activating = 1, .deactivating = 2 } },
        .{ .epoch = 11, .entry = .{ .effective = 200, .activating = 3, .deactivating = 4 } },
        .{ .epoch = 12, .entry = .{ .effective = 300, .activating = 5, .deactivating = 6 } },
    };
    var data = try buildStakeHistorySysvar(&records);
    defer data.deinit(std.testing.allocator);

    var cursor = stakeHistoryCursor(data.items, 2);
    try std.testing.expect(cursor.hasNext());
    const newest = readStakeHistory(data.items, &cursor).?;
    const next = readStakeHistory(data.items, &cursor).?;
    try std.testing.expectEqual(@as(u64, 12), newest.epoch);
    try std.testing.expectEqual(@as(u64, 300), newest.entry.effective);
    try std.testing.expectEqual(@as(u64, 11), next.epoch);
    try std.testing.expectEqual(@as(u64, 3), next.entry.activating);
    try std.testing.expect(readStakeHistory(data.items, &cursor) == null);
}

test "readStakeHistory cursor clamps latest count to available entries" {
    const records = [_]StakeHistoryRecord{
        .{ .epoch = 1, .entry = .{ .effective = 10, .activating = 20, .deactivating = 30 } },
        .{ .epoch = 2, .entry = .{ .effective = 40, .activating = 50, .deactivating = 60 } },
    };
    var data = try buildStakeHistorySysvar(&records);
    defer data.deinit(std.testing.allocator);

    var cursor = stakeHistoryCursor(data.items, 99);
    try std.testing.expectEqual(@as(usize, 2), cursor.remaining);
    try std.testing.expectEqual(@as(u64, 2), readStakeHistory(data.items, &cursor).?.epoch);
    try std.testing.expectEqual(@as(u64, 1), readStakeHistory(data.items, &cursor).?.epoch);
    try std.testing.expect(!cursor.hasNext());
}

test "readStakeHistory ignores truncated trailing records" {
    var data = std.ArrayList(u8).empty;
    defer data.deinit(std.testing.allocator);
    try appendU64(&data, 2);
    try appendStakeHistoryRecord(&data, 7, 70, 71, 72);
    try appendU64(&data, 8);

    var cursor = stakeHistoryCursor(data.items, 2);
    try std.testing.expectEqual(@as(usize, 1), cursor.remaining);
    const only = readStakeHistory(data.items, &cursor).?;
    try std.testing.expectEqual(@as(u64, 7), only.epoch);
    try std.testing.expectEqual(@as(u64, 72), only.entry.deactivating);
    try std.testing.expect(readStakeHistory(data.items, &cursor) == null);
}

test "readStakeHistory empty and short account data are exhausted" {
    const short = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
    var short_cursor = stakeHistoryCursor(&short, 1);
    try std.testing.expect(!short_cursor.hasNext());
    try std.testing.expect(readStakeHistory(&short, &short_cursor) == null);

    var empty = std.ArrayList(u8).empty;
    defer empty.deinit(std.testing.allocator);
    try appendU64(&empty, 0);
    var empty_cursor = stakeHistoryCursor(empty.items, 1);
    try std.testing.expect(!empty_cursor.hasNext());
    try std.testing.expect(readStakeHistory(empty.items, &empty_cursor) == null);
}

test "readEpochSchedule parses packed fields with one-byte warmup bool" {
    var data = [_]u8{0} ** epoch_schedule_account_data_len;
    writeU64Le(&data, 0, 432_000);
    writeU64Le(&data, 8, 432_000);
    data[16] = 1;
    writeU64Le(&data, 17, 14);
    writeU64Le(&data, 25, 524_256);

    const schedule = readEpochSchedule(&data);
    try std.testing.expectEqual(@as(u64, 432_000), schedule.slots_per_epoch);
    try std.testing.expectEqual(@as(u64, 432_000), schedule.leader_schedule_slot_offset);
    try std.testing.expect(schedule.warmup);
    try std.testing.expectEqual(@as(u64, 14), schedule.first_normal_epoch);
    try std.testing.expectEqual(@as(u64, 524_256), schedule.first_normal_slot);
}

test "readEpochSchedule warmup is false for byte value zero" {
    var data = [_]u8{0} ** epoch_schedule_account_data_len;
    writeU64Le(&data, 0, 64);
    writeU64Le(&data, 8, 32);
    data[16] = 0;
    writeU64Le(&data, 17, 3);
    writeU64Le(&data, 25, 9);

    const schedule = readEpochSchedule(&data);
    try std.testing.expect(!schedule.warmup);
    try std.testing.expectEqual(@as(u64, 64), schedule.slots_per_epoch);
    try std.testing.expectEqual(@as(u64, 3), schedule.first_normal_epoch);
}

test "readEpochSchedule returns zero value for short account data" {
    const short = [_]u8{0xaa} ** (epoch_schedule_account_data_len - 1);
    const schedule = readEpochSchedule(&short);
    try std.testing.expectEqual(@as(u64, 0), schedule.slots_per_epoch);
    try std.testing.expectEqual(@as(u64, 0), schedule.leader_schedule_slot_offset);
    try std.testing.expect(!schedule.warmup);
    try std.testing.expectEqual(@as(u64, 0), schedule.first_normal_epoch);
    try std.testing.expectEqual(@as(u64, 0), schedule.first_normal_slot);
}

test "readEpochSchedule treats non-one warmup byte as false" {
    var data = [_]u8{0} ** epoch_schedule_account_data_len;
    writeU64Le(&data, 0, 1);
    writeU64Le(&data, 8, 2);
    data[16] = 2;
    writeU64Le(&data, 17, 3);
    writeU64Le(&data, 25, 4);

    const schedule = readEpochSchedule(&data);
    try std.testing.expect(!schedule.warmup);
    try std.testing.expectEqual(@as(u64, 4), schedule.first_normal_slot);
}
