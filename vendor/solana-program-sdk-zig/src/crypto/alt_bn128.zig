//! BN254 (alt_bn128) elliptic curve operations via syscall.
//!
//! Wraps `sol_alt_bn128_group_op` for the three core ZK-circuit
//! primitives:
//!
//!   - **G1 add / sub** — point addition / subtraction in G1
//!   - **G1 mul** — scalar multiplication in G1
//!   - **Pairing** — multi-pairing check (used by Groth16 verifiers)
//!
//! These syscalls are the foundation for on-chain Groth16 / PLONK
//! verification, and are the same primitives Ethereum exposes via
//! its EIP-196 / EIP-197 precompiles. The Solana syscall accepts
//! both EIP-197-style **big-endian** (`*_BE`) and ark-bn254-style
//! **little-endian** (`*_LE`) inputs — the LE variants are typically
//! cheaper because they skip the runtime endianness conversion.
//!
//! ### Buffer layout (input)
//!
//! | Op | Size | Layout |
//! |----|------|--------|
//! | G1 add | 128 B | `g1_a (64) || g1_b (64)` — each is `(x, y)` packed |
//! | G1 mul | 96 B  | `g1 (64) || scalar (32)` |
//! | Pairing | k × 192 B | `[g1 (64) || g2 (128)] × k` |
//!
//! The pairing output is **32 bytes**: the integer `1` (LE or BE)
//! encoded across the buffer if the multi-pairing check passes,
//! otherwise `0`.
//!
//! G2 add / sub / mul also exist (`G2_*` operation IDs); not exposed
//! here yet — open an issue if you need them.
//!
//! ### Endianness
//!
//! Most ZK tooling on Ethereum uses **EIP-197 big-endian**. Most
//! native ark-bn254 code uses little-endian. Pick the variant
//! matching your serialization. The LE variants save a few CU per
//! call at the syscall boundary.

const std = @import("std");
const builtin = @import("builtin");
const program_error = @import("../program_error/root.zig");

const ProgramError = program_error.ProgramError;

// =============================================================================
// Sizes (bytes)
// =============================================================================

/// One field element in Fq (the base field of BN254).
pub const FIELD_SIZE: usize = 32;
/// G1 affine point: `(x, y)` — two field elements packed.
pub const G1_POINT_SIZE: usize = FIELD_SIZE * 2; // 64
/// One element of the extension field Fq2 (used by G2 coordinates).
pub const FQ2_SIZE: usize = FIELD_SIZE * 2; // 64
/// G2 affine point: `(x, y)` over Fq2 — four field elements.
pub const G2_POINT_SIZE: usize = FQ2_SIZE * 2; // 128

/// Input size for `g1_addition_*` (two G1 points).
pub const G1_ADDITION_INPUT_SIZE: usize = G1_POINT_SIZE * 2; // 128
/// Input size for `g1_multiplication_*` (G1 + 32-byte scalar).
pub const G1_MULTIPLICATION_INPUT_SIZE: usize = G1_POINT_SIZE + FIELD_SIZE; // 96

/// One pairing input element: `(g1, g2)`.
pub const PAIRING_ELEMENT_SIZE: usize = G1_POINT_SIZE + G2_POINT_SIZE; // 192
/// Pairing output: `0x00…01` (success) or `0x00…00` (failure).
pub const PAIRING_OUTPUT_SIZE: usize = 32;

// =============================================================================
// Syscall operation IDs (matches `solana_bn254` constants)
// =============================================================================

/// Bit set on `*_LE` operation IDs to signal little-endian I/O.
const LE_FLAG: u64 = 0x80;

const G1_ADD_BE: u64 = 0;
const G1_SUB_BE: u64 = 1;
const G1_MUL_BE: u64 = 2;
const PAIRING_BE: u64 = 3;

const G1_ADD_LE: u64 = G1_ADD_BE | LE_FLAG;
const G1_SUB_LE: u64 = G1_SUB_BE | LE_FLAG;
const G1_MUL_LE: u64 = G1_MUL_BE | LE_FLAG;
const PAIRING_LE: u64 = PAIRING_BE | LE_FLAG;

/// Errors returned by alt_bn128 ops. The numeric codes mirror the
/// `solana_bn254::AltBn128Error` mapping (`1` … `5`).
pub const Error = error{
    InvalidInputData,
    GroupError,
    SliceOutOfBounds,
    Unexpected,
};

const is_solana = builtin.os.tag == .freestanding and builtin.cpu.arch == .bpfel;

extern fn sol_alt_bn128_group_op(
    group_op: u64,
    input: [*]const u8,
    input_size: u64,
    result: [*]u8,
) callconv(.c) u64;

fn syscall(op: u64, input: []const u8, out: []u8) Error!void {
    if (comptime !is_solana) return error.Unexpected;
    const rc = sol_alt_bn128_group_op(op, input.ptr, input.len, out.ptr);
    return switch (rc) {
        0 => {},
        1 => error.InvalidInputData,
        2 => error.GroupError,
        3 => error.SliceOutOfBounds,
        else => error.Unexpected,
    };
}

// =============================================================================
// G1 addition
// =============================================================================

/// G1 point addition (big-endian / EIP-197 input). `input.len` must
/// be ≤ 128; shorter inputs are zero-padded by the runtime. Result
/// is written to `out` (must be ≥ 64 bytes).
pub fn g1AdditionBE(input: []const u8, out: *[G1_POINT_SIZE]u8) Error!void {
    if (input.len > G1_ADDITION_INPUT_SIZE) return error.InvalidInputData;
    return syscall(G1_ADD_BE, input, out);
}

/// G1 point addition (little-endian / ark-bn254 input). `input` must
/// be exactly 128 bytes.
pub fn g1AdditionLE(input: *const [G1_ADDITION_INPUT_SIZE]u8, out: *[G1_POINT_SIZE]u8) Error!void {
    return syscall(G1_ADD_LE, input, out);
}

/// G1 point subtraction (BE). `a - b`.
pub fn g1SubtractionBE(input: []const u8, out: *[G1_POINT_SIZE]u8) Error!void {
    if (input.len > G1_ADDITION_INPUT_SIZE) return error.InvalidInputData;
    return syscall(G1_SUB_BE, input, out);
}

/// G1 point subtraction (LE).
pub fn g1SubtractionLE(input: *const [G1_ADDITION_INPUT_SIZE]u8, out: *[G1_POINT_SIZE]u8) Error!void {
    return syscall(G1_SUB_LE, input, out);
}

// =============================================================================
// G1 scalar multiplication
// =============================================================================

/// G1 scalar multiplication (BE). `input` ≤ 96 bytes —
/// `point (64) || scalar (32)`. Shorter inputs are zero-padded.
pub fn g1MultiplicationBE(input: []const u8, out: *[G1_POINT_SIZE]u8) Error!void {
    if (input.len > G1_MULTIPLICATION_INPUT_SIZE) return error.InvalidInputData;
    return syscall(G1_MUL_BE, input, out);
}

/// G1 scalar multiplication (LE). `input` is exactly 96 bytes.
pub fn g1MultiplicationLE(input: *const [G1_MULTIPLICATION_INPUT_SIZE]u8, out: *[G1_POINT_SIZE]u8) Error!void {
    return syscall(G1_MUL_LE, input, out);
}

// =============================================================================
// Pairing check
// =============================================================================

/// Multi-pairing check (BE). `input.len` must be a multiple of 192.
/// Result is the 32-byte big-endian encoding of `1` if the pairing
/// equation holds, `0` otherwise.
pub fn pairingBE(input: []const u8, out: *[PAIRING_OUTPUT_SIZE]u8) Error!void {
    if (input.len % PAIRING_ELEMENT_SIZE != 0) return error.InvalidInputData;
    return syscall(PAIRING_BE, input, out);
}

/// Multi-pairing check (LE).
pub fn pairingLE(input: []const u8, out: *[PAIRING_OUTPUT_SIZE]u8) Error!void {
    if (input.len % PAIRING_ELEMENT_SIZE != 0) return error.InvalidInputData;
    return syscall(PAIRING_LE, input, out);
}

// =============================================================================
// Bridging — see `secp256k1_recover.zig` for the design rationale.
// =============================================================================

/// Numeric code matching the syscall's return values and the Rust
/// SDK's `impl From<AltBn128Error> for u64`. Use with
/// `sol.customError(code)` to preserve the failure sub-type on the
/// wire as `Custom(N)`.
///
/// Codes: `1 = InvalidInputData`, `2 = GroupError`,
/// `3 = SliceOutOfBounds`, `6 = Unexpected` (matches Rust's
/// `UnexpectedError` numeric slot — `4` and `5` are reserved for
/// `TryIntoVecError` / `ProjectiveToG1Failed` which the syscall
/// itself never produces).
pub fn errorToCode(err: Error) u32 {
    return switch (err) {
        error.InvalidInputData => 1,
        error.GroupError => 2,
        error.SliceOutOfBounds => 3,
        error.Unexpected => 6,
    };
}

/// Collapse to a `ProgramError`:
///   - `InvalidInputData` / `SliceOutOfBounds` → `InvalidInstructionData`
///     (the caller's input was malformed before it ever hit the curve).
///   - `GroupError` → `InvalidArgument`
///     (input parsed, but failed the on-curve / subgroup checks — a
///     genuine semantic error, not a length / encoding issue).
///   - `Unexpected` → `InvalidArgument` (defensive default).
pub fn errorToProgramError(err: Error) ProgramError {
    return switch (err) {
        error.InvalidInputData, error.SliceOutOfBounds => error.InvalidInstructionData,
        error.GroupError, error.Unexpected => error.InvalidArgument,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "alt_bn128: size constants" {
    try testing.expectEqual(@as(usize, 64), G1_POINT_SIZE);
    try testing.expectEqual(@as(usize, 128), G2_POINT_SIZE);
    try testing.expectEqual(@as(usize, 128), G1_ADDITION_INPUT_SIZE);
    try testing.expectEqual(@as(usize, 96), G1_MULTIPLICATION_INPUT_SIZE);
    try testing.expectEqual(@as(usize, 192), PAIRING_ELEMENT_SIZE);
    try testing.expectEqual(@as(usize, 32), PAIRING_OUTPUT_SIZE);
}

test "alt_bn128: g1AdditionBE rejects oversize input" {
    const input: [G1_ADDITION_INPUT_SIZE + 1]u8 = .{0} ** (G1_ADDITION_INPUT_SIZE + 1);
    var out: [G1_POINT_SIZE]u8 = undefined;
    try testing.expectError(error.InvalidInputData, g1AdditionBE(&input, &out));
}

test "alt_bn128: pairing rejects unaligned input" {
    const input: [193]u8 = .{0} ** 193;
    var out: [PAIRING_OUTPUT_SIZE]u8 = undefined;
    try testing.expectError(error.InvalidInputData, pairingBE(&input, &out));
}

test "alt_bn128: host stub returns Unexpected for valid sizes" {
    const input: [G1_ADDITION_INPUT_SIZE]u8 = .{0} ** G1_ADDITION_INPUT_SIZE;
    var out: [G1_POINT_SIZE]u8 = undefined;
    try testing.expectError(error.Unexpected, g1AdditionBE(&input, &out));
}

test "alt_bn128: errorToCode matches Rust mapping" {
    try testing.expectEqual(@as(u32, 1), errorToCode(error.InvalidInputData));
    try testing.expectEqual(@as(u32, 2), errorToCode(error.GroupError));
    try testing.expectEqual(@as(u32, 3), errorToCode(error.SliceOutOfBounds));
    try testing.expectEqual(@as(u32, 6), errorToCode(error.Unexpected));
}

test "alt_bn128: errorToProgramError split between malformed-input and on-curve failures" {
    try testing.expectEqual(ProgramError.InvalidInstructionData, errorToProgramError(error.InvalidInputData));
    try testing.expectEqual(ProgramError.InvalidInstructionData, errorToProgramError(error.SliceOutOfBounds));
    try testing.expectEqual(ProgramError.InvalidArgument, errorToProgramError(error.GroupError));
    try testing.expectEqual(ProgramError.InvalidArgument, errorToProgramError(error.Unexpected));
}
