//! Zero-allocation SPL Token UI-amount helpers.
//!
//! These mirror the classic SPL Token crate's string conversion semantics while
//! staying allocator-free and on-chain-friendly:
//!
//! - `amountToUiAmountString(...)`
//! - `amountToUiAmountStringTrimmed(...)`
//! - `tryUiAmountIntoAmount(...)`
//!
//! The caller supplies the output buffer for formatting.

const std = @import("std");

pub const Error = error{
    BufferTooSmall,
    InvalidArgument,
};

/// Maximum decimal places representable by SPL Token mint metadata.
pub const MAX_DECIMALS: usize = std.math.maxInt(u8);

/// Worst-case formatted length for any `u64` amount with `u8` decimals:
/// `0.` + 255 fractional digits.
pub const MAX_FORMATTED_UI_AMOUNT_LEN: usize = MAX_DECIMALS + 2;

pub fn formattedLen(amount: u64, decimals: u8) usize {
    var digits_buf: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{}", .{amount}) catch unreachable;
    if (decimals == 0) return digits.len;
    return if (digits.len > decimals) digits.len + 1 else @as(usize, decimals) + 2;
}

/// Format a raw token amount using mint decimals, preserving trailing zeroes.
pub fn amountToUiAmountString(amount: u64, decimals: u8, out: []u8) Error![]const u8 {
    var digits_buf: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{}", .{amount}) catch unreachable;
    const need = if (decimals == 0)
        digits.len
    else if (digits.len > decimals)
        digits.len + 1
    else
        @as(usize, decimals) + 2;
    if (out.len < need) return error.BufferTooSmall;

    if (decimals == 0) {
        @memcpy(out[0..digits.len], digits);
        return out[0..digits.len];
    }

    if (digits.len > decimals) {
        const int_len = digits.len - decimals;
        @memcpy(out[0..int_len], digits[0..int_len]);
        out[int_len] = '.';
        @memcpy(out[int_len + 1 .. need], digits[int_len..]);
        return out[0..need];
    }

    out[0] = '0';
    out[1] = '.';
    const zero_pad = @as(usize, decimals) - digits.len;
    @memset(out[2 .. 2 + zero_pad], '0');
    @memcpy(out[2 + zero_pad .. need], digits);
    return out[0..need];
}

/// Format a raw token amount and trim redundant trailing zeroes / trailing dot.
pub fn amountToUiAmountStringTrimmed(amount: u64, decimals: u8, out: []u8) Error![]const u8 {
    const formatted = try amountToUiAmountString(amount, decimals, out);
    if (decimals == 0) return formatted;

    var end = formatted.len;
    while (end > 0 and formatted[end - 1] == '0') : (end -= 1) {}
    if (end > 0 and formatted[end - 1] == '.') end -= 1;
    return formatted[0..end];
}

/// Parse a UI amount string using mint decimals, matching SPL Token semantics.
pub fn tryUiAmountIntoAmount(ui_amount: []const u8, decimals: u8) Error!u64 {
    const dot_index = std.mem.indexOfScalar(u8, ui_amount, '.');
    if (dot_index) |first_dot| {
        if (std.mem.indexOfScalarPos(u8, ui_amount, first_dot + 1, '.')) |_| {
            return error.InvalidArgument;
        }
    }

    const int_part = if (dot_index) |idx| ui_amount[0..idx] else ui_amount;
    const frac_raw = if (dot_index) |idx| ui_amount[idx + 1 ..] else "";
    var frac_len = frac_raw.len;
    while (frac_len > 0 and frac_raw[frac_len - 1] == '0') : (frac_len -= 1) {}
    const frac = frac_raw[0..frac_len];

    if (int_part.len == 0 and frac.len == 0) return error.InvalidArgument;
    if (frac.len > decimals) return error.InvalidArgument;

    var amount: u64 = 0;
    for (int_part) |c| {
        if (c < '0' or c > '9') return error.InvalidArgument;
        amount = std.math.mul(u64, amount, 10) catch return error.InvalidArgument;
        amount = std.math.add(u64, amount, c - '0') catch return error.InvalidArgument;
    }
    for (frac) |c| {
        if (c < '0' or c > '9') return error.InvalidArgument;
        amount = std.math.mul(u64, amount, 10) catch return error.InvalidArgument;
        amount = std.math.add(u64, amount, c - '0') catch return error.InvalidArgument;
    }
    var i: usize = 0;
    while (i < @as(usize, decimals) - frac.len) : (i += 1) {
        amount = std.math.mul(u64, amount, 10) catch return error.InvalidArgument;
    }
    return amount;
}

test "ui_amount: format preserves canonical zero padding" {
    var buf: [MAX_FORMATTED_UI_AMOUNT_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("1.234567", try amountToUiAmountString(1_234_567, 6, buf[0..]));
    try std.testing.expectEqualStrings("1.000000", try amountToUiAmountString(1_000_000, 6, buf[0..]));
    try std.testing.expectEqualStrings("0.000123", try amountToUiAmountString(123, 6, buf[0..]));
    try std.testing.expectEqualStrings("42", try amountToUiAmountString(42, 0, buf[0..]));
}

test "ui_amount: trimmed formatting matches SPL token semantics" {
    var buf: [MAX_FORMATTED_UI_AMOUNT_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("1.2345", try amountToUiAmountStringTrimmed(1_234_500, 6, buf[0..]));
    try std.testing.expectEqualStrings("1", try amountToUiAmountStringTrimmed(1_000_000, 6, buf[0..]));
    try std.testing.expectEqualStrings("0", try amountToUiAmountStringTrimmed(0, 6, buf[0..]));
    try std.testing.expectEqualStrings("42", try amountToUiAmountStringTrimmed(42, 0, buf[0..]));
}

test "ui_amount: parse accepts canonical and trimmed forms" {
    try std.testing.expectEqual(@as(u64, 1_230_000), try tryUiAmountIntoAmount("1.23", 6));
    try std.testing.expectEqual(@as(u64, 500_000), try tryUiAmountIntoAmount(".5", 6));
    try std.testing.expectEqual(@as(u64, 12_000_000), try tryUiAmountIntoAmount("12.", 6));
    try std.testing.expectEqual(@as(u64, 0), try tryUiAmountIntoAmount("0.000000", 6));
    try std.testing.expectEqual(@as(u64, 1_200_000), try tryUiAmountIntoAmount("1.200000", 6));
}

test "ui_amount: parse rejects invalid forms and overflow" {
    try std.testing.expectError(error.InvalidArgument, tryUiAmountIntoAmount("", 6));
    try std.testing.expectError(error.InvalidArgument, tryUiAmountIntoAmount(".", 6));
    try std.testing.expectError(error.InvalidArgument, tryUiAmountIntoAmount("1.2345678", 6));
    try std.testing.expectError(error.InvalidArgument, tryUiAmountIntoAmount("1.2.3", 6));
    try std.testing.expectError(error.InvalidArgument, tryUiAmountIntoAmount("abc", 6));
    try std.testing.expectError(error.InvalidArgument, tryUiAmountIntoAmount("18446744073709551616", 0));
}

test "ui_amount: formatted length and buffer checks are accurate" {
    try std.testing.expectEqual(@as(usize, 8), formattedLen(1234567, 6));
    try std.testing.expectEqual(@as(usize, 8), formattedLen(123, 6));
    try std.testing.expectEqual(@as(usize, 2), formattedLen(42, 0));

    var short: [5]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, amountToUiAmountString(123, 6, short[0..]));
}
