pub const pubkey = @import("../pubkey/root.zig");
pub const account_mod = @import("../account/root.zig");
pub const program_error = @import("../program_error/root.zig");
pub const clock_mod = @import("../clock.zig");
pub const rent_mod = @import("../rent.zig");
pub const bpf = @import("../bpf.zig");
pub const log = @import("../log/root.zig");

pub const Pubkey = pubkey.Pubkey;
pub const AccountInfo = account_mod.AccountInfo;
pub const ProgramError = program_error.ProgramError;

/// Clock sysvar — re-exported from `clock.zig` so it is the single
/// canonical type in the SDK.
pub const Clock = clock_mod.Clock;

/// Rent sysvar data — re-exported from `rent.zig`.
pub const Rent = rent_mod.Rent.Data;

/// Clock sysvar ID
pub const CLOCK_ID: Pubkey = pubkey.comptimeFromBase58("SysvarC1ock11111111111111111111111111111111");

/// Rent sysvar ID
pub const RENT_ID: Pubkey = pubkey.comptimeFromBase58("SysvarRent111111111111111111111111111111111");

/// Epoch schedule sysvar ID
pub const EPOCH_SCHEDULE_ID: Pubkey = pubkey.comptimeFromBase58("SysvarEpochSchedu1e111111111111111111111111");

/// Slot hashes sysvar ID
pub const SLOT_HASHES_ID: Pubkey = pubkey.comptimeFromBase58("SysvarS1otHashes111111111111111111111111111");

/// Stake history sysvar ID
pub const STAKE_HISTORY_ID: Pubkey = pubkey.comptimeFromBase58("SysvarStakeHistory1111111111111111111111111");

/// Instructions sysvar ID
pub const INSTRUCTIONS_ID: Pubkey = pubkey.comptimeFromBase58("Sysvar1nstructions1111111111111111111111111");
