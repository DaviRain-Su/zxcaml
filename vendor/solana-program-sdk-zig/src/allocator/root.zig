//! Bump allocation helpers for Solana programs.
//!
//! This module provides a small allocation surface for on-chain code:
//!
//! - `BumpAllocator` for caller-owned fixed-buffer allocation.
//! - heap constants that mirror Solana's default BPF heap layout.
//! - `global_allocator` / `initGlobalAllocator()` for the legacy global pattern.
//!
//! Physical layout:
//! - `shared.zig` — imports and heap-related constants
//! - `bump.zig` — `BumpAllocator` and std allocator adapter
//! - `root.zig` — global allocator instance, initializer, and tests
//!
//! The public API stays flattened as `sol.allocator.*`.

const std = @import("std");
const shared = @import("shared.zig");
const bump = @import("bump.zig");

/// Heap layout constants shared by allocator entrypoints.
pub const HEAP_START_ADDRESS = shared.HEAP_START_ADDRESS;
pub const HEAP_LENGTH = shared.HEAP_LENGTH;
pub const MAX_HEAP_LENGTH = shared.MAX_HEAP_LENGTH;

/// Fixed-buffer bump allocator and std allocator bridge.
pub const BumpAllocator = bump.BumpAllocator;

/// Optional global allocator surface for legacy-style initialization.
pub var global_allocator: BumpAllocator = undefined;

/// Initialize global allocator with default heap.
pub fn initGlobalAllocator() void {
    const heap = @as([*]u8, @ptrFromInt(HEAP_START_ADDRESS))[0..HEAP_LENGTH];
    global_allocator = BumpAllocator.init(heap);
}

// =============================================================================
// Tests
// =============================================================================

test "BumpAllocator: basic allocation" {
    var buffer: [1024]u8 = undefined;
    var alloc = BumpAllocator.init(&buffer);

    const ptr1 = alloc.allocDirect(10, 1).?;
    @memcpy(ptr1[0..5], "hello");
    try std.testing.expectEqualStrings("hello", ptr1[0..5]);

    const ptr2 = alloc.allocDirect(20, 1).?;
    @memcpy(ptr2[0..5], "world");
    try std.testing.expectEqualStrings("world", ptr2[0..5]);
}

test "BumpAllocator: aligned allocation" {
    var buffer: [1024]u8 = undefined;
    var alloc = BumpAllocator.init(&buffer);

    const ptr2 = alloc.allocDirect(8, 8).?;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(ptr2) % 8);

    const ptr3 = alloc.allocDirect(16, 16).?;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(ptr3) % 16);
}

test "BumpAllocator: reset" {
    var buffer align(8) = [_]u8{0} ** 1024;
    var alloc = BumpAllocator.init(&buffer);

    const first = alloc.allocDirect(100, 1).?;
    alloc.reset();
    const second = alloc.allocDirect(100, 1).?;

    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(second));
}

test "BumpAllocator: std interface" {
    var buffer align(8) = [_]u8{0} ** 1024;
    var bump_alloc = BumpAllocator.init(&buffer);
    const std_alloc = bump_alloc.allocator();

    const ptr = try std_alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), ptr.len);

    std_alloc.free(ptr);
}

test "BumpAllocator: out of memory" {
    var buffer align(8) = [_]u8{0} ** 64;
    var alloc = BumpAllocator.init(&buffer);

    const ptr1 = alloc.allocDirect(32, 1);
    try std.testing.expect(ptr1 != null);

    const ptr2 = alloc.allocDirect(64, 1);
    try std.testing.expect(ptr2 == null);
}
