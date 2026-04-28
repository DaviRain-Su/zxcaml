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
    type_decls: []const LVariantType = &.{},
};

/// A lowered function using the P1 arena-threaded calling convention.
pub const LFunc = struct {
    name: []const u8,
    params: []const LParam = &.{},
    captures: []const LParam = &.{},
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
    /// ADR-007 first-class closure code pointer convention.
    Closure,
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
    Closure: LClosure,
};

/// Lowered function application.
pub const LApp = struct {
    callee: *const LExpr,
    args: []const *const LExpr,
    kind: LCallKind = .Direct,
};

/// Whether a lowered application calls a named helper directly or a closure pointer.
pub const LCallKind = enum {
    Direct,
    Closure,
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

/// Arena-allocated closure record value with a code pointer and captured values.
pub const LClosure = struct {
    name: []const u8,
    captures: []const LClosureCapture = &.{},
};

/// One captured value stored in a closure record.
pub const LClosureCapture = struct {
    name: []const u8,
    ty: LTy,
};

/// Lowered constructor expression.
pub const LCtor = struct {
    name: []const u8,
    args: []const *const LExpr,
    ty: LTy,
    layout: @import("../core/layout.zig").Layout,
    tag: u32 = 0,
    type_name: ?[]const u8 = null,
};

/// Lowered pattern match expression. Arms keep source order; first match wins.
pub const LMatch = struct {
    scrutinee: *const LExpr,
    arms: []const LArm,
};

/// Lowered match arm.
pub const LArm = struct {
    pattern: LPattern,
    guard: ?*const LExpr = null,
    body: *const LExpr,
};

/// Lowered recursive pattern subset.
pub const LPattern = union(enum) {
    Wildcard,
    Var: []const u8,
    Ctor: LCtorPattern,
};

/// Lowered constructor pattern, including nested constructor payloads.
pub const LCtorPattern = struct {
    name: []const u8,
    args: []const LPattern,
    tag: u32 = 0,
    type_name: ?[]const u8 = null,
};

/// Lowered user-defined ADT declaration.
pub const LVariantType = struct {
    name: []const u8,
    params: []const []const u8 = &.{},
    variants: []const LVariantCtor,
    is_recursive: bool = false,
};

/// Lowered user-defined ADT constructor metadata.
pub const LVariantCtor = struct {
    name: []const u8,
    tag: u32,
    payload_types: []const LTypeExpr = &.{},
};

/// Lowered type expressions used by user-defined constructor payloads.
pub const LTypeExpr = union(enum) {
    TypeVar: []const u8,
    TypeRef: LTypeRef,
    RecursiveRef: LTypeRef,
    Tuple: []const LTypeExpr,
};

/// Lowered named type reference.
pub const LTypeRef = struct {
    name: []const u8,
    args: []const LTypeExpr = &.{},
};

/// Lowered type information needed by source emission.
pub const LTy = union(enum) {
    Int,
    Bool,
    Unit,
    String,
    Var: []const u8,
    Adt: LAdt,
    Closure,
};

/// Lowered ADT type reference.
pub const LAdt = struct {
    name: []const u8,
    params: []const LTy,
};
