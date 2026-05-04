const std = @import("std");
const ir = @import("../ir.zig");
const context = @import("context.zig");
const type_ops = @import("type_ops.zig");

const LowerError = context.LowerError;
const LowerContext = context.LowerContext;
const exprTy = type_ops.exprTy;
const exprLayout = type_ops.exprLayout;

pub const RenameBinding = struct {
    from: []const u8,
    to: []const u8,
};

pub fn freshSyntheticName(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, base: []const u8) LowerError![]const u8 {
    const id = ctx.next_temp;
    ctx.next_temp += 1;
    return std.fmt.allocPrint(arena.allocator(), "{s}__omlz_{d}", .{ base, id });
}

pub fn renamedName(name: []const u8, renames: []const RenameBinding) []const u8 {
    for (renames) |rename| {
        if (std.mem.eql(u8, name, rename.from)) return rename.to;
    }
    return name;
}

pub fn renameExprVars(arena: *std.heap.ArenaAllocator, expr: *const ir.Expr, renames: []const RenameBinding) LowerError!*const ir.Expr {
    const renamed = try arena.allocator().create(ir.Expr);
    renamed.* = try renameExprValueVars(arena, expr.*, renames);
    return renamed;
}

pub fn renameExprValueVars(arena: *std.heap.ArenaAllocator, expr: ir.Expr, renames: []const RenameBinding) LowerError!ir.Expr {
    return switch (expr) {
        .Lambda => |lambda| blk: {
            const body_renames = try filterRenamesForParams(arena, renames, lambda.params);
            break :blk .{ .Lambda = .{
                .params = lambda.params,
                .body = try renameExprVars(arena, lambda.body, body_renames),
                .ty = lambda.ty,
                .layout = lambda.layout,
            } };
        },
        .Constant => |constant| .{ .Constant = constant },
        .App => |app| .{ .App = .{
            .callee = try renameExprVars(arena, app.callee, renames),
            .args = try renameExprSliceVars(arena, app.args, renames),
            .ty = app.ty,
            .layout = app.layout,
            .is_tail_call = app.is_tail_call,
        } },
        .Let => |let_expr| blk: {
            const body_renames = try filterRenamesForName(arena, renames, let_expr.name);
            break :blk .{ .Let = .{
                .name = let_expr.name,
                .value = try renameExprVars(arena, let_expr.value, renames),
                .body = try renameExprVars(arena, let_expr.body, body_renames),
                .ty = let_expr.ty,
                .layout = let_expr.layout,
                .is_rec = let_expr.is_rec,
            } };
        },
        .LetGroup => |group| blk: {
            var group_renames = renames;
            for (group.bindings) |binding| group_renames = try filterRenamesForName(arena, group_renames, binding.name);
            const bindings = try arena.allocator().alloc(ir.LetGroupBinding, group.bindings.len);
            for (group.bindings, 0..) |binding, index| {
                bindings[index] = .{
                    .name = binding.name,
                    .value = try renameExprVars(arena, binding.value, group_renames),
                    .ty = binding.ty,
                    .layout = binding.layout,
                };
            }
            break :blk .{ .LetGroup = .{
                .bindings = bindings,
                .body = try renameExprVars(arena, group.body, group_renames),
                .ty = group.ty,
                .layout = group.layout,
            } };
        },
        .Assert => |assert_expr| .{ .Assert = .{
            .condition = try renameExprVars(arena, assert_expr.condition, renames),
            .ty = assert_expr.ty,
            .layout = assert_expr.layout,
        } },
        .If => |if_expr| .{ .If = .{
            .cond = try renameExprVars(arena, if_expr.cond, renames),
            .then_branch = try renameExprVars(arena, if_expr.then_branch, renames),
            .else_branch = try renameExprVars(arena, if_expr.else_branch, renames),
            .ty = if_expr.ty,
            .layout = if_expr.layout,
        } },
        .Prim => |prim| .{ .Prim = .{
            .op = prim.op,
            .args = try renameExprSliceVars(arena, prim.args, renames),
            .ty = prim.ty,
            .layout = prim.layout,
        } },
        .Var => |var_ref| .{ .Var = .{
            .name = renamedName(var_ref.name, renames),
            .ty = var_ref.ty,
            .layout = var_ref.layout,
        } },
        .Ctor => |ctor_expr| .{ .Ctor = .{
            .name = ctor_expr.name,
            .args = try renameExprSliceVars(arena, ctor_expr.args, renames),
            .ty = ctor_expr.ty,
            .layout = ctor_expr.layout,
            .tag = ctor_expr.tag,
            .type_name = ctor_expr.type_name,
        } },
        .Match => |match_expr| .{ .Match = .{
            .scrutinee = try renameExprVars(arena, match_expr.scrutinee, renames),
            .arms = try renameArmsVars(arena, match_expr.arms, renames),
            .ty = match_expr.ty,
            .layout = match_expr.layout,
        } },
        .Tuple => |tuple_expr| .{ .Tuple = .{
            .items = try renameExprSliceVars(arena, tuple_expr.items, renames),
            .ty = tuple_expr.ty,
            .layout = tuple_expr.layout,
        } },
        .TupleProj => |tuple_proj| .{ .TupleProj = .{
            .tuple_expr = try renameExprVars(arena, tuple_proj.tuple_expr, renames),
            .index = tuple_proj.index,
            .ty = tuple_proj.ty,
            .layout = tuple_proj.layout,
        } },
        .Record => |record_expr| .{ .Record = .{
            .fields = try renameRecordExprFieldsVars(arena, record_expr.fields, renames),
            .ty = record_expr.ty,
            .layout = record_expr.layout,
        } },
        .RecordField => |record_field| .{ .RecordField = .{
            .record_expr = try renameExprVars(arena, record_field.record_expr, renames),
            .field_name = record_field.field_name,
            .ty = record_field.ty,
            .layout = record_field.layout,
        } },
        .RecordUpdate => |record_update| .{ .RecordUpdate = .{
            .base_expr = try renameExprVars(arena, record_update.base_expr, renames),
            .fields = try renameRecordExprFieldsVars(arena, record_update.fields, renames),
            .ty = record_update.ty,
            .layout = record_update.layout,
        } },
        .AccountFieldSet => |field_set| .{ .AccountFieldSet = .{
            .account_expr = try renameExprVars(arena, field_set.account_expr, renames),
            .field_name = field_set.field_name,
            .value = try renameExprVars(arena, field_set.value, renames),
            .ty = field_set.ty,
            .layout = field_set.layout,
        } },
    };
}

pub fn renameExprSliceVars(
    arena: *std.heap.ArenaAllocator,
    exprs: []const *const ir.Expr,
    renames: []const RenameBinding,
) LowerError![]const *const ir.Expr {
    const out = try arena.allocator().alloc(*const ir.Expr, exprs.len);
    for (exprs, 0..) |expr, index| out[index] = try renameExprVars(arena, expr, renames);
    return out;
}

pub fn filterRenamesForName(
    arena: *std.heap.ArenaAllocator,
    renames: []const RenameBinding,
    bound_name: []const u8,
) LowerError![]const RenameBinding {
    var kept: usize = 0;
    for (renames) |rename| {
        if (!std.mem.eql(u8, rename.from, bound_name)) kept += 1;
    }
    if (kept == renames.len) return renames;

    const out = try arena.allocator().alloc(RenameBinding, kept);
    var index: usize = 0;
    for (renames) |rename| {
        if (std.mem.eql(u8, rename.from, bound_name)) continue;
        out[index] = rename;
        index += 1;
    }
    return out;
}

pub fn filterRenamesForParams(
    arena: *std.heap.ArenaAllocator,
    renames: []const RenameBinding,
    params: []const ir.Param,
) LowerError![]const RenameBinding {
    var current = renames;
    for (params) |param| current = try filterRenamesForName(arena, current, param.name);
    return current;
}

pub fn filterRenamesForPattern(
    arena: *std.heap.ArenaAllocator,
    renames: []const RenameBinding,
    pattern: ir.Pattern,
) LowerError![]const RenameBinding {
    var current = renames;
    switch (pattern) {
        .Wildcard, .Constant => {},
        .Var => |var_pattern| current = try filterRenamesForName(arena, current, var_pattern.name),
        .Alias => |alias| {
            current = try filterRenamesForPattern(arena, current, alias.pattern.*);
            current = try filterRenamesForName(arena, current, alias.name);
        },
        .Ctor => |ctor_pattern| {
            for (ctor_pattern.args) |arg| current = try filterRenamesForPattern(arena, current, arg);
        },
        .Tuple => |items| {
            for (items) |item| current = try filterRenamesForPattern(arena, current, item);
        },
        .Record => |fields| {
            for (fields) |field| current = try filterRenamesForPattern(arena, current, field.pattern);
        },
    }
    return current;
}

pub fn renameArmsVars(
    arena: *std.heap.ArenaAllocator,
    arms: []const ir.Arm,
    renames: []const RenameBinding,
) LowerError![]const ir.Arm {
    const out = try arena.allocator().alloc(ir.Arm, arms.len);
    for (arms, 0..) |arm, index| {
        const arm_renames = try filterRenamesForPattern(arena, renames, arm.pattern);
        out[index] = .{
            .pattern = arm.pattern,
            .guard = if (arm.guard) |guard| try renameExprVars(arena, guard, arm_renames) else null,
            .body = try renameExprVars(arena, arm.body, arm_renames),
        };
    }
    return out;
}

pub fn renameRecordExprFieldsVars(
    arena: *std.heap.ArenaAllocator,
    fields: []const ir.RecordExprField,
    renames: []const RenameBinding,
) LowerError![]const ir.RecordExprField {
    const out = try arena.allocator().alloc(ir.RecordExprField, fields.len);
    for (fields, 0..) |field, index| {
        out[index] = .{
            .name = field.name,
            .value = try renameExprVars(arena, field.value, renames),
        };
    }
    return out;
}
