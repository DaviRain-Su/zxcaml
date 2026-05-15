//! Program events — emit structured data on-chain via `sol_log_data`.
//!
//! Solana programs emit "events" by logging a discriminator-prefixed
//! payload that off-chain indexers can decode from transaction logs.
//!
//! Physical layout:
//! - `shared.zig` — imports plus event/discriminator constants
//! - `emitter.zig` — discriminator helpers and `emit(...)`
//!
//! The public API stays flattened as `sol.event.*`, with the top-level
//! alias `sol.emit` preserved at `src/root.zig`.

const std = @import("std");
const shared = @import("shared.zig");
const emitter = @import("emitter.zig");

/// Soft size cap for a single emitted event payload.
pub const MAX_EVENT_SIZE = shared.MAX_EVENT_SIZE;

/// Event discriminator helpers and emit surface.
pub const discriminatorFor = emitter.discriminatorFor;
pub const trimTypeName = emitter.trimTypeName;
pub const emit = emitter.emit;

// =============================================================================
// Tests
// =============================================================================

const discriminator = shared.discriminator;

const TransferEvent = extern struct {
    from: [32]u8,
    to: [32]u8,
    amount: u64,

    pub const DISCRIMINATOR = discriminator.forEvent("Transfer");
};

const UntaggedEvent = extern struct {
    amount: u64,
    // No DISCRIMINATOR decl — falls back to forEvent(@typeName(T))
};

test "event: emit transfer event (host fallback)" {
    emit(TransferEvent{
        .from = .{1} ** 32,
        .to = .{2} ** 32,
        .amount = 100,
    });
}

test "event: emit untagged event computes discriminator from type name" {
    emit(UntaggedEvent{ .amount = 42 });
}

test "event: discriminator decl is used when present" {
    const want = discriminator.forEvent("Transfer");
    const got = discriminatorFor(TransferEvent);
    try std.testing.expectEqualSlices(u8, &want, &got);
}

test "event: trimTypeName strips module prefix" {
    try std.testing.expectEqualStrings("MyEvent", trimTypeName("foo.bar.MyEvent"));
    try std.testing.expectEqualStrings("Simple", trimTypeName("Simple"));
}
