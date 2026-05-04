const std = @import("std");
const ttree = @import("../../frontend_bridge/ttree.zig");
const ir = @import("../ir.zig");
const layout = @import("../layout.zig");
const pretty = @import("../pretty.zig");
const types = @import("../types.zig");
const context = @import("context.zig");
const tail = @import("tail.zig");
const rename = @import("rename.zig");
const match_lower = @import("match.zig");
const type_ops = @import("type_ops.zig");

pub const LowerError = context.LowerError;
const BindingInfo = context.BindingInfo;
const ConstructorInfo = context.ConstructorInfo;
const ScopedBinding = context.ScopedBinding;
const TypeBindings = context.TypeBindings;
const LowerContext = context.LowerContext;

const markTailCallsInFunction = tail.markTailCallsInFunction;
const RenameBinding = rename.RenameBinding;
const freshSyntheticName = rename.freshSyntheticName;
const renameExprVars = rename.renameExprVars;
const lowerMatch = match_lower.lowerMatch;
const lowerPattern = match_lower.lowerPattern;
const restoreBindings = match_lower.restoreBindings;
const ctorTy = match_lower.ctorTy;
const bindTypeParamsFromPayload = match_lower.bindTypeParamsFromPayload;
const builtinCtorTag = match_lower.builtinCtorTag;
const validateCtor = match_lower.validateCtor;
const bindTypeParamsFromMatchedAdt = match_lower.bindTypeParamsFromMatchedAdt;
const isAtomicTtree = match_lower.isAtomicTtree;
const freshTemp = match_lower.freshTemp;

const typeExprsToTys = type_ops.typeExprsToTys;
const typeExprsToTysWithBindings = type_ops.typeExprsToTysWithBindings;
const externalTypeExprToTy = type_ops.externalTypeExprToTy;
const listTy = type_ops.listTy;
const arrayTy = type_ops.arrayTy;
const optionTy = type_ops.optionTy;
const resultTy = type_ops.resultTy;
const accountTy = type_ops.accountTy;
const tySlice = type_ops.tySlice;
const arrowTy = type_ops.arrowTy;
const recordTy = type_ops.recordTy;
const recordTyWithBindings = type_ops.recordTyWithBindings;
const findRecordDecl = type_ops.findRecordDecl;
const findRecordDeclForFields = type_ops.findRecordDeclForFields;
const findRecordExprField = type_ops.findRecordExprField;
const recordFieldTy = type_ops.recordFieldTy;
const recordFieldTyForRecord = type_ops.recordFieldTyForRecord;
const recordFieldAccessTy = type_ops.recordFieldAccessTy;
const isAccountTy = type_ops.isAccountTy;
const layoutForTy = type_ops.layoutForTy;
const makeArrowTy = type_ops.makeArrowTy;
const makeArrowTyFromPieces = type_ops.makeArrowTyFromPieces;
const intToIntArrowTy = type_ops.intToIntArrowTy;
const exprTy = type_ops.exprTy;
const tyEql = type_ops.tyEql;
const exprLayout = type_ops.exprLayout;
const recBindingEscapes = type_ops.recBindingEscapes;
const lambdaParamIsFunction = type_ops.lambdaParamIsFunction;
const lambdaParamRecordTy = type_ops.lambdaParamRecordTy;
const lambdaParamIsAccount = type_ops.lambdaParamIsAccount;
const isInstructionDataParamName = type_ops.isInstructionDataParamName;
const lambdaParamIsList = type_ops.lambdaParamIsList;

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
            .LetRecGroup => |group| {
                for (group.bindings) |binding| {
                    try ctx.scope.put(binding.name, .{
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
            .LetGroup => |group| for (group.bindings) |binding| {
                try ctx.scope.put(binding.name, .{
                    .ty = binding.ty,
                    .layout = binding.layout,
                });
            },
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

pub fn lowerDecl(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, decl: ttree.Decl) LowerError!ir.Decl {
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
        .LetRecGroup => |group| blk: {
            const bindings = try arena.allocator().alloc(ir.LetGroupBinding, group.bindings.len);
            for (group.bindings, 0..) |binding, index| {
                bindings[index] = try lowerLetRecGroupBinding(arena, ctx, binding);
            }
            break :blk .{ .LetGroup = .{ .bindings = bindings } };
        },
    };
}

pub fn lowerLetRecGroupBinding(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, binding: ttree.LetRecBinding) LowerError!ir.LetGroupBinding {
    const lambda: ttree.Lambda = .{
        .params = binding.params,
        .body = &binding.body,
    };
    var value = try lowerExprPtr(arena, ctx, .{ .Lambda = lambda });
    value = try markTailCallsInFunction(arena, value, binding.name);
    return .{
        .name = try arena.allocator().dupe(u8, binding.name),
        .value = value,
        .ty = exprTy(value.*),
        .layout = exprLayout(value.*),
    };
}

pub fn lowerLambda(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, lambda: ttree.Lambda) LowerError!ir.Lambda {
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
        else if (lambdaParamRecordTy(arena, ctx, lambda.body.*, param_name)) |record_ty|
            record_ty
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

pub fn lowerExprPtr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, expr: ttree.Expr) LowerError!*const ir.Expr {
    return lowerExprPtrExpected(arena, ctx, expr, null);
}

pub fn lowerExprPtrExpected(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    expr: ttree.Expr,
    expected_ty: ?ir.Ty,
) LowerError!*const ir.Expr {
    const ptr = try arena.allocator().create(ir.Expr);
    ptr.* = try lowerExprExpected(arena, ctx, expr, expected_ty);
    return ptr;
}

pub fn lowerExpr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, expr: ttree.Expr) LowerError!ir.Expr {
    return lowerExprExpected(arena, ctx, expr, null);
}

pub fn lowerExprExpected(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, expr: ttree.Expr, expected_ty: ?ir.Ty) LowerError!ir.Expr {
    return switch (expr) {
        .Lambda => |lambda| .{ .Lambda = try lowerLambda(arena, ctx, lambda) },
        .Constant => |constant| .{ .Constant = try lowerConstant(arena, constant) },
        .App => |app| try lowerApp(arena, ctx, app),
        .Let => |let_expr| .{ .Let = try lowerLetExpr(arena, ctx, let_expr) },
        .LetRecGroup => |group| .{ .LetGroup = try lowerLetRecGroupExpr(arena, ctx, group) },
        .Assert => |assert_expr| .{ .Assert = try lowerAssert(arena, ctx, assert_expr) },
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

pub fn lowerAssert(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, assert_expr: ttree.AssertExpr) LowerError!ir.AssertExpr {
    return .{
        .condition = try lowerExprPtrExpected(arena, ctx, assert_expr.condition.*, .Bool),
        .ty = .Unit,
        .layout = layout.unitValue(),
    };
}

pub fn lowerTuple(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, tuple_expr: ttree.Tuple) LowerError!ir.Expr {
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

pub fn lowerTupleProj(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, tuple_proj: ttree.TupleProj) LowerError!ir.Expr {
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

pub fn lowerRecord(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, record_expr: ttree.Record) LowerError!ir.Expr {
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

pub fn lowerRecordField(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, field_access: ttree.RecordField) LowerError!ir.Expr {
    const record_expr = try lowerExprPtr(arena, ctx, field_access.record_expr.*);
    const ty = try recordFieldAccessTy(arena, ctx, exprTy(record_expr.*), field_access.field_name);
    return .{ .RecordField = .{
        .record_expr = record_expr,
        .field_name = try arena.allocator().dupe(u8, field_access.field_name),
        .ty = ty,
        .layout = layoutForTy(ty),
    } };
}

pub fn lowerRecordUpdate(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, record_update: ttree.RecordUpdate) LowerError!ir.Expr {
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

pub fn lowerFieldSet(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, field_set: ttree.FieldSet) LowerError!ir.Expr {
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

pub fn lowerLetRecGroupExpr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, group: ttree.LetRecGroupExpr) LowerError!ir.LetGroupExpr {
    var inserted = std.ArrayList(ScopedBinding).empty;
    defer inserted.deinit(arena.allocator());

    for (group.bindings) |binding| {
        const owned_name = try arena.allocator().dupe(u8, binding.name);
        const previous = ctx.scope.get(owned_name);
        try ctx.scope.put(owned_name, .{ .ty = .Unit, .layout = layout.topLevelLambda() });
        try inserted.append(arena.allocator(), .{ .name = owned_name, .previous = previous });
    }

    const bindings = try arena.allocator().alloc(ir.LetGroupBinding, group.bindings.len);
    for (group.bindings, 0..) |binding, index| {
        bindings[index] = try lowerLetRecGroupBinding(arena, ctx, binding);
    }
    for (bindings) |binding| {
        try ctx.scope.put(binding.name, .{ .ty = binding.ty, .layout = binding.layout });
    }

    const body = try lowerExprPtr(arena, ctx, group.body.*);

    var index = inserted.items.len;
    while (index > 0) {
        index -= 1;
        const item = inserted.items[index];
        if (item.previous) |previous| {
            ctx.scope.getPtr(item.name).?.* = previous;
        } else {
            _ = ctx.scope.remove(item.name);
        }
    }

    return .{
        .bindings = bindings,
        .body = body,
        .ty = exprTy(body.*),
        .layout = exprLayout(body.*),
    };
}

pub fn lowerLetExpr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, let_expr: ttree.LetExpr) LowerError!ir.LetExpr {
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

pub fn lowerApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
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
    if (isVarNamed(app.callee.*, "&&") and app.args.len == 2) {
        return lowerLogicalAnd(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "||") and app.args.len == 2) {
        return lowerLogicalOr(arena, ctx, app);
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

pub fn lowerLogicalAnd(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    const cond = try lowerExprPtrExpected(arena, ctx, app.args[0], .Bool);
    const then_branch = try lowerExprPtrExpected(arena, ctx, app.args[1], .Bool);
    const else_branch = try boolCoreExpr(arena, false);
    return .{ .If = .{
        .cond = cond,
        .then_branch = then_branch,
        .else_branch = else_branch,
        .ty = .Bool,
        .layout = layoutForTy(.Bool),
    } };
}

pub fn lowerLogicalOr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    const cond = try lowerExprPtrExpected(arena, ctx, app.args[0], .Bool);
    const then_branch = try boolCoreExpr(arena, true);
    const else_branch = try lowerExprPtrExpected(arena, ctx, app.args[1], .Bool);
    return .{ .If = .{
        .cond = cond,
        .then_branch = then_branch,
        .else_branch = else_branch,
        .ty = .Bool,
        .layout = layoutForTy(.Bool),
    } };
}

pub fn boolCoreExpr(arena: *std.heap.ArenaAllocator, value: bool) LowerError!*const ir.Expr {
    const ptr = try arena.allocator().create(ir.Expr);
    ptr.* = .{ .Ctor = .{
        .name = if (value) "true" else "false",
        .args = &.{},
        .ty = .Bool,
        .layout = layout.ctor(0),
        .tag = if (value) 1 else 0,
        .type_name = null,
    } };
    return ptr;
}

pub fn lowerBuiltinCallApp(
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

pub fn builtinCallOp(callee: ttree.Expr, arg_count: usize) ?ir.PrimOp {
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

pub fn builtinCallArgTys(arena: *std.heap.ArenaAllocator, op: ir.PrimOp) LowerError![]const ir.Ty {
    return switch (op) {
        .StringLength => try tySlice(arena, &.{.String}),
        .StringGet => try tySlice(arena, &.{ .String, .Int }),
        .StringSub => try tySlice(arena, &.{ .String, .Int, .Int }),
        .StringConcat => try tySlice(arena, &.{ .String, .String }),
        .CharCode, .CharChr => try tySlice(arena, &.{.Int}),
        else => return error.UnsupportedPrim,
    };
}

pub fn builtinCallReturnTy(op: ir.PrimOp) ir.Ty {
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

pub fn lowerStdlibCallApp(
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

pub fn lowerArrayOfListApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
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

pub fn lowerListLiteralExpr(
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

pub fn stdlibCallSignature(arena: *std.heap.ArenaAllocator, callee: ttree.Expr, arg_count: usize) ?StdlibCallSignature {
    const var_ref = switch (callee) {
        .Var => |value| value,
        else => return null,
    };
    return makeStdlibCallSignature(arena, var_ref.name, arg_count) catch null;
}

pub fn makeStdlibCallSignature(arena: *std.heap.ArenaAllocator, name: []const u8, arg_count: usize) LowerError!?StdlibCallSignature {
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

pub fn lowerListMapLiteralApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
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

pub fn lowerListFilterLiteralApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
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

pub fn lowerListFoldLeftLiteralApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
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

pub fn collectListLiteralItems(allocator: std.mem.Allocator, expr: ttree.Expr, items: *std.ArrayList(ttree.Expr)) LowerError!void {
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

pub fn isVarNamed(expr: ttree.Expr, name: []const u8) bool {
    return switch (expr) {
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        else => false,
    };
}

pub fn appReturnTy(arena: *std.heap.ArenaAllocator, callee_ty: ir.Ty, arg_count: usize) LowerError!ir.Ty {
    const arrow = switch (callee_ty) {
        .Arrow => |value| value,
        else => return .Int,
    };
    if (arg_count >= arrow.params.len) return arrow.ret.*;
    const remaining = arrow.params[arg_count..];
    return makeArrowTyFromPieces(arena, remaining, arrow.ret.*);
}

pub fn lowerIf(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, if_expr: ttree.IfExpr) LowerError!ir.Expr {
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

pub fn lowerPrim(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, prim: ttree.Prim) LowerError!ir.Expr {
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

pub fn lowerPrimOp(op: []const u8) LowerError!ir.PrimOp {
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

pub fn primOpArity(op: ir.PrimOp) usize {
    return switch (op) {
        .StringLength, .CharCode, .CharChr => 1,
        .Add, .Sub, .Mul, .Div, .Mod, .Eq, .Ne, .Lt, .Le, .Gt, .Ge, .StringGet, .StringConcat => 2,
        .StringSub => 3,
    };
}

pub fn primOpReturnTy(op: ir.PrimOp) ir.Ty {
    return switch (op) {
        .Add, .Sub, .Mul, .Div, .Mod, .StringLength, .StringGet, .CharCode, .CharChr => .Int,
        .Eq, .Ne, .Lt, .Le, .Gt, .Ge => .Bool,
        .StringSub, .StringConcat => .String,
    };
}

pub fn lowerVar(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, var_ref: ttree.Var) LowerError!ir.Var {
    const binding = ctx.scope.get(var_ref.name) orelse return error.UnboundVariable;
    return .{
        .name = try arena.allocator().dupe(u8, var_ref.name),
        .ty = binding.ty,
        .layout = binding.layout,
    };
}

pub fn lowerVarExpr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, var_ref: ttree.Var, expected_ty: ?ir.Ty) LowerError!ir.Expr {
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

pub fn lowerConstant(arena: *std.heap.ArenaAllocator, constant: ttree.Constant) LowerError!ir.Constant {
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

pub fn lowerCtor(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, ctor_expr: ttree.Ctor, expected_ty: ?ir.Ty) LowerError!ir.Expr {
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
