//! Typed mirror definitions for the M1 P3 ZxCaml frontend S-expression format.
//!
//! RESPONSIBILITIES:
//! - Define the `Module -> Decl -> Expr` typed mirror structs and unions.
//! - Keep all compiler-internal allocation explicit through a caller arena.

const std = @import("std");

/// Source location carried by wire 1.2+ expression nodes.
pub const Loc = struct {
    file: []const u8,
    line: u32,
    col: u32,
    end_line: u32,
    end_col: u32,

    pub const unknown: Loc = .{
        .file = "_unknown_",
        .line = 0,
        .col = 0,
        .end_line = 0,
        .end_col = 0,
    };

    pub fn isUnknown(self: Loc) bool {
        return self.line == 0 and self.end_line == 0 and std.mem.eql(u8, self.file, "_unknown_");
    }
};

/// Typed mirror of an accepted frontend module.
pub const Module = struct {
    decls: []const Decl,
    type_decls: []const TypeDecl = &.{},
    tuple_type_decls: []const TupleTypeDecl = &.{},
    record_type_decls: []const RecordTypeDecl = &.{},
    type_alias_decls: []const TypeAliasDecl = &.{},
    externals: []const ExternalDecl = &.{},
};

/// Typed mirror of an accepted top-level declaration.
pub const Decl = union(enum) {
    Let: LetDecl,
    LetRecGroup: LetRecGroupDecl,
};

/// Top-level `let` declaration.
pub const LetDecl = struct {
    name: []const u8,
    body: Expr,
    is_rec: bool = false,
};

/// One binding in a mutually recursive value group.
pub const LetRecBinding = struct {
    name: []const u8,
    params: []const []const u8,
    /// Lockstep with `params`. See `Lambda.param_types`.
    param_types: []const ?TypeExpr = &.{},
    body: Expr,
};

/// Top-level `let rec ... and ...` group.
pub const LetRecGroupDecl = struct {
    bindings: []const LetRecBinding,
};

/// Top-level external declaration emitted by sexp v1.0.
pub const ExternalDecl = struct {
    name: []const u8,
    ty: ExternalTypeExpr,
    symbol: []const u8,
};

/// Type expression language used by external declarations.
pub const ExternalTypeExpr = union(enum) {
    TypeRef: ExternalTypeRef,
    Tuple: []const ExternalTypeExpr,
    Arrow: ExternalTypeArrow,
};

/// Named external type reference, optionally applied to type arguments.
pub const ExternalTypeRef = struct {
    name: []const u8,
    args: []const ExternalTypeExpr,
};

/// Function arrow type for external declarations.
pub const ExternalTypeArrow = struct {
    arg: *const ExternalTypeExpr,
    result: *const ExternalTypeExpr,
};

/// Top-level user-authored ADT declaration emitted by sexp v0.6.
pub const TypeDecl = struct {
    name: []const u8,
    params: []const []const u8,
    variants: []const TypeVariant,
    is_recursive: bool = false,
};

/// One constructor in a variant type declaration.
pub const TypeVariant = struct {
    name: []const u8,
    payload_types: []const TypeExpr,
};

/// Top-level tuple type alias emitted by sexp v0.7.
pub const TupleTypeDecl = struct {
    name: []const u8,
    params: []const []const u8,
    items: []const TypeExpr,
    is_recursive: bool = false,
};

/// Top-level record type declaration emitted by sexp v0.7.
pub const RecordTypeDecl = struct {
    name: []const u8,
    params: []const []const u8,
    fields: []const RecordTypeField,
    is_recursive: bool = false,
    is_account: bool = false,
};

/// Top-level erased type alias emitted by sexp v1.1.
pub const TypeAliasDecl = struct {
    name: []const u8,
    params: []const []const u8,
    rhs: TypeExpr,
};

/// One record field in a type declaration.
pub const RecordTypeField = struct {
    name: []const u8,
    ty: TypeExpr,
    is_mutable: bool = false,
};

/// Type expression language used inside ADT constructor payloads.
pub const TypeExpr = union(enum) {
    TypeVar: []const u8,
    TypeRef: TypeRef,
    RecursiveRef: TypeRef,
    Tuple: []const TypeExpr,
};

/// Named type reference, optionally applied to type arguments.
pub const TypeRef = struct {
    name: []const u8,
    args: []const TypeExpr,
};

/// Typed mirror of accepted expressions.
pub const Expr = union(enum) {
    Lambda: Lambda,
    Constant: Constant,
    App: App,
    Let: LetExpr,
    LetRecGroup: LetRecGroupExpr,
    Assert: AssertExpr,
    If: IfExpr,
    Prim: Prim,
    Var: Var,
    Ctor: Ctor,
    Match: Match,
    Tuple: Tuple,
    TupleProj: TupleProj,
    Record: Record,
    RecordField: RecordField,
    RecordUpdate: RecordUpdate,
    FieldSet: FieldSet,
    ArrayLit: ArrayLit,
    ArrayGet: ArrayGet,
    ArrayLength: ArrayLength,
    ArraySet: ArraySet,
    ArrayMake: ArrayMake,
    RefMake: RefMake,
    RefGet: RefGet,
    RefSet: RefSet,
};

/// ADR-015 option C / R10: arena-allocated single-slot ref cell.
pub const RefMake = struct {
    elem_ty: TypeExpr,
    init: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option C / R10: ref cell dereference (`!r`).
pub const RefGet = struct {
    target: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option C / R10: ref cell assignment (`r := v`).
pub const RefSet = struct {
    target: *const Expr,
    value: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option B / R9.1: read-only int array literal.
pub const ArrayLit = struct {
    /// Element type as carried by the wire 1.4 envelope. R9.1 only emits
    /// `(type-ref int)`; non-int element types are rejected upstream
    /// (frontend E0040).
    elem_ty: TypeExpr,
    elems: []const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option B / R9.1: read-only array indexed access (`a.(i)`).
pub const ArrayGet = struct {
    arr: *const Expr,
    idx: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option B / R9.1: array length (`Array.length a`).
pub const ArrayLength = struct {
    arr: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option B / R9.2: in-place int array write
/// (`Array.set a i v` or `a.(i) <- v`).
pub const ArraySet = struct {
    arr: *const Expr,
    idx: *const Expr,
    value: *const Expr,
    loc: Loc = Loc.unknown,
};

/// ADR-015 option B / R9.2: `Array.make N init` where `N` is a positive
/// int literal known at parse time and the element type is `Int`.
pub const ArrayMake = struct {
    elem_ty: TypeExpr,
    size: u32,
    init: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Single lambda form.
pub const Lambda = struct {
    params: []const []const u8,
    /// One entry per `params`, in lockstep. Wire 1.3 emits an explicit type per
    /// parameter; wire <=1.2 emits the bare-name form and the bridge fills
    /// these with `null` so downstream consumers fall back to heuristics.
    param_types: []const ?TypeExpr = &.{},
    body: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Function application expression.
pub const App = struct {
    callee: *const Expr,
    args: []const Expr,
    loc: Loc = Loc.unknown,
};

/// Nested `let NAME = VALUE in BODY` expression.
pub const LetExpr = struct {
    name: []const u8,
    value: *const Expr,
    body: *const Expr,
    is_rec: bool = false,
    loc: Loc = Loc.unknown,
};

/// Nested `let rec A = ... and B = ... in BODY` expression.
pub const LetRecGroupExpr = struct {
    bindings: []const LetRecBinding,
    body: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Assert expression whose condition must evaluate to true.
pub const AssertExpr = struct {
    condition: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Conditional expression with an explicit else branch.
pub const IfExpr = struct {
    cond: *const Expr,
    then_branch: *const Expr,
    else_branch: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Primitive integer/comparison operation.
pub const Prim = struct {
    op: []const u8,
    args: []const Expr,
    loc: Loc = Loc.unknown,
};

/// Variable reference expression.
pub const Var = struct {
    name: []const u8,
    loc: Loc = Loc.unknown,
};

/// Constructor expression such as `None`, `Some x`, `Ok x`, `Error e`, `[]`, or `x :: xs`.
pub const Ctor = struct {
    name: []const u8,
    args: []const Expr,
    loc: Loc = Loc.unknown,
};

/// Tuple construction expression.
pub const Tuple = struct {
    items: []const Expr,
    loc: Loc = Loc.unknown,
};

/// Tuple projection expression, emitted for `fst`/`snd` helpers.
pub const TupleProj = struct {
    tuple_expr: *const Expr,
    index: usize,
    loc: Loc = Loc.unknown,
};

/// Record construction expression with source-order fields.
pub const Record = struct {
    fields: []const RecordExprField,
    loc: Loc = Loc.unknown,
};

/// One field assignment in a record construction/update expression.
pub const RecordExprField = struct {
    name: []const u8,
    value: Expr,
};

/// Record field access expression.
pub const RecordField = struct {
    record_expr: *const Expr,
    field_name: []const u8,
    loc: Loc = Loc.unknown,
};

/// Functional record update expression.
pub const RecordUpdate = struct {
    base_expr: *const Expr,
    fields: []const RecordExprField,
    loc: Loc = Loc.unknown,
};

/// In-place record field assignment expression emitted for mutable fields.
pub const FieldSet = struct {
    record_expr: *const Expr,
    field_name: []const u8,
    value: *const Expr,
    loc: Loc = Loc.unknown,
};

/// Pattern match expression with arms evaluated top-to-bottom.
pub const Match = struct {
    scrutinee: *const Expr,
    arms: []const Arm,
    loc: Loc = Loc.unknown,
};

/// Single match arm.
pub const Arm = struct {
    pattern: Pattern,
    guard: ?*const Expr = null,
    body: *const Expr,
};

/// Recursive pattern forms accepted for match arms.
pub const Pattern = union(enum) {
    Wildcard,
    Var: []const u8,
    Const: PatternConstant,
    Ctor: CtorPattern,
    Tuple: []const Pattern,
    Record: []const RecordPatternField,
    Alias: AliasPattern,
    Or: []const Pattern,
};

/// Literal constant pattern such as `0`, `"hello"`, or `'a'`.
pub const PatternConstant = union(enum) {
    Int: i64,
    String: []const u8,
    Char: i64,
};

/// Alias pattern such as `p as name`.
pub const AliasPattern = struct {
    pattern: *const Pattern,
    name: []const u8,
};

/// Constructor pattern such as `Some x`, `None`, `[]`, `x :: xs`, or nested constructor payloads.
pub const CtorPattern = struct {
    name: []const u8,
    args: []const Pattern,
};

/// One field pattern inside a record pattern.
pub const RecordPatternField = struct {
    name: []const u8,
    pattern: Pattern,
};

/// Typed mirror of constants.
pub const Constant = union(enum) {
    Int: i64,
    String: []const u8,
};
