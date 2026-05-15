//! Sysvar accessors for Solana programs
//!
//! Two access patterns:
//!
//! 1. **Syscall-based** (`Sysvar.get()`): no account-list entry
//!    required, ~250-300 CU per call. Available for: Clock, Rent,
//!    EpochSchedule, LastRestartSlot, EpochRewards.
//!
//! 2. **Account-based** (`getSysvarRef(T, account)` / `getSysvar(T, account)`):
//!    caller must pass the sysvar account in the instruction's `accounts`.
//!    `getSysvarRef` gives a zero-copy typed view over the account bytes;
//!    `getSysvar` copies that typed value out when ownership-by-value is
//!    more convenient.
//!
//! Choose syscalls when you can — they're cheaper and remove a
//! constraint on the client (no need to list the sysvar account).
//!
//! Physical layout:
//! - `shared.zig` — common imports, aliases, re-exported types, sysvar IDs
//! - `account_access.zig` — zero-copy / copy-returning account-based readers
//! - `syscall_access.zig` — generic `sol_get_sysvar` byte-slice access
//! - `typed.zig` — typed syscall-backed sysvar structs and `get()` helpers
//!
//! The public API stays flattened as `sol.sysvar.*`.

const std = @import("std");
const shared = @import("shared.zig");
const account_mod = shared.account_mod;
const clock_mod = shared.clock_mod;
const rent_mod = shared.rent_mod;
const Pubkey = shared.Pubkey;
const AccountInfo = shared.AccountInfo;
const ProgramError = shared.ProgramError;
const access_mod = @import("account_access.zig");
const syscall_access_mod = @import("syscall_access.zig");
const typed_mod = @import("typed.zig");

/// Re-exported syscall-backed sysvar types and canonical IDs.
pub const Clock = shared.Clock;
pub const Rent = shared.Rent;
pub const CLOCK_ID = shared.CLOCK_ID;
pub const RENT_ID = shared.RENT_ID;
pub const EPOCH_SCHEDULE_ID = shared.EPOCH_SCHEDULE_ID;
pub const SLOT_HASHES_ID = shared.SLOT_HASHES_ID;
pub const STAKE_HISTORY_ID = shared.STAKE_HISTORY_ID;
pub const INSTRUCTIONS_ID = shared.INSTRUCTIONS_ID;

/// Account-based and generic byte-slice sysvar readers.
pub const getSysvarRef = access_mod.getSysvarRef;
pub const getSysvar = access_mod.getSysvar;
pub const getSysvarBytes = syscall_access_mod.getSysvarBytes;

/// Typed syscall-backed layouts beyond Clock / Rent.
pub const EpochSchedule = typed_mod.EpochSchedule;
pub const LastRestartSlot = typed_mod.LastRestartSlot;
pub const EpochRewards = typed_mod.EpochRewards;
pub const SlotHash = typed_mod.SlotHash;

// =============================================================================
// Tests
// =============================================================================

test "sysvar: Clock re-export points to clock.Clock" {
    try std.testing.expectEqual(@sizeOf(clock_mod.Clock), @sizeOf(Clock));
}

test "sysvar: Rent re-export points to rent.Rent.Data" {
    const r: Rent = .{};
    try std.testing.expect(r.lamports_per_byte_year > 0);
}

test "sysvar: EpochSchedule layout is 33 bytes" {
    // u64 + u64 + bool(1) + u64 + u64 = 33 (no padding because
    // extern struct uses C layout and bool is 1 byte). When laid out
    // for the syscall buffer the runtime sends the packed form.
    try std.testing.expect(@sizeOf(EpochSchedule) >= 33);
}

test "sysvar: LastRestartSlot is a single u64" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(LastRestartSlot));
}

test "sysvar: getSysvarBytes returns InvalidArgument when dst is too small" {
    const sid: Pubkey = .{0} ** 32;
    var buf: [4]u8 = undefined;
    try std.testing.expectError(
        ProgramError.InvalidArgument,
        getSysvarBytes(&buf, &sid, 0, 8),
    );
}

test "sysvar: getSysvarBytes on host returns UnsupportedSysvar" {
    const sid: Pubkey = .{0} ** 32;
    var buf: [8]u8 = undefined;
    try std.testing.expectError(
        ProgramError.UnsupportedSysvar,
        getSysvarBytes(&buf, &sid, 0, 8),
    );
}

test "sysvar: EpochRewards layout has expected fields" {
    const er: EpochRewards = .{
        .distribution_starting_block_height = 0,
        .num_partitions = 0,
        .parent_blockhash = .{0} ** 32,
        .total_points = 0,
        .total_rewards = 0,
        .distributed_rewards = 0,
        .active = false,
    };
    try std.testing.expectEqual(@as(u64, 0), er.total_rewards);
}

const TestSysvarBuf = struct {
    bytes: [@sizeOf(account_mod.Account) + 128]u8 align(8),

    fn init(comptime T: type, value: T) TestSysvarBuf {
        var self: TestSysvarBuf = .{ .bytes = .{0} ** (@sizeOf(account_mod.Account) + 128) };
        const acc: *account_mod.Account = @ptrCast(&self.bytes);
        acc.* = .{
            .borrow_state = account_mod.NOT_BORROWED,
            .is_signer = 0,
            .is_writable = 0,
            .is_executable = 0,
            ._padding = .{0} ** 4,
            .key = .{0} ** 32,
            .owner = .{0} ** 32,
            .lamports = 0,
            .data_len = @sizeOf(T),
        };
        const data_ptr: [*]u8 = @ptrFromInt(@intFromPtr(acc) + @sizeOf(account_mod.Account));
        @memcpy(data_ptr[0..@sizeOf(T)], std.mem.asBytes(&value));
        return self;
    }

    fn info(self: *TestSysvarBuf) AccountInfo {
        return .{ .raw = @ptrCast(&self.bytes) };
    }
};

test "sysvar: getSysvarRef returns zero-copy typed view" {
    const original = EpochSchedule{
        .slots_per_epoch = 432_000,
        .leader_schedule_slot_offset = 432_000,
        .warmup = false,
        .first_normal_epoch = 14,
        .first_normal_slot = 999,
    };
    var buf = TestSysvarBuf.init(EpochSchedule, original);
    const info = buf.info();

    const ref = try getSysvarRef(EpochSchedule, info);
    try std.testing.expectEqual(@as(u64, 432_000), ref.slots_per_epoch);
    try std.testing.expectEqual(@as(bool, false), ref.warmup);

    const copy = try getSysvar(EpochSchedule, info);
    try std.testing.expectEqual(ref.*, copy);

    const mut = info.dataAs(EpochSchedule);
    mut.warmup = true;
    mut.first_normal_slot = 12345;

    try std.testing.expectEqual(@as(bool, true), ref.warmup);
    try std.testing.expectEqual(@as(u64, 12345), ref.first_normal_slot);
    try std.testing.expectEqual(@as(bool, false), copy.warmup);
    try std.testing.expectEqual(@as(u64, 999), copy.first_normal_slot);
}

test "sysvar: getSysvarRef errors when account data is too small" {
    var buf = TestSysvarBuf.init(u32, 7);
    try std.testing.expectError(
        ProgramError.InvalidAccountData,
        getSysvarRef(EpochSchedule, buf.info()),
    );
}
