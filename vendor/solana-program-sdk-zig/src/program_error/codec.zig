const core = @import("core.zig");
const ProgramError = core.ProgramError;
const CUSTOM_ZERO = core.CUSTOM_ZERO;
const INVALID_ARGUMENT = core.INVALID_ARGUMENT;
const INVALID_INSTRUCTION_DATA = core.INVALID_INSTRUCTION_DATA;
const INVALID_ACCOUNT_DATA = core.INVALID_ACCOUNT_DATA;
const ACCOUNT_DATA_TOO_SMALL = core.ACCOUNT_DATA_TOO_SMALL;
const INSUFFICIENT_FUNDS = core.INSUFFICIENT_FUNDS;
const INCORRECT_PROGRAM_ID = core.INCORRECT_PROGRAM_ID;
const MISSING_REQUIRED_SIGNATURES = core.MISSING_REQUIRED_SIGNATURES;
const ACCOUNT_ALREADY_INITIALIZED = core.ACCOUNT_ALREADY_INITIALIZED;
const UNINITIALIZED_ACCOUNT = core.UNINITIALIZED_ACCOUNT;
const NOT_ENOUGH_ACCOUNT_KEYS = core.NOT_ENOUGH_ACCOUNT_KEYS;
const ACCOUNT_BORROW_FAILED = core.ACCOUNT_BORROW_FAILED;
const MAX_SEED_LENGTH_EXCEEDED = core.MAX_SEED_LENGTH_EXCEEDED;
const INVALID_SEEDS = core.INVALID_SEEDS;
const BORSH_IO_ERROR = core.BORSH_IO_ERROR;
const ACCOUNT_NOT_RENT_EXEMPT = core.ACCOUNT_NOT_RENT_EXEMPT;
const UNSUPPORTED_SYSVAR = core.UNSUPPORTED_SYSVAR;
const ILLEGAL_OWNER = core.ILLEGAL_OWNER;
const MAX_ACCOUNTS_DATA_ALLOCATIONS_EXCEEDED = core.MAX_ACCOUNTS_DATA_ALLOCATIONS_EXCEEDED;
const INVALID_ACCOUNT_DATA_REALLOC = core.INVALID_ACCOUNT_DATA_REALLOC;
const MAX_INSTRUCTION_TRACE_LENGTH_EXCEEDED = core.MAX_INSTRUCTION_TRACE_LENGTH_EXCEEDED;
const BUILTIN_PROGRAMS_MUST_CONSUME_COMPUTE_UNITS = core.BUILTIN_PROGRAMS_MUST_CONSUME_COMPUTE_UNITS;
const INVALID_ACCOUNT_OWNER = core.INVALID_ACCOUNT_OWNER;
const ARITHMETIC_OVERFLOW = core.ARITHMETIC_OVERFLOW;
const IMMUTABLE = core.IMMUTABLE;
const INCORRECT_AUTHORITY = core.INCORRECT_AUTHORITY;

/// Convert a `ProgramError` to the runtime's u64 wire format.
///
/// Uses `inline switch` so the resulting BPF code is a single
/// jump-table-like dispatch on the error tag.
pub inline fn errorToU64(err: ProgramError) u64 {
    return switch (err) {
        ProgramError.Custom => CUSTOM_ZERO,
        ProgramError.InvalidArgument => INVALID_ARGUMENT,
        ProgramError.InvalidInstructionData => INVALID_INSTRUCTION_DATA,
        ProgramError.InvalidAccountData => INVALID_ACCOUNT_DATA,
        ProgramError.AccountDataTooSmall => ACCOUNT_DATA_TOO_SMALL,
        ProgramError.InsufficientFunds => INSUFFICIENT_FUNDS,
        ProgramError.IncorrectProgramId => INCORRECT_PROGRAM_ID,
        ProgramError.MissingRequiredSignature => MISSING_REQUIRED_SIGNATURES,
        ProgramError.AccountAlreadyInitialized => ACCOUNT_ALREADY_INITIALIZED,
        ProgramError.UninitializedAccount => UNINITIALIZED_ACCOUNT,
        ProgramError.NotEnoughAccountKeys => NOT_ENOUGH_ACCOUNT_KEYS,
        ProgramError.AccountBorrowFailed => ACCOUNT_BORROW_FAILED,
        ProgramError.MaxSeedLengthExceeded => MAX_SEED_LENGTH_EXCEEDED,
        ProgramError.InvalidSeeds => INVALID_SEEDS,
        ProgramError.BorshIoError => BORSH_IO_ERROR,
        ProgramError.AccountNotRentExempt => ACCOUNT_NOT_RENT_EXEMPT,
        ProgramError.UnsupportedSysvar => UNSUPPORTED_SYSVAR,
        ProgramError.IllegalOwner => ILLEGAL_OWNER,
        ProgramError.MaxAccountsDataAllocationsExceeded => MAX_ACCOUNTS_DATA_ALLOCATIONS_EXCEEDED,
        ProgramError.InvalidRealloc => INVALID_ACCOUNT_DATA_REALLOC,
        ProgramError.MaxInstructionTraceLengthExceeded => MAX_INSTRUCTION_TRACE_LENGTH_EXCEEDED,
        ProgramError.BuiltinProgramsMustConsumeComputeUnits => BUILTIN_PROGRAMS_MUST_CONSUME_COMPUTE_UNITS,
        ProgramError.InvalidAccountOwner => INVALID_ACCOUNT_OWNER,
        ProgramError.ArithmeticOverflow => ARITHMETIC_OVERFLOW,
        ProgramError.ImmutableAccount => IMMUTABLE,
        ProgramError.IncorrectAuthority => INCORRECT_AUTHORITY,
    };
}

/// Decode a u64 returned by a CPI / syscall back into a `ProgramError`.
///
/// Anything that isn't a recognised builtin maps to
/// `ProgramError.Custom`.
pub fn u64ToError(code: u64) ProgramError {
    return switch (code) {
        CUSTOM_ZERO => ProgramError.Custom,
        INVALID_ARGUMENT => ProgramError.InvalidArgument,
        INVALID_INSTRUCTION_DATA => ProgramError.InvalidInstructionData,
        INVALID_ACCOUNT_DATA => ProgramError.InvalidAccountData,
        ACCOUNT_DATA_TOO_SMALL => ProgramError.AccountDataTooSmall,
        INSUFFICIENT_FUNDS => ProgramError.InsufficientFunds,
        INCORRECT_PROGRAM_ID => ProgramError.IncorrectProgramId,
        MISSING_REQUIRED_SIGNATURES => ProgramError.MissingRequiredSignature,
        ACCOUNT_ALREADY_INITIALIZED => ProgramError.AccountAlreadyInitialized,
        UNINITIALIZED_ACCOUNT => ProgramError.UninitializedAccount,
        NOT_ENOUGH_ACCOUNT_KEYS => ProgramError.NotEnoughAccountKeys,
        ACCOUNT_BORROW_FAILED => ProgramError.AccountBorrowFailed,
        MAX_SEED_LENGTH_EXCEEDED => ProgramError.MaxSeedLengthExceeded,
        INVALID_SEEDS => ProgramError.InvalidSeeds,
        BORSH_IO_ERROR => ProgramError.BorshIoError,
        ACCOUNT_NOT_RENT_EXEMPT => ProgramError.AccountNotRentExempt,
        UNSUPPORTED_SYSVAR => ProgramError.UnsupportedSysvar,
        ILLEGAL_OWNER => ProgramError.IllegalOwner,
        MAX_ACCOUNTS_DATA_ALLOCATIONS_EXCEEDED => ProgramError.MaxAccountsDataAllocationsExceeded,
        INVALID_ACCOUNT_DATA_REALLOC => ProgramError.InvalidRealloc,
        MAX_INSTRUCTION_TRACE_LENGTH_EXCEEDED => ProgramError.MaxInstructionTraceLengthExceeded,
        BUILTIN_PROGRAMS_MUST_CONSUME_COMPUTE_UNITS => ProgramError.BuiltinProgramsMustConsumeComputeUnits,
        INVALID_ACCOUNT_OWNER => ProgramError.InvalidAccountOwner,
        ARITHMETIC_OVERFLOW => ProgramError.ArithmeticOverflow,
        IMMUTABLE => ProgramError.ImmutableAccount,
        INCORRECT_AUTHORITY => ProgramError.IncorrectAuthority,
        else => ProgramError.Custom,
    };
}
