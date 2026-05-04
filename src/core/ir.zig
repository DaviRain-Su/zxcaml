//! CONTRACT: Core IR data model for the ZxCaml compiler pipeline.
//!
//! This file is the stable Core IR contract described by `docs/03-core-ir.md`;
//! changes to its shape must update all consumers in the same commit.
//!
//! RESPONSIBILITIES:
//! - Represent the ANF, typed, Layout-tagged Core IR data model.
//! - Keep allocation-bearing nodes explicit about their `Layout`.
//! - Serve consumers: `anf`, `lower`, `interp`, `zig_codegen`, and `pretty`.
//! - Preserve pattern-match order: arms are tested top-to-bottom and the first
//!   matching arm wins in every backend.
//!
//! Ctor layout policy (F10/F13):
//! ```text
//! Some(x) -> Ctor { name = "Some", args = [x],
//!                   ty = option<int>,
//!                   layout = { region = Arena, repr = Boxed } }
//!   The backend heap-allocates the discriminant plus payload in the arena,
//!   because payload-bearing ADT values are boxed in P1.
//!
//! None    -> Ctor { name = "None", args = [],
//!                   ty = option<int>,
//!                   layout = { region = Static, repr = TaggedImmediate } }
//!   The value is zero-sized at runtime: only the constructor tag is needed.
//!
//! Ok(x) and Error(e) follow the same result<T,E> rule: payload variants are
//! Arena/Boxed, while future nullary variants would be Static/TaggedImmediate.
//!
//! (::)(head, tail) -> Ctor { name = "::", args = [head, tail],
//!                            ty = list<int>,
//!                            layout = { region = Arena, repr = Boxed } }
//!   Cons cells are heap-allocated in the arena; the runtime payload stores
//!   the head plus a tail pointer.
//!
//! [] -> Ctor { name = "[]", args = [],
//!              ty = list<int>,
//!              layout = { region = Static, repr = TaggedImmediate } }
//!   Nil is zero-sized at runtime: only the empty-list discriminant is needed.
//! ```

const layout = @import("layout.zig");
const types = @import("types.zig");

/// A Core IR module containing top-level declarations.
pub const Module = struct {
    decls: []const Decl,
    type_decls: []const types.VariantType = &.{},
    tuple_type_decls: []const types.TupleType = &.{},
    record_type_decls: []const types.RecordType = &.{},
    externals: []const ExternalDecl = &.{},
};

/// Top-level Core IR declarations.
pub const Decl = union(enum) {
    Let: Let,
    LetGroup: LetGroup,
};

/// Top-level external function declaration with its direct Zig symbol.
pub const ExternalDecl = struct {
    name: []const u8,
    ty: Ty,
    symbol: []const u8,
};

/// Top-level let declaration.
pub const Let = struct {
    name: []const u8,
    value: *const Expr,
    ty: Ty,
    layout: layout.Layout,
    is_rec: bool = false,
};

/// One function binding in a mutually recursive group.
pub const LetGroupBinding = struct {
    name: []const u8,
    value: *const Expr,
    ty: Ty,
    layout: layout.Layout,
};

/// Top-level mutually recursive group.
pub const LetGroup = struct {
    bindings: []const LetGroupBinding,
};

/// Core IR lambda in ANF form.
pub const Lambda = struct {
    params: []const Param,
    body: *const Expr,
    ty: Ty,
    layout: layout.Layout,
};

/// Lambda parameter with a resolved type.
pub const Param = struct {
    name: []const u8,
    ty: Ty,
};

/// Core IR expression.
pub const Expr = union(enum) {
    Lambda: Lambda,
    Constant: Constant,
    App: App,
    Let: LetExpr,
    LetGroup: LetGroupExpr,
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
    AccountFieldSet: AccountFieldSet,
};

/// Function application expression.
pub const App = struct {
    callee: *const Expr,
    args: []const *const Expr,
    ty: Ty,
    layout: layout.Layout,
    is_tail_call: bool = false,
};

/// Lexically-scoped let expression in ANF form.
pub const LetExpr = struct {
    name: []const u8,
    value: *const Expr,
    body: *const Expr,
    ty: Ty,
    layout: layout.Layout,
    is_rec: bool = false,
};

/// Lexically-scoped mutually recursive group in ANF form.
pub const LetGroupExpr = struct {
    bindings: []const LetGroupBinding,
    body: *const Expr,
    ty: Ty,
    layout: layout.Layout,
};

/// Runtime assertion that traps when its boolean condition is false.
pub const AssertExpr = struct {
    condition: *const Expr,
    ty: Ty,
    layout: layout.Layout,
};

/// Conditional expression.
pub const IfExpr = struct {
    cond: *const Expr,
    then_branch: *const Expr,
    else_branch: *const Expr,
    ty: Ty,
    layout: layout.Layout,
};

/// Primitive integer/comparison operation.
pub const Prim = struct {
    op: PrimOp,
    args: []const *const Expr,
    ty: Ty,
    layout: layout.Layout,
};

/// Primitive operations supported by the current Core IR.
pub const PrimOp = enum {
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
};

/// Integer constant expression with type and layout annotations.
pub const Constant = struct {
    value: ConstantValue,
    ty: Ty,
    layout: layout.Layout,
};

/// Literal payload carried by a constant expression.
pub const ConstantValue = union(enum) {
    Int: i64,
    String: []const u8,
};

/// Variable reference with type and layout inherited from its binding.
pub const Var = struct {
    name: []const u8,
    ty: Ty,
    layout: layout.Layout,
};

/// Constructor expression for whitelisted option/result/list ADTs.
pub const Ctor = struct {
    name: []const u8,
    args: []const *const Expr,
    ty: Ty,
    layout: layout.Layout,
    tag: u32 = 0,
    type_name: ?[]const u8 = null,
};

/// Tuple construction expression.
pub const Tuple = struct {
    items: []const *const Expr,
    ty: Ty,
    layout: layout.Layout,
};

/// Tuple projection expression.
pub const TupleProj = struct {
    tuple_expr: *const Expr,
    index: usize,
    ty: Ty,
    layout: layout.Layout,
};

/// Record construction expression.
pub const Record = struct {
    fields: []const RecordExprField,
    ty: Ty,
    layout: layout.Layout,
};

/// One field assignment in a record construction/update expression.
pub const RecordExprField = struct {
    name: []const u8,
    value: *const Expr,
};

/// Record field access expression.
pub const RecordField = struct {
    record_expr: *const Expr,
    field_name: []const u8,
    ty: Ty,
    layout: layout.Layout,
};

/// Functional record update expression.
pub const RecordUpdate = struct {
    base_expr: *const Expr,
    fields: []const RecordExprField,
    ty: Ty,
    layout: layout.Layout,
};

/// AccountFieldSet is the sole mutating Core/ANF expression.
/// It preserves ANF because account-field writes are effects threaded through
/// let/program order, not nested as operands inside other expressions.
/// The ANF lowering pass in src/core/anf/module.zig emits it from writable
/// Solana account-field updates.
pub const AccountFieldSet = struct {
    account_expr: *const Expr,
    field_name: []const u8,
    value: *const Expr,
    ty: Ty,
    layout: layout.Layout,
};

/// Pattern match expression; arms are evaluated top-to-bottom.
pub const Match = struct {
    scrutinee: *const Expr,
    arms: []const Arm,
    ty: Ty,
    layout: layout.Layout,
};

/// One pattern-match arm.
pub const Arm = struct {
    pattern: Pattern,
    guard: ?*const Expr = null,
    body: *const Expr,
};

/// Recursive pattern subset used by match arms.
pub const Pattern = union(enum) {
    Wildcard,
    Var: PatternVar,
    Constant: PatternConstant,
    Ctor: PatternCtor,
    Tuple: []const Pattern,
    Record: []const RecordPatternField,
    Alias: PatternAlias,
};

/// Literal constant pattern used by match arms.
pub const PatternConstant = union(enum) {
    Int: i64,
    String: []const u8,
    Char: i64,
};

/// Alias pattern that binds the full matched value in addition to nested bindings.
pub const PatternAlias = struct {
    pattern: *const Pattern,
    name: []const u8,
    ty: Ty,
    layout: layout.Layout,
};

/// Variable pattern that binds the matched value into the arm body.
pub const PatternVar = struct {
    name: []const u8,
    ty: Ty,
    layout: layout.Layout,
};

/// Constructor pattern such as `Some x`, `None`, `Ok x`, `Error e`, `[]`, `x :: xs`, or nested constructor payloads.
pub const PatternCtor = struct {
    name: []const u8,
    args: []const Pattern,
    tag: u32 = 0,
    type_name: ?[]const u8 = null,
};

/// One field pattern inside a record pattern.
pub const RecordPatternField = struct {
    name: []const u8,
    pattern: Pattern,
};

/// M1 type language needed to describe current examples.
pub const Ty = union(enum) {
    Int,
    Bool,
    Unit,
    String,
    Var: []const u8,
    Adt: Adt,
    Tuple: []const Ty,
    Record: RecordTy,
    Arrow: Arrow,
};

/// Algebraic data type reference with concrete parameter types.
pub const Adt = struct {
    name: []const u8,
    params: []const Ty,
};

/// Multi-argument arrow type.
pub const Arrow = struct {
    params: []const Ty,
    ret: *const Ty,
};

/// Nominal record type reference with concrete parameter types.
pub const RecordTy = struct {
    name: []const u8,
    params: []const Ty,
};
