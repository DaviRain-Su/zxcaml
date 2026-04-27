//! Runtime prelude helpers used by generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Provide arena-friendly tagged unions for option/result/list constructors.
//! - Keep constructor helpers allocation-free unless generated Layout code allocates.
//! - Keep integer helpers and constructor helpers BPF-compatible.

const std = @import("std");
const Arena = @import("arena.zig").Arena;
const runtime_panic = @import("panic.zig");

/// Divides two i64 values with ZxCaml's pinned truncating semantics.
pub fn intDiv(lhs: i64, rhs: i64) i64 {
    if (rhs == 0) runtime_panic.divisionByZero();
    if (lhs == std.math.minInt(i64) and rhs == -1) return std.math.minInt(i64);
    return @divTrunc(lhs, rhs);
}

/// Computes i64 remainder with ZxCaml's pinned truncating semantics.
pub fn intMod(lhs: i64, rhs: i64) i64 {
    if (rhs == 0) runtime_panic.divisionByZero();
    if (lhs == std.math.minInt(i64) and rhs == -1) return 0;
    return @rem(lhs, rhs);
}

/// OCaml-style `'a option` representation used by generated Zig.
pub fn Option(comptime T: type) type {
    return union(enum) {
        none,
        some: T,

        /// Constructs `None` without heap allocation.
        pub fn None() @This() {
            return .none;
        }

        /// Constructs `Some(value)` by value; codegen handles any layout-driven arena box.
        pub fn Some(value: T) @This() {
            return .{ .some = value };
        }
    };
}

/// OCaml-style `('a, 'e) result` representation used by generated Zig.
pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        err: E,

        /// Constructs `Ok(value)` by value; codegen handles any layout-driven arena box.
        pub fn Ok(value: T) @This() {
            return .{ .ok = value };
        }

        /// Constructs `Error(value)` by value; codegen handles any layout-driven arena box.
        pub fn Error(value: E) @This() {
            return .{ .err = value };
        }
    };
}

/// OCaml-style `'a list` representation used by generated Zig.
pub fn List(comptime T: type) type {
    return union(enum) {
        nil,
        cons: Cons,

        const Self = @This();

        /// Heap-allocated cons-cell payload: head plus pointer to the tail list.
        pub const Cons = struct {
            head: T,
            tail: *const Self,
        };

        /// Constructs `[]` without heap allocation.
        pub fn Nil() Self {
            return .nil;
        }

        /// Constructs a cons value from an already-boxed tail pointer.
        pub fn ConsFromTailPtr(head: T, tail: *const Self) Self {
            return .{ .cons = .{ .head = head, .tail = tail } };
        }

        /// Allocates a list value in the arena and returns a stable tail pointer.
        pub fn Box(arena: *Arena, value: Self) *const Self {
            const slot = arena.alloc(Self, 1) catch unreachable;
            slot[0] = value;
            return &slot[0];
        }

        /// Allocates the tail value and constructs a cons cell that points at it.
        pub fn ConsAlloc(arena: *Arena, head: T, tail: Self) Self {
            return ConsFromTailPtr(head, Box(arena, tail));
        }
    };
}

test "Option and Result constructors preserve payloads" {
    const maybe = Option(i64).Some(1);
    switch (maybe) {
        .some => |value| try @import("std").testing.expectEqual(@as(i64, 1), value),
        .none => return error.TestUnexpectedResult,
    }

    const absent = Option(i64).None();
    switch (absent) {
        .none => {},
        .some => return error.TestUnexpectedResult,
    }

    const ok = Result(i64, i64).Ok(2);
    switch (ok) {
        .ok => |value| try @import("std").testing.expectEqual(@as(i64, 2), value),
        .err => return error.TestUnexpectedResult,
    }

    const err = Result(i64, i64).Error(3);
    switch (err) {
        .err => |value| try @import("std").testing.expectEqual(@as(i64, 3), value),
        .ok => return error.TestUnexpectedResult,
    }
}

test "List constructors preserve head and tail payloads" {
    var buf: [256]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);

    const nil = List(i64).Nil();
    const one = List(i64).ConsAlloc(&arena, 1, nil);
    switch (one) {
        .cons => |cell| {
            try @import("std").testing.expectEqual(@as(i64, 1), cell.head);
            switch (cell.tail.*) {
                .nil => {},
                .cons => return error.TestUnexpectedResult,
            }
        },
        .nil => return error.TestUnexpectedResult,
    }
}

test "integer division and modulus pin overflow edge semantics" {
    try std.testing.expectEqual(@as(i64, 3), intDiv(7, 2));
    try std.testing.expectEqual(@as(i64, -3), intDiv(-7, 2));
    try std.testing.expectEqual(std.math.minInt(i64), intDiv(std.math.minInt(i64), -1));
    try std.testing.expectEqual(@as(i64, 1), intMod(7, 3));
    try std.testing.expectEqual(@as(i64, -1), intMod(-7, 3));
    try std.testing.expectEqual(@as(i64, 0), intMod(std.math.minInt(i64), -1));
    try std.testing.expectEqualStrings("ZXCAML_PANIC:division_by_zero", runtime_panic.division_by_zero_marker);
}
