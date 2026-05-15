const shared = @import("shared.zig");
const log = shared.log;
const ProgramError = shared.ProgramError;
const bpf = shared.bpf;

/// Epoch schedule sysvar.
///
/// Use `EpochSchedule.get()` to read this via syscall (no account
/// required). The layout matches the runtime's serialized form.
pub const EpochSchedule = extern struct {
    /// The maximum number of slots in each epoch
    slots_per_epoch: u64,
    /// A number of slots before beginning of an epoch to calculate
    /// a leader schedule for that epoch
    leader_schedule_slot_offset: u64,
    /// Whether epochs start short and grow
    warmup: bool,
    /// The first epoch after the warmup period
    first_normal_epoch: u64,
    /// The first slot after the warmup period
    first_normal_slot: u64,

    /// Read the epoch schedule via syscall. Returns
    /// `error.UnsupportedSysvar` if the runtime rejects the call or
    /// when running off-chain without the syscall surface.
    pub fn get() ProgramError!EpochSchedule {
        var es: EpochSchedule = undefined;
        if (bpf.is_bpf_program) {
            const Syscall = struct {
                extern fn sol_get_epoch_schedule_sysvar(ptr: *EpochSchedule) callconv(.c) u64;
            };
            const rc = Syscall.sol_get_epoch_schedule_sysvar(&es);
            if (rc != 0) {
                log.print("failed to get epoch_schedule sysvar: {d}", .{rc});
                return ProgramError.UnsupportedSysvar;
            }
        } else {
            log.log("cannot get epoch_schedule sysvar in non-bpf context");
            return error.UnsupportedSysvar;
        }
        return es;
    }
};

/// LastRestartSlot sysvar — exposes the slot at which the cluster
/// most recently restarted. Useful for time-sensitive program logic
/// that needs to detect a restart event.
pub const LastRestartSlot = extern struct {
    /// The last slot at which the cluster was restarted; `0` means
    /// no restart has occurred since the genesis epoch.
    last_restart_slot: u64,

    pub fn get() ProgramError!LastRestartSlot {
        var v: LastRestartSlot = undefined;
        if (bpf.is_bpf_program) {
            const Syscall = struct {
                extern fn sol_get_last_restart_slot(ptr: *LastRestartSlot) callconv(.c) u64;
            };
            const rc = Syscall.sol_get_last_restart_slot(&v);
            if (rc != 0) {
                log.print("failed to get last_restart_slot sysvar: {d}", .{rc});
                return ProgramError.UnsupportedSysvar;
            }
        } else {
            log.log("cannot get last_restart_slot sysvar in non-bpf context");
            return error.UnsupportedSysvar;
        }
        return v;
    }
};

/// EpochRewards sysvar — exposed during epoch-rewards distribution
/// (rare). Read via syscall.
pub const EpochRewards = extern struct {
    /// Total rewards for the current epoch, in lamports.
    distribution_starting_block_height: u64,
    /// Number of partitions in the rewards distribution.
    num_partitions: u64,
    /// Hash of the parent block at the start of distribution.
    parent_blockhash: [32]u8,
    /// Lamports remaining to be distributed.
    total_points: u128,
    /// Total rewards for current epoch, in lamports.
    total_rewards: u64,
    /// Distributed rewards so far, in lamports.
    distributed_rewards: u64,
    /// Whether the rewards period is currently active.
    active: bool,

    pub fn get() ProgramError!EpochRewards {
        var v: EpochRewards = undefined;
        if (bpf.is_bpf_program) {
            const Syscall = struct {
                extern fn sol_get_epoch_rewards_sysvar(ptr: *EpochRewards) callconv(.c) u64;
            };
            const rc = Syscall.sol_get_epoch_rewards_sysvar(&v);
            if (rc != 0) {
                log.print("failed to get epoch_rewards sysvar: {d}", .{rc});
                return ProgramError.UnsupportedSysvar;
            }
        } else {
            log.log("cannot get epoch_rewards sysvar in non-bpf context");
            return error.UnsupportedSysvar;
        }
        return v;
    }
};

/// Slot hash entry
pub const SlotHash = extern struct {
    slot: u64,
    hash: [32]u8,
};

test "typed sysvars: host getters return UnsupportedSysvar" {
    const testing = @import("std").testing;
    try testing.expectError(error.UnsupportedSysvar, EpochSchedule.get());
    try testing.expectError(error.UnsupportedSysvar, LastRestartSlot.get());
    try testing.expectError(error.UnsupportedSysvar, EpochRewards.get());
}
