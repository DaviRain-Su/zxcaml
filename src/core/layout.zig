//! Layout descriptors for Core IR allocation and representation choices.
//!
//! RESPONSIBILITIES:
//! - Define the `Region`, `Repr`, and `Layout` extension point from `docs/03-core-ir.md`.
//! - Centralize the M0 default layout derivation rules used by ANF lowering.
//! - Keep future region/repr growth localized to this file.

const std = @import("std");

/// Memory region selected for a Core IR value.
pub const Region = enum {
    /// P1 default for runtime-owned values.
    Arena,
    /// Compile-time literals and other immutable static data.
    Static,
    /// Obvious non-escaping locals; reserved for post-M0 inference.
    Stack,
};

/// Physical representation selected for a Core IR value.
pub const Repr = enum {
    /// Inline flat value.
    Flat,
    /// Pointer to an out-of-line value.
    Boxed,
    /// Small tagged value such as future nullary constructors.
    TaggedImmediate,
};

/// Layout annotation carried by Core IR nodes that need representation decisions.
pub const Layout = struct {
    region: Region,
    repr: Repr,
};

/// M0 value classes that have a deterministic default layout.
pub const DefaultKind = enum {
    IntConstant,
    UnitValue,
    TopLevelLambda,
    Aggregate,
    StringLiteral,
};

/// Returns the default M0 layout for a value class.
pub fn defaultFor(kind: DefaultKind) Layout {
    return switch (kind) {
        .IntConstant => .{ .region = .Static, .repr = .Flat },
        .UnitValue => .{ .region = .Static, .repr = .Flat },
        .TopLevelLambda => .{ .region = .Arena, .repr = .Flat },
        .Aggregate => .{ .region = .Arena, .repr = .Boxed },
        .StringLiteral => .{ .region = .Static, .repr = .Boxed },
    };
}

/// Returns the M0 layout for integer constants.
pub fn intConstant() Layout {
    return defaultFor(.IntConstant);
}

/// Returns the M1 layout for unit values and unit-typed lambda parameters.
pub fn unitValue() Layout {
    return defaultFor(.UnitValue);
}

/// Returns the M0 layout for top-level lambdas.
pub fn topLevelLambda() Layout {
    return defaultFor(.TopLevelLambda);
}

/// Returns the M1 layout for a constructor with `arg_count` payload fields.
pub fn ctor(arg_count: usize) Layout {
    if (arg_count == 0) {
        return .{ .region = .Static, .repr = .TaggedImmediate };
    }
    return defaultFor(.Aggregate);
}

test "M0 default layout derivation" {
    try std.testing.expectEqual(Layout{ .region = .Static, .repr = .Flat }, intConstant());
    try std.testing.expectEqual(Layout{ .region = .Static, .repr = .Flat }, unitValue());
    try std.testing.expectEqual(Layout{ .region = .Arena, .repr = .Flat }, topLevelLambda());
    try std.testing.expectEqual(Layout{ .region = .Arena, .repr = .Boxed }, defaultFor(.Aggregate));
    try std.testing.expectEqual(Layout{ .region = .Static, .repr = .Boxed }, defaultFor(.StringLiteral));
    try std.testing.expectEqual(Layout{ .region = .Static, .repr = .TaggedImmediate }, ctor(0));
    try std.testing.expectEqual(Layout{ .region = .Arena, .repr = .Boxed }, ctor(1));
}
