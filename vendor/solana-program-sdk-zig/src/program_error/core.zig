const std = @import("std");

/// Reasons a program may fail. Variants and order match
/// `solana_program_error::ProgramError` 3.x so the on-wire u64 codes
/// agree with Rust programs.
pub const ProgramError = error{
    /// `Custom(0)` — programs use this for their own error 0. The
    /// runtime treats raw `0` as success, so we encode this as the
    /// sentinel `1 << 32` (`CUSTOM_ZERO`). For any non-zero custom
    /// code, use `customError(code)` directly instead of this variant.
    Custom,
    InvalidArgument,
    InvalidInstructionData,
    InvalidAccountData,
    AccountDataTooSmall,
    InsufficientFunds,
    IncorrectProgramId,
    MissingRequiredSignature,
    AccountAlreadyInitialized,
    UninitializedAccount,
    NotEnoughAccountKeys,
    AccountBorrowFailed,
    MaxSeedLengthExceeded,
    InvalidSeeds,
    BorshIoError,
    AccountNotRentExempt,
    UnsupportedSysvar,
    IllegalOwner,
    MaxAccountsDataAllocationsExceeded,
    InvalidRealloc,
    MaxInstructionTraceLengthExceeded,
    BuiltinProgramsMustConsumeComputeUnits,
    InvalidAccountOwner,
    ArithmeticOverflow,
    ImmutableAccount,
    IncorrectAuthority,
};

/// Success return value (raw u64 returned by the entrypoint).
pub const SUCCESS: u64 = 0;

/// Bit shift applied to builtin error codes (matches Rust's
/// `BUILTIN_BIT_SHIFT`).
pub const BUILTIN_BIT_SHIFT: u6 = 32;

/// `Custom(0)` sentinel — `0` itself means success.
pub const CUSTOM_ZERO: u64 = 1 << BUILTIN_BIT_SHIFT;

/// Compute a builtin code at compile time.
inline fn builtin(comptime n: u64) u64 {
    return n << BUILTIN_BIT_SHIFT;
}

// Builtin codes (kept as `pub const` so downstream code can compare or
// log them without re-shifting).
pub const INVALID_ARGUMENT: u64 = builtin(2);
pub const INVALID_INSTRUCTION_DATA: u64 = builtin(3);
pub const INVALID_ACCOUNT_DATA: u64 = builtin(4);
pub const ACCOUNT_DATA_TOO_SMALL: u64 = builtin(5);
pub const INSUFFICIENT_FUNDS: u64 = builtin(6);
pub const INCORRECT_PROGRAM_ID: u64 = builtin(7);
pub const MISSING_REQUIRED_SIGNATURES: u64 = builtin(8);
pub const ACCOUNT_ALREADY_INITIALIZED: u64 = builtin(9);
pub const UNINITIALIZED_ACCOUNT: u64 = builtin(10);
pub const NOT_ENOUGH_ACCOUNT_KEYS: u64 = builtin(11);
pub const ACCOUNT_BORROW_FAILED: u64 = builtin(12);
pub const MAX_SEED_LENGTH_EXCEEDED: u64 = builtin(13);
pub const INVALID_SEEDS: u64 = builtin(14);
pub const BORSH_IO_ERROR: u64 = builtin(15);
pub const ACCOUNT_NOT_RENT_EXEMPT: u64 = builtin(16);
pub const UNSUPPORTED_SYSVAR: u64 = builtin(17);
pub const ILLEGAL_OWNER: u64 = builtin(18);
pub const MAX_ACCOUNTS_DATA_ALLOCATIONS_EXCEEDED: u64 = builtin(19);
pub const INVALID_ACCOUNT_DATA_REALLOC: u64 = builtin(20);
pub const MAX_INSTRUCTION_TRACE_LENGTH_EXCEEDED: u64 = builtin(21);
pub const BUILTIN_PROGRAMS_MUST_CONSUME_COMPUTE_UNITS: u64 = builtin(22);
pub const INVALID_ACCOUNT_OWNER: u64 = builtin(23);
pub const ARITHMETIC_OVERFLOW: u64 = builtin(24);
pub const IMMUTABLE: u64 = builtin(25);
pub const INCORRECT_AUTHORITY: u64 = builtin(26);

/// Program result type — either success or a ProgramError
pub const ProgramResult = ProgramError!void;

/// Encode a custom error code into the runtime's u64 wire format.
///
/// Code `0` collides with `SUCCESS`, so the runtime reserves
/// `CUSTOM_ZERO` for it. Any non-zero `u32` is passed through as-is.
pub inline fn customError(code: u32) u64 {
    return if (code == 0) CUSTOM_ZERO else @as(u64, code);
}
