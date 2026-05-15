//! Standard program error types.
//!
//! ABI-compatible with `solana_program_error::ProgramError` (crate
//! `solana-program-error` 3.x). On entrypoint return / CPI propagation
//! the Solana runtime expects the code as a u64 in the canonical
//! encoding:
//!
//! - Builtin variants occupy the upper 32 bits: `(N << 32)` for the
//!   N-th builtin (matching Rust's `BUILTIN_BIT_SHIFT = 32`).
//! - `Custom(code)` returns `code` directly, except `Custom(0)` which
//!   collides with `SUCCESS` and is mapped to the sentinel `1 << 32`
//!   (`CUSTOM_ZERO`).
//!
//! Physical layout:
//! - `core.zig` — error set, wire constants, and result aliases
//! - `codec.zig` — `ProgramError` ↔ runtime `u64` conversion
//! - `diagnostics.zig` — failure-path logging helpers (`fail`, `failFmt`)
//!
//! The public API stays flattened as `sol.program_error.*`, with the
//! top-level aliases `sol.ProgramError`, `sol.ProgramResult`, `sol.SUCCESS`,
//! `sol.fail(...)`, and `sol.failFmt(...)` preserved at `src/root.zig`.
//!
//! See: <https://docs.rs/solana-program-error/latest/src/solana_program_error/lib.rs.html>

const std = @import("std");
const core_mod = @import("core.zig");
const codec_mod = @import("codec.zig");
const diagnostics_mod = @import("diagnostics.zig");

/// Program error set, wire-format constants, and result aliases.
pub const ProgramError = core_mod.ProgramError;
pub const SUCCESS = core_mod.SUCCESS;
pub const BUILTIN_BIT_SHIFT = core_mod.BUILTIN_BIT_SHIFT;
pub const CUSTOM_ZERO = core_mod.CUSTOM_ZERO;
pub const INVALID_ARGUMENT = core_mod.INVALID_ARGUMENT;
pub const INVALID_INSTRUCTION_DATA = core_mod.INVALID_INSTRUCTION_DATA;
pub const INVALID_ACCOUNT_DATA = core_mod.INVALID_ACCOUNT_DATA;
pub const ACCOUNT_DATA_TOO_SMALL = core_mod.ACCOUNT_DATA_TOO_SMALL;
pub const INSUFFICIENT_FUNDS = core_mod.INSUFFICIENT_FUNDS;
pub const INCORRECT_PROGRAM_ID = core_mod.INCORRECT_PROGRAM_ID;
pub const MISSING_REQUIRED_SIGNATURES = core_mod.MISSING_REQUIRED_SIGNATURES;
pub const ACCOUNT_ALREADY_INITIALIZED = core_mod.ACCOUNT_ALREADY_INITIALIZED;
pub const UNINITIALIZED_ACCOUNT = core_mod.UNINITIALIZED_ACCOUNT;
pub const NOT_ENOUGH_ACCOUNT_KEYS = core_mod.NOT_ENOUGH_ACCOUNT_KEYS;
pub const ACCOUNT_BORROW_FAILED = core_mod.ACCOUNT_BORROW_FAILED;
pub const MAX_SEED_LENGTH_EXCEEDED = core_mod.MAX_SEED_LENGTH_EXCEEDED;
pub const INVALID_SEEDS = core_mod.INVALID_SEEDS;
pub const BORSH_IO_ERROR = core_mod.BORSH_IO_ERROR;
pub const ACCOUNT_NOT_RENT_EXEMPT = core_mod.ACCOUNT_NOT_RENT_EXEMPT;
pub const UNSUPPORTED_SYSVAR = core_mod.UNSUPPORTED_SYSVAR;
pub const ILLEGAL_OWNER = core_mod.ILLEGAL_OWNER;
pub const MAX_ACCOUNTS_DATA_ALLOCATIONS_EXCEEDED = core_mod.MAX_ACCOUNTS_DATA_ALLOCATIONS_EXCEEDED;
pub const INVALID_ACCOUNT_DATA_REALLOC = core_mod.INVALID_ACCOUNT_DATA_REALLOC;
pub const MAX_INSTRUCTION_TRACE_LENGTH_EXCEEDED = core_mod.MAX_INSTRUCTION_TRACE_LENGTH_EXCEEDED;
pub const BUILTIN_PROGRAMS_MUST_CONSUME_COMPUTE_UNITS = core_mod.BUILTIN_PROGRAMS_MUST_CONSUME_COMPUTE_UNITS;
pub const INVALID_ACCOUNT_OWNER = core_mod.INVALID_ACCOUNT_OWNER;
pub const ARITHMETIC_OVERFLOW = core_mod.ARITHMETIC_OVERFLOW;
pub const IMMUTABLE = core_mod.IMMUTABLE;
pub const INCORRECT_AUTHORITY = core_mod.INCORRECT_AUTHORITY;
pub const ProgramResult = core_mod.ProgramResult;
pub const customError = core_mod.customError;

/// ProgramError ↔ runtime u64 wire-code conversion.
pub const errorToU64 = codec_mod.errorToU64;
pub const u64ToError = codec_mod.u64ToError;

/// Failure-path diagnostic helpers.
pub const fail = diagnostics_mod.fail;
pub const failFmt = diagnostics_mod.failFmt;
const basename = diagnostics_mod.basename;

// =============================================================================
// Tests
// =============================================================================

test "program_error: builtin codes match Solana ABI" {
    // Spot-check against known builtin codes (see Rust source).
    try std.testing.expectEqual(@as(u64, 1 << 32), CUSTOM_ZERO);
    try std.testing.expectEqual(@as(u64, 2 << 32), INVALID_ARGUMENT);
    try std.testing.expectEqual(@as(u64, 7 << 32), INCORRECT_PROGRAM_ID);
    try std.testing.expectEqual(@as(u64, 11 << 32), NOT_ENOUGH_ACCOUNT_KEYS);
    try std.testing.expectEqual(@as(u64, 24 << 32), ARITHMETIC_OVERFLOW);
}

test "program_error: errorToU64 / u64ToError roundtrip" {
    const errors = [_]ProgramError{
        ProgramError.Custom,
        ProgramError.InvalidArgument,
        ProgramError.InvalidInstructionData,
        ProgramError.InvalidAccountData,
        ProgramError.AccountDataTooSmall,
        ProgramError.InsufficientFunds,
        ProgramError.IncorrectProgramId,
        ProgramError.MissingRequiredSignature,
        ProgramError.AccountAlreadyInitialized,
        ProgramError.UninitializedAccount,
        ProgramError.NotEnoughAccountKeys,
        ProgramError.AccountBorrowFailed,
        ProgramError.MaxSeedLengthExceeded,
        ProgramError.InvalidSeeds,
        ProgramError.BorshIoError,
        ProgramError.AccountNotRentExempt,
        ProgramError.UnsupportedSysvar,
        ProgramError.IllegalOwner,
        ProgramError.MaxAccountsDataAllocationsExceeded,
        ProgramError.InvalidRealloc,
        ProgramError.MaxInstructionTraceLengthExceeded,
        ProgramError.BuiltinProgramsMustConsumeComputeUnits,
        ProgramError.InvalidAccountOwner,
        ProgramError.ArithmeticOverflow,
        ProgramError.ImmutableAccount,
        ProgramError.IncorrectAuthority,
    };

    for (errors) |err| {
        try std.testing.expectEqual(err, u64ToError(errorToU64(err)));
    }
}

test "program_error: customError encodes Custom(0) as sentinel" {
    try std.testing.expectEqual(CUSTOM_ZERO, customError(0));
    try std.testing.expectEqual(@as(u64, 42), customError(42));
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF), customError(0xFFFF_FFFF));
}

test "program_error: fail returns the supplied error" {
    const got = fail(@src(), "test:tag", ProgramError.InvalidArgument);
    try std.testing.expectEqual(ProgramError.InvalidArgument, got);
}

test "program_error: failFmt returns the supplied error" {
    const got = failFmt(@src(), "test:tag", "x={d}", .{42}, ProgramError.IncorrectAuthority);
    try std.testing.expectEqual(ProgramError.IncorrectAuthority, got);
}

test "program_error: basename strips path" {
    try std.testing.expectEqualStrings("file.zig", basename("/a/b/c/file.zig"));
    try std.testing.expectEqualStrings("file.zig", basename("file.zig"));
    try std.testing.expectEqualStrings("file.zig", basename("c:\\foo\\file.zig"));
}
