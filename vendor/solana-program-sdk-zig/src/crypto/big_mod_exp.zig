//! Big-integer modular exponentiation via `sol_big_mod_exp`.
//!
//! Computes `base^exponent mod modulus` over arbitrary-precision
//! big-endian integers. The on-chain syscall is the cheap way to do
//! RSA-flavoured number theory inside a Solana program — everything
//! from light-client verification (DLEQ, accumulator proofs) to
//! threshold-signature schemes that can't fit on a curve.
//!
//! ## Encoding
//!
//! All three inputs and the output are **big-endian** byte strings
//! of arbitrary length. The output is exactly `modulus.len()` bytes
//! (left-padded with zeros when the result fits in fewer bytes).
//!
//! ## ABI
//!
//! ```rust
//! #[repr(C)]
//! pub struct BigModExpParams {
//!     pub base: *const u8, pub base_len: u64,
//!     pub exponent: *const u8, pub exponent_len: u64,
//!     pub modulus: *const u8, pub modulus_len: u64,
//! }
//! extern fn sol_big_mod_exp(params: *const u8, return_value: *mut u8) -> u64;
//! ```
//!
//! Per the Rust SDK, when `modulus` is `0` or `1` the result is
//! defined to be all-zeros of length `modulus.len()` (the syscall
//! short-circuits before the modpow).

const std = @import("std");
const builtin = @import("builtin");

const is_solana = builtin.os.tag == .freestanding and builtin.cpu.arch == .bpfel;

/// ABI-stable parameter block consumed by the syscall.
///
/// Layout matches `solana_program::big_mod_exp::BigModExpParams`:
/// six u64-sized fields, no padding under `extern struct`.
pub const Params = extern struct {
    base: [*]const u8,
    base_len: u64,
    exponent: [*]const u8,
    exponent_len: u64,
    modulus: [*]const u8,
    modulus_len: u64,
};

extern fn sol_big_mod_exp(params: *const u8, result: *u8) callconv(.c) u64;

/// Errors surfaced by the wrapper. The syscall itself is currently
/// infallible on supported clusters, but `OutputTooSmall` is checked
/// host-side so callers can't silently truncate the result.
pub const Error = error{
    /// `out.len < modulus.len`.
    OutputTooSmall,
    /// Any non-zero return code from the syscall.
    Unexpected,
};

/// Compute `base^exponent mod modulus`. Writes exactly `modulus.len`
/// bytes (big-endian, left-padded with zeros) into the prefix of
/// `out`. Returns the slice that was actually written.
///
/// `out` must be at least `modulus.len` bytes long.
pub fn bigModExp(
    base: []const u8,
    exponent: []const u8,
    modulus: []const u8,
    out: []u8,
) Error![]u8 {
    if (out.len < modulus.len) return error.OutputTooSmall;
    const result_slice = out[0..modulus.len];

    const params: Params = .{
        .base = base.ptr,
        .base_len = base.len,
        .exponent = exponent.ptr,
        .exponent_len = exponent.len,
        .modulus = modulus.ptr,
        .modulus_len = modulus.len,
    };

    if (is_solana) {
        const rc = sol_big_mod_exp(
            @as(*const u8, @ptrCast(&params)),
            @as(*u8, @ptrCast(result_slice.ptr)),
        );
        if (rc != 0) return error.Unexpected;
    } else {
        // Host fallback: zero the output. The syscall on real clusters
        // does the modpow; on host we can't bring in num-bigint as a
        // dependency, so callers shouldn't rely on real values from
        // host stubs. This keeps the wrapper testable without changing
        // its API.
        @memset(result_slice, 0);
        return error.Unexpected;
    }

    return result_slice;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "big_mod_exp: Params layout matches Rust BigModExpParams (48 bytes on 64-bit)" {
    // 6 × 8 bytes (3 pointers, 3 u64 lengths), no padding.
    try testing.expectEqual(@as(usize, 48), @sizeOf(Params));
}

test "big_mod_exp: OutputTooSmall when out shorter than modulus" {
    const base = [_]u8{1};
    const exp = [_]u8{1};
    const modulus = [_]u8{ 0, 0, 0, 7 };
    var out: [3]u8 = undefined;
    try testing.expectError(error.OutputTooSmall, bigModExp(&base, &exp, &modulus, &out));
}

test "big_mod_exp: host stub returns Unexpected" {
    const base = [_]u8{2};
    const exp = [_]u8{3};
    const modulus = [_]u8{5};
    var out: [1]u8 = undefined;
    try testing.expectError(error.Unexpected, bigModExp(&base, &exp, &modulus, &out));
}
