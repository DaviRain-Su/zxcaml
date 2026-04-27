//! Runtime prelude helpers used by generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Provide arena-friendly tagged unions for option/result constructors.
//! - Keep constructor helpers allocation-free unless generated Layout code allocates.
//! - Stay dependency-free for BPF-compatible generated programs.

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
