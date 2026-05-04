const std = @import("std");
const ir = @import("../ir.zig");
const types = @import("../types.zig");

pub const LowerError = std.mem.Allocator.Error || error{
    UnsupportedNode,
    UnboundVariable,
    UnsupportedCtor,
    UnsupportedCtorArity,
    UnsupportedPattern,
    UnsupportedPrim,
    UnsupportedPrimArity,
    MatchWithoutArms,
};

pub const BindingInfo = struct {
    ty: ir.Ty,
    layout: @import("../layout.zig").Layout,
};

pub const ConstructorInfo = struct {
    type_name: []const u8,
    tag: u32,
    payload_types: []const types.TypeExpr,
    type_params: []const []const u8,
};

pub const ScopedBinding = struct {
    name: []const u8,
    previous: ?BindingInfo,
};

pub const TypeBindings = std.StringHashMap(ir.Ty);

pub const LowerContext = struct {
    scope: std.StringHashMap(BindingInfo),
    constructors: std.StringHashMap(ConstructorInfo),
    tuple_type_decls: []const types.TupleType = &.{},
    record_type_decls: []const types.RecordType = &.{},
    next_temp: usize = 0,
};
