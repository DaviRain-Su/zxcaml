//! 8-byte account-type discriminator.
//!
//! Computes `sha256("account:" ++ name)[0..8]` at compile time. Used
//! as the leading 8 bytes of a typed account's serialized layout so
//! that programs can refuse to deserialize an account whose type
//! doesn't match what's expected — defending against the canonical
//! "type confusion" attack class (e.g. handing a `Vault` account into
//! an instruction that expected a `UserState`).
//!
//! Convention is borrowed from Anchor:
//!   - "account:<TypeName>" for state accounts
//!   - "event:<EventName>"  for emitted events (future)
//!
//! All work is comptime; on BPF the discriminator becomes 8 immediate
//! bytes / a single 64-bit constant compare.

const std = @import("std");

/// Length of an account discriminator in bytes.
pub const DISCRIMINATOR_LEN: usize = 8;

/// Compute `sha256("account:" ++ name)[0..8]` at compile time.
///
/// Example:
/// ```zig
/// const DISC = sol.discriminator.forAccount("Vault");
/// // DISC is [8]u8, e.g. .{ 0xab, 0x12, ... }
/// ```
pub fn forAccount(comptime name: []const u8) [DISCRIMINATOR_LEN]u8 {
    return computeWithNamespace("account:", name);
}

/// Compute `sha256("event:" ++ name)[0..8]` at compile time.
pub fn forEvent(comptime name: []const u8) [DISCRIMINATOR_LEN]u8 {
    return computeWithNamespace("event:", name);
}

/// Compute `sha256(namespace ++ name)[0..8]` at compile time.
/// Generic form — both arguments are comptime.
pub fn computeWithNamespace(
    comptime namespace: []const u8,
    comptime name: []const u8,
) [DISCRIMINATOR_LEN]u8 {
    return comptime blk: {
        @setEvalBranchQuota(10_000);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(namespace);
        hasher.update(name);
        var out: [32]u8 = undefined;
        hasher.final(&out);
        var disc: [DISCRIMINATOR_LEN]u8 = undefined;
        @memcpy(&disc, out[0..DISCRIMINATOR_LEN]);
        break :blk disc;
    };
}

/// Constant-time-style equality check on two 8-byte discriminators.
/// On BPF this is folded into a single `u64` compare against the
/// comptime-known constant.
pub inline fn eq(a: *const [DISCRIMINATOR_LEN]u8, b: *const [DISCRIMINATOR_LEN]u8) bool {
    const a_u64: *align(1) const u64 = @ptrCast(a);
    const b_u64: *align(1) const u64 = @ptrCast(b);
    return a_u64.* == b_u64.*;
}

// =============================================================================
// Tests
// =============================================================================

test "discriminator: forAccount is stable" {
    // sha256("account:Vault")[0..8] — pin this to a known value so we
    // catch any accidental change to the hashing convention.
    const expected = [_]u8{ 0xd3, 0x08, 0xe8, 0x2b, 0x02, 0x98, 0x75, 0x77 };
    const got = forAccount("Vault");
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "discriminator: forEvent differs from forAccount" {
    const a = forAccount("Foo");
    const e = forEvent("Foo");
    try std.testing.expect(!std.mem.eql(u8, &a, &e));
}

test "discriminator: eq comparison" {
    const a = forAccount("X");
    const b = forAccount("X");
    const c = forAccount("Y");
    try std.testing.expect(eq(&a, &b));
    try std.testing.expect(!eq(&a, &c));
}
