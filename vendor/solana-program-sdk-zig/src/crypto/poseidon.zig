//! Poseidon hash via the `sol_poseidon` syscall.
//!
//! [Poseidon](https://www.poseidon-hash.info/) is a ZK-friendly hash
//! function — efficient inside arithmetic circuits but slow on
//! general-purpose CPUs. On Solana, `sol_poseidon` exposes a native
//! implementation that's cheap enough to use on-chain for:
//!
//!   - Merkle trees inside Groth16 / PLONK circuits
//!   - Compressed-account commitments (Light Protocol, …)
//!   - Light-client state-root verification
//!
//! The syscall currently supports a single configuration:
//! **BN254 X5** (S-box `x^5` over the BN254 prime field), with
//! 1–12 32-byte input elements.

const std = @import("std");
const builtin = @import("builtin");
const program_error = @import("../program_error/root.zig");

const ProgramError = program_error.ProgramError;

/// 32 bytes — fixed Poseidon hash output size.
pub const HASH_LEN: usize = 32;

/// Maximum number of input elements accepted by the syscall.
pub const MAX_INPUTS: usize = 12;

/// Hash configuration. The syscall currently supports only one
/// variant; the enum exists to mirror the Rust SDK's API shape and
/// to leave room for future curve additions.
pub const Parameters = enum(u64) {
    /// BN254 with S-box `x^5`, 1 ≤ n ≤ 12 inputs.
    bn254_x5 = 0,
};

/// Endianness for both inputs and result. Most ZK circuits use
/// big-endian; on-chain code that interops with light-protocol uses
/// little-endian.
pub const Endianness = enum(u64) {
    big_endian = 0,
    little_endian = 1,
};

/// Errors returned by `hashv`. The numeric codes mirror the
/// `solana_poseidon::PoseidonSyscallError` mapping (`1` … `11`).
pub const Error = error{
    InvalidParameters,
    InvalidEndianness,
    InvalidNumberOfInputs,
    EmptyInput,
    InvalidInputLength,
    BytesToPrimeFieldElement,
    InputLargerThanModulus,
    VecToArray,
    U64Tou8,
    BytesToBigInt,
    InvalidWidthCircom,
    Unexpected,
};

const is_solana = builtin.os.tag == .freestanding and builtin.cpu.arch == .bpfel;

// Solana's `sol_poseidon` ABI: `vals` is a pointer to an array of
// `(ptr, len)` slice headers (matching Rust's `&[&[u8]]`). On BPF a
// slice header is `{ ptr: u64, len: u64 }` — 16 bytes per entry.
const SliceHeader = extern struct {
    ptr: [*]const u8,
    len: u64,
};

extern fn sol_poseidon(
    parameters: u64,
    endianness: u64,
    vals: [*]const SliceHeader,
    val_len: u64,
    hash_result: [*]u8,
) callconv(.c) u64;

/// Compute a Poseidon hash over the concatenation of `vals`.
///
/// Each element of `vals` must be exactly 32 bytes and ≤ the BN254
/// field modulus. The runtime enforces this. Maximum 12 elements.
pub fn hashv(
    params: Parameters,
    endianness: Endianness,
    vals: []const []const u8,
    out: *[HASH_LEN]u8,
) Error!void {
    if (vals.len == 0) return error.EmptyInput;
    if (vals.len > MAX_INPUTS) return error.InvalidNumberOfInputs;

    if (comptime !is_solana) {
        // No host fallback — Poseidon is not in std.crypto. Return
        // `Unexpected` so host tests can exercise the entry point
        // without producing misleading "valid" results.
        return error.Unexpected;
    }

    // Stage slice headers into a fixed stack-resident buffer matching
    // the syscall's expected layout (`*const [&[u8]]`).
    var headers: [MAX_INPUTS]SliceHeader = undefined;
    for (vals, 0..) |v, i| {
        if (v.len != HASH_LEN) return error.InvalidInputLength;
        headers[i] = .{ .ptr = v.ptr, .len = v.len };
    }

    const rc = sol_poseidon(
        @intFromEnum(params),
        @intFromEnum(endianness),
        &headers,
        vals.len,
        out,
    );
    return mapError(rc);
}

/// Convenience: hash a single 32-byte input.
pub fn hash(
    params: Parameters,
    endianness: Endianness,
    val: *const [HASH_LEN]u8,
    out: *[HASH_LEN]u8,
) Error!void {
    const slices: [1][]const u8 = .{val};
    return hashv(params, endianness, &slices, out);
}

fn mapError(rc: u64) Error!void {
    return switch (rc) {
        0 => {},
        1 => error.InvalidParameters,
        2 => error.InvalidEndianness,
        3 => error.InvalidNumberOfInputs,
        4 => error.EmptyInput,
        5 => error.InvalidInputLength,
        6 => error.BytesToPrimeFieldElement,
        7 => error.InputLargerThanModulus,
        8 => error.VecToArray,
        9 => error.U64Tou8,
        10 => error.BytesToBigInt,
        11 => error.InvalidWidthCircom,
        else => error.Unexpected,
    };
}

// =============================================================================
// Bridging — see `secp256k1_recover.zig` for the design rationale.
// =============================================================================

/// Numeric code matching the syscall's return values and the Rust
/// SDK's `impl From<PoseidonSyscallError> for u64`. Use with
/// `sol.customError(code)` to preserve the failure sub-type on the
/// wire as `Custom(N)`.
pub fn errorToCode(err: Error) u32 {
    return switch (err) {
        error.InvalidParameters => 1,
        error.InvalidEndianness => 2,
        error.InvalidNumberOfInputs => 3,
        error.EmptyInput => 4,
        error.InvalidInputLength => 5,
        error.BytesToPrimeFieldElement => 6,
        error.InputLargerThanModulus => 7,
        error.VecToArray => 8,
        error.U64Tou8 => 9,
        error.BytesToBigInt => 10,
        error.InvalidWidthCircom => 11,
        error.Unexpected => 12,
    };
}

/// Collapse to a `ProgramError`:
///   - Input-shape failures (`EmptyInput`, `InvalidNumberOfInputs`,
///     `InvalidInputLength`, `InvalidParameters`, `InvalidEndianness`,
///     `InvalidWidthCircom`) → `InvalidInstructionData`.
///   - Value failures (`InputLargerThanModulus`,
///     `BytesToPrimeFieldElement`, `BytesToBigInt`) → `InvalidArgument`.
///   - Wrapper / runtime defaults (`VecToArray`, `U64Tou8`,
///     `Unexpected`) → `InvalidArgument`.
pub fn errorToProgramError(err: Error) ProgramError {
    return switch (err) {
        error.EmptyInput,
        error.InvalidNumberOfInputs,
        error.InvalidInputLength,
        error.InvalidParameters,
        error.InvalidEndianness,
        error.InvalidWidthCircom,
        => error.InvalidInstructionData,
        error.InputLargerThanModulus,
        error.BytesToPrimeFieldElement,
        error.BytesToBigInt,
        error.VecToArray,
        error.U64Tou8,
        error.Unexpected,
        => error.InvalidArgument,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "poseidon: empty input rejected" {
    var out: [HASH_LEN]u8 = undefined;
    try testing.expectError(error.EmptyInput, hashv(.bn254_x5, .big_endian, &.{}, &out));
}

test "poseidon: too many inputs rejected" {
    var out: [HASH_LEN]u8 = undefined;
    const v: [HASH_LEN]u8 = .{0} ** HASH_LEN;
    var inputs: [MAX_INPUTS + 1][]const u8 = undefined;
    for (&inputs) |*slot| slot.* = &v;
    try testing.expectError(error.InvalidNumberOfInputs, hashv(
        .bn254_x5,
        .big_endian,
        &inputs,
        &out,
    ));
}

test "poseidon: host stub returns Unexpected for valid input" {
    var out: [HASH_LEN]u8 = undefined;
    const v: [HASH_LEN]u8 = .{1} ** HASH_LEN;
    try testing.expectError(error.Unexpected, hash(.bn254_x5, .big_endian, &v, &out));
}

test "poseidon: enum discriminants match SDK ABI" {
    try testing.expectEqual(@as(u64, 0), @intFromEnum(Parameters.bn254_x5));
    try testing.expectEqual(@as(u64, 0), @intFromEnum(Endianness.big_endian));
    try testing.expectEqual(@as(u64, 1), @intFromEnum(Endianness.little_endian));
}

test "poseidon: SliceHeader is 16 bytes on 64-bit hosts" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(SliceHeader));
}

test "poseidon: errorToCode matches Rust mapping" {
    try testing.expectEqual(@as(u32, 1), errorToCode(error.InvalidParameters));
    try testing.expectEqual(@as(u32, 4), errorToCode(error.EmptyInput));
    try testing.expectEqual(@as(u32, 7), errorToCode(error.InputLargerThanModulus));
    try testing.expectEqual(@as(u32, 12), errorToCode(error.Unexpected));
}

test "poseidon: errorToProgramError split between input-shape and value failures" {
    try testing.expectEqual(ProgramError.InvalidInstructionData, errorToProgramError(error.EmptyInput));
    try testing.expectEqual(ProgramError.InvalidInstructionData, errorToProgramError(error.InvalidNumberOfInputs));
    try testing.expectEqual(ProgramError.InvalidArgument, errorToProgramError(error.InputLargerThanModulus));
    try testing.expectEqual(ProgramError.InvalidArgument, errorToProgramError(error.Unexpected));
}
