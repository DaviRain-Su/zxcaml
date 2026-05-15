//! `StakeHistory` sysvar accessor.
//!
//! Unlike Clock / Rent / EpochSchedule, the stake-history sysvar has
//! no direct syscall. Reading it requires the caller to pass the
//! sysvar account as part of the instruction's account list, after
//! which the SDK parses the account data zero-copy.
//!
//! Physical layout:
//! - `shared.zig` — imports and shared aliases
//! - `model.zig` — `MAX_ENTRIES` and `Entry`
//! - `view.zig` — `StakeHistory` parsing and lookup helpers
//!
//! The public API stays flattened as `sol.stake_history.*`.

const std = @import("std");
const model = @import("model.zig");
const view = @import("view.zig");

/// Stake-history wire-layout constants and entry model.
pub const MAX_ENTRIES = model.MAX_ENTRIES;
pub const Entry = model.Entry;

/// Zero-copy stake-history account view.
pub const StakeHistory = view.StakeHistory;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "stake_history: Entry layout is 32 bytes" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(Entry));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Entry, "epoch"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Entry, "effective"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Entry, "activating"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Entry, "deactivating"));
}

test "stake_history: get finds entries by binary search" {
    const entries = [_]Entry{
        .{ .epoch = 10, .effective = 100, .activating = 0, .deactivating = 0 },
        .{ .epoch = 7, .effective = 70, .activating = 5, .deactivating = 0 },
        .{ .epoch = 5, .effective = 50, .activating = 0, .deactivating = 10 },
        .{ .epoch = 2, .effective = 20, .activating = 0, .deactivating = 0 },
    };
    const sh: StakeHistory = .{ .entries = &entries };

    try testing.expectEqual(@as(?Entry, entries[0]), sh.get(10));
    try testing.expectEqual(@as(?Entry, entries[1]), sh.get(7));
    try testing.expectEqual(@as(?Entry, entries[2]), sh.get(5));
    try testing.expectEqual(@as(?Entry, entries[3]), sh.get(2));
    try testing.expectEqual(@as(?Entry, null), sh.get(0));
    try testing.expectEqual(@as(?Entry, null), sh.get(3));
    try testing.expectEqual(@as(?Entry, null), sh.get(11));
}

test "stake_history: latest returns the highest-epoch entry" {
    const entries = [_]Entry{
        .{ .epoch = 100, .effective = 1, .activating = 0, .deactivating = 0 },
        .{ .epoch = 50, .effective = 2, .activating = 0, .deactivating = 0 },
    };
    const sh: StakeHistory = .{ .entries = &entries };
    try testing.expectEqual(@as(u64, 100), sh.latest().?.epoch);

    const empty: StakeHistory = .{ .entries = &.{} };
    try testing.expectEqual(@as(?Entry, null), empty.latest());
}
