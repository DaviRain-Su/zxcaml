//! Branch prediction hints for CU optimization
//!
//! These hints help the compiler generate more efficient branch instructions,
//! reducing compute unit consumption for hot paths.
//!
//! Usage:
//! ```zig
//! if (hint.likely(account.isSigner())) {
//!     // Fast path - optimized for likely case
//! } else {
//!     // Slow path
//! }
//! ```

/// Cold path hint - marks the current branch as unlikely to execute.
pub inline fn coldPath() void {
    @branchHint(.cold);
}

/// Returns the given bool with a hint that `true` is the likely case.
///
/// Use this for branches where the true case is expected to execute
/// most of the time (e.g., success checks, valid input).
pub inline fn likely(b: bool) bool {
    if (!b) {
        @branchHint(.cold);
        return false;
    }
    return true;
}

/// Returns the given bool with a hint that `false` is the likely case.
///
/// Use this for branches where the false case is expected to execute
/// most of the time (e.g., error checks, edge cases).
pub inline fn unlikely(b: bool) bool {
    if (b) {
        coldPath();
        return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

test "hint: likely" {
    try @import("std").testing.expect(likely(true));
    try @import("std").testing.expect(!likely(false));
}

test "hint: unlikely" {
    try @import("std").testing.expect(unlikely(true));
    try @import("std").testing.expect(!unlikely(false));
}

test "hint: cold path" {
    coldPath();
}
