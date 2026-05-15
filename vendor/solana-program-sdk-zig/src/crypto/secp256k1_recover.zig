//! Public key recovery from secp256k1 ECDSA signatures.
//!
//! Wrapper around the `sol_secp256k1_recover` syscall — the building
//! block for Ethereum-compatible `ecrecover`, oracle attestation
//! verification, and bridge / cross-chain message validation.
//!
//! ### Hashing requirement
//! ECDSA recovery operates on a 32-byte **cryptographic hash of the
//! message**, never the message itself. Pass `hash` already hashed by
//! the program (typically with `sol.keccak256` for Ethereum
//! compatibility). The runtime does NOT validate that the input is
//! actually a hash.
//!
//! ### Signature malleability
//! Solana's syscall does NOT reject high-`S` signatures. For
//! applications where unique signature representation matters (e.g.
//! anti-replay), the program must reject high-`S` values itself —
//! see the Rust SDK docs for the canonical pattern.
//!
//! ### On-chain length contract
//! On SBF the syscall does **not** validate that `hash` is 32 bytes
//! or `signature` is 64 bytes — it just reads from the pointers. The
//! caller must guarantee the buffer lengths before invoking.

const std = @import("std");
const builtin = @import("builtin");
const program_error = @import("../program_error/root.zig");

const ProgramError = program_error.ProgramError;

/// 32 bytes — fixed size of the message hash.
pub const HASH_LEN: usize = 32;
/// 64 bytes — compact (r || s) secp256k1 signature.
pub const SIGNATURE_LEN: usize = 64;
/// 64 bytes — uncompressed public key (x || y), without the leading
/// `0x04` SEC1 prefix.
pub const PUBKEY_LEN: usize = 64;

/// Errors returned by `recover`. The numeric codes match the
/// `solana-program::secp256k1_recover::Secp256k1RecoverError` mapping
/// (`1` / `2` / `3`).
pub const Error = error{
    /// The hash buffer length isn't 32 (host-side check only).
    InvalidHash,
    /// `recovery_id` outside `[0, 3]` or signature is "overflowing".
    InvalidRecoveryId,
    /// Signature isn't 64 bytes, or is malformed.
    InvalidSignature,
    /// Catch-all for any future syscall error.
    Unexpected,
};

/// Recovered 64-byte secp256k1 public key. Use `.bytes` for raw
/// access; the type exists for self-documentation at call sites.
pub const RecoveredPubkey = struct {
    bytes: [PUBKEY_LEN]u8,
};

const is_solana = builtin.os.tag == .freestanding and builtin.cpu.arch == .bpfel;

extern fn sol_secp256k1_recover(
    hash: [*]const u8,
    recovery_id: u64,
    signature: [*]const u8,
    result: [*]u8,
) callconv(.c) u64;

/// Recover a secp256k1 public key from a message hash, recovery id,
/// and 64-byte (r || s) signature.
///
/// Returns the uncompressed (x || y) public key — drop the leading
/// `0x04` SEC1 prefix if you're interoperating with libraries that
/// produce 65-byte encodings.
///
/// To derive an Ethereum address: `keccak256(pubkey)[12..32]`.
pub fn recover(
    hash: []const u8,
    recovery_id: u8,
    signature: []const u8,
) Error!RecoveredPubkey {
    // On SBF the syscall doesn't validate lengths — do it ourselves so
    // host and BPF return the same error variants on the same inputs.
    if (hash.len != HASH_LEN) return error.InvalidHash;
    if (signature.len != SIGNATURE_LEN) return error.InvalidSignature;
    if (recovery_id > 3) return error.InvalidRecoveryId;

    if (comptime !is_solana) {
        // Host fallback: we can't actually recover without pulling in
        // a secp256k1 implementation. Return a deterministic stub so
        // host tests can at least exercise the call path; flag the
        // limitation in the error so production code doesn't rely on
        // host-side recovery.
        return error.Unexpected;
    }

    var out: RecoveredPubkey = .{ .bytes = undefined };
    const rc = sol_secp256k1_recover(
        hash.ptr,
        @intCast(recovery_id),
        signature.ptr,
        &out.bytes,
    );
    return switch (rc) {
        0 => out,
        1 => error.InvalidHash,
        2 => error.InvalidRecoveryId,
        3 => error.InvalidSignature,
        else => error.Unexpected,
    };
}

// =============================================================================
// Bridging to the rest of the SDK
//
// The crypto error sets are kept independent of `ProgramError` so the
// fine-grained variants survive logging and conditional branching.
// Solana's wire format only carries a single `u64`, so when a program
// is about to return up the entrypoint it must collapse the typed
// error into one of two shapes:
//
//   1. `Custom(N)` carrying the syscall's numeric code — preserves
//      "which kind of failure" all the way to the client / explorer.
//      Use `errorToCode(err)` to get N, then `sol.customError(N)`.
//   2. A builtin `ProgramError` variant — discards the sub-classification
//      but composes cleanly with `try` / `ProgramResult` returns.
//      Use `errorToProgramError(err)`.
//
// This mirrors the Rust SDK's `From<Secp256k1RecoverError> for u64`
// (option 1) and the idiomatic `.map_err(|_| ProgramError::InvalidArgument)`
// pattern (option 2). The SDK does not pick for you — both bridges are
// provided so the call site can be explicit.
// =============================================================================

/// Numeric code matching the syscall's return values and the Rust
/// SDK's `impl From<Secp256k1RecoverError> for u64`. Use with
/// `sol.customError(code)` to surface the failure as `Custom(N)` on
/// the wire.
///
/// Codes: `1 = InvalidHash`, `2 = InvalidRecoveryId`,
/// `3 = InvalidSignature`. Other variants get `0xFFFF_FFFF` so
/// callers can recognise "wrapper-only" failures distinctly from the
/// runtime's three documented codes.
pub fn errorToCode(err: Error) u32 {
    return switch (err) {
        error.InvalidHash => 1,
        error.InvalidRecoveryId => 2,
        error.InvalidSignature => 3,
        error.Unexpected => 0xFFFF_FFFF,
    };
}

/// Collapse to a `ProgramError` variant — convenient when the caller
/// doesn't care to distinguish failure sub-types and just wants `try`
/// to propagate up to a `ProgramResult`-returning handler.
///
/// All variants map to `InvalidArgument`, matching the conventional
/// Rust `.map_err(|_| ProgramError::InvalidArgument)?` idiom for
/// secp256k1 recovery failures.
pub fn errorToProgramError(err: Error) ProgramError {
    return switch (err) {
        error.InvalidHash,
        error.InvalidRecoveryId,
        error.InvalidSignature,
        error.Unexpected,
        => error.InvalidArgument,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "secp256k1_recover: length validation rejects wrong-size hash" {
    var sig: [SIGNATURE_LEN]u8 = .{0} ** SIGNATURE_LEN;
    try testing.expectError(error.InvalidHash, recover(&[_]u8{0} ** 31, 0, &sig));
}

test "secp256k1_recover: length validation rejects wrong-size signature" {
    var hash: [HASH_LEN]u8 = .{0} ** HASH_LEN;
    try testing.expectError(error.InvalidSignature, recover(&hash, 0, &[_]u8{0} ** 63));
}

test "secp256k1_recover: invalid recovery_id rejected" {
    var hash: [HASH_LEN]u8 = .{0} ** HASH_LEN;
    var sig: [SIGNATURE_LEN]u8 = .{0} ** SIGNATURE_LEN;
    try testing.expectError(error.InvalidRecoveryId, recover(&hash, 4, &sig));
    try testing.expectError(error.InvalidRecoveryId, recover(&hash, 255, &sig));
}

test "secp256k1_recover: host stub returns Unexpected" {
    var hash: [HASH_LEN]u8 = .{1} ** HASH_LEN;
    var sig: [SIGNATURE_LEN]u8 = .{2} ** SIGNATURE_LEN;
    // On host we cannot perform real recovery — the wrapper returns
    // Unexpected so callers know the operation didn't actually run.
    try testing.expectError(error.Unexpected, recover(&hash, 0, &sig));
}

test "secp256k1_recover: constants match Rust SDK" {
    try testing.expectEqual(@as(usize, 32), HASH_LEN);
    try testing.expectEqual(@as(usize, 64), SIGNATURE_LEN);
    try testing.expectEqual(@as(usize, 64), PUBKEY_LEN);
}

test "secp256k1_recover: errorToCode matches Rust mapping" {
    try testing.expectEqual(@as(u32, 1), errorToCode(error.InvalidHash));
    try testing.expectEqual(@as(u32, 2), errorToCode(error.InvalidRecoveryId));
    try testing.expectEqual(@as(u32, 3), errorToCode(error.InvalidSignature));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), errorToCode(error.Unexpected));
}

test "secp256k1_recover: errorToProgramError collapses to InvalidArgument" {
    try testing.expectEqual(ProgramError.InvalidArgument, errorToProgramError(error.InvalidHash));
    try testing.expectEqual(ProgramError.InvalidArgument, errorToProgramError(error.InvalidRecoveryId));
    try testing.expectEqual(ProgramError.InvalidArgument, errorToProgramError(error.InvalidSignature));
    try testing.expectEqual(ProgramError.InvalidArgument, errorToProgramError(error.Unexpected));
}
