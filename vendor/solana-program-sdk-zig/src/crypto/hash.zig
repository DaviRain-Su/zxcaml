//! Hash utilities — SHA-256, Keccak-256, Blake3 syscall wrappers.
//!
//! Mirrors `solana-program`'s `hash` / `keccak` / `blake3` modules.
//! Each hash family exposes a single function:
//!
//!   ```zig
//!   const h = try sol.hash.sha256(.{ "hello", " ", "world" });
//!   ```
//!
//! `hashv` is also re-exported under the legacy name (matches the
//! Rust SDK's `solana_program::hash::hashv`). The `Hash` struct is a
//! 32-byte newtype with a Base58 `format()` (built on the SDK's
//! inline encoder — zero external deps).

const std = @import("std");
const bpf = @import("../bpf.zig");
const log = @import("../log/root.zig");
const pubkey = @import("../pubkey/root.zig");
const program_error = @import("../program_error/root.zig");

const ProgramError = program_error.ProgramError;

/// Hash output length — 32 bytes (same for SHA-256, Keccak-256,
/// Blake3, Poseidon — every hash family currently exposed by the
/// Solana runtime).
pub const HASH_BYTES: usize = 32;

/// A 32-byte hash value.
///
/// `format()` prints the hash as Base58 (no allocations, no external
/// deps — uses the SDK's inline `pubkey.encodeBase58`).
pub const Hash = struct {
    bytes: [HASH_BYTES]u8 = .{0} ** HASH_BYTES,

    pub fn format(
        self: Hash,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        // Base58-encode the 32 bytes. We reuse the pubkey encoder
        // since the algorithm is byte-string agnostic.
        var buffer: [44]u8 = undefined;
        const len = pubkey.encodeBase58(&self.bytes, &buffer);
        try writer.print("{s}", .{buffer[0..len]});
    }
};

// =============================================================================
// SHA-256
// =============================================================================

extern fn sol_sha256(
    vals_ptr: [*]const []const u8,
    vals_len: u64,
    hash_ptr: *Hash,
) callconv(.c) u64;

/// Compute SHA-256 over a list of byte slices, concatenated.
///
/// On host, uses `std.crypto.hash.sha2.Sha256` so unit tests work.
pub fn sha256(vals: []const []const u8) ProgramError!Hash {
    var hash: Hash = undefined;
    if (bpf.is_bpf_program) {
        const rc = sol_sha256(vals.ptr, vals.len, &hash);
        if (rc != 0) {
            log.print("sol_sha256 failed: {d}", .{rc});
            return error.InvalidArgument;
        }
    } else {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (vals) |v| hasher.update(v);
        hasher.final(&hash.bytes);
    }
    return hash;
}

// =============================================================================
// Keccak-256 (EVM-compatible)
// =============================================================================

extern fn sol_keccak256(
    vals_ptr: [*]const []const u8,
    vals_len: u64,
    hash_ptr: *Hash,
) callconv(.c) u64;

/// Compute Keccak-256 over a list of byte slices, concatenated.
///
/// Critically **not** SHA-3 — this is the legacy Keccak variant used
/// by Ethereum. Use this when you need to verify EVM-style signatures
/// or compute EVM-derived addresses.
pub fn keccak256(vals: []const []const u8) ProgramError!Hash {
    var hash: Hash = undefined;
    if (bpf.is_bpf_program) {
        const rc = sol_keccak256(vals.ptr, vals.len, &hash);
        if (rc != 0) {
            log.print("sol_keccak256 failed: {d}", .{rc});
            return error.InvalidArgument;
        }
    } else {
        var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
        for (vals) |v| hasher.update(v);
        hasher.final(&hash.bytes);
    }
    return hash;
}

// =============================================================================
// Blake3
// =============================================================================

extern fn sol_blake3(
    vals_ptr: [*]const []const u8,
    vals_len: u64,
    hash_ptr: *Hash,
) callconv(.c) u64;

/// Compute Blake3 over a list of byte slices, concatenated.
///
/// Host fallback uses `std.crypto.hash.Blake3` (default 32-byte
/// output, matching the Solana syscall).
pub fn blake3(vals: []const []const u8) ProgramError!Hash {
    var hash: Hash = undefined;
    if (bpf.is_bpf_program) {
        const rc = sol_blake3(vals.ptr, vals.len, &hash);
        if (rc != 0) {
            log.print("sol_blake3 failed: {d}", .{rc});
            return error.InvalidArgument;
        }
    } else {
        var hasher = std.crypto.hash.Blake3.init(.{});
        for (vals) |v| hasher.update(v);
        hasher.final(&hash.bytes);
    }
    return hash;
}

/// Legacy name — same as `sha256`. Matches Rust SDK's
/// `solana_program::hash::hashv` which has been the canonical
/// "hash these byte slices" helper for years.
pub const hashv = sha256;

// =============================================================================
// Tests (host-only — syscalls aren't reachable in unit tests)
// =============================================================================

test "hash: sha256 host fallback" {
    const empty = try sha256(&.{});
    // Known SHA-256 of the empty string.
    const expected = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    try std.testing.expectEqualSlices(u8, &expected, &empty.bytes);
}

test "hash: sha256 concatenates slices" {
    const a = try sha256(&.{ "hello", " ", "world" });
    const b = try sha256(&.{"hello world"});
    try std.testing.expectEqualSlices(u8, &a.bytes, &b.bytes);
}

test "hash: keccak256 EVM empty string" {
    const empty = try keccak256(&.{});
    // Famous Keccak-256("") — every EVM developer's favourite constant.
    const expected = [_]u8{
        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
        0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
        0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
    };
    try std.testing.expectEqualSlices(u8, &expected, &empty.bytes);
}

test "hash: blake3 hashes" {
    const h = try blake3(&.{"abc"});
    // Known Blake3 of "abc".
    const expected = [_]u8{
        0x64, 0x37, 0xb3, 0xac, 0x38, 0x46, 0x51, 0x33,
        0xff, 0xb6, 0x3b, 0x75, 0x27, 0x3a, 0x8d, 0xb5,
        0x48, 0xc5, 0x58, 0x46, 0x5d, 0x79, 0xdb, 0x03,
        0xfd, 0x35, 0x9c, 0x6c, 0xd5, 0xbd, 0x9d, 0x85,
    };
    try std.testing.expectEqualSlices(u8, &expected, &h.bytes);
}

test "hash: hashv alias points to sha256" {
    const a = try hashv(&.{"factory"});
    const b = try sha256(&.{"factory"});
    try std.testing.expectEqualSlices(u8, &a.bytes, &b.bytes);
}
