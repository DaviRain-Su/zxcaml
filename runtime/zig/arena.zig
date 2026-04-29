//! Minimal static-buffer bump arena used by generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Construct an arena view over caller-owned static memory.
//! - Provide typed bump allocations for future arena-lowered values.
//! - Reset the bump cursor at program exit without owning the backing buffer.

const std = @import("std");

/// A bump allocator over a caller-owned byte buffer.
pub const Arena = struct {
    buffer: []u8,
    offset: usize,

    /// Creates an arena that allocates from `buf` without taking ownership.
    pub fn fromStaticBuffer(buf: []u8) Arena {
        return .{
            .buffer = buf,
            .offset = 0,
        };
    }

    /// Allocates `count` contiguous values of `T` from the arena.
    pub fn alloc(self: *Arena, comptime T: type, count: usize) ![]T {
        const byte_count = try std.math.mul(usize, @sizeOf(T), count);
        const base = @intFromPtr(self.buffer.ptr);
        const aligned_addr = std.mem.alignForward(usize, base + self.offset, @alignOf(T));
        const start = aligned_addr - base;
        const end = try std.math.add(usize, start, byte_count);

        if (end > self.buffer.len) return error.OutOfMemory;

        self.offset = end;
        const ptr: [*]T = @ptrCast(@alignCast(self.buffer.ptr + start));
        return ptr[0..count];
    }

    /// Allocates `count` contiguous values into `out`, trapping on failure without returning an aggregate slice.
    pub fn allocIntoOrTrap(self: *Arena, comptime T: type, count: usize, out: *[]T) void {
        const byte_count = @sizeOf(T) * count;
        const base = @intFromPtr(self.buffer.ptr);
        const aligned_addr = std.mem.alignForward(usize, base + self.offset, @alignOf(T));
        const start = aligned_addr - base;
        const end = start + byte_count;

        if (end > self.buffer.len) unreachable;

        self.offset = end;
        const ptr: [*]T = @ptrCast(@alignCast(self.buffer.ptr + start));
        out.* = ptr[0..count];
    }

    /// Allocates one value of `T`, trapping on out-of-memory for BPF-friendly codegen.
    pub fn allocOneOrTrap(self: *Arena, comptime T: type) *T {
        const byte_count = roundUpArenaSlot(@sizeOf(T));
        const start = self.offset;

        if (start > self.buffer.len or byte_count > self.buffer.len - start) unreachable;

        self.offset = start + byte_count;
        return @ptrCast(@alignCast(self.buffer.ptr + start));
    }

    /// Rewinds the arena so future allocations reuse the static buffer.
    pub fn reset(self: *Arena) void {
        self.offset = 0;
    }
};

fn roundUpArenaSlot(comptime size: usize) usize {
    if (size == 0) return 0;
    var out = size;
    while (out % 8 != 0) : (out += 1) {}
    return out;
}

test "Arena allocates typed slices from a static buffer and resets" {
    var buf: [64]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);

    const ints = try arena.alloc(u32, 3);
    try std.testing.expectEqual(@as(usize, 3), ints.len);
    ints[0] = 7;
    ints[1] = 11;
    ints[2] = 13;
    try std.testing.expectEqual(@as(u32, 11), ints[1]);
    try std.testing.expect(arena.offset > 0);

    const one = arena.allocOneOrTrap(u16);
    one.* = 42;
    try std.testing.expectEqual(@as(u16, 42), one.*);

    var bytes: []u8 = undefined;
    arena.allocIntoOrTrap(u8, 2, &bytes);
    try std.testing.expectEqual(@as(usize, 2), bytes.len);

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.offset);
}

test "Arena reports OutOfMemory when the static buffer is exhausted" {
    var buf: [4]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);

    try std.testing.expectError(error.OutOfMemory, arena.alloc(u64, 1));
}
