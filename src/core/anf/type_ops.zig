const std = @import("std");
const ttree = @import("../../frontend_bridge/ttree.zig");
const ir = @import("../ir.zig");
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const context = @import("context.zig");

const LowerError = context.LowerError;
const TypeBindings = context.TypeBindings;
const LowerContext = context.LowerContext;

pub fn typeExprsToTys(arena: *std.heap.ArenaAllocator, exprs: []const types.TypeExpr) LowerError![]const ir.Ty {
    return typeExprsToTysWithBindings(arena, &.{}, exprs, null);
}

pub fn typeExprsToTysWithBindings(
    arena: *std.heap.ArenaAllocator,
    record_type_decls: []const types.RecordType,
    exprs: []const types.TypeExpr,
    bindings: ?*TypeBindings,
) LowerError![]const ir.Ty {
    const out = try arena.allocator().alloc(ir.Ty, exprs.len);
    for (exprs, 0..) |expr, index| {
        out[index] = try typeExprToTyWithBindings(arena, record_type_decls, expr, bindings);
    }
    return out;
}

pub fn typeExprToTy(arena: *std.heap.ArenaAllocator, expr: types.TypeExpr) LowerError!ir.Ty {
    return typeExprToTyWithBindings(arena, &.{}, expr, null);
}

pub fn externalTypeExprToTy(
    arena: *std.heap.ArenaAllocator,
    record_type_decls: []const types.RecordType,
    expr: ttree.ExternalTypeExpr,
) LowerError!ir.Ty {
    switch (expr) {
        .Arrow => {
            var params = std.ArrayList(ir.Ty).empty;
            defer params.deinit(arena.allocator());

            var current = expr;
            while (true) {
                switch (current) {
                    .Arrow => |arrow| {
                        try params.append(arena.allocator(), try externalTypeExprToTy(arena, record_type_decls, arrow.arg.*));
                        current = arrow.result.*;
                    },
                    else => {
                        const ret_ty = try externalTypeExprToTy(arena, record_type_decls, current);
                        return makeArrowTyFromPieces(arena, params.items, ret_ty);
                    },
                }
            }
        },
        .Tuple => |items| {
            const tys = try arena.allocator().alloc(ir.Ty, items.len);
            for (items, 0..) |item, index| {
                tys[index] = try externalTypeExprToTy(arena, record_type_decls, item);
            }
            return .{ .Tuple = tys };
        },
        .TypeRef => |ref| return externalTypeRefToTy(arena, record_type_decls, ref),
    }
}

pub fn externalTypeRefToTy(
    arena: *std.heap.ArenaAllocator,
    record_type_decls: []const types.RecordType,
    ref: ttree.ExternalTypeRef,
) LowerError!ir.Ty {
    if (std.mem.eql(u8, ref.name, "int")) return .Int;
    if (std.mem.eql(u8, ref.name, "bool")) return .Bool;
    if (std.mem.eql(u8, ref.name, "unit")) return .Unit;
    if (std.mem.eql(u8, ref.name, "string")) return .String;
    if (std.mem.eql(u8, ref.name, "bytes")) return .String;
    if (std.mem.startsWith(u8, ref.name, "'")) return .{ .Var = try arena.allocator().dupe(u8, ref.name) };

    const params = try arena.allocator().alloc(ir.Ty, ref.args.len);
    for (ref.args, 0..) |arg, index| {
        params[index] = try externalTypeExprToTy(arena, record_type_decls, arg);
    }
    if (findRecordDecl(record_type_decls, ref.name) != null) {
        return .{ .Record = .{
            .name = try arena.allocator().dupe(u8, ref.name),
            .params = params,
        } };
    }
    return .{ .Adt = .{
        .name = try arena.allocator().dupe(u8, ref.name),
        .params = params,
    } };
}

pub fn typeExprToTyWithBindings(
    arena: *std.heap.ArenaAllocator,
    record_type_decls: []const types.RecordType,
    expr: types.TypeExpr,
    bindings: ?*TypeBindings,
) LowerError!ir.Ty {
    return switch (expr) {
        .TypeVar => |name| if (bindings) |values| values.get(name) orelse .{ .Var = name } else .{ .Var = name },
        .TypeRef => |ref| try typeRefToTyWithBindings(arena, record_type_decls, ref, bindings),
        .RecursiveRef => |ref| try typeRefToTyWithBindings(arena, record_type_decls, ref, bindings),
        .Tuple => |items| .{ .Tuple = try typeExprsToTysWithBindings(arena, record_type_decls, items, bindings) },
    };
}

pub fn typeRefToTy(arena: *std.heap.ArenaAllocator, ref: types.TypeRef) LowerError!ir.Ty {
    return typeRefToTyWithBindings(arena, &.{}, ref, null);
}

pub fn typeRefToTyWithBindings(
    arena: *std.heap.ArenaAllocator,
    record_type_decls: []const types.RecordType,
    ref: types.TypeRef,
    bindings: ?*TypeBindings,
) LowerError!ir.Ty {
    if (std.mem.eql(u8, ref.name, "int")) return .Int;
    if (std.mem.eql(u8, ref.name, "bool")) return .Bool;
    if (std.mem.eql(u8, ref.name, "unit")) return .Unit;
    if (std.mem.eql(u8, ref.name, "string")) return .String;
    if (std.mem.eql(u8, ref.name, "bytes")) return .String;
    if (findRecordDecl(record_type_decls, ref.name) != null) {
        return .{ .Record = .{
            .name = ref.name,
            .params = try typeExprsToTysWithBindings(arena, record_type_decls, ref.args, bindings),
        } };
    }
    return .{ .Adt = .{
        .name = ref.name,
        .params = try typeExprsToTysWithBindings(arena, record_type_decls, ref.args, bindings),
    } };
}

pub fn listTy(arena: *std.heap.ArenaAllocator, elem_ty: ir.Ty) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, 1);
    params[0] = elem_ty;
    return .{ .Adt = .{
        .name = "list",
        .params = params,
    } };
}

pub fn arrayTy(arena: *std.heap.ArenaAllocator, elem_ty: ir.Ty) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, 1);
    params[0] = elem_ty;
    return .{ .Adt = .{
        .name = "array",
        .params = params,
    } };
}

pub fn optionTy(arena: *std.heap.ArenaAllocator, elem_ty: ir.Ty) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, 1);
    params[0] = elem_ty;
    return .{ .Adt = .{
        .name = "option",
        .params = params,
    } };
}

pub fn resultTy(arena: *std.heap.ArenaAllocator, ok_ty: ir.Ty, err_ty: ir.Ty) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, 2);
    params[0] = ok_ty;
    params[1] = err_ty;
    return .{ .Adt = .{
        .name = "result",
        .params = params,
    } };
}

pub fn accountTy(arena: *std.heap.ArenaAllocator) LowerError!ir.Ty {
    return .{ .Record = .{
        .name = try arena.allocator().dupe(u8, "account"),
        .params = &.{},
    } };
}

pub fn tySlice(arena: *std.heap.ArenaAllocator, tys: []const ir.Ty) LowerError![]const ir.Ty {
    const out = try arena.allocator().alloc(ir.Ty, tys.len);
    for (tys, 0..) |ty, index| out[index] = ty;
    return out;
}

pub fn arrowTy(arena: *std.heap.ArenaAllocator, params: []const ir.Ty, ret: ir.Ty) LowerError!ir.Ty {
    const owned_ret = try arena.allocator().create(ir.Ty);
    owned_ret.* = ret;
    return .{ .Arrow = .{
        .params = try tySlice(arena, params),
        .ret = owned_ret,
    } };
}

pub fn recordTy(arena: *std.heap.ArenaAllocator, decl: types.RecordType) LowerError!ir.Ty {
    return recordTyWithBindings(arena, decl, null);
}

pub fn recordTyWithBindings(arena: *std.heap.ArenaAllocator, decl: types.RecordType, bindings: ?*TypeBindings) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, decl.params.len);
    for (decl.params, 0..) |param_name, index| {
        params[index] = if (bindings) |values| values.get(param_name) orelse .{ .Var = param_name } else .{ .Var = param_name };
    }
    return .{ .Record = .{
        .name = decl.name,
        .params = params,
    } };
}

pub fn findRecordDecl(decls: []const types.RecordType, name: []const u8) ?types.RecordType {
    for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return decl;
    }
    return null;
}

pub fn findRecordDeclForFields(decls: []const types.RecordType, fields: []const ttree.RecordExprField) ?types.RecordType {
    for (decls) |decl| {
        if (decl.fields.len != fields.len) continue;
        var all_present = true;
        for (decl.fields) |decl_field| {
            var found = false;
            for (fields) |field| {
                if (std.mem.eql(u8, decl_field.name, field.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                all_present = false;
                break;
            }
        }
        if (all_present) return decl;
    }
    return null;
}

pub fn findRecordExprField(fields: []const ir.RecordExprField, field_name: []const u8) ?ir.RecordExprField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) return field;
    }
    return null;
}

pub fn recordFieldTy(arena: *std.heap.ArenaAllocator, decl: types.RecordType, field_name: []const u8) LowerError!ir.Ty {
    for (decl.fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) return typeExprToTy(arena, field.ty);
    }
    return error.UnsupportedNode;
}

pub fn recordFieldTyWithBindings(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    decl: types.RecordType,
    bindings: ?*TypeBindings,
    field_name: []const u8,
) LowerError!ir.Ty {
    for (decl.fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return typeExprToTyWithBindings(arena, ctx.record_type_decls, field.ty, bindings);
        }
    }
    return error.UnsupportedNode;
}

pub fn recordFieldTyForRecord(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    decl: types.RecordType,
    ty: ir.Ty,
    field_name: []const u8,
) LowerError!ir.Ty {
    const record = switch (ty) {
        .Record => |value| value,
        else => return error.UnsupportedNode,
    };
    if (!std.mem.eql(u8, record.name, decl.name)) return error.UnsupportedNode;
    if (record.params.len != decl.params.len) return error.UnsupportedNode;

    var bindings = TypeBindings.init(arena.allocator());
    defer bindings.deinit();
    for (decl.params, record.params) |param_name, param_ty| {
        try bindings.put(param_name, param_ty);
    }
    return recordFieldTyWithBindings(arena, ctx, decl, &bindings, field_name);
}

pub fn recordFieldAccessTy(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, ty: ir.Ty, field_name: []const u8) LowerError!ir.Ty {
    const record = switch (ty) {
        .Record => |value| value,
        else => return error.UnsupportedNode,
    };
    const decl = findRecordDecl(ctx.record_type_decls, record.name) orelse return error.UnsupportedNode;
    return recordFieldTyForRecord(arena, ctx, decl, ty, field_name);
}

pub fn isAccountTy(ty: ir.Ty) bool {
    const record = switch (ty) {
        .Record => |value| value,
        else => return false,
    };
    return std.mem.eql(u8, record.name, "account") and record.params.len == 0;
}

pub fn layoutForTy(ty: ir.Ty) layout.Layout {
    return switch (ty) {
        .Int, .Bool, .Var => layout.intConstant(),
        .Unit => layout.unitValue(),
        .String => layout.defaultFor(.StringLiteral),
        .Adt => layout.ctor(1),
        .Tuple, .Record => layout.structPack(),
        .Arrow => layout.closure(),
    };
}

pub fn recBindingEscapes(name: []const u8, expr: ttree.Expr) bool {
    return switch (expr) {
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        .App => |app| blk: {
            const direct_self_call = switch (app.callee.*) {
                .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
                else => false,
            };
            if (!direct_self_call and recBindingEscapes(name, app.callee.*)) break :blk true;
            for (app.args) |arg| {
                if (recBindingEscapes(name, arg)) break :blk true;
            }
            break :blk false;
        },
        .Let => |let_expr| blk: {
            if (recBindingEscapes(name, let_expr.value.*)) break :blk true;
            if (!std.mem.eql(u8, let_expr.name, name) and recBindingEscapes(name, let_expr.body.*)) break :blk true;
            break :blk false;
        },
        .LetRecGroup => |group| blk: {
            for (group.bindings) |binding| {
                if (!std.mem.eql(u8, binding.name, name) and recBindingEscapes(name, binding.body)) break :blk true;
            }
            for (group.bindings) |binding| {
                if (std.mem.eql(u8, binding.name, name)) break :blk false;
            }
            break :blk recBindingEscapes(name, group.body.*);
        },
        .Assert => |assert_expr| recBindingEscapes(name, assert_expr.condition.*),
        .Lambda => |lambda| lambdaParamShadows(lambda.params, name) == false and recBindingEscapes(name, lambda.body.*),
        .If => |if_expr| recBindingEscapes(name, if_expr.cond.*) or
            recBindingEscapes(name, if_expr.then_branch.*) or
            recBindingEscapes(name, if_expr.else_branch.*),
        .Prim => |prim| blk: {
            for (prim.args) |arg| {
                if (recBindingEscapes(name, arg)) break :blk true;
            }
            break :blk false;
        },
        .Ctor => |ctor| blk: {
            for (ctor.args) |arg| {
                if (recBindingEscapes(name, arg)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple_expr| blk: {
            for (tuple_expr.items) |item| {
                if (recBindingEscapes(name, item)) break :blk true;
            }
            break :blk false;
        },
        .TupleProj => |tuple_proj| recBindingEscapes(name, tuple_proj.tuple_expr.*),
        .Record => |record_expr| blk: {
            for (record_expr.fields) |field| {
                if (recBindingEscapes(name, field.value)) break :blk true;
            }
            break :blk false;
        },
        .RecordField => |field_access| recBindingEscapes(name, field_access.record_expr.*),
        .RecordUpdate => |record_update| blk: {
            if (recBindingEscapes(name, record_update.base_expr.*)) break :blk true;
            for (record_update.fields) |field| {
                if (recBindingEscapes(name, field.value)) break :blk true;
            }
            break :blk false;
        },
        .FieldSet => |field_set| recBindingEscapes(name, field_set.record_expr.*) or recBindingEscapes(name, field_set.value.*),
        .Match => |match_expr| blk: {
            if (recBindingEscapes(name, match_expr.scrutinee.*)) break :blk true;
            for (match_expr.arms) |arm| {
                if (!patternBindsTtreeName(arm.pattern, name)) {
                    if (arm.guard) |guard_expr| {
                        if (recBindingEscapes(name, guard_expr.*)) break :blk true;
                    }
                }
                if (!patternBindsTtreeName(arm.pattern, name) and recBindingEscapes(name, arm.body.*)) break :blk true;
            }
            break :blk false;
        },
        .Constant => false,
    };
}

pub fn lambdaParamShadows(params: []const []const u8, name: []const u8) bool {
    for (params) |param| {
        if (std.mem.eql(u8, param, name)) return true;
    }
    return false;
}

pub fn patternBindsTtreeName(pattern: ttree.Pattern, name: []const u8) bool {
    return switch (pattern) {
        .Var => |var_name| std.mem.eql(u8, var_name, name),
        .Ctor => |ctor_pattern| blk: {
            for (ctor_pattern.args) |arg| {
                if (patternBindsTtreeName(arg, name)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |items| blk: {
            for (items) |item| {
                if (patternBindsTtreeName(item, name)) break :blk true;
            }
            break :blk false;
        },
        .Record => |fields| blk: {
            for (fields) |field| {
                if (patternBindsTtreeName(field.pattern, name)) break :blk true;
            }
            break :blk false;
        },
        .Alias => |alias| std.mem.eql(u8, alias.name, name) or patternBindsTtreeName(alias.pattern.*, name),
        .Or => |alternatives| blk: {
            for (alternatives) |alternative| {
                if (patternBindsTtreeName(alternative, name)) break :blk true;
            }
            break :blk false;
        },
        .Wildcard, .Const => false,
    };
}

pub fn lambdaParamIsFunction(expr: ttree.Expr, param_name: []const u8) bool {
    return switch (expr) {
        .App => |app| blk: {
            switch (app.callee.*) {
                .Var => |var_ref| if (std.mem.eql(u8, var_ref.name, param_name)) break :blk true,
                else => if (lambdaParamIsFunction(app.callee.*, param_name)) break :blk true,
            }
            for (app.args) |arg| {
                if (lambdaParamIsFunction(arg, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Lambda => |lambda| !lambdaParamShadows(lambda.params, param_name) and lambdaParamIsFunction(lambda.body.*, param_name),
        .Let => |let_expr| lambdaParamIsFunction(let_expr.value.*, param_name) or
            (!std.mem.eql(u8, let_expr.name, param_name) and lambdaParamIsFunction(let_expr.body.*, param_name)),
        .LetRecGroup => |group| blk: {
            for (group.bindings) |binding| {
                if (lambdaParamIsFunction(binding.body, param_name)) break :blk true;
                if (std.mem.eql(u8, binding.name, param_name)) break :blk false;
            }
            break :blk lambdaParamIsFunction(group.body.*, param_name);
        },
        .Assert => |assert_expr| lambdaParamIsFunction(assert_expr.condition.*, param_name),
        .If => |if_expr| lambdaParamIsFunction(if_expr.cond.*, param_name) or
            lambdaParamIsFunction(if_expr.then_branch.*, param_name) or
            lambdaParamIsFunction(if_expr.else_branch.*, param_name),
        .Prim => |prim| blk: {
            for (prim.args) |arg| {
                if (lambdaParamIsFunction(arg, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Ctor => |ctor| blk: {
            for (ctor.args) |arg| {
                if (lambdaParamIsFunction(arg, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple_expr| blk: {
            for (tuple_expr.items) |item| {
                if (lambdaParamIsFunction(item, param_name)) break :blk true;
            }
            break :blk false;
        },
        .TupleProj => |tuple_proj| lambdaParamIsFunction(tuple_proj.tuple_expr.*, param_name),
        .Record => |record_expr| blk: {
            for (record_expr.fields) |field| {
                if (lambdaParamIsFunction(field.value, param_name)) break :blk true;
            }
            break :blk false;
        },
        .RecordField => |field_access| lambdaParamIsFunction(field_access.record_expr.*, param_name),
        .RecordUpdate => |record_update| blk: {
            if (lambdaParamIsFunction(record_update.base_expr.*, param_name)) break :blk true;
            for (record_update.fields) |field| {
                if (lambdaParamIsFunction(field.value, param_name)) break :blk true;
            }
            break :blk false;
        },
        .FieldSet => |field_set| lambdaParamIsFunction(field_set.record_expr.*, param_name) or lambdaParamIsFunction(field_set.value.*, param_name),
        .Match => |match_expr| blk: {
            if (lambdaParamIsFunction(match_expr.scrutinee.*, param_name)) break :blk true;
            for (match_expr.arms) |arm| {
                if (!patternBindsTtreeName(arm.pattern, param_name)) {
                    if (arm.guard) |guard_expr| {
                        if (lambdaParamIsFunction(guard_expr.*, param_name)) break :blk true;
                    }
                }
                if (!patternBindsTtreeName(arm.pattern, param_name) and lambdaParamIsFunction(arm.body.*, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Constant, .Var => false,
    };
}

pub fn lambdaParamRecordTy(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, expr: ttree.Expr, param_name: []const u8) ?ir.Ty {
    return switch (expr) {
        .RecordField => |field_access| blk: {
            if (exprIsVarNamed(field_access.record_expr.*, param_name)) {
                if (recordTyContainingField(arena, ctx, field_access.field_name)) |ty| break :blk ty;
            }
            break :blk lambdaParamRecordTy(arena, ctx, field_access.record_expr.*, param_name);
        },
        .App => |app| blk: {
            if (lambdaParamRecordTy(arena, ctx, app.callee.*, param_name)) |ty| break :blk ty;
            for (app.args) |arg| {
                if (lambdaParamRecordTy(arena, ctx, arg, param_name)) |ty| break :blk ty;
            }
            break :blk null;
        },
        .Lambda => |lambda| if (lambdaParamShadows(lambda.params, param_name)) null else lambdaParamRecordTy(arena, ctx, lambda.body.*, param_name),
        .Let => |let_expr| blk: {
            if (lambdaParamRecordTy(arena, ctx, let_expr.value.*, param_name)) |ty| break :blk ty;
            if (!std.mem.eql(u8, let_expr.name, param_name)) break :blk lambdaParamRecordTy(arena, ctx, let_expr.body.*, param_name);
            break :blk null;
        },
        .LetRecGroup => |group| blk: {
            for (group.bindings) |binding| {
                if (lambdaParamRecordTy(arena, ctx, binding.body, param_name)) |ty| break :blk ty;
                if (std.mem.eql(u8, binding.name, param_name)) break :blk null;
            }
            break :blk lambdaParamRecordTy(arena, ctx, group.body.*, param_name);
        },
        .Assert => |assert_expr| lambdaParamRecordTy(arena, ctx, assert_expr.condition.*, param_name),
        .If => |if_expr| lambdaParamRecordTy(arena, ctx, if_expr.cond.*, param_name) orelse
            lambdaParamRecordTy(arena, ctx, if_expr.then_branch.*, param_name) orelse
            lambdaParamRecordTy(arena, ctx, if_expr.else_branch.*, param_name),
        .Prim => |prim| blk: {
            for (prim.args) |arg| {
                if (lambdaParamRecordTy(arena, ctx, arg, param_name)) |ty| break :blk ty;
            }
            break :blk null;
        },
        .Ctor => |ctor| blk: {
            for (ctor.args) |arg| {
                if (lambdaParamRecordTy(arena, ctx, arg, param_name)) |ty| break :blk ty;
            }
            break :blk null;
        },
        .Tuple => |tuple_expr| blk: {
            for (tuple_expr.items) |item| {
                if (lambdaParamRecordTy(arena, ctx, item, param_name)) |ty| break :blk ty;
            }
            break :blk null;
        },
        .TupleProj => |tuple_proj| lambdaParamRecordTy(arena, ctx, tuple_proj.tuple_expr.*, param_name),
        .Record => |record_expr| blk: {
            for (record_expr.fields) |field| {
                if (lambdaParamRecordTy(arena, ctx, field.value, param_name)) |ty| break :blk ty;
            }
            break :blk null;
        },
        .RecordUpdate => |record_update| blk: {
            if (lambdaParamRecordTy(arena, ctx, record_update.base_expr.*, param_name)) |ty| break :blk ty;
            for (record_update.fields) |field| {
                if (lambdaParamRecordTy(arena, ctx, field.value, param_name)) |ty| break :blk ty;
            }
            break :blk null;
        },
        .FieldSet => |field_set| lambdaParamRecordTy(arena, ctx, field_set.record_expr.*, param_name) orelse
            lambdaParamRecordTy(arena, ctx, field_set.value.*, param_name),
        .Match => |match_expr| blk: {
            if (lambdaParamRecordTy(arena, ctx, match_expr.scrutinee.*, param_name)) |ty| break :blk ty;
            for (match_expr.arms) |arm| {
                if (!patternBindsTtreeName(arm.pattern, param_name)) {
                    if (arm.guard) |guard_expr| {
                        if (lambdaParamRecordTy(arena, ctx, guard_expr.*, param_name)) |ty| break :blk ty;
                    }
                    if (lambdaParamRecordTy(arena, ctx, arm.body.*, param_name)) |ty| break :blk ty;
                }
            }
            break :blk null;
        },
        .Constant, .Var => null,
    };
}

pub fn recordTyContainingField(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, field_name: []const u8) ?ir.Ty {
    for (ctx.record_type_decls) |decl| {
        for (decl.fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                const params = arena.allocator().alloc(ir.Ty, decl.params.len) catch return null;
                for (params) |*param| param.* = .Int;
                return .{ .Record = .{ .name = decl.name, .params = params } };
            }
        }
    }
    return null;
}

pub fn lambdaParamIsAccount(expr: ttree.Expr, param_name: []const u8) bool {
    return switch (expr) {
        .RecordField => |field_access| (exprIsVarNamed(field_access.record_expr.*, param_name) and isAccountFieldName(field_access.field_name)) or
            lambdaParamIsAccount(field_access.record_expr.*, param_name),
        .FieldSet => |field_set| (exprIsVarNamed(field_set.record_expr.*, param_name) and isAccountFieldName(field_set.field_name)) or
            lambdaParamIsAccount(field_set.record_expr.*, param_name) or
            lambdaParamIsAccount(field_set.value.*, param_name),
        .App => |app| blk: {
            if (lambdaParamIsAccount(app.callee.*, param_name)) break :blk true;
            for (app.args) |arg| {
                if (lambdaParamIsAccount(arg, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Lambda => |lambda| !lambdaParamShadows(lambda.params, param_name) and lambdaParamIsAccount(lambda.body.*, param_name),
        .Let => |let_expr| lambdaParamIsAccount(let_expr.value.*, param_name) or
            (!std.mem.eql(u8, let_expr.name, param_name) and lambdaParamIsAccount(let_expr.body.*, param_name)),
        .LetRecGroup => |group| blk: {
            for (group.bindings) |binding| {
                if (lambdaParamIsAccount(binding.body, param_name)) break :blk true;
                if (std.mem.eql(u8, binding.name, param_name)) break :blk false;
            }
            break :blk lambdaParamIsAccount(group.body.*, param_name);
        },
        .Assert => |assert_expr| lambdaParamIsAccount(assert_expr.condition.*, param_name),
        .If => |if_expr| lambdaParamIsAccount(if_expr.cond.*, param_name) or
            lambdaParamIsAccount(if_expr.then_branch.*, param_name) or
            lambdaParamIsAccount(if_expr.else_branch.*, param_name),
        .Prim => |prim| blk: {
            for (prim.args) |arg| {
                if (lambdaParamIsAccount(arg, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Ctor => |ctor| blk: {
            for (ctor.args) |arg| {
                if (lambdaParamIsAccount(arg, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple_expr| blk: {
            for (tuple_expr.items) |item| {
                if (lambdaParamIsAccount(item, param_name)) break :blk true;
            }
            break :blk false;
        },
        .TupleProj => |tuple_proj| lambdaParamIsAccount(tuple_proj.tuple_expr.*, param_name),
        .Record => |record_expr| blk: {
            for (record_expr.fields) |field| {
                if (lambdaParamIsAccount(field.value, param_name)) break :blk true;
            }
            break :blk false;
        },
        .RecordUpdate => |record_update| blk: {
            if (lambdaParamIsAccount(record_update.base_expr.*, param_name)) break :blk true;
            for (record_update.fields) |field| {
                if (lambdaParamIsAccount(field.value, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Match => |match_expr| blk: {
            if (lambdaParamIsAccount(match_expr.scrutinee.*, param_name)) break :blk true;
            for (match_expr.arms) |arm| {
                if (!patternBindsTtreeName(arm.pattern, param_name)) {
                    if (arm.guard) |guard_expr| {
                        if (lambdaParamIsAccount(guard_expr.*, param_name)) break :blk true;
                    }
                    if (lambdaParamIsAccount(arm.body.*, param_name)) break :blk true;
                }
            }
            break :blk false;
        },
        .Constant, .Var => false,
    };
}

pub fn exprIsVarNamed(expr: ttree.Expr, name: []const u8) bool {
    return switch (expr) {
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        else => false,
    };
}

pub fn isAccountFieldName(field_name: []const u8) bool {
    return std.mem.eql(u8, field_name, "key") or
        std.mem.eql(u8, field_name, "lamports") or
        std.mem.eql(u8, field_name, "data") or
        std.mem.eql(u8, field_name, "owner") or
        std.mem.eql(u8, field_name, "is_signer") or
        std.mem.eql(u8, field_name, "is_writable") or
        std.mem.eql(u8, field_name, "executable");
}

pub fn isInstructionDataParamName(param_name: []const u8) bool {
    return std.mem.eql(u8, param_name, "input") or
        std.mem.eql(u8, param_name, "instruction_data");
}

pub fn lambdaParamIsList(arena: *std.heap.ArenaAllocator, expr: ttree.Expr, param_name: []const u8) LowerError!bool {
    return switch (expr) {
        .Match => |match_expr| blk: {
            const scrutinee_is_param = switch (match_expr.scrutinee.*) {
                .Var => |var_ref| std.mem.eql(u8, var_ref.name, param_name),
                else => false,
            };
            if (scrutinee_is_param) {
                for (match_expr.arms) |arm| {
                    if (patternIsListCtor(arm.pattern)) break :blk true;
                }
            }
            if (try lambdaParamIsList(arena, match_expr.scrutinee.*, param_name)) break :blk true;
            for (match_expr.arms) |arm| {
                if (!patternBindsTtreeName(arm.pattern, param_name)) {
                    if (arm.guard) |guard_expr| {
                        if (try lambdaParamIsList(arena, guard_expr.*, param_name)) break :blk true;
                    }
                }
                if (try lambdaParamIsList(arena, arm.body.*, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Lambda => |lambda| try lambdaParamIsList(arena, lambda.body.*, param_name),
        .App => |app| blk: {
            if (try lambdaParamIsList(arena, app.callee.*, param_name)) break :blk true;
            for (app.args) |arg| {
                if (try lambdaParamIsList(arena, arg, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Let => |let_expr| (try lambdaParamIsList(arena, let_expr.value.*, param_name)) or
            (!std.mem.eql(u8, let_expr.name, param_name) and try lambdaParamIsList(arena, let_expr.body.*, param_name)),
        .LetRecGroup => |group| blk: {
            for (group.bindings) |binding| {
                if (try lambdaParamIsList(arena, binding.body, param_name)) break :blk true;
                if (std.mem.eql(u8, binding.name, param_name)) break :blk false;
            }
            break :blk try lambdaParamIsList(arena, group.body.*, param_name);
        },
        .Assert => |assert_expr| try lambdaParamIsList(arena, assert_expr.condition.*, param_name),
        .If => |if_expr| (try lambdaParamIsList(arena, if_expr.cond.*, param_name)) or
            (try lambdaParamIsList(arena, if_expr.then_branch.*, param_name)) or
            (try lambdaParamIsList(arena, if_expr.else_branch.*, param_name)),
        .Prim => |prim| blk: {
            for (prim.args) |arg| {
                if (try lambdaParamIsList(arena, arg, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Ctor => |ctor| blk: {
            for (ctor.args) |arg| {
                if (try lambdaParamIsList(arena, arg, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple_expr| blk: {
            for (tuple_expr.items) |item| {
                if (try lambdaParamIsList(arena, item, param_name)) break :blk true;
            }
            break :blk false;
        },
        .TupleProj => |tuple_proj| try lambdaParamIsList(arena, tuple_proj.tuple_expr.*, param_name),
        .Record => |record_expr| blk: {
            for (record_expr.fields) |field| {
                if (try lambdaParamIsList(arena, field.value, param_name)) break :blk true;
            }
            break :blk false;
        },
        .RecordField => |field_access| try lambdaParamIsList(arena, field_access.record_expr.*, param_name),
        .RecordUpdate => |record_update| blk: {
            if (try lambdaParamIsList(arena, record_update.base_expr.*, param_name)) break :blk true;
            for (record_update.fields) |field| {
                if (try lambdaParamIsList(arena, field.value, param_name)) break :blk true;
            }
            break :blk false;
        },
        .FieldSet => |field_set| (try lambdaParamIsList(arena, field_set.record_expr.*, param_name)) or
            (try lambdaParamIsList(arena, field_set.value.*, param_name)),
        .Constant, .Var => false,
    };
}

pub fn patternIsListCtor(pattern: ttree.Pattern) bool {
    return switch (pattern) {
        .Ctor => |ctor_pattern| std.mem.eql(u8, ctor_pattern.name, "[]") or std.mem.eql(u8, ctor_pattern.name, "::"),
        .Alias => |alias| patternIsListCtor(alias.pattern.*),
        .Or => |alternatives| blk: {
            for (alternatives) |alternative| {
                if (patternIsListCtor(alternative)) break :blk true;
            }
            break :blk false;
        },
        .Tuple, .Record, .Wildcard, .Var, .Const => false,
    };
}

pub fn makeArrowTy(
    arena: *std.heap.ArenaAllocator,
    params: []const ir.Param,
    ret_ty: ir.Ty,
) LowerError!ir.Ty {
    const param_tys = try arena.allocator().alloc(ir.Ty, params.len);
    for (params, 0..) |param, index| {
        param_tys[index] = param.ty;
    }

    const ret = try arena.allocator().create(ir.Ty);
    ret.* = ret_ty;

    return .{ .Arrow = .{
        .params = param_tys,
        .ret = ret,
    } };
}

pub fn makeArrowTyFromPieces(
    arena: *std.heap.ArenaAllocator,
    param_tys_in: []const ir.Ty,
    ret_ty: ir.Ty,
) LowerError!ir.Ty {
    const param_tys = try arena.allocator().alloc(ir.Ty, param_tys_in.len);
    @memcpy(param_tys, param_tys_in);
    const ret = try arena.allocator().create(ir.Ty);
    ret.* = ret_ty;
    return .{ .Arrow = .{
        .params = param_tys,
        .ret = ret,
    } };
}

pub fn intToIntArrowTy(arena: *std.heap.ArenaAllocator) LowerError!ir.Ty {
    const param_tys = try arena.allocator().alloc(ir.Ty, 1);
    param_tys[0] = .Int;
    const ret = try arena.allocator().create(ir.Ty);
    ret.* = .Int;
    return .{ .Arrow = .{
        .params = param_tys,
        .ret = ret,
    } };
}

pub fn exprTy(expr: ir.Expr) ir.Ty {
    return switch (expr) {
        .Lambda => |lambda| lambda.ty,
        .Constant => |constant| constant.ty,
        .App => |app| app.ty,
        .Let => |let_expr| let_expr.ty,
        .LetGroup => |group| group.ty,
        .Assert => |assert_expr| assert_expr.ty,
        .If => |if_expr| if_expr.ty,
        .Prim => |prim| prim.ty,
        .Var => |var_ref| var_ref.ty,
        .Ctor => |ctor_expr| ctor_expr.ty,
        .Match => |match_expr| match_expr.ty,
        .Tuple => |tuple_expr| tuple_expr.ty,
        .TupleProj => |tuple_proj| tuple_proj.ty,
        .Record => |record_expr| record_expr.ty,
        .RecordField => |record_field| record_field.ty,
        .RecordUpdate => |record_update| record_update.ty,
        .AccountFieldSet => |field_set| field_set.ty,
    };
}

pub fn tyEql(lhs: ir.Ty, rhs: ir.Ty) bool {
    return switch (lhs) {
        .Int => std.meta.activeTag(rhs) == .Int,
        .Bool => std.meta.activeTag(rhs) == .Bool,
        .Unit => std.meta.activeTag(rhs) == .Unit,
        .String => std.meta.activeTag(rhs) == .String,
        .Var => |lhs_name| switch (rhs) {
            .Var => |rhs_name| std.mem.eql(u8, lhs_name, rhs_name),
            else => false,
        },
        .Adt => |lhs_adt| switch (rhs) {
            .Adt => |rhs_adt| blk: {
                if (!std.mem.eql(u8, lhs_adt.name, rhs_adt.name) or lhs_adt.params.len != rhs_adt.params.len) break :blk false;
                for (lhs_adt.params, rhs_adt.params) |lhs_param, rhs_param| {
                    if (!tyEql(lhs_param, rhs_param)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .Tuple => |lhs_items| switch (rhs) {
            .Tuple => |rhs_items| blk: {
                if (lhs_items.len != rhs_items.len) break :blk false;
                for (lhs_items, rhs_items) |lhs_item, rhs_item| {
                    if (!tyEql(lhs_item, rhs_item)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .Record => |lhs_record| switch (rhs) {
            .Record => |rhs_record| std.mem.eql(u8, lhs_record.name, rhs_record.name),
            else => false,
        },
        .Arrow => false,
    };
}

pub fn exprLayout(expr: ir.Expr) layout.Layout {
    return switch (expr) {
        .Lambda => |lambda| lambda.layout,
        .Constant => |constant| constant.layout,
        .App => |app| app.layout,
        .Let => |let_expr| let_expr.layout,
        .LetGroup => |group| group.layout,
        .Assert => |assert_expr| assert_expr.layout,
        .If => |if_expr| if_expr.layout,
        .Prim => |prim| prim.layout,
        .Var => |var_ref| var_ref.layout,
        .Ctor => |ctor_expr| ctor_expr.layout,
        .Match => |match_expr| match_expr.layout,
        .Tuple => |tuple_expr| tuple_expr.layout,
        .TupleProj => |tuple_proj| tuple_proj.layout,
        .Record => |record_expr| record_expr.layout,
        .RecordField => |record_field| record_field.layout,
        .RecordUpdate => |record_update| record_update.layout,
        .AccountFieldSet => |field_set| field_set.layout,
    };
}
