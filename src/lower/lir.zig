//! Lowered IR consumed by source-emitting backends after memory lowering.
//!
//! RESPONSIBILITIES:
//! - Represent the M0 Lowered IR module shape produced by ArenaStrategy.
//! - Keep the backend input independent from frontend_bridge and Core IR.
//! - Record the arena-threaded calling convention required by ADR-007.

/// A lowered module with the single M0 user entrypoint.
pub const LModule = struct {
    entrypoint: LFunc,
    functions: []const LFunc = &.{},
};

/// A lowered function using the P1 arena-threaded calling convention.
pub const LFunc = struct {
    name: []const u8,
    params: []const LParam = &.{},
    body: LExpr,
    calling_convention: CallingConvention = .ArenaThreaded,
    source_span: SourceSpan = .unavailable,
};

/// Lowered function parameter.
pub const LParam = struct {
    name: []const u8,
    ty: LTy,
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
    App: LApp,
    Let: LLet,
    If: LIf,
    Prim: LPrim,
    Var: LVar,
    Ctor: LCtor,
    Match: LMatch,
};

/// Lowered function application.
pub const LApp = struct {
    callee: *const LExpr,
    args: []const *const LExpr,
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
    is_rec: bool = false,
};

/// Lowered conditional expression.
pub const LIf = struct {
    cond: *const LExpr,
    then_branch: *const LExpr,
    else_branch: *const LExpr,
};

/// Lowered primitive operation.
pub const LPrim = struct {
    op: LPrimOp,
    args: []const *const LExpr,
};

/// Lowered primitive operation kind.
pub const LPrimOp = enum {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
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

/// Lowered pattern match expression. Arms keep source order; first match wins.
pub const LMatch = struct {
    scrutinee: *const LExpr,
    arms: []const LArm,
};

/// Lowered match arm.
pub const LArm = struct {
    pattern: LPattern,
    body: *const LExpr,
};

/// Lowered F11 basic pattern subset.
pub const LPattern = union(enum) {
    Wildcard,
    Var: []const u8,
    Ctor: LCtorPattern,
};

/// Lowered single-level constructor pattern.
pub const LCtorPattern = struct {
    name: []const u8,
    args: []const LPattern,
};

/// Lowered type information needed by source emission.
pub const LTy = union(enum) {
    Int,
    Bool,
    Unit,
    String,
    Adt: LAdt,
};

/// Lowered ADT type reference.
pub const LAdt = struct {
    name: []const u8,
    params: []const LTy,
};
