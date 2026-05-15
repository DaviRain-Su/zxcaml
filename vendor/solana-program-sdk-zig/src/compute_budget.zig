//! Compute-budget introspection — `sol_remaining_compute_units` wrapper.
//!
//! On-chain programs are billed per BPF instruction (a few CU per op,
//! plus larger fixed costs for syscalls). `sol_remaining_compute_units`
//! lets a program query — without consuming any meaningful budget
//! itself — how many CU are left in the current transaction. Useful
//! for:
//!
//!   - Bailing out of a long loop before the runtime hard-aborts.
//!   - Choosing between a fast / slow path based on remaining budget.
//!   - Defensive logging in profilers / batch processors.
//!
//! The Rust SDK exposes this under `solana_program::compute_budget`,
//! so we mirror the namespace here for parity.

const std = @import("std");
const builtin = @import("builtin");
const is_bpf_program = @import("bpf.zig").is_bpf_program;

extern fn sol_remaining_compute_units() callconv(.c) u64;

pub const GuardError = error{ComputationalBudgetExceeded};

/// Remaining compute units in the current transaction.
///
/// On host, returns `std.math.maxInt(u64)` so test code can treat
/// "plenty of budget" as the default. On-chain, calls the syscall
/// directly — the syscall itself costs a fixed number of CU per the
/// runtime's pricing table (currently 1 CU).
pub fn remaining() u64 {
    if (is_bpf_program) {
        return sol_remaining_compute_units();
    } else {
        return std.math.maxInt(u64);
    }
}

/// Pure threshold predicate for host tests and caller-provided mocks.
pub inline fn hasAtLeast(remaining_units: u64, threshold: u64) bool {
    return remaining_units >= threshold;
}

/// Pure checked threshold helper.
pub inline fn requireAtLeast(remaining_units: u64, threshold: u64) GuardError!void {
    if (!hasAtLeast(remaining_units, threshold)) {
        return error.ComputationalBudgetExceeded;
    }
}

/// Query the current remaining CU and require at least `threshold`.
pub inline fn requireRemaining(threshold: u64) GuardError!void {
    return requireAtLeast(remaining(), threshold);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "compute_budget: host returns sentinel" {
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), remaining());
}

test "compute_budget: pure threshold semantics are exact" {
    try testing.expect(hasAtLeast(10, 10));
    try testing.expect(hasAtLeast(11, 10));
    try testing.expect(!hasAtLeast(9, 10));

    try requireAtLeast(10, 10);
    try requireAtLeast(11, 10);
    try testing.expectError(error.ComputationalBudgetExceeded, requireAtLeast(9, 10));
}

test "compute_budget: guard failure is side-effect-free for caller state" {
    const cpi = @import("cpi/root.zig");
    const account = @import("account/root.zig");

    var raw_a: account.Account = .{
        .borrow_state = account.NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0x11} ** 32,
        .owner = .{0x22} ** 32,
        .lamports = 1,
        .data_len = 0,
    };

    var metas: [1]cpi.AccountMeta = undefined;
    var infos: [1]account.CpiAccountInfo = undefined;
    var staging = cpi.CpiAccountStaging.init(metas[0..], infos[0..]);

    try staging.appendAccount(account.CpiAccountInfo.fromPtr(&raw_a));
    const meta_len = staging.accountMetas().len;
    const info_len = staging.accountInfos().len;

    try testing.expectError(error.ComputationalBudgetExceeded, requireAtLeast(99, 100));
    try testing.expectEqual(meta_len, staging.accountMetas().len);
    try testing.expectEqual(info_len, staging.accountInfos().len);
}

test "compute_budget: guard API supports pre-route and per-hop checks" {
    const route_threshold = 500;
    const hop_thresholds = [_]u64{ 250, 200, 125 };

    try requireAtLeast(500, route_threshold);
    inline for (hop_thresholds) |threshold| {
        try requireAtLeast(500, threshold);
    }

    try testing.expectError(error.ComputationalBudgetExceeded, requireAtLeast(199, 200));
}
