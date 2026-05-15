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
    tuple_type_decls: []const LTupleType = &.{},
    record_type_decls: []const LRecordType = &.{},
    externals: []const LExternalDecl = &.{},
};

/// A lowered function using the P1 arena-threaded calling convention.
pub const LFunc = struct {
    name: []const u8,
    params: []const LParam = &.{},
    captures: []const LParam = &.{},
    return_ty: LTy = .Int,
    body: LExpr,
    calling_convention: CallingConvention = .ArenaThreaded,
    source_span: SourceSpan = .unavailable,
};

/// Lowered function parameter.
pub const LParam = struct {
    name: []const u8,
    ty: LTy,
};

/// Lowered external function declaration with its direct Zig symbol.
pub const LExternalDecl = struct {
    name: []const u8,
    ty: LTy,
    symbol: []const u8,
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
    Assert: LAssert,
    If: LIf,
    Prim: LPrim,
    Var: LVar,
    Ctor: LCtor,
    Match: LMatch,
    Closure: LClosure,
    Tuple: LTuple,
    TupleProj: LTupleProj,
    Record: LRecord,
    RecordField: LRecordField,
    RecordUpdate: LRecordUpdate,
    AccountFieldSet: LAccountFieldSet,
    ArrayLit: LArrayLit,
    ArrayGet: LArrayGet,
    ArrayLength: LArrayLength,
    ArraySet: LArraySet,
    ArrayMake: LArrayMake,
    RefMake: LRefMake,
    RefGet: LRefGet,
    RefSet: LRefSet,
};

/// ADR-015 R9.1 lowered int-array literal.
pub const LArrayLit = struct {
    elem_ty: LTy,
    elems: []const *const LExpr,
    ty: LTy = .Int,
    layout: @import("../core/layout.zig").Layout = .{ .region = .Static, .repr = .Flat },
};

/// ADR-015 R9.1 lowered read-only array index access.
pub const LArrayGet = struct {
    arr: *const LExpr,
    idx: *const LExpr,
    ty: LTy = .Int,
    layout: @import("../core/layout.zig").Layout = .{ .region = .Static, .repr = .Flat },
};

/// ADR-015 R9.1 lowered array length probe.
pub const LArrayLength = struct {
    arr: *const LExpr,
    ty: LTy = .Int,
    layout: @import("../core/layout.zig").Layout = .{ .region = .Static, .repr = .Flat },
};

/// ADR-015 R9.2 lowered in-place int array write.
pub const LArraySet = struct {
    arr: *const LExpr,
    idx: *const LExpr,
    value: *const LExpr,
    ty: LTy = .Unit,
    layout: @import("../core/layout.zig").Layout = .{ .region = .Static, .repr = .Flat },
};

/// ADR-015 R9.2 lowered `Array.make N init` with literal size.
pub const LArrayMake = struct {
    elem_ty: LTy,
    size: u32,
    init: *const LExpr,
    ty: LTy,
    layout: @import("../core/layout.zig").Layout = .{ .region = .Static, .repr = .Flat },
};

/// ADR-015 option C / R10 lowered ref-cell allocation.
pub const LRefMake = struct {
    elem_ty: LTy,
    init: *const LExpr,
    ty: LTy,
    layout: @import("../core/layout.zig").Layout = .{ .region = .Static, .repr = .Flat },
};

/// ADR-015 option C / R10 lowered ref-cell read.
pub const LRefGet = struct {
    target: *const LExpr,
    ty: LTy,
    layout: @import("../core/layout.zig").Layout = .{ .region = .Static, .repr = .Flat },
};

/// ADR-015 option C / R10 lowered ref-cell write (yields unit/int 0).
pub const LRefSet = struct {
    target: *const LExpr,
    value: *const LExpr,
    ty: LTy = .Unit,
    layout: @import("../core/layout.zig").Layout = .{ .region = .Static, .repr = .Flat },
};

/// Lowered function application.
pub const LApp = struct {
    callee: *const LExpr,
    args: []const *const LExpr,
    ty: LTy = .Int,
    callee_ty: LTy = .Int,
    kind: LCallKind = .Direct,
    is_tail_call: bool = false,
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
    ty: LTy = .Int,
    layout: @import("../core/layout.zig").Layout = .{ .region = .Static, .repr = .Flat },
    is_rec: bool = false,
};

/// Lowered runtime assertion that traps if condition evaluates false.
pub const LAssert = struct {
    condition: *const LExpr,
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
    StringLength,
    StringGet,
    StringSub,
    StringConcat,
    CharCode,
    CharChr,
    BitAnd,
    BitOr,
    BitXor,
    ShiftLeft,
    ShiftRight,
    BitNot,
    BytesCreate,
    BytesSet,
    BytesBlit,
    BytesFill,
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

/// Lowered tuple construction expression.
pub const LTuple = struct {
    items: []const *const LExpr,
    ty: LTy,
};

/// Lowered tuple projection expression.
pub const LTupleProj = struct {
    tuple_expr: *const LExpr,
    index: usize,
};

/// Lowered record construction expression.
pub const LRecord = struct {
    fields: []const LRecordExprField,
    ty: LTy,
};

/// Lowered record expression field.
pub const LRecordExprField = struct {
    name: []const u8,
    value: *const LExpr,
};

/// Lowered record field access expression.
pub const LRecordField = struct {
    record_expr: *const LExpr,
    field_name: []const u8,
    record_ty: ?LTy = null,
};

/// Lowered functional record update expression.
pub const LRecordUpdate = struct {
    base_expr: *const LExpr,
    fields: []const LRecordExprField,
    ty: LTy,
};

/// Lowered in-place mutation of a writable Solana account field.
pub const LAccountFieldSet = struct {
    account_expr: *const LExpr,
    field_name: []const u8,
    value: *const LExpr,
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
    Constant: LPatternConstant,
    Ctor: LCtorPattern,
    Tuple: []const LPattern,
    Record: []const LRecordPatternField,
    Alias: LAliasPattern,
};

/// Lowered literal constant pattern.
pub const LPatternConstant = union(enum) {
    Int: i64,
    String: []const u8,
    Char: i64,
};

/// Lowered alias pattern.
pub const LAliasPattern = struct {
    pattern: *const LPattern,
    name: []const u8,
};

/// Lowered constructor pattern, including nested constructor payloads.
pub const LCtorPattern = struct {
    name: []const u8,
    args: []const LPattern,
    tag: u32 = 0,
    type_name: ?[]const u8 = null,
};

/// Lowered record pattern field.
pub const LRecordPatternField = struct {
    name: []const u8,
    pattern: LPattern,
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

/// Lowered tuple type declaration.
pub const LTupleType = struct {
    name: []const u8,
    params: []const []const u8 = &.{},
    items: []const LTypeExpr = &.{},
    is_recursive: bool = false,
};

/// Lowered record type declaration.
pub const LRecordType = struct {
    name: []const u8,
    params: []const []const u8 = &.{},
    fields: []const LRecordTypeField = &.{},
    is_recursive: bool = false,
};

/// One lowered record type field.
pub const LRecordTypeField = struct {
    name: []const u8,
    ty: LTypeExpr,
    is_mutable: bool = false,
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
    Tuple: []const LTy,
    Record: LRecordTy,
    Closure: LClosureTy,
    /// ADR-015 R9.1 lowered array type. Mirrors `ir.Ty.Array`.
    Array: *const LTy,
    /// ADR-015 option C / R10 lowered ref-cell type. Mirrors `ir.Ty.Ref`.
    Ref: *const LTy,
};

/// Lowered ADT type reference.
pub const LAdt = struct {
    name: []const u8,
    params: []const LTy,
};

/// Lowered first-class function type carried for typed closure calls.
pub const LClosureTy = struct {
    params: []const LTy,
    ret: *const LTy,
};

/// Lowered nominal record type reference.
pub const LRecordTy = struct {
    name: []const u8,
    params: []const LTy,
};
