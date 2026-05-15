const std = @import("std");
const sol = @import("solana_sdk_m2");

const clock_data_len = 40;
const rent_data_len = 17;

const crypto_input = "m2-syscall-equivalence";
const clock_slot: u64 = 1_234_567;
const clock_epoch: u64 = 42;
const clock_unix_timestamp: i64 = 1_700_000_123;
const rent_lamports_per_byte_year: u64 = 3_480;
const rent_exemption_threshold: f64 = 2.0;
const rent_burn_percent: u8 = 50;

fn makeClockData() [clock_data_len]u8 {
    var data = [_]u8{0} ** clock_data_len;
    std.mem.writeInt(u64, data[0..8], clock_slot, .little);
    std.mem.writeInt(i64, data[8..16], 0, .little);
    std.mem.writeInt(u64, data[16..24], clock_epoch, .little);
    std.mem.writeInt(u64, data[24..32], 0, .little);
    std.mem.writeInt(i64, data[32..40], clock_unix_timestamp, .little);
    return data;
}

fn makeRentData() [rent_data_len]u8 {
    var data = [_]u8{0} ** rent_data_len;
    std.mem.writeInt(u64, data[0..8], rent_lamports_per_byte_year, .little);
    std.mem.writeInt(u64, data[8..16], @bitCast(rent_exemption_threshold), .little);
    data[16] = rent_burn_percent;
    return data;
}

pub fn main() void {
    var clock_data = makeClockData();
    var rent_data = makeRentData();
    const reader_clock = readClock(clock_data[0..]);
    const reader_rent_lamports = readRentLamports(rent_data[0..]);
    const direct_clock_slot: u64 = 0;
    const direct_clock_epoch: u64 = 0;
    const direct_clock_unix_timestamp: i64 = 0;
    const direct_rent_lamports: u64 = 0;
    const remaining: u64 = 0;
    const sha = hashSha256(crypto_input);
    const keccak = hashKeccak256(crypto_input);
    const blake3 = hashBlake3(crypto_input);

    var output_data = [_]u8{0} ** 168;
    @memcpy(output_data[0..32], &sha);
    @memcpy(output_data[32..64], &keccak);
    @memcpy(output_data[64..96], &blake3);
    std.mem.writeInt(u64, output_data[96..104], reader_clock.slot, .little);
    std.mem.writeInt(u64, output_data[104..112], reader_clock.epoch, .little);
    std.mem.writeInt(i64, output_data[112..120], reader_clock.unix_timestamp, .little);
    std.mem.writeInt(u64, output_data[120..128], reader_rent_lamports, .little);
    std.mem.writeInt(u64, output_data[128..136], direct_clock_slot, .little);
    std.mem.writeInt(u64, output_data[136..144], direct_clock_epoch, .little);
    std.mem.writeInt(i64, output_data[144..152], direct_clock_unix_timestamp, .little);
    std.mem.writeInt(u64, output_data[152..160], direct_rent_lamports, .little);
    std.mem.writeInt(u64, output_data[160..168], remaining, .little);

    for (output_data) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});
}

const ReaderClock = struct {
    slot: u64,
    epoch: u64,
    unix_timestamp: i64,
};

fn readClock(account_data: []const u8) ReaderClock {
    return .{
        .slot = std.mem.readInt(u64, account_data[0..8], .little),
        .epoch = std.mem.readInt(u64, account_data[16..24], .little),
        .unix_timestamp = std.mem.readInt(i64, account_data[32..40], .little),
    };
}

fn readRentLamports(account_data: []const u8) u64 {
    return std.mem.readInt(u64, account_data[0..8], .little);
}

fn hashSha256(payload: []const u8) [32]u8 {
    const parts = [_][]const u8{payload};
    return (sol.hash.sha256(&parts) catch unreachable).bytes;
}

fn hashKeccak256(payload: []const u8) [32]u8 {
    const parts = [_][]const u8{payload};
    return (sol.hash.keccak256(&parts) catch unreachable).bytes;
}

fn hashBlake3(payload: []const u8) [32]u8 {
    const parts = [_][]const u8{payload};
    return (sol.hash.blake3(&parts) catch unreachable).bytes;
}
