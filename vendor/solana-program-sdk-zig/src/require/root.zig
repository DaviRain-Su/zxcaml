//! Anchor-style `require!` family — assert-and-log-and-return.
//!
//! Each helper is the Zig analogue of one of Anchor's `require_*!`
//! macros, with the same trade-off: on the happy path it compiles down
//! to a single `if` + branch; on failure it logs the comptime tag and
//! returns the supplied `ProgramError`.
//!
//! Physical layout:
//! - `shared.zig` — imports plus shared `program_error` / `pubkey` aliases
//! - `generic.zig` — `require`, `requireEq`, and `requireNeq`
//! - `pubkeys.zig` — `requireKeysEq` and `requireKeysNeq`
//!
//! The public API stays flattened as `sol.require_mod.*`, with the
//! top-level aliases `sol.require*` preserved at `src/root.zig`.

const std = @import("std");
const shared = @import("shared.zig");
const generic = @import("generic.zig");
const pubkeys = @import("pubkeys.zig");

/// Generic assert-and-fail helpers.
pub const require = generic.require;
pub const requireEq = generic.requireEq;
pub const requireNeq = generic.requireNeq;

/// Pubkey-specialized assert-and-fail helpers.
pub const requireKeysEq = pubkeys.requireKeysEq;
pub const requireKeysNeq = pubkeys.requireKeysNeq;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const Pubkey = shared.Pubkey;

test "require: passes on true, fails with err on false" {
    try require(@src(), true, "ok", error.InvalidArgument);
    try testing.expectError(
        error.InvalidArgument,
        require(@src(), false, "fail:test", error.InvalidArgument),
    );
}

test "requireEq / requireNeq for ints" {
    try requireEq(@src(), @as(u64, 7), @as(u64, 7), "eq:ok", error.InvalidArgument);
    try testing.expectError(
        error.InvalidArgument,
        requireEq(@src(), @as(u64, 7), @as(u64, 8), "eq:fail", error.InvalidArgument),
    );
    try requireNeq(@src(), @as(u64, 7), @as(u64, 8), "neq:ok", error.InvalidArgument);
    try testing.expectError(
        error.InvalidArgument,
        requireNeq(@src(), @as(u64, 7), @as(u64, 7), "neq:fail", error.InvalidArgument),
    );
}

test "requireKeysEq / requireKeysNeq" {
    const a: Pubkey = .{1} ** 32;
    const b: Pubkey = .{1} ** 32;
    const c: Pubkey = .{2} ** 32;
    try requireKeysEq(@src(), &a, &b, "keyseq:ok", error.IncorrectAuthority);
    try testing.expectError(
        error.IncorrectAuthority,
        requireKeysEq(@src(), &a, &c, "keyseq:fail", error.IncorrectAuthority),
    );
    try requireKeysNeq(@src(), &a, &c, "keysneq:ok", error.IncorrectAuthority);
    try testing.expectError(
        error.IncorrectAuthority,
        requireKeysNeq(@src(), &a, &b, "keysneq:fail", error.IncorrectAuthority),
    );
}
