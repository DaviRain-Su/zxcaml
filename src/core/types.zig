//! Core type declarations for user-defined algebraic data types and product types.
//!
//! RESPONSIBILITIES:
//! - Preserve frontend ADT declaration metadata below the OCaml/Zig boundary.
//! - Assign deterministic constructor tag values for interpreter and backend use.
//! - Describe constructor payload, tuple, and record field types without depending
//!   on backend-specific names.

/// A user-defined variant type declaration with explicit constructor tags.
pub const VariantType = struct {
    name: []const u8,
    params: []const []const u8 = &.{},
    variants: []const VariantCtor,
    is_recursive: bool = false,
};

/// A tuple type declaration/alias with a fixed ordered element list.
pub const TupleType = struct {
    name: []const u8,
    params: []const []const u8 = &.{},
    items: []const TypeExpr = &.{},
    is_recursive: bool = false,
};

/// A record type declaration with deterministic source-order fields.
pub const RecordType = struct {
    name: []const u8,
    params: []const []const u8 = &.{},
    fields: []const RecordField = &.{},
    is_recursive: bool = false,
    is_account: bool = false,
};

/// One field in a record type declaration.
pub const RecordField = struct {
    name: []const u8,
    ty: TypeExpr,
    is_mutable: bool = false,
};

/// One constructor of a user-defined variant type.
pub const VariantCtor = struct {
    name: []const u8,
    tag: u32,
    payload_types: []const TypeExpr = &.{},
};

/// Type expressions allowed in constructor payload declarations.
pub const TypeExpr = union(enum) {
    TypeVar: []const u8,
    TypeRef: TypeRef,
    RecursiveRef: TypeRef,
    Tuple: []const TypeExpr,
};

/// Named type reference with optional type arguments.
pub const TypeRef = struct {
    name: []const u8,
    args: []const TypeExpr = &.{},
};
