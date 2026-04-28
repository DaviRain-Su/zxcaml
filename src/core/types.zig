//! Core type declarations for user-defined algebraic data types.
//!
//! RESPONSIBILITIES:
//! - Preserve frontend ADT declaration metadata below the OCaml/Zig boundary.
//! - Assign deterministic constructor tag values for interpreter and backend use.
//! - Describe constructor payload types without depending on backend-specific names.

/// A user-defined variant type declaration with explicit constructor tags.
pub const VariantType = struct {
    name: []const u8,
    params: []const []const u8 = &.{},
    variants: []const VariantCtor,
    is_recursive: bool = false,
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
