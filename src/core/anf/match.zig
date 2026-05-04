const std = @import("std");
const ttree = @import("../../frontend_bridge/ttree.zig");
const ir = @import("../ir.zig");
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const context = @import("context.zig");
const module_lower = @import("module.zig");
const type_ops = @import("type_ops.zig");

const LowerError = context.LowerError;
const BindingInfo = context.BindingInfo;
const ConstructorInfo = context.ConstructorInfo;
const ScopedBinding = context.ScopedBinding;
const TypeBindings = context.TypeBindings;
const LowerContext = context.LowerContext;

const lowerExprPtr = module_lower.lowerExprPtr;
const lowerExprPtrExpected = module_lower.lowerExprPtrExpected;
const lowerExpr = module_lower.lowerExpr;
const lowerConstant = module_lower.lowerConstant;
const lowerPrimOp = module_lower.lowerPrimOp;
const primOpReturnTy = module_lower.primOpReturnTy;
const typeExprToTyWithBindings = type_ops.typeExprToTyWithBindings;
const typeExprsToTysWithBindings = type_ops.typeExprsToTysWithBindings;
const typeRefToTy = type_ops.typeRefToTy;
const listTy = type_ops.listTy;
const findRecordDecl = type_ops.findRecordDecl;
const recordFieldTyForRecord = type_ops.recordFieldTyForRecord;
const exprTy = type_ops.exprTy;
const exprLayout = type_ops.exprLayout;
const tyEql = type_ops.tyEql;
const layoutForTy = type_ops.layoutForTy;

pub fn lowerMatch(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, match_expr: ttree.Match) LowerError!ir.Expr {
    if (match_expr.arms.len == 0) return error.MatchWithoutArms;

    const expected_scrutinee_ty = try inferMatchScrutineeExpectedTy(arena, ctx, match_expr);
    const scrutinee_value = try lowerExprPtrExpected(arena, ctx, match_expr.scrutinee.*, expected_scrutinee_ty);
    const scrutinee_atom = if (isAtomicCore(scrutinee_value.*)) scrutinee_value else blk: {
        const temp_name = try freshMatchTemp(arena, ctx);
        const var_ptr = try arena.allocator().create(ir.Expr);
        var_ptr.* = .{ .Var = .{
            .name = temp_name,
            .ty = exprTy(scrutinee_value.*),
            .layout = exprLayout(scrutinee_value.*),
        } };
        break :blk var_ptr;
    };

    const lowered_match = try lowerMatchWithScrutinee(arena, ctx, match_expr, scrutinee_atom);
    if (scrutinee_atom == scrutinee_value) return lowered_match.*;

    const temp_name = switch (scrutinee_atom.*) {
        .Var => |var_ref| var_ref.name,
        else => unreachable,
    };
    const wrapped = try arena.allocator().create(ir.Expr);
    wrapped.* = .{ .Let = .{
        .name = temp_name,
        .value = scrutinee_value,
        .body = lowered_match,
        .ty = exprTy(lowered_match.*),
        .layout = exprLayout(lowered_match.*),
    } };
    return wrapped.*;
}

pub fn lowerMatchWithScrutinee(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    match_expr: ttree.Match,
    scrutinee: *const ir.Expr,
) LowerError!*const ir.Expr {
    var arms = std.ArrayList(ir.Arm).empty;
    errdefer arms.deinit(arena.allocator());

    for (match_expr.arms) |arm| {
        if (arm.pattern == .Or) {
            for (arm.pattern.Or) |alternative| {
                try lowerAndAppendMatchArm(arena, ctx, &arms, alternative, arm.guard, arm.body, scrutinee);
            }
        } else {
            try lowerAndAppendMatchArm(arena, ctx, &arms, arm.pattern, arm.guard, arm.body, scrutinee);
        }
    }

    const owned_arms = try arms.toOwnedSlice(arena.allocator());
    const match_ty = exprTy(owned_arms[0].body.*);
    const match_layout = exprLayout(owned_arms[0].body.*);

    const ptr = try arena.allocator().create(ir.Expr);
    ptr.* = .{ .Match = .{
        .scrutinee = scrutinee,
        .arms = owned_arms,
        .ty = match_ty,
        .layout = match_layout,
    } };
    return ptr;
}

pub fn lowerAndAppendMatchArm(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    arms: *std.ArrayList(ir.Arm),
    pattern: ttree.Pattern,
    guard_expr: ?*const ttree.Expr,
    body_expr: *const ttree.Expr,
    scrutinee: *const ir.Expr,
) LowerError!void {
    var inserted = std.ArrayList(ScopedBinding).empty;
    defer inserted.deinit(arena.allocator());

    const lowered_pattern = try lowerPattern(arena, ctx, pattern, exprTy(scrutinee.*), exprLayout(scrutinee.*), &inserted);
    const guard = if (guard_expr) |guard|
        try lowerExprPtrExpected(arena, ctx, guard.*, .Bool)
    else
        null;
    const body = try lowerExprPtr(arena, ctx, body_expr.*);
    try arms.append(arena.allocator(), .{
        .pattern = lowered_pattern,
        .guard = guard,
        .body = body,
    });

    restoreBindings(ctx, inserted.items);
}

pub fn inferMatchScrutineeExpectedTy(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, match_expr: ttree.Match) LowerError!?ir.Ty {
    var pattern_var_tys = TypeBindings.init(arena.allocator());
    defer pattern_var_tys.deinit();

    const result_ty = try inferMatchResultTy(arena, &pattern_var_tys, match_expr.arms);
    for (match_expr.arms) |arm| {
        if (arm.guard) |guard_expr| try inferExprVarExpectations(arena, &pattern_var_tys, guard_expr.*, .Bool);
        try inferExprVarExpectations(arena, &pattern_var_tys, arm.body.*, result_ty);
    }

    if (inferConstantPatternTy(match_expr.arms)) |ty| return ty;

    var type_bindings = TypeBindings.init(arena.allocator());
    defer type_bindings.deinit();

    var candidate: ?ConstructorInfo = null;
    for (match_expr.arms) |arm| {
        try inferCtorCandidateFromPattern(ctx, arm.pattern, &candidate, &type_bindings, &pattern_var_tys);
    }

    const info = candidate orelse return null;
    const params = try arena.allocator().alloc(ir.Ty, info.type_params.len);
    for (info.type_params, 0..) |param_name, index| {
        params[index] = type_bindings.get(param_name) orelse .{ .Var = param_name };
    }
    return .{ .Adt = .{
        .name = info.type_name,
        .params = params,
    } };
}

pub fn inferConstantPatternTy(arms: []const ttree.Arm) ?ir.Ty {
    for (arms) |arm| {
        if (inferConstantPatternTyFromPattern(arm.pattern)) |ty| return ty;
    }
    return null;
}

pub fn inferConstantPatternTyFromPattern(pattern: ttree.Pattern) ?ir.Ty {
    return switch (pattern) {
        .Const => |constant| switch (constant) {
            .Int, .Char => .Int,
            .String => .String,
        },
        .Or => |alternatives| blk: {
            for (alternatives) |alternative| {
                if (inferConstantPatternTyFromPattern(alternative)) |ty| break :blk ty;
            }
            break :blk null;
        },
        .Alias => |alias| inferConstantPatternTyFromPattern(alias.pattern.*),
        .Ctor, .Tuple, .Record, .Wildcard, .Var => null,
    };
}

pub fn inferCtorCandidateFromPattern(
    ctx: *LowerContext,
    pattern: ttree.Pattern,
    candidate: *?ConstructorInfo,
    type_bindings: *TypeBindings,
    pattern_var_tys: *TypeBindings,
) LowerError!void {
    switch (pattern) {
        .Ctor => |ctor_pattern| {
            const info = ctx.constructors.get(ctor_pattern.name) orelse return;
            if (candidate.*) |existing| {
                if (!std.mem.eql(u8, existing.type_name, info.type_name)) return;
            } else {
                candidate.* = info;
            }
            try bindTypeParamsFromPatternPayloads(type_bindings, info.payload_types, ctor_pattern.args, pattern_var_tys);
        },
        .Or => |alternatives| {
            for (alternatives) |alternative| try inferCtorCandidateFromPattern(ctx, alternative, candidate, type_bindings, pattern_var_tys);
        },
        .Alias => |alias| try inferCtorCandidateFromPattern(ctx, alias.pattern.*, candidate, type_bindings, pattern_var_tys),
        .Tuple => |items| {
            for (items) |item| try inferCtorCandidateFromPattern(ctx, item, candidate, type_bindings, pattern_var_tys);
        },
        .Record => |fields| {
            for (fields) |field| try inferCtorCandidateFromPattern(ctx, field.pattern, candidate, type_bindings, pattern_var_tys);
        },
        .Wildcard, .Var, .Const => {},
    }
}

pub fn inferMatchResultTy(arena: *std.heap.ArenaAllocator, pattern_var_tys: *TypeBindings, arms: []const ttree.Arm) LowerError!?ir.Ty {
    for (arms) |arm| {
        if (try inferSimpleExprTy(arena, pattern_var_tys, arm.body.*)) |ty| return ty;
    }
    return null;
}

pub fn inferSimpleExprTy(arena: *std.heap.ArenaAllocator, pattern_var_tys: *TypeBindings, expr: ttree.Expr) LowerError!?ir.Ty {
    return switch (expr) {
        .Constant => |constant| switch (constant) {
            .Int => .Int,
            .String => .String,
        },
        .Prim => |prim| blk: {
            const op = try lowerPrimOp(prim.op);
            break :blk primOpReturnTy(op);
        },
        .If => |if_expr| blk: {
            try inferExprVarExpectations(arena, pattern_var_tys, if_expr.cond.*, .Bool);
            const then_ty = try inferSimpleExprTy(arena, pattern_var_tys, if_expr.then_branch.*);
            const else_ty = try inferSimpleExprTy(arena, pattern_var_tys, if_expr.else_branch.*);
            if (then_ty) |lhs| {
                if (else_ty) |rhs| {
                    if (tyEql(lhs, rhs)) break :blk lhs;
                }
            }
            break :blk null;
        },
        .Var => |var_ref| pattern_var_tys.get(var_ref.name),
        .Let => |let_expr| try inferSimpleExprTy(arena, pattern_var_tys, let_expr.body.*),
        .LetRecGroup => |group| try inferSimpleExprTy(arena, pattern_var_tys, group.body.*),
        .Assert => .Unit,
        .Tuple => |tuple_expr| blk: {
            const tys = try arena.allocator().alloc(ir.Ty, tuple_expr.items.len);
            for (tuple_expr.items, 0..) |item, index| {
                tys[index] = (try inferSimpleExprTy(arena, pattern_var_tys, item)) orelse .Int;
            }
            break :blk .{ .Tuple = tys };
        },
        .Lambda, .App, .Ctor, .Match, .TupleProj, .Record, .RecordField, .RecordUpdate, .FieldSet => null,
    };
}

pub fn inferExprVarExpectations(arena: *std.heap.ArenaAllocator, pattern_var_tys: *TypeBindings, expr: ttree.Expr, expected_ty: ?ir.Ty) LowerError!void {
    switch (expr) {
        .Var => |var_ref| {
            if (expected_ty) |ty| {
                if (!pattern_var_tys.contains(var_ref.name)) try pattern_var_tys.put(var_ref.name, ty);
            }
        },
        .If => |if_expr| {
            try inferExprVarExpectations(arena, pattern_var_tys, if_expr.cond.*, .Bool);
            try inferExprVarExpectations(arena, pattern_var_tys, if_expr.then_branch.*, expected_ty);
            try inferExprVarExpectations(arena, pattern_var_tys, if_expr.else_branch.*, expected_ty);
        },
        .Prim => |prim| {
            const op = try lowerPrimOp(prim.op);
            const arg_ty: ?ir.Ty = switch (op) {
                .Add, .Sub, .Mul, .Div, .Mod, .Lt, .Le, .Gt, .Ge => .Int,
                .Eq, .Ne => null,
                .StringLength, .StringGet, .StringSub, .StringConcat, .CharCode, .CharChr => null,
            };
            for (prim.args) |arg| try inferExprVarExpectations(arena, pattern_var_tys, arg, arg_ty);
        },
        .Let => |let_expr| {
            try inferExprVarExpectations(arena, pattern_var_tys, let_expr.value.*, null);
            try inferExprVarExpectations(arena, pattern_var_tys, let_expr.body.*, expected_ty);
        },
        .LetRecGroup => |group| {
            for (group.bindings) |binding| try inferExprVarExpectations(arena, pattern_var_tys, binding.body, null);
            try inferExprVarExpectations(arena, pattern_var_tys, group.body.*, expected_ty);
        },
        .Assert => |assert_expr| try inferExprVarExpectations(arena, pattern_var_tys, assert_expr.condition.*, .Bool),
        .App => |app| {
            try inferExprVarExpectations(arena, pattern_var_tys, app.callee.*, null);
            for (app.args) |arg| try inferExprVarExpectations(arena, pattern_var_tys, arg, null);
        },
        .Ctor => |ctor| {
            for (ctor.args) |arg| try inferExprVarExpectations(arena, pattern_var_tys, arg, null);
        },
        .Tuple => |tuple_expr| {
            for (tuple_expr.items) |item| try inferExprVarExpectations(arena, pattern_var_tys, item, null);
        },
        .TupleProj => |tuple_proj| try inferExprVarExpectations(arena, pattern_var_tys, tuple_proj.tuple_expr.*, null),
        .Record => |record_expr| {
            for (record_expr.fields) |field| try inferExprVarExpectations(arena, pattern_var_tys, field.value, null);
        },
        .RecordField => |field_access| try inferExprVarExpectations(arena, pattern_var_tys, field_access.record_expr.*, null),
        .RecordUpdate => |record_update| {
            try inferExprVarExpectations(arena, pattern_var_tys, record_update.base_expr.*, null);
            for (record_update.fields) |field| try inferExprVarExpectations(arena, pattern_var_tys, field.value, null);
        },
        .FieldSet => |field_set| {
            try inferExprVarExpectations(arena, pattern_var_tys, field_set.record_expr.*, null);
            try inferExprVarExpectations(arena, pattern_var_tys, field_set.value.*, null);
        },
        .Match => |nested_match| {
            try inferExprVarExpectations(arena, pattern_var_tys, nested_match.scrutinee.*, null);
            for (nested_match.arms) |arm| {
                if (arm.guard) |guard_expr| try inferExprVarExpectations(arena, pattern_var_tys, guard_expr.*, .Bool);
                try inferExprVarExpectations(arena, pattern_var_tys, arm.body.*, expected_ty);
            }
        },
        .Lambda, .Constant => {},
    }
}

pub fn bindTypeParamsFromPatternPayloads(
    bindings: *TypeBindings,
    expected_payloads: []const types.TypeExpr,
    patterns: []const ttree.Pattern,
    pattern_var_tys: *TypeBindings,
) LowerError!void {
    for (expected_payloads, patterns) |expected, pattern| {
        try bindTypeParamsFromPattern(bindings, expected, pattern, pattern_var_tys);
    }
}

pub fn bindTypeParamsFromPattern(
    bindings: *TypeBindings,
    expected: types.TypeExpr,
    pattern: ttree.Pattern,
    pattern_var_tys: *TypeBindings,
) LowerError!void {
    switch (pattern) {
        .Var => |name| {
            if (std.mem.eql(u8, name, "_")) return;
            if (pattern_var_tys.get(name)) |actual| {
                try bindTypeParamsFromPayload(bindings, expected, actual);
            }
        },
        .Wildcard, .Const => {},
        .Alias => |alias| {
            try bindTypeParamsFromPattern(bindings, expected, alias.pattern.*, pattern_var_tys);
            if (pattern_var_tys.get(alias.name)) |actual| {
                try bindTypeParamsFromPayload(bindings, expected, actual);
            }
        },
        .Or => |alternatives| {
            for (alternatives) |alternative| try bindTypeParamsFromPattern(bindings, expected, alternative, pattern_var_tys);
        },
        .Ctor => {},
        .Tuple => |items| switch (expected) {
            .Tuple => |expected_items| {
                for (expected_items, items) |expected_item, item_pattern| {
                    try bindTypeParamsFromPattern(bindings, expected_item, item_pattern, pattern_var_tys);
                }
            },
            else => {},
        },
        .Record => {},
    }
}

pub fn lowerPattern(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    pattern: ttree.Pattern,
    matched_ty: ir.Ty,
    matched_layout: layout.Layout,
    inserted: *std.ArrayList(ScopedBinding),
) LowerError!ir.Pattern {
    return switch (pattern) {
        .Wildcard => .Wildcard,
        .Var => |name| blk: {
            if (std.mem.eql(u8, name, "_")) break :blk .Wildcard;
            const owned_name = try arena.allocator().dupe(u8, name);
            try bindPatternName(arena.allocator(), ctx, inserted, owned_name, .{
                .ty = matched_ty,
                .layout = matched_layout,
            });
            break :blk .{ .Var = .{
                .name = owned_name,
                .ty = matched_ty,
                .layout = matched_layout,
            } };
        },
        .Const => |constant| .{ .Constant = try lowerPatternConstant(arena, constant, matched_ty) },
        .Alias => |alias| blk: {
            const child = try arena.allocator().create(ir.Pattern);
            child.* = try lowerPattern(arena, ctx, alias.pattern.*, matched_ty, matched_layout, inserted);
            const owned_name = try arena.allocator().dupe(u8, alias.name);
            try bindPatternName(arena.allocator(), ctx, inserted, owned_name, .{
                .ty = matched_ty,
                .layout = matched_layout,
            });
            break :blk .{ .Alias = .{
                .pattern = child,
                .name = owned_name,
                .ty = matched_ty,
                .layout = matched_layout,
            } };
        },
        .Or => return error.UnsupportedPattern,
        .Ctor => |ctor_pattern| try lowerCtorPattern(arena, ctx, ctor_pattern, matched_ty, inserted),
        .Tuple => |items| blk: {
            const tuple_tys = switch (matched_ty) {
                .Tuple => |tys| tys,
                else => return error.UnsupportedPattern,
            };
            if (items.len != tuple_tys.len) return error.UnsupportedPattern;
            const patterns = try arena.allocator().alloc(ir.Pattern, items.len);
            for (items, tuple_tys, 0..) |item_pattern, item_ty, index| {
                patterns[index] = try lowerPattern(arena, ctx, item_pattern, item_ty, layoutForTy(item_ty), inserted);
            }
            break :blk .{ .Tuple = patterns };
        },
        .Record => |fields| blk: {
            const record = switch (matched_ty) {
                .Record => |value| value,
                else => return error.UnsupportedPattern,
            };
            const record_decl = findRecordDecl(ctx.record_type_decls, record.name) orelse return error.UnsupportedPattern;
            const lowered_fields = try arena.allocator().alloc(ir.RecordPatternField, fields.len);
            for (fields, 0..) |field, index| {
                const field_ty = try recordFieldTyForRecord(arena, ctx, record_decl, matched_ty, field.name);
                lowered_fields[index] = .{
                    .name = try arena.allocator().dupe(u8, field.name),
                    .pattern = try lowerPattern(arena, ctx, field.pattern, field_ty, layoutForTy(field_ty), inserted),
                };
            }
            break :blk .{ .Record = lowered_fields };
        },
    };
}

pub fn lowerPatternConstant(arena: *std.heap.ArenaAllocator, constant: ttree.PatternConstant, matched_ty: ir.Ty) LowerError!ir.PatternConstant {
    return switch (constant) {
        .Int => |value| blk: {
            switch (matched_ty) {
                .Int => {},
                else => return error.UnsupportedPattern,
            }
            break :blk .{ .Int = value };
        },
        .Char => |value| blk: {
            switch (matched_ty) {
                .Int => {},
                else => return error.UnsupportedPattern,
            }
            break :blk .{ .Char = value };
        },
        .String => |value| blk: {
            switch (matched_ty) {
                .String => {},
                else => return error.UnsupportedPattern,
            }
            break :blk .{ .String = try arena.allocator().dupe(u8, value) };
        },
    };
}

pub fn lowerCtorPattern(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    ctor_pattern: ttree.CtorPattern,
    matched_ty: ir.Ty,
    inserted: *std.ArrayList(ScopedBinding),
) LowerError!ir.Pattern {
    const ctor_info = try validateCtor(ctx, ctor_pattern.name, ctor_pattern.args.len);
    const payload_tys = try ctorPatternPayloadTys(arena, ctx, ctor_pattern.name, matched_ty);

    var args = std.ArrayList(ir.Pattern).empty;
    errdefer args.deinit(arena.allocator());
    for (ctor_pattern.args, 0..) |arg, index| {
        try args.append(
            arena.allocator(),
            try lowerPattern(arena, ctx, arg, payload_tys[index], layoutForTy(payload_tys[index]), inserted),
        );
    }

    return .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, ctor_pattern.name),
        .args = try args.toOwnedSlice(arena.allocator()),
        .tag = if (ctor_info) |info| info.tag else builtinCtorTag(ctor_pattern.name),
        .type_name = if (ctor_info) |info| try arena.allocator().dupe(u8, info.type_name) else null,
    } };
}

pub fn validateCtor(ctx: *LowerContext, name: []const u8, arg_count: usize) LowerError!?ConstructorInfo {
    if (ctx.constructors.get(name)) |info| {
        if (arg_count != info.payload_types.len) return error.UnsupportedCtorArity;
        return info;
    }
    if (std.mem.eql(u8, name, "None")) {
        if (arg_count != 0) return error.UnsupportedCtorArity;
        return null;
    }
    if (std.mem.eql(u8, name, "Some") or std.mem.eql(u8, name, "Ok") or std.mem.eql(u8, name, "Error")) {
        if (arg_count != 1) return error.UnsupportedCtorArity;
        return null;
    }
    if (std.mem.eql(u8, name, "[]")) {
        if (arg_count != 0) return error.UnsupportedCtorArity;
        return null;
    }
    if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) {
        if (arg_count != 0) return error.UnsupportedCtorArity;
        return null;
    }
    if (std.mem.eql(u8, name, "()")) {
        if (arg_count != 0) return error.UnsupportedCtorArity;
        return null;
    }
    if (std.mem.eql(u8, name, "::")) {
        if (arg_count != 2) return error.UnsupportedCtorArity;
        return null;
    }
    return error.UnsupportedCtor;
}

pub fn builtinCtorTag(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "None")) return 0;
    if (std.mem.eql(u8, name, "Some")) return 1;
    if (std.mem.eql(u8, name, "Ok")) return 0;
    if (std.mem.eql(u8, name, "Error")) return 1;
    if (std.mem.eql(u8, name, "[]")) return 0;
    if (std.mem.eql(u8, name, "::")) return 1;
    if (std.mem.eql(u8, name, "true")) return 1;
    if (std.mem.eql(u8, name, "false")) return 0;
    return 0;
}

pub fn isAtomicTtree(expr: ttree.Expr) bool {
    return switch (expr) {
        .Constant, .Var => true,
        else => false,
    };
}

pub fn isAtomicCore(expr: ir.Expr) bool {
    return switch (expr) {
        .Constant, .Var => true,
        else => false,
    };
}

pub fn freshTemp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext) LowerError![]const u8 {
    const name = try std.fmt.allocPrint(arena.allocator(), "__omlz_ctor_arg_{d}", .{ctx.next_temp});
    ctx.next_temp += 1;
    return name;
}

pub fn freshMatchTemp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext) LowerError![]const u8 {
    const name = try std.fmt.allocPrint(arena.allocator(), "__omlz_match_scrutinee_{d}", .{ctx.next_temp});
    ctx.next_temp += 1;
    return name;
}

pub fn bindPatternName(
    allocator: std.mem.Allocator,
    ctx: *LowerContext,
    inserted: *std.ArrayList(ScopedBinding),
    name: []const u8,
    binding: BindingInfo,
) LowerError!void {
    const previous = ctx.scope.get(name);
    try ctx.scope.put(name, binding);
    try inserted.append(allocator, .{ .name = name, .previous = previous });
}

pub fn restoreBindings(ctx: *LowerContext, inserted: []const ScopedBinding) void {
    var index = inserted.len;
    while (index > 0) {
        index -= 1;
        const binding = inserted[index];
        if (binding.previous) |previous| {
            ctx.scope.getPtr(binding.name).?.* = previous;
        } else {
            _ = ctx.scope.remove(binding.name);
        }
    }
}

pub fn ctorPatternPayloadTys(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, name: []const u8, matched_ty: ir.Ty) LowerError![]const ir.Ty {
    if (ctx.constructors.get(name)) |info| {
        var bindings = TypeBindings.init(arena.allocator());
        defer bindings.deinit();
        try bindTypeParamsFromMatchedAdt(&bindings, info, matched_ty);
        return typeExprsToTysWithBindings(arena, ctx.record_type_decls, info.payload_types, &bindings);
    }

    const adt = switch (matched_ty) {
        .Adt => |value| value,
        else => return error.UnsupportedPattern,
    };

    if (std.mem.eql(u8, name, "Some")) {
        if (adt.params.len != 1) return error.UnsupportedPattern;
        const payloads = try arena.allocator().alloc(ir.Ty, 1);
        payloads[0] = adt.params[0];
        return payloads;
    }
    if (std.mem.eql(u8, name, "Ok")) {
        if (adt.params.len != 2) return error.UnsupportedPattern;
        const payloads = try arena.allocator().alloc(ir.Ty, 1);
        payloads[0] = adt.params[0];
        return payloads;
    }
    if (std.mem.eql(u8, name, "Error")) {
        if (adt.params.len != 2) return error.UnsupportedPattern;
        const payloads = try arena.allocator().alloc(ir.Ty, 1);
        payloads[0] = adt.params[1];
        return payloads;
    }
    if (std.mem.eql(u8, name, "None")) return &.{};
    if (std.mem.eql(u8, name, "[]")) {
        if (!std.mem.eql(u8, adt.name, "list")) return error.UnsupportedPattern;
        return &.{};
    }
    if (std.mem.eql(u8, name, "::")) {
        if (!std.mem.eql(u8, adt.name, "list") or adt.params.len != 1) return error.UnsupportedPattern;
        const payloads = try arena.allocator().alloc(ir.Ty, 2);
        payloads[0] = adt.params[0];
        payloads[1] = matched_ty;
        return payloads;
    }
    return error.UnsupportedPattern;
}

pub fn ctorTy(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, name: []const u8, args: []const *const ir.Expr, expected_ty: ?ir.Ty) LowerError!ir.Ty {
    if (ctx.constructors.get(name)) |info| {
        const params = try inferConstructorTypeParams(arena, info, args, expected_ty);
        return .{ .Adt = .{
            .name = info.type_name,
            .params = params,
        } };
    }

    if (std.mem.eql(u8, name, "[]")) {
        return listTy(arena, .Int);
    }
    if (std.mem.eql(u8, name, "::")) {
        return listTy(arena, exprTy(args[0].*));
    }
    if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) {
        return .Bool;
    }
    if (std.mem.eql(u8, name, "()")) {
        return .Unit;
    }
    if (expected_ty) |ty| {
        switch (ty) {
            .Adt => |expected_adt| {
                if ((std.mem.eql(u8, name, "Some") or std.mem.eql(u8, name, "None")) and
                    std.mem.eql(u8, expected_adt.name, "option"))
                {
                    return ty;
                }
                if ((std.mem.eql(u8, name, "Ok") or std.mem.eql(u8, name, "Error")) and
                    std.mem.eql(u8, expected_adt.name, "result"))
                {
                    return ty;
                }
            },
            else => {},
        }
    }
    const adt_name = if (std.mem.eql(u8, name, "Some") or std.mem.eql(u8, name, "None")) "option" else "result";
    const param_count: usize = if (std.mem.eql(u8, adt_name, "option")) 1 else 2;
    const params = try arena.allocator().alloc(ir.Ty, param_count);
    if (std.mem.eql(u8, adt_name, "option")) {
        params[0] = if (args.len == 1) exprTy(args[0].*) else .Int;
    } else if (std.mem.eql(u8, name, "Ok")) {
        params[0] = exprTy(args[0].*);
        params[1] = .Unit;
    } else {
        params[0] = .Unit;
        params[1] = exprTy(args[0].*);
    }
    return .{ .Adt = .{
        .name = adt_name,
        .params = params,
    } };
}

pub fn inferConstructorTypeParams(arena: *std.heap.ArenaAllocator, info: ConstructorInfo, args: []const *const ir.Expr, expected_ty: ?ir.Ty) LowerError![]const ir.Ty {
    var bindings = TypeBindings.init(arena.allocator());
    defer bindings.deinit();

    if (expected_ty) |ty| {
        bindTypeParamsFromMatchedAdt(&bindings, info, ty) catch {};
    }

    for (info.payload_types, args) |payload_ty, arg| {
        try bindTypeParamsFromPayload(&bindings, payload_ty, exprTy(arg.*));
    }

    const params = try arena.allocator().alloc(ir.Ty, info.type_params.len);
    for (info.type_params, 0..) |param_name, index| {
        params[index] = bindings.get(param_name) orelse .{ .Var = param_name };
    }
    return params;
}

pub fn bindTypeParamsFromMatchedAdt(bindings: *TypeBindings, info: ConstructorInfo, matched_ty: ir.Ty) LowerError!void {
    const adt = switch (matched_ty) {
        .Adt => |value| value,
        else => return error.UnsupportedPattern,
    };
    if (!std.mem.eql(u8, adt.name, info.type_name)) return error.UnsupportedPattern;
    if (adt.params.len != info.type_params.len) return error.UnsupportedPattern;
    for (info.type_params, adt.params) |param_name, param_ty| {
        try bindings.put(param_name, param_ty);
    }
}

pub fn bindTypeParamsFromPayload(
    bindings: *TypeBindings,
    expected: types.TypeExpr,
    actual: ir.Ty,
) LowerError!void {
    switch (expected) {
        .TypeVar => |name| {
            if (bindings.get(name)) |existing| {
                if (std.meta.activeTag(existing) == .Var and std.meta.activeTag(actual) != .Var) {
                    try bindings.put(name, actual);
                }
            } else {
                try bindings.put(name, actual);
            }
        },
        .TypeRef, .RecursiveRef => |ref| {
            const ActualTypeRef = struct {
                name: []const u8,
                params: []const ir.Ty,
            };
            const actual_ref = switch (actual) {
                .Adt => |value| ActualTypeRef{ .name = value.name, .params = value.params },
                .Record => |value| ActualTypeRef{ .name = value.name, .params = value.params },
                else => return,
            };
            if (!std.mem.eql(u8, ref.name, actual_ref.name)) return;
            for (ref.args, actual_ref.params) |arg_expr, arg_ty| {
                try bindTypeParamsFromPayload(bindings, arg_expr, arg_ty);
            }
        },
        .Tuple => |items| {
            const actual_items = switch (actual) {
                .Tuple => |value| value,
                else => return,
            };
            for (items, actual_items) |expected_item, actual_item| {
                try bindTypeParamsFromPayload(bindings, expected_item, actual_item);
            }
        },
    }
}
