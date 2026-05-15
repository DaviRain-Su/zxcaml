//! Checked integer arithmetic — `?T` and `!T` flavors.
//!
//! Every DeFi-style Solana program does this dance:
//! ```zig
//! const new_balance, const ovf = @addWithOverflow(balance, amount);
//! if (ovf != 0) return error.ArithmeticOverflow;
//! ```
//!
//! This module collapses it to:
//! ```zig
//! const new_balance = try sol.math.add(balance, amount);
//! ```
//!
//! Zero overhead — LLVM folds `@addWithOverflow` + branch into the
//! same instructions as the hand-written form. Verified by
//! disassembly + measured 0 CU change in the vault benchmark.
//!
//! Three flavors of each operation:
//! - `addUnchecked(a, b)` — wraps. Same as `a +% b`. For when you've
//!   already proven non-overflow.
//! - `tryAdd(a, b)` — returns `?T`. Composes with `orelse`.
//! - `add(a, b)` — returns `ProgramError!T`. Composes with `try`.
//!
//! Physical layout:
//! - `shared.zig` — shared error sets, enums, denominators, and comptime guards
//! - `checked.zig` — wrapping / checked add-sub-mul helpers
//! - `router.zig` — checked division, mulDiv, fee, and slippage helpers
//!
//! The public API stays flattened as `sol.math.*`.

const std = @import("std");
const shared = @import("shared.zig");
const checked_mod = @import("checked.zig");
const router_mod = @import("router.zig");

/// Error sets, rounding/slippage enums, and shared denominators.
pub const ArithmeticError = shared.ArithmeticError;
pub const SlippageError = shared.SlippageError;
pub const RouterMathError = shared.RouterMathError;
pub const Rounding = shared.Rounding;
pub const SlippageBound = shared.SlippageBound;
pub const BASIS_POINTS_DENOMINATOR = shared.BASIS_POINTS_DENOMINATOR;
pub const PARTS_PER_MILLION_DENOMINATOR = shared.PARTS_PER_MILLION_DENOMINATOR;

/// Checked and wrapping integer arithmetic helpers.
pub const addUnchecked = checked_mod.addUnchecked;
pub const tryAdd = checked_mod.tryAdd;
pub const add = checked_mod.add;
pub const subUnchecked = checked_mod.subUnchecked;
pub const trySub = checked_mod.trySub;
pub const sub = checked_mod.sub;
pub const mulUnchecked = checked_mod.mulUnchecked;
pub const tryMul = checked_mod.tryMul;
pub const mul = checked_mod.mul;
pub const checkedDiv = router_mod.checkedDiv;
pub const tryCheckedDiv = router_mod.tryCheckedDiv;

/// Router-grade division, fee, and slippage helpers.
pub const mulDiv = router_mod.mulDiv;
pub const tryMulDiv = router_mod.tryMulDiv;
pub const feeAmount = router_mod.feeAmount;
pub const feeAmountBps = router_mod.feeAmountBps;
pub const feeAmountPpm = router_mod.feeAmountPpm;
pub const amountAfterFee = router_mod.amountAfterFee;
pub const amountAfterFeeBps = router_mod.amountAfterFeeBps;
pub const amountAfterFeePpm = router_mod.amountAfterFeePpm;
pub const deriveSlippageThreshold = router_mod.deriveSlippageThreshold;
pub const deriveSlippageThresholdBps = router_mod.deriveSlippageThresholdBps;
pub const deriveSlippageThresholdPpm = router_mod.deriveSlippageThresholdPpm;
pub const deriveMinOutBps = router_mod.deriveMinOutBps;
pub const deriveMinOutPpm = router_mod.deriveMinOutPpm;
pub const requireMinOut = router_mod.requireMinOut;
pub const requireSlippage = router_mod.requireSlippage;
pub const requireSlippageBps = router_mod.requireSlippageBps;
pub const requireSlippagePpm = router_mod.requireSlippagePpm;

// =============================================================================
// Tests
// =============================================================================

test "math: add happy path" {
    try std.testing.expectEqual(@as(u64, 3), try add(@as(u64, 1), 2));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), try add(@as(u64, std.math.maxInt(u64) - 1), 1));
}

test "math: add overflow" {
    try std.testing.expectError(error.ArithmeticOverflow, add(@as(u64, std.math.maxInt(u64)), 1));
}

test "math: tryAdd returns null on overflow" {
    try std.testing.expect(tryAdd(@as(u64, std.math.maxInt(u64)), 1) == null);
    try std.testing.expectEqual(@as(?u64, 5), tryAdd(@as(u64, 2), 3));
}

test "math: sub happy path" {
    try std.testing.expectEqual(@as(u64, 5), try sub(@as(u64, 10), 5));
    try std.testing.expectEqual(@as(u64, 0), try sub(@as(u64, 1), 1));
}

test "math: sub underflow" {
    try std.testing.expectError(error.ArithmeticOverflow, sub(@as(u64, 0), 1));
}

test "math: mul happy path" {
    try std.testing.expectEqual(@as(u64, 12), try mul(@as(u64, 3), 4));
}

test "math: mul overflow" {
    try std.testing.expectError(error.ArithmeticOverflow, mul(@as(u64, std.math.maxInt(u64)), 2));
}

test "math: wrapping variants" {
    try std.testing.expectEqual(@as(u64, 0), addUnchecked(@as(u64, std.math.maxInt(u64)), 1));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), subUnchecked(@as(u64, 0), 1));
    // maxInt * 2 wraps to (2^65 - 2) mod 2^64 = 2^64 - 2.
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), mulUnchecked(@as(u64, std.math.maxInt(u64)), 2));
}

test "math: works for u32" {
    try std.testing.expectError(error.ArithmeticOverflow, add(@as(u32, std.math.maxInt(u32)), 1));
}

test "math: works for i64 signed" {
    try std.testing.expectError(error.ArithmeticOverflow, add(@as(i64, std.math.maxInt(i64)), 1));
    try std.testing.expectError(error.ArithmeticOverflow, sub(@as(i64, std.math.minInt(i64)), 1));
}

test "math: checkedDiv rejects zero and preserves quotient semantics" {
    const Case = struct {
        numerator: u64,
        denominator: u64,
        expected: u64,
    };

    const cases = [_]Case{
        .{ .numerator = 5, .denominator = 2, .expected = 2 },
        .{ .numerator = 0, .denominator = 9, .expected = 0 },
        .{ .numerator = std.math.maxInt(u64), .denominator = std.math.maxInt(u64), .expected = 1 },
        .{ .numerator = std.math.maxInt(u64), .denominator = 2, .expected = std.math.maxInt(u64) / 2 },
    };

    try std.testing.expectError(error.InvalidArgument, checkedDiv(@as(u64, 1), 0));
    try std.testing.expect(tryCheckedDiv(@as(u64, 1), 0) == null);

    inline for (cases) |case| {
        try std.testing.expectEqual(case.expected, try checkedDiv(case.numerator, case.denominator));
        try std.testing.expectEqual(case.expected, tryCheckedDiv(case.numerator, case.denominator).?);
    }
}

test "math: mulDiv uses double-width intermediate and rejects overflow" {
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        try mulDiv(@as(u64, std.math.maxInt(u64)), std.math.maxInt(u64), std.math.maxInt(u64), .down),
    );
    try std.testing.expectError(
        error.ArithmeticOverflow,
        mulDiv(@as(u64, std.math.maxInt(u64)), std.math.maxInt(u64), 1, .down),
    );
    try std.testing.expectError(error.InvalidArgument, mulDiv(@as(u64, 9), 3, 0, .down));
    try std.testing.expect(tryMulDiv(@as(u64, 9), 3, 0, .down) == null);
}

test "math: mulDiv rounding modes are explicit and correct" {
    try std.testing.expectEqual(@as(u64, 4), try mulDiv(@as(u64, 12), 1, 3, .down));
    try std.testing.expectEqual(@as(u64, 4), try mulDiv(@as(u64, 12), 1, 3, .up));
    try std.testing.expectEqual(@as(u64, 3), try mulDiv(@as(u64, 7), 1, 2, .down));
    try std.testing.expectEqual(@as(u64, 4), try mulDiv(@as(u64, 7), 1, 2, .up));
    try std.testing.expectEqual(@as(u64, 0), try mulDiv(@as(u64, 0), 9, 7, .up));
    try std.testing.expectEqual(@as(u64, 1), try mulDiv(@as(u64, 1), 1, std.math.maxInt(u64), .up));
    try std.testing.expectError(
        error.ArithmeticOverflow,
        mulDiv(@as(u8, 254), 202, 201, .up),
    );
}

test "math: fee helpers use explicit denominators and rounding" {
    try std.testing.expectEqual(@as(u64, 123), try feeAmountBps(@as(u64, 12_300), 100, .down));
    try std.testing.expectEqual(@as(u64, 124), try feeAmountBps(@as(u64, 12_301), 100, .up));
    try std.testing.expectEqual(@as(u64, 250), try feeAmountPpm(@as(u64, 1_000_000), 250, .down));
    try std.testing.expectEqual(@as(u64, 251), try feeAmountPpm(@as(u64, 1_000_001), 250, .up));
    try std.testing.expectError(error.InvalidArgument, feeAmountBps(@as(u64, 100), 10_001, .down));
    try std.testing.expectError(error.InvalidArgument, feeAmountPpm(@as(u64, 100), 1_000_001, .up));
}

test "math: amountAfterFee rejects underflow and allows exact full fee" {
    try std.testing.expectEqual(@as(u64, 0), try amountAfterFeeBps(@as(u64, 50), 10_000, .down));
    try std.testing.expectEqual(@as(u64, 9), try amountAfterFee(@as(u64, 10), 1, 10, .down));
    try std.testing.expectError(error.InvalidArgument, amountAfterFee(@as(u64, 10), 11, 10, .down));
}

test "math: min-out and slippage checks accept equality and reject below threshold" {
    try requireMinOut(@as(u64, 50), 50);
    try std.testing.expectError(error.SlippageExceeded, requireMinOut(@as(u64, 49), 50));
    try requireMinOut(@as(u64, 0), 0);
    try std.testing.expectError(error.SlippageExceeded, requireMinOut(@as(u64, 0), 1));

    try requireSlippageBps(@as(u64, 95), 100, 500, .down);
    try std.testing.expectError(error.SlippageExceeded, requireSlippageBps(@as(u64, 94), 100, 500, .down));
    try requireSlippageBps(@as(u64, 0), 0, 500, .down);
    try requireSlippagePpm(@as(u64, 1_000_000), 1_000_000, 0, .down);
}

test "math: derived slippage thresholds use checked math" {
    try std.testing.expectEqual(@as(u64, 95), try deriveMinOutBps(@as(u64, 100), 500, .down));
    try std.testing.expectEqual(@as(u64, 999_000), try deriveMinOutPpm(@as(u64, 1_000_000), 1_000, .down));
    try std.testing.expectEqual(@as(u64, 106), try deriveSlippageThresholdBps(@as(u64, 100), 550, .max_in, .up));
    try std.testing.expectError(
        error.ArithmeticOverflow,
        deriveSlippageThreshold(@as(u64, std.math.maxInt(u64)), 1, 1, .max_in, .up),
    );
}
