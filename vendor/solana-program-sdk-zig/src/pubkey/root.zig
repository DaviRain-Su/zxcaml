//! Public key primitives: Base58, equality, curve validation, and formatting.
//!
//! Physical layout:
//! - `shared.zig` — shared constants, types, Base58 tables, and BPF dependency
//! - `base58.zig` — compile-time decode and runtime encode helpers
//! - `equality.zig` — runtime/comptime equality helpers
//! - `curve.zig` — curve validation and formatting helpers
//!
//! The public API stays flattened as `sol.pubkey.*`, with the top-level
//! aliases `sol.Pubkey` and `sol.PUBKEY_BYTES` preserved at `src/root.zig`.

const std = @import("std");
const shared = @import("shared.zig");
const base58_mod = @import("base58.zig");
const equality_mod = @import("equality.zig");
const curve_mod = @import("curve.zig");

/// Pubkey size/type aliases and shared PDA-related limits.
pub const PUBKEY_BYTES = shared.PUBKEY_BYTES;
pub const Pubkey = shared.Pubkey;
pub const MAX_SEEDS = shared.MAX_SEEDS;
pub const MAX_SEED_LEN = shared.MAX_SEED_LEN;

/// Base58 encode/decode helpers.
pub const comptimeFromBase58 = base58_mod.comptimeFromBase58;
pub const encodeBase58 = base58_mod.encodeBase58;

/// Equality helpers for runtime and comptime-known pubkeys.
pub const pubkeyEq = equality_mod.pubkeyEq;
pub const pubkeyEqAligned = equality_mod.pubkeyEqAligned;
pub const pubkeyEqComptime = equality_mod.pubkeyEqComptime;
pub const pubkeyEqAny = equality_mod.pubkeyEqAny;

/// Curve validation and formatting helpers.
pub const isPointOnCurve = curve_mod.isPointOnCurve;
pub const formatPubkey = curve_mod.formatPubkey;

// =============================================================================
// Tests
// =============================================================================

test "pubkey: comptimeFromBase58" {
    const id = comptimeFromBase58("11111111111111111111111111111111");
    const expected: Pubkey = .{0} ** PUBKEY_BYTES;
    try std.testing.expectEqual(expected, id);
}

test "pubkey: encodeBase58 roundtrip" {
    const original = comptimeFromBase58("11111111111111111111111111111111");
    var encoded: [44]u8 = undefined;
    const len = encodeBase58(&original, &encoded);
    try std.testing.expectEqualStrings("11111111111111111111111111111111", encoded[0..len]);
}

test "pubkey: equality" {
    const a = comptimeFromBase58("11111111111111111111111111111111");
    const b = comptimeFromBase58("11111111111111111111111111111111");
    try std.testing.expect(pubkeyEq(&a, &b));
}

test "pubkey: pubkeyEqComptime matches/mismatches" {
    const same = comptimeFromBase58("SysvarRent111111111111111111111111111111111");
    try std.testing.expect(pubkeyEqComptime(
        &same,
        comptime comptimeFromBase58("SysvarRent111111111111111111111111111111111"),
    ));

    const different = comptimeFromBase58("SysvarC1ock11111111111111111111111111111111");
    try std.testing.expect(!pubkeyEqComptime(
        &different,
        comptime comptimeFromBase58("SysvarRent111111111111111111111111111111111"),
    ));

    // Smoke-test the all-zero (System Program) case
    const zero: Pubkey = .{0} ** PUBKEY_BYTES;
    try std.testing.expect(pubkeyEqComptime(&zero, comptime .{0} ** PUBKEY_BYTES));
}

test "pubkey: pubkeyEqAny matches first / second / none" {
    const k1: Pubkey = .{1} ** PUBKEY_BYTES;
    const k2: Pubkey = .{2} ** PUBKEY_BYTES;
    const k3: Pubkey = .{3} ** PUBKEY_BYTES;
    const allowed = comptime [_]Pubkey{ k1, k2 };

    try std.testing.expect(pubkeyEqAny(&k1, &allowed));
    try std.testing.expect(pubkeyEqAny(&k2, &allowed));
    try std.testing.expect(!pubkeyEqAny(&k3, &allowed));
}

test "pubkey: pubkeyEqAny single-element collapses to pubkeyEqComptime" {
    const k1: Pubkey = .{42} ** PUBKEY_BYTES;
    const k2: Pubkey = .{99} ** PUBKEY_BYTES;
    const allowed = comptime [_]Pubkey{k1};

    try std.testing.expect(pubkeyEqAny(&k1, &allowed));
    try std.testing.expect(!pubkeyEqAny(&k2, &allowed));
}

test "pubkey: pubkeyEqAny empty list always returns false" {
    const k: Pubkey = .{0} ** PUBKEY_BYTES;
    try std.testing.expect(!pubkeyEqAny(&k, &.{}));
}

test "pubkey: isPointOnCurve" {
    // Ed25519's identity element y=1 (encoded as 01 00 ... 00) is a
    // canonical on-curve point.
    var identity: Pubkey = .{0} ** PUBKEY_BYTES;
    identity[0] = 1;
    try std.testing.expect(isPointOnCurve(&identity));

    // The y-coordinate of an Ed25519 point is a field element mod
    // 2^255 - 19, so the encoding with the low bits set to 2^255-18
    // (i.e. p = 2^255 - 19 reduced to 0 but with a non-canonical
    // representation) does not decompress to a valid point. We use a
    // value that fails `fromBytes`: a non-canonical y whose squared
    // value yields a non-square `u/v` ratio.
    var not_on_curve: Pubkey = .{0} ** PUBKEY_BYTES;
    not_on_curve[0] = 2; // y=2 is not on Edwards25519 (no x exists).
    try std.testing.expect(!isPointOnCurve(&not_on_curve));
}
