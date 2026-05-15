//! Stake-related on-chain queries.
//!
//! Currently exposes a single syscall: `sol_get_epoch_stake`, which
//! returns a vote account's *active* delegated stake for the current
//! epoch. This is the same number the runtime uses to weight the
//! vote-account's contribution to consensus.
//!
//! The historical / per-epoch data lives in the `StakeHistory` sysvar
//! (see `src/stake_history/root.zig`); this module is for the
//! "right now, this epoch" view that the syscall makes free for
//! programs to read.
//!
//! Typical use cases:
//!
//!   - Validator-restaking / LST programs that need to verify a
//!     delegation amount against the canonical runtime value.
//!   - Snapshot-style oracles publishing a vote-account weight.

const std = @import("std");
const builtin = @import("builtin");
const pubkey = @import("pubkey/root.zig");

const Pubkey = pubkey.Pubkey;

const is_solana = builtin.os.tag == .freestanding and builtin.cpu.arch == .bpfel;

extern fn sol_get_epoch_stake(vote_address: *const u8) callconv(.c) u64;

/// Active stake (lamports) delegated to `vote_address` for the
/// current epoch.
///
/// Returns `0` if:
///   - the address isn't a vote account, or
///   - it has no active stake this epoch.
///
/// On host (non-BPF), always returns `0` — there's no global runtime
/// state to query.
///
/// The syscall itself is ~250 CU per the current pricing table.
pub fn getEpochStake(vote_address: *const Pubkey) u64 {
    if (is_solana) {
        return sol_get_epoch_stake(@as(*const u8, @ptrCast(vote_address)));
    } else {
        return 0;
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "stake: host stub returns zero" {
    const vote: Pubkey = .{0} ** 32;
    try testing.expectEqual(@as(u64, 0), getEpochStake(&vote));
}
