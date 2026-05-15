//! SPL Token custom error-code parity.
//!
//! Mirrors the classic `spl-token-interface` `TokenError` enum so Zig programs
//! can decode, inspect, and re-emit the same custom error codes.
//!
//! The module provides three layers:
//!
//! - `TokenError` — the raw `enum(u32)` discriminator space
//! - `Error` / `TokenErrorSet` — an `ErrorCode(...)` wrapper for ergonomic
//!   typed entrypoints
//! - `tryFrom`, `toStr`, `toU64` — decode / render / re-emit helpers

const sol = @import("solana_program_sdk");

pub const TokenError = enum(u32) {
    NotRentExempt = 0,
    InsufficientFunds = 1,
    InvalidMint = 2,
    MintMismatch = 3,
    OwnerMismatch = 4,
    FixedSupply = 5,
    AlreadyInUse = 6,
    InvalidNumberOfProvidedSigners = 7,
    InvalidNumberOfRequiredSigners = 8,
    UninitializedState = 9,
    NativeNotSupported = 10,
    NonNativeHasBalance = 11,
    InvalidInstruction = 12,
    InvalidState = 13,
    Overflow = 14,
    AuthorityTypeNotSupported = 15,
    MintCannotFreeze = 16,
    AccountFrozen = 17,
    MintDecimalsMismatch = 18,
    NonNativeNotSupported = 19,
};

pub const Error = sol.ErrorCode(TokenError, error{
    NotRentExempt,
    InsufficientFunds,
    InvalidMint,
    MintMismatch,
    OwnerMismatch,
    FixedSupply,
    AlreadyInUse,
    InvalidNumberOfProvidedSigners,
    InvalidNumberOfRequiredSigners,
    UninitializedState,
    NativeNotSupported,
    NonNativeHasBalance,
    InvalidInstruction,
    InvalidState,
    Overflow,
    AuthorityTypeNotSupported,
    MintCannotFreeze,
    AccountFrozen,
    MintDecimalsMismatch,
    NonNativeNotSupported,
});

pub fn tryFrom(code: u32) sol.ProgramError!TokenError {
    return switch (code) {
        0 => .NotRentExempt,
        1 => .InsufficientFunds,
        2 => .InvalidMint,
        3 => .MintMismatch,
        4 => .OwnerMismatch,
        5 => .FixedSupply,
        6 => .AlreadyInUse,
        7 => .InvalidNumberOfProvidedSigners,
        8 => .InvalidNumberOfRequiredSigners,
        9 => .UninitializedState,
        10 => .NativeNotSupported,
        11 => .NonNativeHasBalance,
        12 => .InvalidInstruction,
        13 => .InvalidState,
        14 => .Overflow,
        15 => .AuthorityTypeNotSupported,
        16 => .MintCannotFreeze,
        17 => .AccountFrozen,
        18 => .MintDecimalsMismatch,
        19 => .NonNativeNotSupported,
        else => error.InvalidArgument,
    };
}

pub fn toStr(err: TokenError) []const u8 {
    return switch (err) {
        .NotRentExempt => "Error: Lamport balance below rent-exempt threshold",
        .InsufficientFunds => "Error: insufficient funds",
        .InvalidMint => "Error: Invalid Mint",
        .MintMismatch => "Error: Account not associated with this Mint",
        .OwnerMismatch => "Error: owner does not match",
        .FixedSupply => "Error: the total supply of this token is fixed",
        .AlreadyInUse => "Error: account or token already in use",
        .InvalidNumberOfProvidedSigners => "Error: Invalid number of provided signers",
        .InvalidNumberOfRequiredSigners => "Error: Invalid number of required signers",
        .UninitializedState => "Error: State is uninitialized",
        .NativeNotSupported => "Error: Instruction does not support native tokens",
        .NonNativeHasBalance => "Error: Non-native account can only be closed if its balance is zero",
        .InvalidInstruction => "Error: Invalid instruction",
        .InvalidState => "Error: Invalid account state for operation",
        .Overflow => "Error: Operation overflowed",
        .AuthorityTypeNotSupported => "Error: Account does not support specified authority type",
        .MintCannotFreeze => "Error: This token mint cannot freeze accounts",
        .AccountFrozen => "Error: Account is frozen",
        .MintDecimalsMismatch => "Error: decimals different from the Mint decimals",
        .NonNativeNotSupported => "Error: Instruction does not support non-native tokens",
    };
}

pub inline fn toU64(err: TokenError) u64 {
    return sol.customError(@intFromEnum(err));
}

test "spl-token error: tryFrom is exhaustive across the classic range" {
    inline for (@typeInfo(TokenError).@"enum".fields) |field| {
        const code: u32 = field.value;
        const err = try tryFrom(code);
        try @import("std").testing.expectEqual(code, @intFromEnum(err));
    }
    try @import("std").testing.expectError(error.InvalidArgument, tryFrom(20));
}

test "spl-token error: ErrorCode wrapper preserves custom u32 values" {
    try @import("std").testing.expectEqual(@as(u64, 17), Error.catchToU64(error.AccountFrozen));
    try @import("std").testing.expectEqual(
        sol.program_error.errorToU64(error.InvalidArgument),
        Error.catchToU64(error.InvalidArgument),
    );
}

test "spl-token error: toStr and toU64 match upstream semantics" {
    try @import("std").testing.expectEqualStrings(
        "Error: decimals different from the Mint decimals",
        toStr(.MintDecimalsMismatch),
    );
    try @import("std").testing.expectEqual(@as(u64, 19), toU64(.NonNativeNotSupported));
}
