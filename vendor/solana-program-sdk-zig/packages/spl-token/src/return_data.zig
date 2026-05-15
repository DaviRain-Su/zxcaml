//! SPL Token return-data decoders.
//!
//! Classic SPL Token and Token-2022 expose a few utility instructions that
//! return their answers via `sol_get_return_data` rather than by mutating an
//! account. This module centralizes the decoding / program-id validation for
//! those responses so on-chain callers can write:
//!
//! ```zig
//! var buf: [64]u8 = undefined;
//! const returned = sol.cpi.getReturnData(buf[0..]) orelse return error.InvalidInstructionData;
//! const size = try spl_token.return_data.parseGetAccountDataSizeReturn(returned);
//! ```

const std = @import("std");
const sol = @import("solana_program_sdk");
const id = @import("id.zig");

const Pubkey = sol.Pubkey;

pub const Error = error{
    IncorrectProgramId,
    InvalidReturnData,
};

pub inline fn isTokenProgram(program_id: *const Pubkey) bool {
    return sol.pubkey.pubkeyEq(program_id, &id.PROGRAM_ID) or
        sol.pubkey.pubkeyEq(program_id, &id.PROGRAM_ID_2022);
}

inline fn requireTokenProgram(program_id: *const Pubkey) Error!void {
    if (!isTokenProgram(program_id)) return error.IncorrectProgramId;
}

inline fn parseReturnedU64(program_id: *const Pubkey, data: []const u8) Error!u64 {
    try requireTokenProgram(program_id);
    if (data.len != @sizeOf(u64)) return error.InvalidReturnData;
    return std.mem.readInt(u64, data[0..8], .little);
}

/// Decode `GetAccountDataSize` return data (`u64`, little-endian).
pub inline fn parseGetAccountDataSize(program_id: *const Pubkey, data: []const u8) Error!u64 {
    return parseReturnedU64(program_id, data);
}

/// Generic helper when the caller already has the tuple from
/// `sol.cpi.getReturnData(...)`.
pub inline fn parseGetAccountDataSizeReturn(returned: anytype) Error!u64 {
    const program_id: Pubkey = returned.@"0";
    return parseGetAccountDataSize(&program_id, returned.@"1");
}

/// Decode `AmountToUiAmount` return data (UTF-8 string bytes).
pub inline fn parseAmountToUiAmount(program_id: *const Pubkey, data: []const u8) Error![]const u8 {
    try requireTokenProgram(program_id);
    if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidReturnData;
    return data;
}

pub inline fn parseAmountToUiAmountReturn(returned: anytype) Error![]const u8 {
    const program_id: Pubkey = returned.@"0";
    return parseAmountToUiAmount(&program_id, returned.@"1");
}

/// Decode `UiAmountToAmount` return data (`u64`, little-endian).
pub inline fn parseUiAmountToAmount(program_id: *const Pubkey, data: []const u8) Error!u64 {
    return parseReturnedU64(program_id, data);
}

pub inline fn parseUiAmountToAmountReturn(returned: anytype) Error!u64 {
    const program_id: Pubkey = returned.@"0";
    return parseUiAmountToAmount(&program_id, returned.@"1");
}

test "spl-token return-data: token family program ids are accepted" {
    try std.testing.expect(isTokenProgram(&id.PROGRAM_ID));
    try std.testing.expect(isTokenProgram(&id.PROGRAM_ID_2022));
    try std.testing.expect(!isTokenProgram(&sol.system_program_id));
}

test "spl-token return-data: getAccountDataSize and uiAmountToAmount decode u64" {
    const payload = [_]u8{ 165, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u64, 165), try parseGetAccountDataSize(&id.PROGRAM_ID, &payload));
    try std.testing.expectEqual(@as(u64, 165), try parseUiAmountToAmount(&id.PROGRAM_ID_2022, &payload));
    try std.testing.expectError(error.InvalidReturnData, parseGetAccountDataSize(&id.PROGRAM_ID, payload[0..7]));
    try std.testing.expectError(error.IncorrectProgramId, parseUiAmountToAmount(&sol.system_program_id, &payload));
}

test "spl-token return-data: amountToUiAmount validates utf8 and program id" {
    try std.testing.expectEqualStrings("1.2345", try parseAmountToUiAmount(&id.PROGRAM_ID, "1.2345"));

    const invalid_utf8 = [_]u8{ 0xff, 0xfe };
    try std.testing.expectError(error.InvalidReturnData, parseAmountToUiAmount(&id.PROGRAM_ID_2022, &invalid_utf8));
    try std.testing.expectError(error.IncorrectProgramId, parseAmountToUiAmount(&sol.system_program_id, "1"));
}

test "spl-token return-data: tuple helpers decode getReturnData-style values" {
    const payload_u64 = [_]u8{ 9, 0, 0, 0, 0, 0, 0, 0 };
    const tuple_u64 = .{ id.PROGRAM_ID, payload_u64[0..] };
    try std.testing.expectEqual(@as(u64, 9), try parseGetAccountDataSizeReturn(tuple_u64));
    try std.testing.expectEqual(@as(u64, 9), try parseUiAmountToAmountReturn(tuple_u64));

    const tuple_text = .{ id.PROGRAM_ID_2022, "7.5" };
    try std.testing.expectEqualStrings("7.5", try parseAmountToUiAmountReturn(tuple_text));
}
