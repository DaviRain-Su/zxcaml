//! CONTRACT: Core IR data model for the ZxCaml compiler pipeline.
//!
//! This file is the stable Core IR contract described by `docs/03-core-ir.md`;
//! changes to its shape must update all consumers in the same commit.
//!
//! RESPONSIBILITIES:
//! - Represent the ANF, typed, Layout-tagged Core IR data model.
//! - Keep allocation-bearing nodes explicit about their `Layout`.
//! - Serve consumers: `anf`, `lower`, `interp`, `zig_codegen`, and `pretty`.

const layout = @import("layout.zig");

/// A Core IR module containing top-level declarations.
pub const Module = struct {
    decls: []const Decl,
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
    Let: LetExpr,
    Var: Var,
};

/// Lexically-scoped let expression in ANF form.
pub const LetExpr = struct {
    name: []const u8,
    value: *const Expr,
    body: *const Expr,
    ty: Ty,
    layout: layout.Layout,
};

/// Integer constant expression with type and layout annotations.
pub const Constant = struct {
    value: i64,
    ty: Ty,
    layout: layout.Layout,
};

/// Variable reference with type and layout inherited from its binding.
pub const Var = struct {
    name: []const u8,
    ty: Ty,
    layout: layout.Layout,
};

/// M1 type language needed to describe current examples.
pub const Ty = union(enum) {
    Int,
    Unit,
    Arrow: Arrow,
};

/// Multi-argument arrow type.
pub const Arrow = struct {
    params: []const Ty,
    ret: *const Ty,
};
