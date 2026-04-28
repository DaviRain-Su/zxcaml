//! Runtime prelude helpers used by generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Provide arena-friendly tagged unions for bool/option/result/list constructors.
//! - Keep constructor helpers allocation-free unless generated Layout code allocates.
//! - Keep integer helpers and constructor helpers BPF-compatible.

const std = @import("std");
const Arena = @import("arena.zig").Arena;
const runtime_panic = @import("panic.zig");

/// OCaml-style `bool` representation used by generated Zig.
pub const Bool = enum(u1) {
    false = 0,
    true = 1,

    /// Converts a native Zig condition into the bool ADT.
    pub fn fromNative(value: bool) Bool {
        return if (value) .true else .false;
    }

    /// Converts the bool ADT back into the native Zig `if` condition type.
    pub fn toNative(value: Bool) bool {
        return value == .true;
    }
};

/// Runtime value stored inside an arena-allocated closure capture array.
pub const ClosureValue = union(enum) {
    int: i64,
    closure: *const Closure,

    /// Stores an integer capture.
    pub fn fromInt(value: i64) ClosureValue {
        return .{ .int = value };
    }

    /// Stores a closure capture.
    pub fn fromClosure(value: *const Closure) ClosureValue {
        return .{ .closure = value };
    }

    /// Reads an integer capture.
    pub fn asInt(self: ClosureValue) i64 {
        return switch (self) {
            .int => |value| value,
            else => unreachable,
        };
    }

    /// Reads a closure capture.
    pub fn asClosure(self: ClosureValue) *const Closure {
        return switch (self) {
            .closure => |value| value,
            else => unreachable,
        };
    }
};

/// ADR-007 arena closure record: table code id, erased typed captures, and recursive self-reference.
pub const Closure = struct {
    code: u32,
    captures: ?*const anyopaque,
    self: ?*const Closure = null,

    /// Constructs a closure record value; generated code stores it in the arena.
    pub fn init(code: u32, captures: ?*const anyopaque) Closure {
        return .{
            .code = code,
            .captures = captures,
            .self = null,
        };
    }
};

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
    return struct {
        tag: Tag,
        head: T = undefined,
        tail: ?*const @This() = null,

        const Self = @This();
        pub const Tag = enum(u8) { nil, cons };

        /// Heap-allocated cons-cell payload: head plus pointer to the tail list.
        pub const Cons = struct {
            head: T,
            tail: *const Self,
        };

        /// Constructs `[]` without heap allocation.
        pub fn Nil() Self {
            var out: Self = undefined;
            out.tag = .nil;
            return out;
        }

        /// Constructs a cons value from an already-boxed tail pointer.
        pub fn ConsFromTailPtr(head: T, tail: *const Self) Self {
            return .{ .tag = .cons, .head = head, .tail = tail };
        }

        /// Allocates a list value in the arena and returns a stable tail pointer.
        pub fn Box(arena: *Arena, value: Self) *const Self {
            const slot = arena.allocOneOrTrap(Self);
            slot.* = value;
            return slot;
        }

        /// Allocates the tail value and constructs a cons cell that points at it.
        pub fn ConsAlloc(arena: *Arena, head: T, tail: Self) Self {
            return ConsFromTailPtr(head, Box(arena, tail));
        }
    };
}

test "Bool constructors convert to and from native Zig bools" {
    try std.testing.expectEqual(Bool.true, Bool.fromNative(true));
    try std.testing.expectEqual(Bool.false, Bool.fromNative(false));
    try std.testing.expect(Bool.toNative(Bool.true));
    try std.testing.expect(!Bool.toNative(Bool.false));
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
    switch (one.tag) {
        .cons => {
            try @import("std").testing.expectEqual(@as(i64, 1), one.head);
            try @import("std").testing.expect(one.tail != null);
            try @import("std").testing.expectEqual(List(i64).Tag.nil, one.tail.?.tag);
        },
        .nil => return error.TestUnexpectedResult,
    }
}

test "Closure records store code pointer, captures, and self-reference" {
    var buf: [256]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);
    const Captures = struct { value: i64 };
    const captures = arena.alloc(Captures, 1) catch unreachable;
    captures[0] = .{ .value = 2 };
    const slot = arena.alloc(Closure, 1) catch unreachable;
    slot[0] = Closure.init(7, &captures[0]);
    slot[0].self = &slot[0];

    try std.testing.expectEqual(@as(u32, 7), slot[0].code);
    const typed_captures: *const Captures = @ptrCast(@alignCast(slot[0].captures.?));
    try std.testing.expectEqual(@as(i64, 2), typed_captures.value);
    try std.testing.expect(slot[0].self.? == &slot[0]);
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
