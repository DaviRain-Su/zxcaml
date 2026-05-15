const shared = @import("shared.zig");

const is_solana = shared.is_solana;

extern fn sol_get_stack_height() callconv(.c) u64;

/// Stack height assigned to instructions that appear in the transaction
/// message itself (i.e. not invoked via CPI). Higher values mean deeper
/// nesting.
pub const TRANSACTION_LEVEL_STACK_HEIGHT: u64 = 1;

/// Returns the current invocation's stack height.
///
/// On non-Solana hosts always returns `0` (matches the upstream stub).
pub inline fn getStackHeight() u64 {
    if (comptime !is_solana) return 0;
    return sol_get_stack_height();
}
