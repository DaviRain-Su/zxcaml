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
};

/// Top-level Core IR declarations.
pub const Decl = union(enum) {
    Let: Let,
};

/// Top-level let declaration.
pub const Let = struct {
    name: []const u8,
    value: *const Expr,
    ty: Ty,
    layout: layout.Layout,
    is_rec: bool = false,
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
    If: IfExpr,
    Prim: Prim,
    Var: Var,
    Ctor: Ctor,
    Match: Match,
};

/// Function application expression.
pub const App = struct {
    callee: *const Expr,
    args: []const *const Expr,
    ty: Ty,
    layout: layout.Layout,
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
    body: *const Expr,
};

/// Basic, non-nested pattern subset used by F11.
pub const Pattern = union(enum) {
    Wildcard,
    Var: PatternVar,
    Ctor: PatternCtor,
};

/// Variable pattern that binds the matched value into the arm body.
pub const PatternVar = struct {
    name: []const u8,
    ty: Ty,
    layout: layout.Layout,
};

/// Single-level constructor pattern such as `Some x`, `None`, `Ok x`, `Error e`, `[]`, or `x :: xs`.
pub const PatternCtor = struct {
    name: []const u8,
    args: []const Pattern,
    tag: u32 = 0,
    type_name: ?[]const u8 = null,
};

/// M1 type language needed to describe current examples.
pub const Ty = union(enum) {
    Int,
    Bool,
    Unit,
    String,
    Adt: Adt,
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
