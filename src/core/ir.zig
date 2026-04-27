//! CONTRACT: Core IR data model for the ZxCaml compiler pipeline.
//!
//! This file is the stable Core IR contract described by `docs/03-core-ir.md`;
//! changes to its shape must update all consumers in the same commit.
//!
//! RESPONSIBILITIES:
//! - Represent the M0 ANF, typed, Layout-tagged Core IR data model.
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

/// M0 top-level let declaration, restricted to a lambda value.
pub const Let = struct {
    name: []const u8,
    lambda: Lambda,
};

/// Core IR lambda in ANF form.
pub const Lambda = struct {
    params: []const Param,
    body: Expr,
    ty: Ty,
    layout: layout.Layout,
};

/// Lambda parameter with a resolved type.
pub const Param = struct {
    name: []const u8,
    ty: Ty,
};

/// M0 Core IR expression.
pub const Expr = union(enum) {
    Constant: Constant,
};

/// Integer constant expression with type and layout annotations.
pub const Constant = struct {
    value: i64,
    ty: Ty,
    layout: layout.Layout,
};

/// M0 type language needed to describe `let entrypoint _input = 0`.
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
