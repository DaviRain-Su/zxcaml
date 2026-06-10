//! RESPONSIBILITIES:
//! - Lower ttree type, tuple, record, and external declarations into Core IR.
//! - Translate ttree type expressions into `types.TypeExpr` / `ir.Ty`.
//! - Index variant constructors into the lowering context.

const std = @import("std");
const ttree = @import("../../frontend_bridge/ttree.zig");
const ir = @import("../ir.zig");
const types = @import("../types.zig");
const context = @import("context.zig");
const type_ops = @import("type_ops.zig");

const LowerError = context.LowerError;
const LowerContext = context.LowerContext;

const externalTypeExprToTy = type_ops.externalTypeExprToTy;

pub fn lowerTypeDecls(arena: *std.heap.ArenaAllocator, decls: []const ttree.TypeDecl) LowerError![]const types.VariantType {
    const lowered = try arena.allocator().alloc(types.VariantType, decls.len);
    for (decls, 0..) |decl, decl_index| {
        const variants = try arena.allocator().alloc(types.VariantCtor, decl.variants.len);
        for (decl.variants, 0..) |variant, variant_index| {
            variants[variant_index] = .{
                .name = try arena.allocator().dupe(u8, variant.name),
                .tag = @intCast(variant_index),
                .payload_types = try lowerTypeExprs(arena, variant.payload_types),
            };
        }
        lowered[decl_index] = .{
            .name = try arena.allocator().dupe(u8, decl.name),
            .params = try dupeStringSlice(arena, decl.params),
            .variants = variants,
            .is_recursive = decl.is_recursive,
        };
    }
    return lowered;
}

pub fn lowerTupleTypeDecls(arena: *std.heap.ArenaAllocator, decls: []const ttree.TupleTypeDecl) LowerError![]const types.TupleType {
    const lowered = try arena.allocator().alloc(types.TupleType, decls.len);
    for (decls, 0..) |decl, decl_index| {
        lowered[decl_index] = .{
            .name = try arena.allocator().dupe(u8, decl.name),
            .params = try dupeStringSlice(arena, decl.params),
            .items = try lowerTypeExprs(arena, decl.items),
            .is_recursive = decl.is_recursive,
        };
    }
    return lowered;
}

pub fn lowerRecordTypeDecls(arena: *std.heap.ArenaAllocator, decls: []const ttree.RecordTypeDecl) LowerError![]const types.RecordType {
    const lowered = try arena.allocator().alloc(types.RecordType, decls.len);
    for (decls, 0..) |decl, decl_index| {
        const fields = try arena.allocator().alloc(types.RecordField, decl.fields.len);
        for (decl.fields, 0..) |field, field_index| {
            fields[field_index] = .{
                .name = try arena.allocator().dupe(u8, field.name),
                .ty = try lowerTypeExpr(arena, field.ty),
                .is_mutable = field.is_mutable,
            };
        }
        lowered[decl_index] = .{
            .name = try arena.allocator().dupe(u8, decl.name),
            .params = try dupeStringSlice(arena, decl.params),
            .fields = fields,
            .is_recursive = decl.is_recursive,
            .is_account = decl.is_account,
        };
    }
    return lowered;
}

pub fn lowerExternalDecls(
    arena: *std.heap.ArenaAllocator,
    decls: []const ttree.ExternalDecl,
    record_type_decls: []const types.RecordType,
) LowerError![]const ir.ExternalDecl {
    const lowered = try arena.allocator().alloc(ir.ExternalDecl, decls.len);
    for (decls, 0..) |decl, index| {
        lowered[index] = .{
            .name = try arena.allocator().dupe(u8, decl.name),
            .ty = try externalTypeExprToTy(arena, record_type_decls, decl.ty),
            .symbol = try arena.allocator().dupe(u8, decl.symbol),
        };
    }
    return lowered;
}

pub fn lowerTypeExprs(arena: *std.heap.ArenaAllocator, exprs: []const ttree.TypeExpr) LowerError![]const types.TypeExpr {
    const lowered = try arena.allocator().alloc(types.TypeExpr, exprs.len);
    for (exprs, 0..) |expr, index| {
        lowered[index] = try lowerTypeExpr(arena, expr);
    }
    return lowered;
}

pub fn lowerTypeExpr(arena: *std.heap.ArenaAllocator, expr: ttree.TypeExpr) LowerError!types.TypeExpr {
    return switch (expr) {
        .TypeVar => |name| .{ .TypeVar = try arena.allocator().dupe(u8, name) },
        .TypeRef => |ref| .{ .TypeRef = .{
            .name = try arena.allocator().dupe(u8, ref.name),
            .args = try lowerTypeExprs(arena, ref.args),
        } },
        .RecursiveRef => |ref| .{ .RecursiveRef = .{
            .name = try arena.allocator().dupe(u8, ref.name),
            .args = try lowerTypeExprs(arena, ref.args),
        } },
        .Tuple => |items| .{ .Tuple = try lowerTypeExprs(arena, items) },
    };
}

/// Lowers a wire 1.3 lambda-parameter type expression into a Core IR `Ty`.
/// Returns `null` when the wire said the type was unknown (`(any)` / no field),
/// in which case the caller should fall back to its existing heuristics.
pub fn lowerTypeExprOpt(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    expr_opt: ?ttree.TypeExpr,
) LowerError!?ir.Ty {
    const expr = expr_opt orelse return null;
    const lowered = try lowerTypeExpr(arena, expr);
    return try type_ops.typeExprToTyWithBindings(arena, ctx.record_type_decls, lowered, null);
}

pub fn dupeStringSlice(arena: *std.heap.ArenaAllocator, values: []const []const u8) LowerError![]const []const u8 {
    const out = try arena.allocator().alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        out[index] = try arena.allocator().dupe(u8, value);
    }
    return out;
}

pub fn indexConstructors(ctx: *LowerContext, type_decls: []const types.VariantType) LowerError!void {
    for (type_decls) |type_decl| {
        for (type_decl.variants) |variant| {
            try ctx.constructors.put(variant.name, .{
                .type_name = type_decl.name,
                .tag = variant.tag,
                .payload_types = variant.payload_types,
                .type_params = type_decl.params,
            });
        }
    }
}
