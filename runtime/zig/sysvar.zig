//! SVM sysvar account readers.
//!
//! Layout references (Solana 1.18+ SDK):
//! - `solana-program/src/sysvar/clock.rs` (`Clock`)
//! - `solana-program/src/sysvar/rent.rs` (`Rent`)
//!
//! Sysvar account data is serialized field-by-field in little-endian order.
//! These readers do not cast from account bytes, so they are safe for
//! byte-aligned slices and for account data that is not naturally aligned.

const std = @import("std");

pub const clock_account_data_len: usize = 40;
pub const rent_account_data_len: usize = 17;

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

/// Reads a Clock sysvar account payload. Short data returns the zero value.
pub fn readClock(account_data: []const u8) Clock {
    if (account_data.len < clock_account_data_len) return .{};
    return .{
        .slot = readU64Le(account_data, 0).?,
        .epoch_start_timestamp = @bitCast(readU64Le(account_data, 8).?),
        .epoch = readU64Le(account_data, 16).?,
        .leader_schedule_epoch = readU64Le(account_data, 24).?,
        .unix_timestamp = @bitCast(readU64Le(account_data, 32).?),
    };
}

/// Reads a Rent sysvar account payload. Short data returns the zero value.
pub fn readRent(account_data: []const u8) Rent {
    if (account_data.len < rent_account_data_len) return .{};
    return .{
        .lamports_per_byte_year = readU64Le(account_data, 0).?,
        .exemption_threshold = @bitCast(readU64Le(account_data, 8).?),
        .burn_percent = account_data[16],
    };
}

fn readU64Le(account_data: []const u8, offset: usize) ?u64 {
    if (offset + @sizeOf(u64) > account_data.len) return null;
    return std.mem.readInt(u64, account_data[offset..][0..@sizeOf(u64)], .little);
}

fn writeU64Le(out: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, out[offset..][0..@sizeOf(u64)], value, .little);
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
