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

/// Optional source location threaded from frontend wire 1.2.
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
        return self.line == 0 and self.end_line == 0;
    }
};

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
    loc: ?Loc = null,
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

/// Returns the optional source location carried by any Core IR expression.
pub fn exprLoc(expr: Expr) ?Loc {
    return switch (expr) {
        .Lambda => |value| value.loc,
        .Constant => |value| value.loc,
        .App => |value| value.loc,
        .Let => |value| value.loc,
        .LetGroup => |value| value.loc,
        .Assert => |value| value.loc,
        .If => |value| value.loc,
        .Prim => |value| value.loc,
        .Var => |value| value.loc,
        .Ctor => |value| value.loc,
        .Match => |value| value.loc,
        .Tuple => |value| value.loc,
        .TupleProj => |value| value.loc,
        .Record => |value| value.loc,
        .RecordField => |value| value.loc,
        .RecordUpdate => |value| value.loc,
        .AccountFieldSet => |value| value.loc,
    };
}

/// Overwrites the optional source location on any Core IR expression.
pub fn setExprLoc(expr: *Expr, loc: ?Loc) void {
    switch (expr.*) {
        .Lambda => |*value| value.loc = loc,
        .Constant => |*value| value.loc = loc,
        .App => |*value| value.loc = loc,
        .Let => |*value| value.loc = loc,
        .LetGroup => |*value| value.loc = loc,
        .Assert => |*value| value.loc = loc,
        .If => |*value| value.loc = loc,
        .Prim => |*value| value.loc = loc,
        .Var => |*value| value.loc = loc,
        .Ctor => |*value| value.loc = loc,
        .Match => |*value| value.loc = loc,
        .Tuple => |*value| value.loc = loc,
        .TupleProj => |*value| value.loc = loc,
        .Record => |*value| value.loc = loc,
        .RecordField => |*value| value.loc = loc,
        .RecordUpdate => |*value| value.loc = loc,
        .AccountFieldSet => |*value| value.loc = loc,
    }
}

/// Function application expression.
pub const App = struct {
    callee: *const Expr,
    args: []const *const Expr,
    ty: Ty,
    layout: layout.Layout,
    is_tail_call: bool = false,
    loc: ?Loc = null,
};

/// Lexically-scoped let expression in ANF form.
pub const LetExpr = struct {
    name: []const u8,
    value: *const Expr,
    body: *const Expr,
    ty: Ty,
    layout: layout.Layout,
    is_rec: bool = false,
    loc: ?Loc = null,
};

/// Lexically-scoped mutually recursive group in ANF form.
pub const LetGroupExpr = struct {
    bindings: []const LetGroupBinding,
    body: *const Expr,
    ty: Ty,
    layout: layout.Layout,
    loc: ?Loc = null,
};

/// Runtime assertion that traps when its boolean condition is false.
pub const AssertExpr = struct {
    condition: *const Expr,
    ty: Ty,
    layout: layout.Layout,
    loc: ?Loc = null,
};

/// Conditional expression.
pub const IfExpr = struct {
    cond: *const Expr,
    then_branch: *const Expr,
    else_branch: *const Expr,
    ty: Ty,
    layout: layout.Layout,
    loc: ?Loc = null,
};

/// Primitive integer/comparison operation.
pub const Prim = struct {
    op: PrimOp,
    args: []const *const Expr,
    ty: Ty,
    layout: layout.Layout,
    loc: ?Loc = null,
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
    loc: ?Loc = null,
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
    loc: ?Loc = null,
};

/// Constructor expression for whitelisted option/result/list ADTs.
pub const Ctor = struct {
    name: []const u8,
    args: []const *const Expr,
    ty: Ty,
    layout: layout.Layout,
    tag: u32 = 0,
    type_name: ?[]const u8 = null,
    loc: ?Loc = null,
};

/// Tuple construction expression.
pub const Tuple = struct {
    items: []const *const Expr,
    ty: Ty,
    layout: layout.Layout,
    loc: ?Loc = null,
};

/// Tuple projection expression.
pub const TupleProj = struct {
    tuple_expr: *const Expr,
    index: usize,
    ty: Ty,
    layout: layout.Layout,
    loc: ?Loc = null,
};

/// Record construction expression.
pub const Record = struct {
    fields: []const RecordExprField,
    ty: Ty,
    layout: layout.Layout,
    loc: ?Loc = null,
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
    loc: ?Loc = null,
};

/// Functional record update expression.
pub const RecordUpdate = struct {
    base_expr: *const Expr,
    fields: []const RecordExprField,
    ty: Ty,
    layout: layout.Layout,
    loc: ?Loc = null,
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
    loc: ?Loc = null,
};

/// Pattern match expression; arms are evaluated top-to-bottom.
pub const Match = struct {
    scrutinee: *const Expr,
    arms: []const Arm,
    ty: Ty,
    layout: layout.Layout,
    loc: ?Loc = null,
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
