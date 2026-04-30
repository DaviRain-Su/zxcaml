//! ANF lowering from the frontend typed-tree mirror to Core IR.
//!
//! RESPONSIBILITIES:
//! - Convert `frontend_bridge/ttree.zig` values into the stable Core IR contract.
//! - Preserve the ANF property: every non-trivial sub-expression is named via
//!   `let`, and every future call argument is an atom.
//! - Assign deterministic M0 layout annotations while lowering.

const std = @import("std");
const ttree = @import("../frontend_bridge/ttree.zig");
const ir = @import("ir.zig");
const layout = @import("layout.zig");
const pretty = @import("pretty.zig");
const types = @import("types.zig");

/// Errors that can occur while lowering the frontend mirror to Core IR.
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

const BindingInfo = struct {
    ty: ir.Ty,
    layout: layout.Layout,
};

const ConstructorInfo = struct {
    type_name: []const u8,
    tag: u32,
    payload_types: []const types.TypeExpr,
    type_params: []const []const u8,
};

const ScopedBinding = struct {
    name: []const u8,
    previous: ?BindingInfo,
};

const TypeBindings = std.StringHashMap(ir.Ty);

const LowerContext = struct {
    scope: std.StringHashMap(BindingInfo),
    constructors: std.StringHashMap(ConstructorInfo),
    tuple_type_decls: []const types.TupleType = &.{},
    record_type_decls: []const types.RecordType = &.{},
    next_temp: usize = 0,
};

/// Lowers a frontend typed-tree module into an arena-owned Core IR module.
pub fn lowerModule(arena: *std.heap.ArenaAllocator, module: ttree.Module) LowerError!ir.Module {
    var decls = std.ArrayList(ir.Decl).empty;
    errdefer decls.deinit(arena.allocator());

    var ctx: LowerContext = .{
        .scope = std.StringHashMap(BindingInfo).init(arena.allocator()),
        .constructors = std.StringHashMap(ConstructorInfo).init(arena.allocator()),
    };
    defer ctx.constructors.deinit();
    defer ctx.scope.deinit();

    const type_decls = try lowerTypeDecls(arena, module.type_decls);
    const tuple_type_decls = try lowerTupleTypeDecls(arena, module.tuple_type_decls);
    const record_type_decls = try lowerRecordTypeDecls(arena, module.record_type_decls);
    const externals = try lowerExternalDecls(arena, module.externals, record_type_decls);
    ctx.tuple_type_decls = tuple_type_decls;
    ctx.record_type_decls = record_type_decls;
    try indexConstructors(&ctx, type_decls);

    for (externals) |external| {
        try ctx.scope.put(external.name, .{
            .ty = external.ty,
            .layout = layoutForTy(external.ty),
        });
    }

    for (module.decls) |decl| {
        switch (decl) {
            .Let => |let_decl| {
                if (let_decl.is_rec) {
                    try ctx.scope.put(let_decl.name, .{
                        .ty = .Unit,
                        .layout = layout.topLevelLambda(),
                    });
                }
            },
        }
    }

    for (module.decls) |decl| {
        const lowered = try lowerDecl(arena, &ctx, decl);
        try decls.append(arena.allocator(), lowered);
        switch (lowered) {
            .Let => |let_decl| try ctx.scope.put(let_decl.name, .{
                .ty = let_decl.ty,
                .layout = let_decl.layout,
            }),
        }
    }

    return .{
        .decls = try decls.toOwnedSlice(arena.allocator()),
        .type_decls = type_decls,
        .tuple_type_decls = tuple_type_decls,
        .record_type_decls = record_type_decls,
        .externals = externals,
    };
}

fn lowerTypeDecls(arena: *std.heap.ArenaAllocator, decls: []const ttree.TypeDecl) LowerError![]const types.VariantType {
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

fn lowerTupleTypeDecls(arena: *std.heap.ArenaAllocator, decls: []const ttree.TupleTypeDecl) LowerError![]const types.TupleType {
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

fn lowerRecordTypeDecls(arena: *std.heap.ArenaAllocator, decls: []const ttree.RecordTypeDecl) LowerError![]const types.RecordType {
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

fn lowerExternalDecls(
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

fn lowerTypeExprs(arena: *std.heap.ArenaAllocator, exprs: []const ttree.TypeExpr) LowerError![]const types.TypeExpr {
    const lowered = try arena.allocator().alloc(types.TypeExpr, exprs.len);
    for (exprs, 0..) |expr, index| {
        lowered[index] = try lowerTypeExpr(arena, expr);
    }
    return lowered;
}

fn lowerTypeExpr(arena: *std.heap.ArenaAllocator, expr: ttree.TypeExpr) LowerError!types.TypeExpr {
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

fn dupeStringSlice(arena: *std.heap.ArenaAllocator, values: []const []const u8) LowerError![]const []const u8 {
    const out = try arena.allocator().alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        out[index] = try arena.allocator().dupe(u8, value);
    }
    return out;
}

fn indexConstructors(ctx: *LowerContext, type_decls: []const types.VariantType) LowerError!void {
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

fn lowerDecl(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, decl: ttree.Decl) LowerError!ir.Decl {
    return switch (decl) {
        .Let => |let_decl| blk: {
            var value = try lowerExprPtr(arena, ctx, let_decl.body);
            if (let_decl.is_rec) {
                value = try markTailCallsInFunction(arena, value, let_decl.name);
            }
            break :blk .{ .Let = .{
                .name = try arena.allocator().dupe(u8, let_decl.name),
                .value = value,
                .ty = exprTy(value.*),
                .layout = exprLayout(value.*),
                .is_rec = let_decl.is_rec,
            } };
        },
    };
}

fn lowerLambda(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, lambda: ttree.Lambda) LowerError!ir.Lambda {
    var params = std.ArrayList(ir.Param).empty;
    errdefer params.deinit(arena.allocator());

    var inserted_params = std.ArrayList(ScopedBinding).empty;
    defer inserted_params.deinit(arena.allocator());

    for (lambda.params) |param_name| {
        const owned_name = try arena.allocator().dupe(u8, param_name);
        const param_ty: ir.Ty = if (std.mem.startsWith(u8, param_name, "_"))
            .Unit
        else if (isInstructionDataParamName(param_name))
            .String
        else if (lambdaParamIsAccount(lambda.body.*, param_name))
            try accountTy(arena)
        else if (try lambdaParamIsList(arena, lambda.body.*, param_name))
            try listTy(arena, .Int)
        else if (lambdaParamIsFunction(lambda.body.*, param_name))
            try intToIntArrowTy(arena)
        else
            .Int;
        const param_layout = layoutForTy(param_ty);
        try params.append(arena.allocator(), .{
            .name = owned_name,
            .ty = param_ty,
        });
        const previous = ctx.scope.get(owned_name);
        try ctx.scope.put(owned_name, .{
            .ty = param_ty,
            .layout = param_layout,
        });
        try inserted_params.append(arena.allocator(), .{ .name = owned_name, .previous = previous });
    }
    defer {
        var index = inserted_params.items.len;
        while (index > 0) {
            index -= 1;
            const inserted = inserted_params.items[index];
            if (inserted.previous) |binding| {
                ctx.scope.getPtr(inserted.name).?.* = binding;
            } else {
                _ = ctx.scope.remove(inserted.name);
            }
        }
    }

    const owned_params = try params.toOwnedSlice(arena.allocator());
    const body = try lowerExprPtr(arena, ctx, lambda.body.*);
    const lambda_ty = try makeArrowTy(arena, owned_params, exprTy(body.*));

    return .{
        .params = owned_params,
        .body = body,
        .ty = lambda_ty,
        .layout = layout.topLevelLambda(),
    };
}

fn lowerExprPtr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, expr: ttree.Expr) LowerError!*const ir.Expr {
    return lowerExprPtrExpected(arena, ctx, expr, null);
}

fn lowerExprPtrExpected(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    expr: ttree.Expr,
    expected_ty: ?ir.Ty,
) LowerError!*const ir.Expr {
    const ptr = try arena.allocator().create(ir.Expr);
    ptr.* = try lowerExprExpected(arena, ctx, expr, expected_ty);
    return ptr;
}

fn lowerExpr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, expr: ttree.Expr) LowerError!ir.Expr {
    return lowerExprExpected(arena, ctx, expr, null);
}

fn lowerExprExpected(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, expr: ttree.Expr, expected_ty: ?ir.Ty) LowerError!ir.Expr {
    return switch (expr) {
        .Lambda => |lambda| .{ .Lambda = try lowerLambda(arena, ctx, lambda) },
        .Constant => |constant| .{ .Constant = try lowerConstant(arena, constant) },
        .App => |app| try lowerApp(arena, ctx, app),
        .Let => |let_expr| .{ .Let = try lowerLetExpr(arena, ctx, let_expr) },
        .If => |if_expr| try lowerIf(arena, ctx, if_expr),
        .Prim => |prim| try lowerPrim(arena, ctx, prim),
        .Var => |var_ref| try lowerVarExpr(arena, ctx, var_ref, expected_ty),
        .Ctor => |ctor_expr| try lowerCtor(arena, ctx, ctor_expr, expected_ty),
        .Match => |match_expr| try lowerMatch(arena, ctx, match_expr),
        .Tuple => |tuple_expr| try lowerTuple(arena, ctx, tuple_expr),
        .TupleProj => |tuple_proj| try lowerTupleProj(arena, ctx, tuple_proj),
        .Record => |record_expr| try lowerRecord(arena, ctx, record_expr),
        .RecordField => |field_access| try lowerRecordField(arena, ctx, field_access),
        .RecordUpdate => |record_update| try lowerRecordUpdate(arena, ctx, record_update),
        .FieldSet => |field_set| try lowerFieldSet(arena, ctx, field_set),
    };
}

fn lowerTuple(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, tuple_expr: ttree.Tuple) LowerError!ir.Expr {
    const items = try arena.allocator().alloc(*const ir.Expr, tuple_expr.items.len);
    const item_tys = try arena.allocator().alloc(ir.Ty, tuple_expr.items.len);
    for (tuple_expr.items, 0..) |item, index| {
        const lowered = try lowerExprPtr(arena, ctx, item);
        items[index] = lowered;
        item_tys[index] = exprTy(lowered.*);
    }
    return .{ .Tuple = .{
        .items = items,
        .ty = .{ .Tuple = item_tys },
        .layout = layout.structPack(),
    } };
}

fn lowerTupleProj(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, tuple_proj: ttree.TupleProj) LowerError!ir.Expr {
    const tuple_expr = try lowerExprPtr(arena, ctx, tuple_proj.tuple_expr.*);
    const tuple_ty = switch (exprTy(tuple_expr.*)) {
        .Tuple => |items| items,
        else => return error.UnsupportedNode,
    };
    if (tuple_proj.index >= tuple_ty.len) return error.UnsupportedNode;
    const ty = tuple_ty[tuple_proj.index];
    return .{ .TupleProj = .{
        .tuple_expr = tuple_expr,
        .index = tuple_proj.index,
        .ty = ty,
        .layout = layoutForTy(ty),
    } };
}

fn lowerRecord(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, record_expr: ttree.Record) LowerError!ir.Expr {
    const record_decl = findRecordDeclForFields(ctx.record_type_decls, record_expr.fields) orelse return error.UnsupportedNode;
    const fields = try arena.allocator().alloc(ir.RecordExprField, record_expr.fields.len);
    for (record_expr.fields, 0..) |field, index| {
        fields[index] = .{
            .name = try arena.allocator().dupe(u8, field.name),
            .value = try lowerExprPtr(arena, ctx, field.value),
        };
    }
    var bindings = TypeBindings.init(arena.allocator());
    defer bindings.deinit();
    for (record_decl.fields) |decl_field| {
        const field = findRecordExprField(fields, decl_field.name) orelse return error.UnsupportedNode;
        try bindTypeParamsFromPayload(&bindings, decl_field.ty, exprTy(field.value.*));
    }
    return .{ .Record = .{
        .fields = fields,
        .ty = try recordTyWithBindings(arena, record_decl, &bindings),
        .layout = layout.structPack(),
    } };
}

fn lowerRecordField(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, field_access: ttree.RecordField) LowerError!ir.Expr {
    const record_expr = try lowerExprPtr(arena, ctx, field_access.record_expr.*);
    const ty = try recordFieldAccessTy(arena, ctx, exprTy(record_expr.*), field_access.field_name);
    return .{ .RecordField = .{
        .record_expr = record_expr,
        .field_name = try arena.allocator().dupe(u8, field_access.field_name),
        .ty = ty,
        .layout = layoutForTy(ty),
    } };
}

fn lowerRecordUpdate(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, record_update: ttree.RecordUpdate) LowerError!ir.Expr {
    const base_expr = try lowerExprPtr(arena, ctx, record_update.base_expr.*);
    const base_ty = exprTy(base_expr.*);
    const record_decl = switch (base_ty) {
        .Record => |record| findRecordDecl(ctx.record_type_decls, record.name) orelse return error.UnsupportedNode,
        else => return error.UnsupportedNode,
    };
    const fields = try arena.allocator().alloc(ir.RecordExprField, record_update.fields.len);
    for (record_update.fields, 0..) |field, index| {
        fields[index] = .{
            .name = try arena.allocator().dupe(u8, field.name),
            .value = try lowerExprPtrExpected(arena, ctx, field.value, try recordFieldTyForRecord(arena, ctx, record_decl, base_ty, field.name)),
        };
    }
    return .{ .RecordUpdate = .{
        .base_expr = base_expr,
        .fields = fields,
        .ty = base_ty,
        .layout = layout.structPack(),
    } };
}

fn lowerFieldSet(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, field_set: ttree.FieldSet) LowerError!ir.Expr {
    const account_expr = try lowerExprPtr(arena, ctx, field_set.record_expr.*);
    const account_ty = exprTy(account_expr.*);
    if (!isAccountTy(account_ty)) return error.UnsupportedNode;
    const field_ty = try recordFieldAccessTy(arena, ctx, account_ty, field_set.field_name);
    return .{ .AccountFieldSet = .{
        .account_expr = account_expr,
        .field_name = try arena.allocator().dupe(u8, field_set.field_name),
        .value = try lowerExprPtrExpected(arena, ctx, field_set.value.*, field_ty),
        .ty = .Unit,
        .layout = layout.unitValue(),
    } };
}

fn lowerLetExpr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, let_expr: ttree.LetExpr) LowerError!ir.LetExpr {
    const owned_name = try arena.allocator().dupe(u8, let_expr.name);

    const previous = ctx.scope.get(owned_name);
    if (let_expr.is_rec) {
        try ctx.scope.put(owned_name, .{
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        });
    }

    var value = try lowerExprPtr(arena, ctx, let_expr.value.*);
    if (let_expr.is_rec) {
        value = try markTailCallsInFunction(arena, value, let_expr.name);
    }
    if (let_expr.is_rec and recBindingEscapes(let_expr.name, let_expr.body.*)) {
        switch (value.*) {
            .Lambda => |lambda_value| {
                var closure_lambda = lambda_value;
                closure_lambda.layout = layout.closure();
                const closure_value = try arena.allocator().create(ir.Expr);
                closure_value.* = .{ .Lambda = closure_lambda };
                value = closure_value;
            },
            else => {},
        }
    }
    try ctx.scope.put(owned_name, .{
        .ty = exprTy(value.*),
        .layout = exprLayout(value.*),
    });
    defer {
        if (previous) |binding| {
            ctx.scope.getPtr(owned_name).?.* = binding;
        } else {
            _ = ctx.scope.remove(owned_name);
        }
    }

    const body = try lowerExprPtr(arena, ctx, let_expr.body.*);
    return .{
        .name = owned_name,
        .value = value,
        .body = body,
        .ty = exprTy(body.*),
        .layout = exprLayout(body.*),
        .is_rec = let_expr.is_rec,
    };
}

fn markTailCallsInFunction(arena: *std.heap.ArenaAllocator, value: *const ir.Expr, function_name: []const u8) LowerError!*const ir.Expr {
    return switch (value.*) {
        .Lambda => |lambda| blk: {
            var marked_lambda = lambda;
            marked_lambda.body = try markTailPosition(arena, lambda.body, function_name);
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .Lambda = marked_lambda };
            break :blk marked;
        },
        else => value,
    };
}

fn markTailPosition(arena: *std.heap.ArenaAllocator, expr: *const ir.Expr, function_name: []const u8) LowerError!*const ir.Expr {
    return switch (expr.*) {
        .App => |app| blk: {
            var marked_app = app;
            marked_app.is_tail_call = isSelfCall(app, function_name);
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .App = marked_app };
            break :blk marked;
        },
        .If => |if_expr| blk: {
            var marked_if = if_expr;
            marked_if.then_branch = try markTailPosition(arena, if_expr.then_branch, function_name);
            marked_if.else_branch = try markTailPosition(arena, if_expr.else_branch, function_name);
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .If = marked_if };
            break :blk marked;
        },
        .Let => |let_expr| blk: {
            var marked_let = let_expr;
            marked_let.body = try markTailPosition(arena, let_expr.body, function_name);
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .Let = marked_let };
            break :blk marked;
        },
        .Match => |match_expr| blk: {
            const arms = try arena.allocator().alloc(ir.Arm, match_expr.arms.len);
            for (match_expr.arms, 0..) |arm, index| {
                arms[index] = .{
                    .pattern = arm.pattern,
                    .guard = arm.guard,
                    .body = try markTailPosition(arena, arm.body, function_name),
                };
            }
            var marked_match = match_expr;
            marked_match.arms = arms;
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .Match = marked_match };
            break :blk marked;
        },
        .Lambda, .Constant, .Prim, .Var, .Ctor, .Tuple, .TupleProj, .Record, .RecordField, .RecordUpdate, .AccountFieldSet => expr,
    };
}

fn isSelfCall(app: ir.App, function_name: []const u8) bool {
    return switch (app.callee.*) {
        .Var => |callee| std.mem.eql(u8, callee.name, function_name),
        else => false,
    };
}

fn lowerApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (isVarNamed(app.callee.*, "List.map")) {
        return lowerListMapLiteralApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "List.filter")) {
        return lowerListFilterLiteralApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "List.fold_left")) {
        return lowerListFoldLeftLiteralApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "Array.of_list")) {
        return lowerArrayOfListApp(arena, ctx, app);
    }
    if (builtinCallOp(app.callee.*, app.args.len)) |op| {
        return lowerBuiltinCallApp(arena, ctx, app, op);
    }
    if (stdlibCallSignature(arena, app.callee.*, app.args.len)) |signature| {
        return lowerStdlibCallApp(arena, ctx, app, signature);
    }
    const callee = try lowerExprPtr(arena, ctx, app.callee.*);
    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (app.args) |arg| {
        try args.append(arena.allocator(), try lowerExprPtr(arena, ctx, arg));
    }
    const owned_args = try args.toOwnedSlice(arena.allocator());
    const ty = try appReturnTy(arena, exprTy(callee.*), owned_args.len);
    return .{ .App = .{
        .callee = callee,
        .args = owned_args,
        .ty = ty,
        .layout = layoutForTy(ty),
    } };
}

fn lowerBuiltinCallApp(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    app: ttree.App,
    op: ir.PrimOp,
) LowerError!ir.Expr {
    const arg_tys = try builtinCallArgTys(arena, op);
    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (app.args, 0..) |arg, index| {
        try args.append(arena.allocator(), try lowerExprPtrExpected(arena, ctx, arg, arg_tys[index]));
    }
    const return_ty = builtinCallReturnTy(op);
    return .{ .Prim = .{
        .op = op,
        .args = try args.toOwnedSlice(arena.allocator()),
        .ty = return_ty,
        .layout = layoutForTy(return_ty),
    } };
}

fn builtinCallOp(callee: ttree.Expr, arg_count: usize) ?ir.PrimOp {
    const var_ref = switch (callee) {
        .Var => |value| value,
        else => return null,
    };
    if (std.mem.eql(u8, var_ref.name, "String.length") and arg_count == 1) return .StringLength;
    if (std.mem.eql(u8, var_ref.name, "String.get") and arg_count == 2) return .StringGet;
    if (std.mem.eql(u8, var_ref.name, "String.sub") and arg_count == 3) return .StringSub;
    if (std.mem.eql(u8, var_ref.name, "^") and arg_count == 2) return .StringConcat;
    if (std.mem.eql(u8, var_ref.name, "Char.code") and arg_count == 1) return .CharCode;
    if (std.mem.eql(u8, var_ref.name, "Char.chr") and arg_count == 1) return .CharChr;
    return null;
}

fn builtinCallArgTys(arena: *std.heap.ArenaAllocator, op: ir.PrimOp) LowerError![]const ir.Ty {
    return switch (op) {
        .StringLength => try tySlice(arena, &.{.String}),
        .StringGet => try tySlice(arena, &.{ .String, .Int }),
        .StringSub => try tySlice(arena, &.{ .String, .Int, .Int }),
        .StringConcat => try tySlice(arena, &.{ .String, .String }),
        .CharCode, .CharChr => try tySlice(arena, &.{.Int}),
        else => return error.UnsupportedPrim,
    };
}

fn builtinCallReturnTy(op: ir.PrimOp) ir.Ty {
    return switch (op) {
        .StringLength, .StringGet, .CharCode, .CharChr => .Int,
        .StringSub, .StringConcat => .String,
        else => unreachable,
    };
}

const StdlibCallSignature = struct {
    name: []const u8,
    arg_tys: []const ir.Ty,
    return_ty: ir.Ty,
};

fn lowerStdlibCallApp(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    app: ttree.App,
    signature: StdlibCallSignature,
) LowerError!ir.Expr {
    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (app.args, 0..) |arg, index| {
        try args.append(arena.allocator(), try lowerExprPtrExpected(arena, ctx, arg, signature.arg_tys[index]));
    }
    const owned_args = try args.toOwnedSlice(arena.allocator());
    const callee_ty = try arrowTy(arena, signature.arg_tys, signature.return_ty);
    const callee = try arena.allocator().create(ir.Expr);
    callee.* = .{ .Var = .{
        .name = try arena.allocator().dupe(u8, signature.name),
        .ty = callee_ty,
        .layout = layout.closure(),
    } };
    return .{ .App = .{
        .callee = callee,
        .args = owned_args,
        .ty = signature.return_ty,
        .layout = layoutForTy(signature.return_ty),
    } };
}

fn lowerArrayOfListApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 1) return error.UnsupportedNode;
    var literal_items = std.ArrayList(ttree.Expr).empty;
    defer literal_items.deinit(arena.allocator());
    const list_arg = lowerListLiteralExpr(arena, ctx, app.args[0], &literal_items) catch try lowerExprPtr(arena, ctx, app.args[0]);
    const list_adt = switch (exprTy(list_arg.*)) {
        .Adt => |adt| adt,
        else => return error.UnsupportedNode,
    };
    if (!std.mem.eql(u8, list_adt.name, "list") or list_adt.params.len != 1) return error.UnsupportedNode;

    const return_ty = try arrayTy(arena, list_adt.params[0]);
    const arg_tys = try tySlice(arena, &.{exprTy(list_arg.*)});
    const callee_ty = try arrowTy(arena, arg_tys, return_ty);
    const callee = try arena.allocator().create(ir.Expr);
    callee.* = .{ .Var = .{
        .name = try arena.allocator().dupe(u8, "Array.of_list"),
        .ty = callee_ty,
        .layout = layout.closure(),
    } };
    const args = try arena.allocator().alloc(*const ir.Expr, 1);
    args[0] = list_arg;
    return .{ .App = .{
        .callee = callee,
        .args = args,
        .ty = return_ty,
        .layout = layoutForTy(return_ty),
    } };
}

fn lowerListLiteralExpr(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    expr: ttree.Expr,
    items: *std.ArrayList(ttree.Expr),
) LowerError!*const ir.Expr {
    try collectListLiteralItems(arena.allocator(), expr, items);
    if (items.items.len == 0) return error.UnsupportedNode;

    const first_item = try lowerExprPtr(arena, ctx, items.items[items.items.len - 1]);
    const list_ty = try listTy(arena, exprTy(first_item.*));
    var current = try arena.allocator().create(ir.Expr);
    current.* = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "[]"),
        .args = &.{},
        .ty = list_ty,
        .layout = layout.ctor(0),
        .tag = builtinCtorTag("[]"),
    } };

    var index = items.items.len;
    while (index > 0) {
        index -= 1;
        const head = if (index == items.items.len - 1)
            first_item
        else
            try lowerExprPtrExpected(arena, ctx, items.items[index], exprTy(first_item.*));
        const args = try arena.allocator().alloc(*const ir.Expr, 2);
        args[0] = head;
        args[1] = current;
        const next = try arena.allocator().create(ir.Expr);
        next.* = .{ .Ctor = .{
            .name = try arena.allocator().dupe(u8, "::"),
            .args = args,
            .ty = list_ty,
            .layout = layout.ctor(2),
            .tag = builtinCtorTag("::"),
        } };
        current = next;
    }
    return current;
}

fn stdlibCallSignature(arena: *std.heap.ArenaAllocator, callee: ttree.Expr, arg_count: usize) ?StdlibCallSignature {
    const var_ref = switch (callee) {
        .Var => |value| value,
        else => return null,
    };
    return makeStdlibCallSignature(arena, var_ref.name, arg_count) catch null;
}

fn makeStdlibCallSignature(arena: *std.heap.ArenaAllocator, name: []const u8, arg_count: usize) LowerError!?StdlibCallSignature {
    const int_list = try listTy(arena, .Int);
    const int_option = try optionTy(arena, .Int);
    const int_result = try resultTy(arena, .Int, .Int);
    const bytes_ty: ir.Ty = .String;
    const clock_ty: ir.Ty = .{ .Record = .{ .name = "clock", .params = &.{} } };
    const account_meta_ty: ir.Ty = .{ .Record = .{ .name = "account_meta", .params = &.{} } };
    const instruction_ty: ir.Ty = .{ .Record = .{ .name = "instruction", .params = &.{} } };
    const account_meta_array_ty = try arrayTy(arena, account_meta_ty);
    const signer_seed_ty = try arrayTy(arena, bytes_ty);
    const signer_seeds_ty = try arrayTy(arena, signer_seed_ty);

    if (std.mem.eql(u8, name, "List.length") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_list}), .return_ty = .Int };
    if (std.mem.eql(u8, name, "List.rev") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_list}), .return_ty = int_list };
    if (std.mem.eql(u8, name, "List.append") and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ int_list, int_list }), .return_ty = int_list };
    if (std.mem.eql(u8, name, "List.hd") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_list}), .return_ty = .Int };
    if (std.mem.eql(u8, name, "List.tl") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_list}), .return_ty = int_list };

    if (std.mem.eql(u8, name, "Option.is_none") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_option}), .return_ty = .Bool };
    if (std.mem.eql(u8, name, "Option.is_some") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_option}), .return_ty = .Bool };
    if (std.mem.eql(u8, name, "Option.value") and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ int_option, .Int }), .return_ty = .Int };
    if (std.mem.eql(u8, name, "Option.get") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_option}), .return_ty = .Int };

    if (std.mem.eql(u8, name, "Result.is_ok") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_result}), .return_ty = .Bool };
    if (std.mem.eql(u8, name, "Result.is_error") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_result}), .return_ty = .Bool };
    if (std.mem.eql(u8, name, "Result.ok") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_result}), .return_ty = int_option };
    if (std.mem.eql(u8, name, "Result.error") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_result}), .return_ty = int_option };

    if (std.mem.eql(u8, name, "Syscall.sol_log") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.String}), .return_ty = .Unit };
    if (std.mem.eql(u8, name, "Syscall.sol_log_64") and arg_count == 5)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ .Int, .Int, .Int, .Int, .Int }), .return_ty = .Unit };
    if (std.mem.eql(u8, name, "Syscall.sol_log_pubkey") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = .Unit };
    if (std.mem.eql(u8, name, "Syscall.sol_sha256") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Syscall.sol_keccak256") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Crypto.sha256") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Crypto.keccak256") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Syscall.sol_get_clock_sysvar") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = clock_ty };
    if (std.mem.eql(u8, name, "Syscall.sol_remaining_compute_units") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = .Int };
    if ((std.mem.eql(u8, name, "set_return_data") or std.mem.eql(u8, name, "Cpi.set_return_data") or std.mem.eql(u8, name, "Syscall.sol_set_return_data")) and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = .Unit };
    if ((std.mem.eql(u8, name, "get_return_data") or std.mem.eql(u8, name, "Cpi.get_return_data") or std.mem.eql(u8, name, "Syscall.sol_get_return_data")) and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Bytes.of_string") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.String}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "invoke") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{instruction_ty}), .return_ty = .Int };
    if (std.mem.eql(u8, name, "invoke_signed") and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ instruction_ty, signer_seeds_ty }), .return_ty = .Int };
    if (std.mem.eql(u8, name, "create_program_address") and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ signer_seed_ty, bytes_ty }), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "SplToken.program_id") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "SplToken.transfer_data") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Int}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "SplToken.transfer_account_metas") and arg_count == 3)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ bytes_ty, bytes_ty, bytes_ty }), .return_ty = account_meta_array_ty };
    if (std.mem.eql(u8, name, "SplToken.transfer_instruction") and arg_count == 4)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ bytes_ty, bytes_ty, bytes_ty, .Int }), .return_ty = instruction_ty };

    return null;
}

fn lowerListMapLiteralApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 2) return error.UnsupportedNode;
    const lambda = switch (app.args[0]) {
        .Lambda => |value| value,
        else => return error.UnsupportedNode,
    };
    if (lambda.params.len != 1) return error.UnsupportedNode;

    var items = std.ArrayList(ttree.Expr).empty;
    errdefer items.deinit(arena.allocator());
    try collectListLiteralItems(arena.allocator(), app.args[1], &items);

    const list_ty = try listTy(arena, .Int);
    var current = try arena.allocator().create(ir.Expr);
    current.* = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "[]"),
        .args = &.{},
        .ty = list_ty,
        .layout = layout.ctor(0),
        .tag = builtinCtorTag("[]"),
    } };

    var index = items.items.len;
    while (index > 0) {
        index -= 1;
        const elem = try lowerExprPtrExpected(arena, ctx, items.items[index], .Int);
        const source_param_name = try arena.allocator().dupe(u8, lambda.params[0]);
        const lowered_param_name = try freshSyntheticName(arena, ctx, source_param_name);
        const previous = ctx.scope.get(source_param_name);
        try ctx.scope.put(source_param_name, .{ .ty = .Int, .layout = layout.intConstant() });
        const mapped_body_raw = try lowerExprPtrExpected(arena, ctx, lambda.body.*, .Int);
        if (previous) |binding| {
            ctx.scope.getPtr(source_param_name).?.* = binding;
        } else {
            _ = ctx.scope.remove(source_param_name);
        }
        const mapped_body = try renameExprVars(arena, mapped_body_raw, &.{
            .{ .from = source_param_name, .to = lowered_param_name },
        });

        const mapped = try arena.allocator().create(ir.Expr);
        mapped.* = .{ .Let = .{
            .name = lowered_param_name,
            .value = elem,
            .body = mapped_body,
            .ty = exprTy(mapped_body.*),
            .layout = exprLayout(mapped_body.*),
        } };

        const args = try arena.allocator().alloc(*const ir.Expr, 2);
        args[0] = mapped;
        args[1] = current;
        const next = try arena.allocator().create(ir.Expr);
        next.* = .{ .Ctor = .{
            .name = try arena.allocator().dupe(u8, "::"),
            .args = args,
            .ty = list_ty,
            .layout = layout.ctor(2),
            .tag = builtinCtorTag("::"),
        } };
        current = next;
    }

    return current.*;
}

fn lowerListFilterLiteralApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 2) return error.UnsupportedNode;
    const lambda = switch (app.args[0]) {
        .Lambda => |value| value,
        else => return error.UnsupportedNode,
    };
    if (lambda.params.len != 1) return error.UnsupportedNode;

    var items = std.ArrayList(ttree.Expr).empty;
    errdefer items.deinit(arena.allocator());
    try collectListLiteralItems(arena.allocator(), app.args[1], &items);

    const list_ty = try listTy(arena, .Int);
    var current = try arena.allocator().create(ir.Expr);
    current.* = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "[]"),
        .args = &.{},
        .ty = list_ty,
        .layout = layout.ctor(0),
        .tag = builtinCtorTag("[]"),
    } };

    var index = items.items.len;
    while (index > 0) {
        index -= 1;
        const elem = try lowerExprPtrExpected(arena, ctx, items.items[index], .Int);
        const source_param_name = try arena.allocator().dupe(u8, lambda.params[0]);
        const lowered_param_name = try freshSyntheticName(arena, ctx, source_param_name);
        const previous = ctx.scope.get(source_param_name);
        try ctx.scope.put(source_param_name, .{ .ty = .Int, .layout = layout.intConstant() });
        const predicate_body_raw = try lowerExprPtrExpected(arena, ctx, lambda.body.*, .Bool);
        if (previous) |binding| {
            ctx.scope.getPtr(source_param_name).?.* = binding;
        } else {
            _ = ctx.scope.remove(source_param_name);
        }
        const predicate_body = try renameExprVars(arena, predicate_body_raw, &.{
            .{ .from = source_param_name, .to = lowered_param_name },
        });

        const item_var = try arena.allocator().create(ir.Expr);
        item_var.* = .{ .Var = .{
            .name = lowered_param_name,
            .ty = .Int,
            .layout = layout.intConstant(),
        } };

        const kept_args = try arena.allocator().alloc(*const ir.Expr, 2);
        kept_args[0] = item_var;
        kept_args[1] = current;
        const kept = try arena.allocator().create(ir.Expr);
        kept.* = .{ .Ctor = .{
            .name = try arena.allocator().dupe(u8, "::"),
            .args = kept_args,
            .ty = list_ty,
            .layout = layout.ctor(2),
            .tag = builtinCtorTag("::"),
        } };

        const filtered = try arena.allocator().create(ir.Expr);
        filtered.* = .{ .If = .{
            .cond = predicate_body,
            .then_branch = kept,
            .else_branch = current,
            .ty = list_ty,
            .layout = layoutForTy(list_ty),
        } };

        const next = try arena.allocator().create(ir.Expr);
        next.* = .{ .Let = .{
            .name = lowered_param_name,
            .value = elem,
            .body = filtered,
            .ty = list_ty,
            .layout = layoutForTy(list_ty),
        } };
        current = next;
    }

    return current.*;
}

fn lowerListFoldLeftLiteralApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 3) return error.UnsupportedNode;
    const lambda = switch (app.args[0]) {
        .Lambda => |value| value,
        else => return error.UnsupportedNode,
    };
    if (lambda.params.len != 2) return error.UnsupportedNode;

    var items = std.ArrayList(ttree.Expr).empty;
    errdefer items.deinit(arena.allocator());
    try collectListLiteralItems(arena.allocator(), app.args[2], &items);

    var current = try lowerExprPtrExpected(arena, ctx, app.args[1], .Int);
    for (items.items) |item| {
        const elem = try lowerExprPtrExpected(arena, ctx, item, .Int);
        const source_acc_name = try arena.allocator().dupe(u8, lambda.params[0]);
        const source_item_name = try arena.allocator().dupe(u8, lambda.params[1]);
        const lowered_acc_name = try freshSyntheticName(arena, ctx, source_acc_name);
        const lowered_item_name = try freshSyntheticName(arena, ctx, source_item_name);

        const previous_acc = ctx.scope.get(source_acc_name);
        try ctx.scope.put(source_acc_name, .{ .ty = .Int, .layout = layout.intConstant() });
        const previous_item = ctx.scope.get(source_item_name);
        try ctx.scope.put(source_item_name, .{ .ty = .Int, .layout = layout.intConstant() });

        const folded_body_raw = try lowerExprPtrExpected(arena, ctx, lambda.body.*, .Int);
        const folded_body = try renameExprVars(arena, folded_body_raw, &.{
            .{ .from = source_acc_name, .to = lowered_acc_name },
            .{ .from = source_item_name, .to = lowered_item_name },
        });

        if (previous_item) |binding| {
            ctx.scope.getPtr(source_item_name).?.* = binding;
        } else {
            _ = ctx.scope.remove(source_item_name);
        }
        if (previous_acc) |binding| {
            ctx.scope.getPtr(source_acc_name).?.* = binding;
        } else {
            _ = ctx.scope.remove(source_acc_name);
        }

        const item_let = try arena.allocator().create(ir.Expr);
        item_let.* = .{ .Let = .{
            .name = lowered_item_name,
            .value = elem,
            .body = folded_body,
            .ty = exprTy(folded_body.*),
            .layout = exprLayout(folded_body.*),
        } };

        const acc_let = try arena.allocator().create(ir.Expr);
        acc_let.* = .{ .Let = .{
            .name = lowered_acc_name,
            .value = current,
            .body = item_let,
            .ty = exprTy(item_let.*),
            .layout = exprLayout(item_let.*),
        } };
        current = acc_let;
    }

    return current.*;
}

fn collectListLiteralItems(allocator: std.mem.Allocator, expr: ttree.Expr, items: *std.ArrayList(ttree.Expr)) LowerError!void {
    const ctor = switch (expr) {
        .Ctor => |value| value,
        else => return error.UnsupportedNode,
    };
    if (std.mem.eql(u8, ctor.name, "[]")) {
        if (ctor.args.len != 0) return error.UnsupportedNode;
        return;
    }
    if (!std.mem.eql(u8, ctor.name, "::") or ctor.args.len != 2) return error.UnsupportedNode;
    try items.append(allocator, ctor.args[0]);
    try collectListLiteralItems(allocator, ctor.args[1], items);
}

fn isVarNamed(expr: ttree.Expr, name: []const u8) bool {
    return switch (expr) {
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        else => false,
    };
}

const RenameBinding = struct {
    from: []const u8,
    to: []const u8,
};

fn freshSyntheticName(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, base: []const u8) LowerError![]const u8 {
    const id = ctx.next_temp;
    ctx.next_temp += 1;
    return std.fmt.allocPrint(arena.allocator(), "{s}__omlz_{d}", .{ base, id });
}

fn renamedName(name: []const u8, renames: []const RenameBinding) []const u8 {
    for (renames) |rename| {
        if (std.mem.eql(u8, name, rename.from)) return rename.to;
    }
    return name;
}

fn renameExprVars(arena: *std.heap.ArenaAllocator, expr: *const ir.Expr, renames: []const RenameBinding) LowerError!*const ir.Expr {
    const renamed = try arena.allocator().create(ir.Expr);
    renamed.* = try renameExprValueVars(arena, expr.*, renames);
    return renamed;
}

fn renameExprValueVars(arena: *std.heap.ArenaAllocator, expr: ir.Expr, renames: []const RenameBinding) LowerError!ir.Expr {
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

fn renameExprSliceVars(
    arena: *std.heap.ArenaAllocator,
    exprs: []const *const ir.Expr,
    renames: []const RenameBinding,
) LowerError![]const *const ir.Expr {
    const out = try arena.allocator().alloc(*const ir.Expr, exprs.len);
    for (exprs, 0..) |expr, index| out[index] = try renameExprVars(arena, expr, renames);
    return out;
}

fn filterRenamesForName(
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

fn filterRenamesForParams(
    arena: *std.heap.ArenaAllocator,
    renames: []const RenameBinding,
    params: []const ir.Param,
) LowerError![]const RenameBinding {
    var current = renames;
    for (params) |param| current = try filterRenamesForName(arena, current, param.name);
    return current;
}

fn filterRenamesForPattern(
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

fn renameArmsVars(
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

fn renameRecordExprFieldsVars(
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

fn appReturnTy(arena: *std.heap.ArenaAllocator, callee_ty: ir.Ty, arg_count: usize) LowerError!ir.Ty {
    const arrow = switch (callee_ty) {
        .Arrow => |value| value,
        else => return .Int,
    };
    if (arg_count >= arrow.params.len) return arrow.ret.*;
    const remaining = arrow.params[arg_count..];
    return makeArrowTyFromPieces(arena, remaining, arrow.ret.*);
}

fn lowerIf(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, if_expr: ttree.IfExpr) LowerError!ir.Expr {
    const cond = try lowerExprPtrExpected(arena, ctx, if_expr.cond.*, .Bool);
    const then_branch = try lowerExprPtr(arena, ctx, if_expr.then_branch.*);
    const else_branch = try lowerExprPtr(arena, ctx, if_expr.else_branch.*);
    return .{ .If = .{
        .cond = cond,
        .then_branch = then_branch,
        .else_branch = else_branch,
        .ty = exprTy(then_branch.*),
        .layout = exprLayout(then_branch.*),
    } };
}

fn lowerPrim(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, prim: ttree.Prim) LowerError!ir.Expr {
    const op = try lowerPrimOp(prim.op);
    if (prim.args.len != primOpArity(op)) return error.UnsupportedPrimArity;
    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (prim.args) |arg| {
        try args.append(arena.allocator(), try lowerExprPtr(arena, ctx, arg));
    }
    const ty = primOpReturnTy(op);
    return .{ .Prim = .{
        .op = op,
        .args = try args.toOwnedSlice(arena.allocator()),
        .ty = ty,
        .layout = layout.intConstant(),
    } };
}

fn lowerPrimOp(op: []const u8) LowerError!ir.PrimOp {
    if (std.mem.eql(u8, op, "+")) return .Add;
    if (std.mem.eql(u8, op, "-")) return .Sub;
    if (std.mem.eql(u8, op, "*")) return .Mul;
    if (std.mem.eql(u8, op, "/")) return .Div;
    if (std.mem.eql(u8, op, "mod")) return .Mod;
    if (std.mem.eql(u8, op, "=")) return .Eq;
    if (std.mem.eql(u8, op, "<>")) return .Ne;
    if (std.mem.eql(u8, op, "<")) return .Lt;
    if (std.mem.eql(u8, op, "<=")) return .Le;
    if (std.mem.eql(u8, op, ">")) return .Gt;
    if (std.mem.eql(u8, op, ">=")) return .Ge;
    return error.UnsupportedPrim;
}

fn primOpArity(op: ir.PrimOp) usize {
    return switch (op) {
        .StringLength, .CharCode, .CharChr => 1,
        .Add, .Sub, .Mul, .Div, .Mod, .Eq, .Ne, .Lt, .Le, .Gt, .Ge, .StringGet, .StringConcat => 2,
        .StringSub => 3,
    };
}

fn primOpReturnTy(op: ir.PrimOp) ir.Ty {
    return switch (op) {
        .Add, .Sub, .Mul, .Div, .Mod, .StringLength, .StringGet, .CharCode, .CharChr => .Int,
        .Eq, .Ne, .Lt, .Le, .Gt, .Ge => .Bool,
        .StringSub, .StringConcat => .String,
    };
}

fn lowerVar(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, var_ref: ttree.Var) LowerError!ir.Var {
    const binding = ctx.scope.get(var_ref.name) orelse return error.UnboundVariable;
    return .{
        .name = try arena.allocator().dupe(u8, var_ref.name),
        .ty = binding.ty,
        .layout = binding.layout,
    };
}

fn lowerVarExpr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, var_ref: ttree.Var, expected_ty: ?ir.Ty) LowerError!ir.Expr {
    if (ctx.scope.contains(var_ref.name)) {
        var lowered = try lowerVar(arena, ctx, var_ref);
        if (expected_ty) |ty| {
            lowered.ty = ty;
            lowered.layout = layoutForTy(ty);
        }
        return .{ .Var = lowered };
    }
    if (std.mem.eql(u8, var_ref.name, "max_int")) {
        return .{ .Constant = .{
            .value = .{ .Int = std.math.maxInt(i64) },
            .ty = .Int,
            .layout = layout.intConstant(),
        } };
    }
    if (std.mem.eql(u8, var_ref.name, "min_int")) {
        return .{ .Constant = .{
            .value = .{ .Int = std.math.minInt(i64) },
            .ty = .Int,
            .layout = layout.intConstant(),
        } };
    }
    return error.UnboundVariable;
}

fn lowerConstant(arena: *std.heap.ArenaAllocator, constant: ttree.Constant) LowerError!ir.Constant {
    return switch (constant) {
        .Int => |value| .{
            .value = .{ .Int = value },
            .ty = .Int,
            .layout = layout.intConstant(),
        },
        .String => |value| .{
            .value = .{ .String = try arena.allocator().dupe(u8, value) },
            .ty = .String,
            .layout = layout.defaultFor(.StringLiteral),
        },
    };
}

fn lowerCtor(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, ctor_expr: ttree.Ctor, expected_ty: ?ir.Ty) LowerError!ir.Expr {
    const ctor_info = try validateCtor(ctx, ctor_expr.name, ctor_expr.args.len);
    var expected_payload_tys: ?[]const ir.Ty = null;
    if (ctor_info) |info| {
        if (expected_ty) |ty| {
            var bindings = TypeBindings.init(arena.allocator());
            defer bindings.deinit();
            bindTypeParamsFromMatchedAdt(&bindings, info, ty) catch {};
            if (bindings.count() > 0 or info.type_params.len == 0) {
                expected_payload_tys = try typeExprsToTysWithBindings(arena, ctx.record_type_decls, info.payload_types, &bindings);
            }
        }
    }

    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    var wrappers = std.ArrayList(struct {
        name: []const u8,
        value: *const ir.Expr,
    }).empty;
    errdefer wrappers.deinit(arena.allocator());

    for (ctor_expr.args, 0..) |arg, index| {
        const expected_arg_ty: ?ir.Ty = if (expected_payload_tys) |payload_tys| payload_tys[index] else null;
        if (isAtomicTtree(arg)) {
            try args.append(arena.allocator(), try lowerExprPtrExpected(arena, ctx, arg, expected_arg_ty));
        } else {
            const value = try lowerExprPtrExpected(arena, ctx, arg, expected_arg_ty);
            const temp_name = try freshTemp(arena, ctx);
            const var_ptr = try arena.allocator().create(ir.Expr);
            var_ptr.* = .{ .Var = .{
                .name = temp_name,
                .ty = exprTy(value.*),
                .layout = exprLayout(value.*),
            } };
            try wrappers.append(arena.allocator(), .{ .name = temp_name, .value = value });
            try args.append(arena.allocator(), var_ptr);
        }
    }

    const owned_args = try args.toOwnedSlice(arena.allocator());
    const ctor_ty = try ctorTy(arena, ctx, ctor_expr.name, owned_args, expected_ty);
    const ctor_layout = layout.ctor(owned_args.len);
    var current = try arena.allocator().create(ir.Expr);
    current.* = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, ctor_expr.name),
        .args = owned_args,
        .ty = ctor_ty,
        .layout = ctor_layout,
        .tag = if (ctor_info) |info| info.tag else builtinCtorTag(ctor_expr.name),
        .type_name = if (ctor_info) |info| try arena.allocator().dupe(u8, info.type_name) else null,
    } };

    var index = wrappers.items.len;
    while (index > 0) {
        index -= 1;
        const wrapper = wrappers.items[index];
        const body = current;
        current = try arena.allocator().create(ir.Expr);
        current.* = .{ .Let = .{
            .name = wrapper.name,
            .value = wrapper.value,
            .body = body,
            .ty = ctor_ty,
            .layout = ctor_layout,
        } };
    }

    return current.*;
}

fn lowerMatch(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, match_expr: ttree.Match) LowerError!ir.Expr {
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

fn lowerMatchWithScrutinee(
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

fn lowerAndAppendMatchArm(
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

fn inferMatchScrutineeExpectedTy(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, match_expr: ttree.Match) LowerError!?ir.Ty {
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

fn inferConstantPatternTy(arms: []const ttree.Arm) ?ir.Ty {
    for (arms) |arm| {
        if (inferConstantPatternTyFromPattern(arm.pattern)) |ty| return ty;
    }
    return null;
}

fn inferConstantPatternTyFromPattern(pattern: ttree.Pattern) ?ir.Ty {
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

fn inferCtorCandidateFromPattern(
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

fn inferMatchResultTy(arena: *std.heap.ArenaAllocator, pattern_var_tys: *TypeBindings, arms: []const ttree.Arm) LowerError!?ir.Ty {
    for (arms) |arm| {
        if (try inferSimpleExprTy(arena, pattern_var_tys, arm.body.*)) |ty| return ty;
    }
    return null;
}

fn inferSimpleExprTy(arena: *std.heap.ArenaAllocator, pattern_var_tys: *TypeBindings, expr: ttree.Expr) LowerError!?ir.Ty {
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

fn inferExprVarExpectations(arena: *std.heap.ArenaAllocator, pattern_var_tys: *TypeBindings, expr: ttree.Expr, expected_ty: ?ir.Ty) LowerError!void {
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

fn bindTypeParamsFromPatternPayloads(
    bindings: *TypeBindings,
    expected_payloads: []const types.TypeExpr,
    patterns: []const ttree.Pattern,
    pattern_var_tys: *TypeBindings,
) LowerError!void {
    for (expected_payloads, patterns) |expected, pattern| {
        try bindTypeParamsFromPattern(bindings, expected, pattern, pattern_var_tys);
    }
}

fn bindTypeParamsFromPattern(
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

fn lowerPattern(
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

fn lowerPatternConstant(arena: *std.heap.ArenaAllocator, constant: ttree.PatternConstant, matched_ty: ir.Ty) LowerError!ir.PatternConstant {
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

fn lowerCtorPattern(
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

fn validateCtor(ctx: *LowerContext, name: []const u8, arg_count: usize) LowerError!?ConstructorInfo {
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

fn builtinCtorTag(name: []const u8) u32 {
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

fn isAtomicTtree(expr: ttree.Expr) bool {
    return switch (expr) {
        .Constant, .Var => true,
        else => false,
    };
}

fn isAtomicCore(expr: ir.Expr) bool {
    return switch (expr) {
        .Constant, .Var => true,
        else => false,
    };
}

fn freshTemp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext) LowerError![]const u8 {
    const name = try std.fmt.allocPrint(arena.allocator(), "__omlz_ctor_arg_{d}", .{ctx.next_temp});
    ctx.next_temp += 1;
    return name;
}

fn freshMatchTemp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext) LowerError![]const u8 {
    const name = try std.fmt.allocPrint(arena.allocator(), "__omlz_match_scrutinee_{d}", .{ctx.next_temp});
    ctx.next_temp += 1;
    return name;
}

fn bindPatternName(
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

fn restoreBindings(ctx: *LowerContext, inserted: []const ScopedBinding) void {
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

fn ctorPatternPayloadTys(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, name: []const u8, matched_ty: ir.Ty) LowerError![]const ir.Ty {
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

fn ctorTy(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, name: []const u8, args: []const *const ir.Expr, expected_ty: ?ir.Ty) LowerError!ir.Ty {
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

fn inferConstructorTypeParams(arena: *std.heap.ArenaAllocator, info: ConstructorInfo, args: []const *const ir.Expr, expected_ty: ?ir.Ty) LowerError![]const ir.Ty {
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

fn bindTypeParamsFromMatchedAdt(bindings: *TypeBindings, info: ConstructorInfo, matched_ty: ir.Ty) LowerError!void {
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

fn bindTypeParamsFromPayload(
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

fn typeExprsToTys(arena: *std.heap.ArenaAllocator, exprs: []const types.TypeExpr) LowerError![]const ir.Ty {
    return typeExprsToTysWithBindings(arena, &.{}, exprs, null);
}

fn typeExprsToTysWithBindings(
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

fn typeExprToTy(arena: *std.heap.ArenaAllocator, expr: types.TypeExpr) LowerError!ir.Ty {
    return typeExprToTyWithBindings(arena, &.{}, expr, null);
}

fn externalTypeExprToTy(
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

fn externalTypeRefToTy(
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

fn typeExprToTyWithBindings(
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

fn typeRefToTy(arena: *std.heap.ArenaAllocator, ref: types.TypeRef) LowerError!ir.Ty {
    return typeRefToTyWithBindings(arena, &.{}, ref, null);
}

fn typeRefToTyWithBindings(
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

fn listTy(arena: *std.heap.ArenaAllocator, elem_ty: ir.Ty) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, 1);
    params[0] = elem_ty;
    return .{ .Adt = .{
        .name = "list",
        .params = params,
    } };
}

fn arrayTy(arena: *std.heap.ArenaAllocator, elem_ty: ir.Ty) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, 1);
    params[0] = elem_ty;
    return .{ .Adt = .{
        .name = "array",
        .params = params,
    } };
}

fn optionTy(arena: *std.heap.ArenaAllocator, elem_ty: ir.Ty) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, 1);
    params[0] = elem_ty;
    return .{ .Adt = .{
        .name = "option",
        .params = params,
    } };
}

fn resultTy(arena: *std.heap.ArenaAllocator, ok_ty: ir.Ty, err_ty: ir.Ty) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, 2);
    params[0] = ok_ty;
    params[1] = err_ty;
    return .{ .Adt = .{
        .name = "result",
        .params = params,
    } };
}

fn accountTy(arena: *std.heap.ArenaAllocator) LowerError!ir.Ty {
    return .{ .Record = .{
        .name = try arena.allocator().dupe(u8, "account"),
        .params = &.{},
    } };
}

fn tySlice(arena: *std.heap.ArenaAllocator, tys: []const ir.Ty) LowerError![]const ir.Ty {
    const out = try arena.allocator().alloc(ir.Ty, tys.len);
    for (tys, 0..) |ty, index| out[index] = ty;
    return out;
}

fn arrowTy(arena: *std.heap.ArenaAllocator, params: []const ir.Ty, ret: ir.Ty) LowerError!ir.Ty {
    const owned_ret = try arena.allocator().create(ir.Ty);
    owned_ret.* = ret;
    return .{ .Arrow = .{
        .params = try tySlice(arena, params),
        .ret = owned_ret,
    } };
}

fn recordTy(arena: *std.heap.ArenaAllocator, decl: types.RecordType) LowerError!ir.Ty {
    return recordTyWithBindings(arena, decl, null);
}

fn recordTyWithBindings(arena: *std.heap.ArenaAllocator, decl: types.RecordType, bindings: ?*TypeBindings) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, decl.params.len);
    for (decl.params, 0..) |param_name, index| {
        params[index] = if (bindings) |values| values.get(param_name) orelse .{ .Var = param_name } else .{ .Var = param_name };
    }
    return .{ .Record = .{
        .name = decl.name,
        .params = params,
    } };
}

fn findRecordDecl(decls: []const types.RecordType, name: []const u8) ?types.RecordType {
    for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return decl;
    }
    return null;
}

fn findRecordDeclForFields(decls: []const types.RecordType, fields: []const ttree.RecordExprField) ?types.RecordType {
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

fn findRecordExprField(fields: []const ir.RecordExprField, field_name: []const u8) ?ir.RecordExprField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) return field;
    }
    return null;
}

fn recordFieldTy(arena: *std.heap.ArenaAllocator, decl: types.RecordType, field_name: []const u8) LowerError!ir.Ty {
    for (decl.fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) return typeExprToTy(arena, field.ty);
    }
    return error.UnsupportedNode;
}

fn recordFieldTyWithBindings(
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

fn recordFieldTyForRecord(
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

fn recordFieldAccessTy(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, ty: ir.Ty, field_name: []const u8) LowerError!ir.Ty {
    const record = switch (ty) {
        .Record => |value| value,
        else => return error.UnsupportedNode,
    };
    const decl = findRecordDecl(ctx.record_type_decls, record.name) orelse return error.UnsupportedNode;
    return recordFieldTyForRecord(arena, ctx, decl, ty, field_name);
}

fn isAccountTy(ty: ir.Ty) bool {
    const record = switch (ty) {
        .Record => |value| value,
        else => return false,
    };
    return std.mem.eql(u8, record.name, "account") and record.params.len == 0;
}

fn layoutForTy(ty: ir.Ty) layout.Layout {
    return switch (ty) {
        .Int, .Bool, .Var => layout.intConstant(),
        .Unit => layout.unitValue(),
        .String => layout.defaultFor(.StringLiteral),
        .Adt => layout.ctor(1),
        .Tuple, .Record => layout.structPack(),
        .Arrow => layout.closure(),
    };
}

fn recBindingEscapes(name: []const u8, expr: ttree.Expr) bool {
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

fn lambdaParamShadows(params: []const []const u8, name: []const u8) bool {
    for (params) |param| {
        if (std.mem.eql(u8, param, name)) return true;
    }
    return false;
}

fn patternBindsTtreeName(pattern: ttree.Pattern, name: []const u8) bool {
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

fn lambdaParamIsFunction(expr: ttree.Expr, param_name: []const u8) bool {
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

fn lambdaParamIsAccount(expr: ttree.Expr, param_name: []const u8) bool {
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

fn exprIsVarNamed(expr: ttree.Expr, name: []const u8) bool {
    return switch (expr) {
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        else => false,
    };
}

fn isAccountFieldName(field_name: []const u8) bool {
    return std.mem.eql(u8, field_name, "key") or
        std.mem.eql(u8, field_name, "lamports") or
        std.mem.eql(u8, field_name, "data") or
        std.mem.eql(u8, field_name, "owner") or
        std.mem.eql(u8, field_name, "is_signer") or
        std.mem.eql(u8, field_name, "is_writable") or
        std.mem.eql(u8, field_name, "executable");
}

fn isInstructionDataParamName(param_name: []const u8) bool {
    return std.mem.eql(u8, param_name, "input") or
        std.mem.eql(u8, param_name, "instruction_data");
}

fn lambdaParamIsList(arena: *std.heap.ArenaAllocator, expr: ttree.Expr, param_name: []const u8) LowerError!bool {
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

fn patternIsListCtor(pattern: ttree.Pattern) bool {
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

fn makeArrowTy(
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

fn makeArrowTyFromPieces(
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

fn intToIntArrowTy(arena: *std.heap.ArenaAllocator) LowerError!ir.Ty {
    const param_tys = try arena.allocator().alloc(ir.Ty, 1);
    param_tys[0] = .Int;
    const ret = try arena.allocator().create(ir.Ty);
    ret.* = .Int;
    return .{ .Arrow = .{
        .params = param_tys,
        .ret = ret,
    } };
}

fn exprTy(expr: ir.Expr) ir.Ty {
    return switch (expr) {
        .Lambda => |lambda| lambda.ty,
        .Constant => |constant| constant.ty,
        .App => |app| app.ty,
        .Let => |let_expr| let_expr.ty,
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

fn tyEql(lhs: ir.Ty, rhs: ir.Ty) bool {
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

fn exprLayout(expr: ir.Expr) layout.Layout {
    return switch (expr) {
        .Lambda => |lambda| lambda.layout,
        .Constant => |constant| constant.layout,
        .App => |app| app.layout,
        .Let => |let_expr| let_expr.layout,
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

test "lower M0 constant module through ANF to Core IR" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let entrypoint (lambda (_input) (const-int 0)))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);

    const let_decl = switch (module.decls[0]) {
        .Let => |value| value,
    };
    try std.testing.expectEqualStrings("entrypoint", let_decl.name);
    const lambda = switch (let_decl.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(layout.Layout{ .region = .Arena, .repr = .Flat }, lambda.layout);
    try std.testing.expectEqual(@as(usize, 1), lambda.params.len);
    try std.testing.expectEqualStrings("_input", lambda.params[0].name);

    const constant = switch (lambda.body.*) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (constant.value) {
        .Int => |value| try std.testing.expectEqual(@as(i64, 0), value),
        .String => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(layout.Layout{ .region = .Static, .repr = .Flat }, constant.layout);

    const printed = try pretty.formatModule(std.testing.allocator, module);
    defer std.testing.allocator.free(printed);
    try std.testing.expectEqualStrings(
        "(module (let entrypoint (lambda (_input :ty (arrow unit int) :layout (arena flat)) (const 0 :ty int :layout (static flat)))))",
        printed,
    );
}

test "lower top-level and nested lets with lexical var references" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let x (const-int 1)) (let entrypoint (lambda (_input) (let y (const-int 7) (var x))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    try std.testing.expectEqual(@as(usize, 2), module.decls.len);

    const top_level = switch (module.decls[0]) {
        .Let => |value| value,
    };
    try std.testing.expectEqualStrings("x", top_level.name);
    try std.testing.expectEqual(ir.Ty.Int, top_level.ty);
    try std.testing.expectEqual(layout.intConstant(), top_level.layout);

    const entrypoint = switch (module.decls[1]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const nested = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("y", nested.name);
    const var_ref = switch (nested.body.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("x", var_ref.name);
    try std.testing.expectEqual(layout.intConstant(), var_ref.layout);
}

test "lower max_int and min_int as pinned i64 constants" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let entrypoint (lambda (_) (let _ (prim \"+\" (var max_int) (const-int 1)) (prim \"-\" (var min_int) (const-int 1)))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const first_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const add = switch (first_let.value.*) {
        .Prim => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const max_const = switch (add.args[0].*) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), max_const.value.Int);

    const sub = switch (first_let.body.*) {
        .Prim => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const min_const = switch (sub.args[0].*) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), min_const.value.Int);
}

test "marks only self calls in tail position" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let-rec loop (lambda (n acc) (if (prim \"=\" (var n) (const-int 0)) (var acc) (app (var loop) (prim \"-\" (var n) (const-int 1)) (prim \"+\" (var acc) (var n)))))) (let-rec sum (lambda (n) (prim \"+\" (var n) (app (var sum) (prim \"-\" (var n) (const-int 1))))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const loop_decl = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const loop_lambda = switch (loop_decl.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const loop_if = switch (loop_lambda.body.*) {
        .If => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const tail_app = switch (loop_if.else_branch.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(tail_app.is_tail_call);

    const sum_decl = switch (module.decls[1]) {
        .Let => |value| value,
    };
    const sum_lambda = switch (sum_decl.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const non_tail_prim = switch (sum_lambda.body.*) {
        .Prim => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const non_tail_app = switch (non_tail_prim.args[1].*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!non_tail_app.is_tail_call);
}

test "lower Syscall module calls as typed builtin applications" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.8 (module (let entrypoint (lambda (message) (let _ (app (var Syscall.sol_log) (var message)) (app (var Syscall.sol_remaining_compute_units) (ctor \"()\")))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const log_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const log_app = switch (log_let.value.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const log_callee = switch (log_app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Syscall.sol_log", log_callee.name);
    try std.testing.expectEqual(ir.Ty.Unit, log_app.ty);
    try std.testing.expectEqual(ir.Ty.String, exprTy(log_app.args[0].*));

    const remaining_app = switch (log_let.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const remaining_callee = switch (remaining_app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Syscall.sol_remaining_compute_units", remaining_callee.name);
    try std.testing.expectEqual(ir.Ty.Int, remaining_app.ty);
}

test "lower external declarations into callable Core bindings" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 1.0 (module (external (name \"sol_log\") (type (arrow string unit)) (symbol \"sol_log_\")) (let entrypoint (lambda (_input) (app (var sol_log) (const-string \"hi\"))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    try std.testing.expectEqual(@as(usize, 1), module.externals.len);
    try std.testing.expectEqualStrings("sol_log", module.externals[0].name);
    try std.testing.expectEqualStrings("sol_log_", module.externals[0].symbol);

    const external_ty = switch (module.externals[0].ty) {
        .Arrow => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), external_ty.params.len);
    try std.testing.expectEqual(ir.Ty.String, external_ty.params[0]);
    try std.testing.expectEqual(ir.Ty.Unit, external_ty.ret.*);

    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const app = switch (lambda.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const callee = switch (app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("sol_log", callee.name);
    try std.testing.expectEqual(ir.Ty.Unit, app.ty);
}

test "lower CPI return-data calls as typed builtin applications" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.8 (module (let entrypoint (lambda (_input) (let _ (app (var Cpi.set_return_data) (const-string \"ok\")) (app (var Cpi.get_return_data) (ctor \"()\")))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const set_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const set_app = switch (set_let.value.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const set_callee = switch (set_app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Cpi.set_return_data", set_callee.name);
    try std.testing.expectEqual(ir.Ty.Unit, set_app.ty);
    try std.testing.expectEqual(ir.Ty.String, exprTy(set_app.args[0].*));

    const get_app = switch (set_let.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const get_callee = switch (get_app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Cpi.get_return_data", get_callee.name);
    try std.testing.expectEqual(ir.Ty.String, get_app.ty);
}

test "lower account field assignment as typed account mutation" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.9 (module (record_type_decl (name account) (params) (fields ((key (type-ref bytes)) (lamports (type-ref int)) (data (type-ref bytes)) (owner (type-ref bytes)) (is_signer (type-ref bool)) (is_writable (type-ref bool)) (executable (type-ref bool))))) (let entrypoint (lambda (account) (field_set (var account) lamports (const-int 42))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(isAccountTy(lambda.params[0].ty));
    const field_set = switch (lambda.body.*) {
        .AccountFieldSet => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("lamports", field_set.field_name);
    try std.testing.expectEqual(ir.Ty.Unit, field_set.ty);
    try std.testing.expectEqual(ir.Ty.Int, exprTy(field_set.value.*));
}

test "lower constructor expressions with layout policy" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let entrypoint (lambda (_input) (let _ (ctor Some (const-int 1)) (const-int 0))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const nested = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const ctor_expr = switch (nested.value.*) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Some", ctor_expr.name);
    try std.testing.expectEqual(@as(usize, 1), ctor_expr.args.len);
    try std.testing.expectEqual(layout.Layout{ .region = .Arena, .repr = .Boxed }, ctor_expr.layout);

    const printed = try pretty.formatModule(std.testing.allocator, module);
    defer std.testing.allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "(ctor Some") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, ":layout (arena boxed)") != null);
}

test "lower list constructors and cons patterns with list layout policy" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let entrypoint (lambda (_) (let-rec sum (lambda (xs) (match (var xs) (case (ctor \"[]\") (const-int 0)) (case (ctor \"::\" (var x) (var rest)) (prim \"+\" (var x) (app (var sum) (var rest)))))) (app (var sum) (ctor \"::\" (const-int 1) (ctor \"[]\"))))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const sum_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const sum_lambda = switch (sum_let.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("list", switch (sum_lambda.params[0].ty) {
        .Adt => |adt| adt.name,
        else => return error.TestUnexpectedResult,
    });

    const list_arg = switch (sum_let.body.*) {
        .App => |app| switch (app.args[0].*) {
            .Let => |let_expr| switch (let_expr.body.*) {
                .Ctor => |ctor| ctor,
                else => return error.TestUnexpectedResult,
            },
            .Ctor => |ctor| ctor,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("::", list_arg.name);
    try std.testing.expectEqual(layout.Layout{ .region = .Arena, .repr = .Boxed }, list_arg.layout);

    const printed = try pretty.formatModule(std.testing.allocator, module);
    defer std.testing.allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "(ctor ::") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, ":layout (arena boxed)") != null);
}

test "lower basic match expressions with top-to-bottom arms" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let entrypoint (lambda (_input) (match (ctor Some (const-int 1)) (case (ctor Some (var x)) (var x)) (case (ctor None) (const-int 0)))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const scrutinee_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, scrutinee_let.name, "__omlz_match_scrutinee_"));
    const match_expr = switch (scrutinee_let.body.*) {
        .Match => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), match_expr.arms.len);
    const some_pattern = switch (match_expr.arms[0].pattern) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Some", some_pattern.name);
    const bound = switch (some_pattern.args[0]) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("x", bound.name);

    const printed = try pretty.formatModule(std.testing.allocator, module);
    defer std.testing.allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "(match") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "((pattern (ctor Some (var x)))") != null);
}

test "lower user-defined ADT constructors with explicit tags" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.5 (module (type_decl (name t) (params) (variants ((A (payload_types)) (B (payload_types)) (C (payload_types (type-ref int)))))) (let entrypoint (lambda (_) (match (ctor C (const-int 42)) (case (ctor A) (const-int 0)) (case (ctor C (var x)) (var x)))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    try std.testing.expectEqual(@as(usize, 1), module.type_decls.len);
    try std.testing.expectEqualStrings("t", module.type_decls[0].name);
    try std.testing.expectEqual(@as(u32, 2), module.type_decls[0].variants[2].tag);

    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const scrutinee_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const ctor_expr = switch (scrutinee_let.value.*) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("C", ctor_expr.name);
    try std.testing.expectEqual(@as(u32, 2), ctor_expr.tag);
    try std.testing.expectEqualStrings("t", ctor_expr.type_name.?);

    const printed = try pretty.formatModule(std.testing.allocator, module);
    defer std.testing.allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "(type t (variants (A :tag 0) (B :tag 1) (C :tag 2 :payload (type-ref int))))") != null);
}

test "lower user-defined ADT constructor type parameters from payload types" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.5 (module (type_decl (name box) (params 'a) (variants ((Box (payload_types (type-var 'a)))))) (let entrypoint (lambda (_) (let flag (prim \"=\" (const-int 1) (const-int 1)) (match (ctor Box (var flag)) (case (ctor Box (var boxed_flag)) (if (var boxed_flag) (const-int 0) (const-int 1)))))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const flag_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const scrutinee_let = switch (flag_let.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const ctor_expr = switch (scrutinee_let.value.*) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const adt = switch (ctor_expr.ty) {
        .Adt => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("box", adt.name);
    try std.testing.expectEqual(@as(usize, 1), adt.params.len);
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Ty), .Bool), std.meta.activeTag(adt.params[0]));

    const match_expr = switch (scrutinee_let.body.*) {
        .Match => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const box_pattern = switch (match_expr.arms[0].pattern) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const flag_pattern = switch (box_pattern.args[0]) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Ty), .Bool), std.meta.activeTag(flag_pattern.ty));
}

test "lower nullary user ADT constructor type parameters from match context" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.5 (module (type_decl (name option) (params 'a) (variants ((None (payload_types)) (Some (payload_types (type-var 'a)))))) (let entrypoint (lambda (_) (match (ctor None) (case (ctor Some (var flag)) (if (var flag) (const-int 0) (const-int 1))) (case (ctor None) (const-int 2)))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const scrutinee_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const ctor_expr = switch (scrutinee_let.value.*) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const adt = switch (ctor_expr.ty) {
        .Adt => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("option", adt.name);
    try std.testing.expectEqual(@as(usize, 1), adt.params.len);
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Ty), .Bool), std.meta.activeTag(adt.params[0]));

    const match_expr = switch (scrutinee_let.body.*) {
        .Match => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const some_pattern = switch (match_expr.arms[0].pattern) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const flag_pattern = switch (some_pattern.args[0]) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Ty), .Bool), std.meta.activeTag(flag_pattern.ty));
}

test "lower nullary user ADT constructor without context stays polymorphic" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.5 (module (type_decl (name option) (params 'a) (variants ((None (payload_types)) (Some (payload_types (type-var 'a)))))) (let value (ctor None))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const value_decl = switch (module.decls[0]) {
        .Let => |value| value,
    };
    const ctor_expr = switch (value_decl.value.*) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const adt = switch (ctor_expr.ty) {
        .Adt => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("option", adt.name);
    try std.testing.expectEqual(@as(usize, 1), adt.params.len);
    const type_var = switch (adt.params[0]) {
        .Var => |name| name,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("'a", type_var);
}
