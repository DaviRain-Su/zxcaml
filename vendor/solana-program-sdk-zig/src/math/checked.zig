const std = @import("std");
const shared = @import("shared.zig");
const ProgramError = shared.ProgramError;

// =============================================================================
// Addition
// =============================================================================

/// Wrapping add. Equivalent to `a +% b`. Use when the caller has
/// already proven non-overflow (e.g. comptime bounded operands).
pub inline fn addUnchecked(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return a +% b;
}

/// Checked add. Returns `null` on overflow.
///
/// ```zig
/// const new_balance = sol.math.tryAdd(balance, amount)
///     orelse return error.ArithmeticOverflow;
/// ```
pub inline fn tryAdd(a: anytype, b: @TypeOf(a)) ?@TypeOf(a) {
    const result, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return null;
    return result;
}

/// Checked add. Returns `ProgramError.ArithmeticOverflow` on overflow.
///
/// ```zig
/// const new_balance = try sol.math.add(balance, amount);
/// ```
pub inline fn add(a: anytype, b: @TypeOf(a)) ProgramError!@TypeOf(a) {
    return tryAdd(a, b) orelse error.ArithmeticOverflow;
}

// =============================================================================
// Subtraction
// =============================================================================

/// Wrapping sub. Equivalent to `a -% b`.
pub inline fn subUnchecked(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return a -% b;
}

/// Checked sub. Returns `null` on underflow.
pub inline fn trySub(a: anytype, b: @TypeOf(a)) ?@TypeOf(a) {
    const result, const overflow = @subWithOverflow(a, b);
    if (overflow != 0) return null;
    return result;
}

/// Checked sub. Returns `ProgramError.ArithmeticOverflow` on underflow.
/// We reuse `ArithmeticOverflow` for under/overflow alike — the
/// Solana runtime defines exactly one variant for this case.
pub inline fn sub(a: anytype, b: @TypeOf(a)) ProgramError!@TypeOf(a) {
    return trySub(a, b) orelse error.ArithmeticOverflow;
}

// =============================================================================
// Multiplication
// =============================================================================

/// Wrapping mul. Equivalent to `a *% b`.
pub inline fn mulUnchecked(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return a *% b;
}

/// Checked mul. Returns `null` on overflow.
pub inline fn tryMul(a: anytype, b: @TypeOf(a)) ?@TypeOf(a) {
    const result, const overflow = @mulWithOverflow(a, b);
    if (overflow != 0) return null;
    return result;
}

/// Checked mul. Returns `ProgramError.ArithmeticOverflow` on overflow.
pub inline fn mul(a: anytype, b: @TypeOf(a)) ProgramError!@TypeOf(a) {
    return tryMul(a, b) orelse error.ArithmeticOverflow;
}
