const std = @import("std");
const shared = @import("shared.zig");
const ArithmeticError = shared.ArithmeticError;
const SlippageError = shared.SlippageError;
const RouterMathError = shared.RouterMathError;
const Rounding = shared.Rounding;
const SlippageBound = shared.SlippageBound;
const BASIS_POINTS_DENOMINATOR = shared.BASIS_POINTS_DENOMINATOR;
const PARTS_PER_MILLION_DENOMINATOR = shared.PARTS_PER_MILLION_DENOMINATOR;
const requireUnsignedInt = shared.requireUnsignedInt;
const tryAdd = @import("checked.zig").tryAdd;
const trySub = @import("checked.zig").trySub;

// =============================================================================
// Router-grade division / mulDiv / fees / slippage
// =============================================================================

/// Checked truncating division. Returns `error.InvalidArgument` for a
/// zero denominator and `error.ArithmeticOverflow` for signed overflow
/// (`minInt / -1`).
pub inline fn checkedDiv(a: anytype, b: @TypeOf(a)) ArithmeticError!@TypeOf(a) {
    const T = @TypeOf(a);
    if (b == 0) return error.InvalidArgument;

    const info = @typeInfo(T);
    if (info == .int and info.int.signedness == .signed and a == std.math.minInt(T) and b == -1) {
        return error.ArithmeticOverflow;
    }

    return @divTrunc(a, b);
}

/// Optional-returning version of `checkedDiv`.
pub inline fn tryCheckedDiv(a: anytype, b: @TypeOf(a)) ?@TypeOf(a) {
    return checkedDiv(a, b) catch null;
}

/// Multiply `a * b`, divide by `denominator`, and apply the explicit
/// rounding mode. Uses a double-width intermediate (`u128` for `u64`)
/// so intermediate multiplication never truncates.
pub inline fn mulDiv(
    a: anytype,
    b: @TypeOf(a),
    denominator: @TypeOf(a),
    rounding: Rounding,
) ArithmeticError!@TypeOf(a) {
    const T = @TypeOf(a);
    requireUnsignedInt(T);

    if (denominator == 0) return error.InvalidArgument;

    const wide = std.math.mulWide(T, a, b);
    const WideT = @TypeOf(wide);
    const denominator_wide: WideT = denominator;
    const quotient_wide = @divTrunc(wide, denominator_wide);
    if (quotient_wide > std.math.maxInt(T)) return error.ArithmeticOverflow;

    var quotient: T = @intCast(quotient_wide);
    if (rounding == .up and @rem(wide, denominator_wide) != 0) {
        quotient = tryAdd(quotient, 1) orelse return error.ArithmeticOverflow;
    }
    return quotient;
}

/// Optional-returning version of `mulDiv`.
pub inline fn tryMulDiv(
    a: anytype,
    b: @TypeOf(a),
    denominator: @TypeOf(a),
    rounding: Rounding,
) ?@TypeOf(a) {
    return mulDiv(a, b, denominator, rounding) catch null;
}

inline fn requireFeeScale(rate: anytype, denominator: @TypeOf(rate)) ArithmeticError!void {
    if (denominator == 0 or rate > denominator) return error.InvalidArgument;
}

/// Compute a fee amount with an explicit denominator and rounding
/// policy.
pub inline fn feeAmount(
    amount: anytype,
    rate: @TypeOf(amount),
    denominator: @TypeOf(amount),
    rounding: Rounding,
) ArithmeticError!@TypeOf(amount) {
    requireUnsignedInt(@TypeOf(amount));
    try requireFeeScale(rate, denominator);
    return mulDiv(amount, rate, denominator, rounding);
}

pub inline fn feeAmountBps(amount: anytype, bps: @TypeOf(amount), rounding: Rounding) ArithmeticError!@TypeOf(amount) {
    const T = @TypeOf(amount);
    requireUnsignedInt(T);
    return feeAmount(amount, bps, @as(T, BASIS_POINTS_DENOMINATOR), rounding);
}

pub inline fn feeAmountPpm(amount: anytype, ppm: @TypeOf(amount), rounding: Rounding) ArithmeticError!@TypeOf(amount) {
    const T = @TypeOf(amount);
    requireUnsignedInt(T);
    return feeAmount(amount, ppm, @as(T, PARTS_PER_MILLION_DENOMINATOR), rounding);
}

/// Subtract the computed fee from `amount`, rejecting underflow.
pub inline fn amountAfterFee(
    amount: anytype,
    rate: @TypeOf(amount),
    denominator: @TypeOf(amount),
    rounding: Rounding,
) ArithmeticError!@TypeOf(amount) {
    requireUnsignedInt(@TypeOf(amount));
    const fee = try feeAmount(amount, rate, denominator, rounding);
    return trySub(amount, fee) orelse error.ArithmeticOverflow;
}

pub inline fn amountAfterFeeBps(
    amount: anytype,
    bps: @TypeOf(amount),
    rounding: Rounding,
) ArithmeticError!@TypeOf(amount) {
    const T = @TypeOf(amount);
    requireUnsignedInt(T);
    return amountAfterFee(amount, bps, @as(T, BASIS_POINTS_DENOMINATOR), rounding);
}

pub inline fn amountAfterFeePpm(
    amount: anytype,
    ppm: @TypeOf(amount),
    rounding: Rounding,
) ArithmeticError!@TypeOf(amount) {
    const T = @TypeOf(amount);
    requireUnsignedInt(T);
    return amountAfterFee(amount, ppm, @as(T, PARTS_PER_MILLION_DENOMINATOR), rounding);
}

/// Derive a slippage threshold from an expected amount. `.min_out`
/// subtracts the tolerance; `.max_in` adds it.
pub inline fn deriveSlippageThreshold(
    expected_amount: anytype,
    tolerance: @TypeOf(expected_amount),
    denominator: @TypeOf(expected_amount),
    bound: SlippageBound,
    rounding: Rounding,
) ArithmeticError!@TypeOf(expected_amount) {
    requireUnsignedInt(@TypeOf(expected_amount));
    const delta = try feeAmount(expected_amount, tolerance, denominator, rounding);
    return switch (bound) {
        .min_out => trySub(expected_amount, delta) orelse error.ArithmeticOverflow,
        .max_in => tryAdd(expected_amount, delta) orelse error.ArithmeticOverflow,
    };
}

pub inline fn deriveSlippageThresholdBps(
    expected_amount: anytype,
    bps: @TypeOf(expected_amount),
    bound: SlippageBound,
    rounding: Rounding,
) ArithmeticError!@TypeOf(expected_amount) {
    const T = @TypeOf(expected_amount);
    requireUnsignedInt(T);
    return deriveSlippageThreshold(expected_amount, bps, @as(T, BASIS_POINTS_DENOMINATOR), bound, rounding);
}

pub inline fn deriveSlippageThresholdPpm(
    expected_amount: anytype,
    ppm: @TypeOf(expected_amount),
    bound: SlippageBound,
    rounding: Rounding,
) ArithmeticError!@TypeOf(expected_amount) {
    const T = @TypeOf(expected_amount);
    requireUnsignedInt(T);
    return deriveSlippageThreshold(expected_amount, ppm, @as(T, PARTS_PER_MILLION_DENOMINATOR), bound, rounding);
}

pub inline fn deriveMinOutBps(
    expected_amount: anytype,
    bps: @TypeOf(expected_amount),
    rounding: Rounding,
) ArithmeticError!@TypeOf(expected_amount) {
    return deriveSlippageThresholdBps(expected_amount, bps, .min_out, rounding);
}

pub inline fn deriveMinOutPpm(
    expected_amount: anytype,
    ppm: @TypeOf(expected_amount),
    rounding: Rounding,
) ArithmeticError!@TypeOf(expected_amount) {
    return deriveSlippageThresholdPpm(expected_amount, ppm, .min_out, rounding);
}

/// Require `actual_out >= min_out`.
pub inline fn requireMinOut(actual_out: anytype, min_out: @TypeOf(actual_out)) SlippageError!void {
    if (actual_out < min_out) return error.SlippageExceeded;
}

/// Derive the minimum acceptable output from an expected amount and
/// then enforce it.
pub inline fn requireSlippage(
    actual_out: anytype,
    expected_out: @TypeOf(actual_out),
    tolerance: @TypeOf(actual_out),
    denominator: @TypeOf(actual_out),
    rounding: Rounding,
) RouterMathError!void {
    const min_out = try deriveSlippageThreshold(expected_out, tolerance, denominator, .min_out, rounding);
    try requireMinOut(actual_out, min_out);
}

pub inline fn requireSlippageBps(
    actual_out: anytype,
    expected_out: @TypeOf(actual_out),
    bps: @TypeOf(actual_out),
    rounding: Rounding,
) RouterMathError!void {
    const T = @TypeOf(actual_out);
    requireUnsignedInt(T);
    return requireSlippage(actual_out, expected_out, bps, @as(T, BASIS_POINTS_DENOMINATOR), rounding);
}

pub inline fn requireSlippagePpm(
    actual_out: anytype,
    expected_out: @TypeOf(actual_out),
    ppm: @TypeOf(actual_out),
    rounding: Rounding,
) RouterMathError!void {
    const T = @TypeOf(actual_out);
    requireUnsignedInt(T);
    return requireSlippage(actual_out, expected_out, ppm, @as(T, PARTS_PER_MILLION_DENOMINATOR), rounding);
}
