//! Lowered IR consumed by source-emitting backends after memory lowering.
//!
//! RESPONSIBILITIES:
//! - Represent the M0 Lowered IR module shape produced by ArenaStrategy.
//! - Keep the backend input independent from frontend_bridge and Core IR.
//! - Record the arena-threaded calling convention required by ADR-007.

/// A lowered module with the single M0 user entrypoint.
pub const LModule = struct {
    entrypoint: LFunc,
};

/// A lowered function using the P1 arena-threaded calling convention.
pub const LFunc = struct {
    name: []const u8,
    body: LExpr,
    calling_convention: CallingConvention = .ArenaThreaded,
    source_span: SourceSpan = .unavailable,
};

/// Calling conventions available to lowered functions.
pub const CallingConvention = enum {
    /// ADR-007: `arena: *Arena` is the implicit first parameter.
    ArenaThreaded,
};

/// Source span carried into generated comments; M0 has no real spans yet.
pub const SourceSpan = union(enum) {
    unavailable,
};

/// Lowered expression.
pub const LExpr = union(enum) {
    Constant: LConstant,
    Let: LLet,
    Var: LVar,
    Ctor: LCtor,
};

/// M0 lowered constants.
pub const LConstant = union(enum) {
    Int: i64,
    String: []const u8,
};

/// Lowered lexical let expression.
pub const LLet = struct {
    name: []const u8,
    value: *const LExpr,
    body: *const LExpr,
};

/// Lowered variable reference.
pub const LVar = struct {
    name: []const u8,
};

/// Lowered constructor expression.
pub const LCtor = struct {
    name: []const u8,
    args: []const *const LExpr,
    ty: LTy,
    layout: @import("../core/layout.zig").Layout,
};

/// Lowered type information needed by source emission.
pub const LTy = union(enum) {
    Int,
    Unit,
    String,
    Adt: LAdt,
};

/// Lowered ADT type reference.
pub const LAdt = struct {
    name: []const u8,
    params: []const LTy,
};
