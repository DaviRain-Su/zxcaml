//! Memory operations for Solana programs.
//!
//! This module provides two small families of helpers:
//!
//! - syscall-backed copy/set/compare wrappers for BPF runtime use
//! - typed byte-slice casting helpers for zero-copy views
//!
//! Physical layout:
//! - `shared.zig` — imports and shared aliases
//! - `syscalls.zig` — `memcpy`, `memset`, `memcmp`, and `zero`
//! - `casts.zig` — `fromBytes*` and `asBytes*` helpers
//!
//! The public API stays flattened as `sol.memory.*`.

const std = @import("std");
const syscalls = @import("syscalls.zig");
const casts = @import("casts.zig");

/// Syscall-backed memory wrappers.
pub const memcpy = syscalls.memcpy;
pub const memset = syscalls.memset;
pub const memcmp = syscalls.memcmp;
pub const zero = syscalls.zero;

/// Zero-copy byte-view helpers.
pub const fromBytes = casts.fromBytes;
pub const fromBytesMut = casts.fromBytesMut;
pub const asBytes = casts.asBytes;
pub const asBytesMut = casts.asBytesMut;

// =============================================================================
// Tests
// =============================================================================

test "memory: memcpy" {
    var dst: [10]u8 = undefined;
    const src = "hello";
    memcpy(&dst, src, 5);
    try std.testing.expectEqualStrings("hello", dst[0..5]);
}

test "memory: memset" {
    var dst: [10]u8 = undefined;
    memset(&dst, 0xAA, 10);
    for (dst) |b| {
        try std.testing.expectEqual(@as(u8, 0xAA), b);
    }
}

test "memory: memcmp equal" {
    const a = "hello";
    const b = "hello";
    try std.testing.expectEqual(@as(i32, 0), memcmp(a, b, 5));
}

test "memory: memcmp not equal" {
    const a = "hello";
    const b = "world";
    try std.testing.expect(memcmp(a, b, 5) != 0);
}

test "memory: zero" {
    var dst: [10]u8 = undefined;
    @memset(&dst, 0xFF);
    zero(&dst, 10);
    for (dst) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "memory: fromBytes" {
    var bytes align(4) = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const value = fromBytes(u32, &bytes);
    try std.testing.expectEqual(@as(u32, 0x04030201), value.*);
}
