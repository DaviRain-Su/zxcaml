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
    ctx.tuple_type_decls = tuple_type_decls;
    ctx.record_type_decls = record_type_decls;
    try indexConstructors(&ctx, type_decls);

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
            const value = try lowerExprPtr(arena, ctx, let_decl.body);
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
            .value = try lowerExprPtrExpected(arena, ctx, field.value, try recordFieldTy(arena, record_decl, field.name)),
        };
    }
    return .{ .Record = .{
        .fields = fields,
        .ty = try recordTy(arena, record_decl),
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
            .value = try lowerExprPtrExpected(arena, ctx, field.value, try recordFieldTy(arena, record_decl, field.name)),
        };
    }
    return .{ .RecordUpdate = .{
        .base_expr = base_expr,
        .fields = fields,
        .ty = base_ty,
        .layout = layout.structPack(),
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

fn lowerApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    const callee = try lowerExprPtr(arena, ctx, app.callee.*);
    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (app.args) |arg| {
        try args.append(arena.allocator(), try lowerExprPtr(arena, ctx, arg));
    }
    return .{ .App = .{
        .callee = callee,
        .args = try args.toOwnedSlice(arena.allocator()),
        .ty = .Int,
        .layout = layout.intConstant(),
    } };
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
    if (prim.args.len != 2) return error.UnsupportedPrimArity;
    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (prim.args) |arg| {
        try args.append(arena.allocator(), try lowerExprPtr(arena, ctx, arg));
    }
    const ty: ir.Ty = switch (op) {
        .Add, .Sub, .Mul, .Div, .Mod => .Int,
        .Eq, .Ne, .Lt, .Le, .Gt, .Ge => .Bool,
    };
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
                expected_payload_tys = try typeExprsToTysWithBindings(arena, info.payload_types, &bindings);
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
        var inserted = std.ArrayList(ScopedBinding).empty;
        defer inserted.deinit(arena.allocator());

        const lowered_pattern = try lowerPattern(arena, ctx, arm.pattern, exprTy(scrutinee.*), exprLayout(scrutinee.*), &inserted);
        const guard = if (arm.guard) |guard_expr|
            try lowerExprPtrExpected(arena, ctx, guard_expr.*, .Bool)
        else
            null;
        const body = try lowerExprPtr(arena, ctx, arm.body.*);
        try arms.append(arena.allocator(), .{
            .pattern = lowered_pattern,
            .guard = guard,
            .body = body,
        });

        restoreBindings(ctx, inserted.items);
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

fn inferMatchScrutineeExpectedTy(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, match_expr: ttree.Match) LowerError!?ir.Ty {
    var pattern_var_tys = TypeBindings.init(arena.allocator());
    defer pattern_var_tys.deinit();

    const result_ty = try inferMatchResultTy(arena, &pattern_var_tys, match_expr.arms);
    for (match_expr.arms) |arm| {
        if (arm.guard) |guard_expr| try inferExprVarExpectations(arena, &pattern_var_tys, guard_expr.*, .Bool);
        try inferExprVarExpectations(arena, &pattern_var_tys, arm.body.*, result_ty);
    }

    var type_bindings = TypeBindings.init(arena.allocator());
    defer type_bindings.deinit();

    var candidate: ?ConstructorInfo = null;
    for (match_expr.arms) |arm| {
        const ctor_pattern = switch (arm.pattern) {
            .Ctor => |ctor| ctor,
            .Wildcard, .Var, .Tuple, .Record => continue,
        };
        const info = ctx.constructors.get(ctor_pattern.name) orelse continue;
        if (candidate) |existing| {
            if (!std.mem.eql(u8, existing.type_name, info.type_name)) continue;
        } else {
            candidate = info;
        }
        try bindTypeParamsFromPatternPayloads(&type_bindings, info.payload_types, ctor_pattern.args, &pattern_var_tys);
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
            break :blk switch (op) {
                .Add, .Sub, .Mul, .Div, .Mod => .Int,
                .Eq, .Ne, .Lt, .Le, .Gt, .Ge => .Bool,
            };
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
        .Lambda, .App, .Ctor, .Match, .TupleProj, .Record, .RecordField, .RecordUpdate => null,
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
        .Wildcard => {},
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
                const field_ty = try recordFieldTy(arena, record_decl, field.name);
                lowered_fields[index] = .{
                    .name = try arena.allocator().dupe(u8, field.name),
                    .pattern = try lowerPattern(arena, ctx, field.pattern, field_ty, layoutForTy(field_ty), inserted),
                };
            }
            break :blk .{ .Record = lowered_fields };
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
        return typeExprsToTysWithBindings(arena, info.payload_types, &bindings);
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
            const actual_adt = switch (actual) {
                .Adt => |value| value,
                else => return,
            };
            if (!std.mem.eql(u8, ref.name, actual_adt.name)) return;
            for (ref.args, actual_adt.params) |arg_expr, arg_ty| {
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
    return typeExprsToTysWithBindings(arena, exprs, null);
}

fn typeExprsToTysWithBindings(
    arena: *std.heap.ArenaAllocator,
    exprs: []const types.TypeExpr,
    bindings: ?*TypeBindings,
) LowerError![]const ir.Ty {
    const out = try arena.allocator().alloc(ir.Ty, exprs.len);
    for (exprs, 0..) |expr, index| {
        out[index] = try typeExprToTyWithBindings(arena, expr, bindings);
    }
    return out;
}

fn typeExprToTy(arena: *std.heap.ArenaAllocator, expr: types.TypeExpr) LowerError!ir.Ty {
    return typeExprToTyWithBindings(arena, expr, null);
}

fn typeExprToTyWithBindings(
    arena: *std.heap.ArenaAllocator,
    expr: types.TypeExpr,
    bindings: ?*TypeBindings,
) LowerError!ir.Ty {
    return switch (expr) {
        .TypeVar => |name| if (bindings) |values| values.get(name) orelse .{ .Var = name } else .{ .Var = name },
        .TypeRef => |ref| try typeRefToTyWithBindings(arena, ref, bindings),
        .RecursiveRef => |ref| try typeRefToTyWithBindings(arena, ref, bindings),
        .Tuple => |items| .{ .Tuple = try typeExprsToTysWithBindings(arena, items, bindings) },
    };
}

fn typeRefToTy(arena: *std.heap.ArenaAllocator, ref: types.TypeRef) LowerError!ir.Ty {
    return typeRefToTyWithBindings(arena, ref, null);
}

fn typeRefToTyWithBindings(
    arena: *std.heap.ArenaAllocator,
    ref: types.TypeRef,
    bindings: ?*TypeBindings,
) LowerError!ir.Ty {
    if (std.mem.eql(u8, ref.name, "int")) return .Int;
    if (std.mem.eql(u8, ref.name, "bool")) return .Bool;
    if (std.mem.eql(u8, ref.name, "unit")) return .Unit;
    if (std.mem.eql(u8, ref.name, "string")) return .String;
    return .{ .Adt = .{
        .name = ref.name,
        .params = try typeExprsToTysWithBindings(arena, ref.args, bindings),
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

fn recordTy(arena: *std.heap.ArenaAllocator, decl: types.RecordType) LowerError!ir.Ty {
    const params = try arena.allocator().alloc(ir.Ty, decl.params.len);
    for (params) |*param| param.* = .Unit;
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

fn recordFieldTy(arena: *std.heap.ArenaAllocator, decl: types.RecordType, field_name: []const u8) LowerError!ir.Ty {
    for (decl.fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) return typeExprToTy(arena, field.ty);
    }
    return error.UnsupportedNode;
}

fn recordFieldAccessTy(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, ty: ir.Ty, field_name: []const u8) LowerError!ir.Ty {
    const record = switch (ty) {
        .Record => |value| value,
        else => return error.UnsupportedNode,
    };
    const decl = findRecordDecl(ctx.record_type_decls, record.name) orelse return error.UnsupportedNode;
    return recordFieldTy(arena, decl, field_name);
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
        .Wildcard => false,
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
        .Constant, .Var => false,
    };
}

fn patternIsListCtor(pattern: ttree.Pattern) bool {
    return switch (pattern) {
        .Ctor => |ctor_pattern| std.mem.eql(u8, ctor_pattern.name, "[]") or std.mem.eql(u8, ctor_pattern.name, "::"),
        .Tuple, .Record, .Wildcard, .Var => false,
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
