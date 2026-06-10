//! RESPONSIBILITIES:
//! - Lower ttree declarations and expressions into ANF Core IR.
//! - Handle lambda/let/match/array/ref/record plumbing and scope tracking.
//! - Attach source locations to lowered Core IR expressions.

const std = @import("std");
const ttree = @import("../../frontend_bridge/ttree.zig");
const ir = @import("../ir.zig");
const layout = @import("../layout.zig");
const context = @import("context.zig");
const tail = @import("tail.zig");
const match_lower = @import("match.zig");
const type_ops = @import("type_ops.zig");
const type_lowering = @import("type_lowering.zig");
const call_lowering = @import("call_lowering.zig");

const LowerError = context.LowerError;
const ScopedBinding = context.ScopedBinding;
const TypeBindings = context.TypeBindings;
const LowerContext = context.LowerContext;

const markTailCallsInFunction = tail.markTailCallsInFunction;
const lowerMatch = match_lower.lowerMatch;
const bindTypeParamsFromPayload = match_lower.bindTypeParamsFromPayload;

const listTy = type_ops.listTy;
const accountTy = type_ops.accountTy;
const recordTyWithBindings = type_ops.recordTyWithBindings;
const findRecordDecl = type_ops.findRecordDecl;
const findRecordDeclForFields = type_ops.findRecordDeclForFields;
const findRecordExprField = type_ops.findRecordExprField;
const recordFieldTyForRecord = type_ops.recordFieldTyForRecord;
const recordFieldAccessTy = type_ops.recordFieldAccessTy;
const isAccountTy = type_ops.isAccountTy;
const layoutForTy = type_ops.layoutForTy;
const makeArrowTy = type_ops.makeArrowTy;
const intToIntArrowTy = type_ops.intToIntArrowTy;
const exprTy = type_ops.exprTy;
const exprLayout = type_ops.exprLayout;
const recBindingEscapes = type_ops.recBindingEscapes;
const lambdaParamIsFunction = type_ops.lambdaParamIsFunction;
const lambdaParamRecordTy = type_ops.lambdaParamRecordTy;
const lambdaParamIsAccount = type_ops.lambdaParamIsAccount;
const isInstructionDataParamName = type_ops.isInstructionDataParamName;
const lambdaParamIsList = type_ops.lambdaParamIsList;

const lowerTypeExpr = type_lowering.lowerTypeExpr;
const lowerTypeExprOpt = type_lowering.lowerTypeExprOpt;

const lowerApp = call_lowering.lowerApp;
const lowerIf = call_lowering.lowerIf;
const lowerPrim = call_lowering.lowerPrim;
const lowerVarExpr = call_lowering.lowerVarExpr;
const lowerCtor = call_lowering.lowerCtor;
const lowerConstant = call_lowering.lowerConstant;

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
        .param_types = binding.param_types,
        .param_annotated = binding.param_annotated,
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

    for (lambda.params, 0..) |param_name, param_index| {
        const owned_name = try arena.allocator().dupe(u8, param_name);
        // Per-parameter type precedence (wire 1.7 / CR-13):
        //   1. `_`-prefixed names stay `Unit` — the underscore encodes
        //      "unused" and entrypoint shapes rely on it, even when the
        //      param carries an explicit annotation like `(_a : account)`.
        //   2. Instruction-data names stay `String` (ABI-relevant).
        //   3. An explicitly annotated wire type (`ty!`, wire 1.7) wins
        //      next: `(m : account_meta)` means the programmer said so,
        //      and heuristics must not override it.
        //   4. The structural heuristics (account/record/list/function
        //      callback) classify *unannotated* params, encoding
        //      programmer-intent inferences (e.g. a bare `authority` param
        //      that reaches into `is_signer` is an entrypoint `account`
        //      rather than the formally-inferred `account_meta`).
        //   5. An unannotated wire type beats the historical `Ty.Int`
        //      fallback so string/option/result/etc. payloads flow through
        //      for higher-order callbacks.
        //   6. Truly unconstrained params arrive as `null` and collapse
        //      back to `Ty.Int`.
        const wire_param_ty: ?ir.Ty = if (param_index < lambda.param_types.len)
            try lowerTypeExprOpt(arena, ctx, lambda.param_types[param_index])
        else
            null;
        const annotated = param_index < lambda.param_annotated.len and
            lambda.param_annotated[param_index];
        const param_ty: ir.Ty = if (std.mem.startsWith(u8, param_name, "_"))
            .Unit
        else if (isInstructionDataParamName(param_name))
            .String
        else if (annotated and wire_param_ty != null)
            wire_param_ty.?
        else if (lambdaParamIsAccount(lambda.body.*, param_name))
            try accountTy(arena)
        else if (lambdaParamRecordTy(arena, ctx, lambda.body.*, param_name)) |record_ty|
            record_ty
        else if (try lambdaParamIsList(arena, lambda.body.*, param_name))
            try listTy(arena, .Int)
        else if (lambdaParamIsFunction(lambda.body.*, param_name))
            try intToIntArrowTy(arena)
        else if (wire_param_ty) |ty|
            ty
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
    var lowered: ir.Expr = switch (expr) {
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
        .ArrayLit => |array_lit| try lowerArrayLit(arena, ctx, array_lit),
        .ArrayGet => |array_get| try lowerArrayGet(arena, ctx, array_get),
        .ArrayLength => |array_length| try lowerArrayLength(arena, ctx, array_length),
        .ArraySet => |array_set| try lowerArraySet(arena, ctx, array_set),
        .ArrayMake => |array_make| try lowerArrayMake(arena, ctx, array_make),
        .RefMake => |ref_make| try lowerRefMake(arena, ctx, ref_make),
        .RefGet => |ref_get| try lowerRefGet(arena, ctx, ref_get),
        .RefSet => |ref_set| try lowerRefSet(arena, ctx, ref_set),
    };
    try setCoreLoc(arena, &lowered, ttreeExprLoc(expr));
    return lowered;
}

/// ADR-015 R9.1 lower a typed-tree `array-lit` into a Core IR `ArrayLit`.
/// Elements are coerced to `Int` (the only element type supported in R9.1).
pub fn lowerArrayLit(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, array_lit: ttree.ArrayLit) LowerError!ir.Expr {
    const elems = try arena.allocator().alloc(*const ir.Expr, array_lit.elems.len);
    for (array_lit.elems, 0..) |elem, index| {
        elems[index] = try lowerExprPtrExpected(arena, ctx, elem, .Int);
    }
    const elem_ty_ptr = try arena.allocator().create(ir.Ty);
    elem_ty_ptr.* = .Int;
    return .{ .ArrayLit = .{
        .elem_ty = .Int,
        .elems = elems,
        .ty = .{ .Array = elem_ty_ptr },
        .layout = layout.structPack(),
    } };
}

/// ADR-015 R9.1 lower a typed-tree `array-get` into a Core IR `ArrayGet`.
pub fn lowerArrayGet(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, array_get: ttree.ArrayGet) LowerError!ir.Expr {
    const elem_ty_ptr = try arena.allocator().create(ir.Ty);
    elem_ty_ptr.* = .Int;
    const arr = try lowerExprPtrExpected(arena, ctx, array_get.arr.*, .{ .Array = elem_ty_ptr });
    const idx = try lowerExprPtrExpected(arena, ctx, array_get.idx.*, .Int);
    return .{ .ArrayGet = .{
        .arr = arr,
        .idx = idx,
        .ty = .Int,
        .layout = layout.intConstant(),
    } };
}

/// ADR-015 R9.1 lower a typed-tree `array-length` into a Core IR `ArrayLength`.
pub fn lowerArrayLength(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, array_length: ttree.ArrayLength) LowerError!ir.Expr {
    const elem_ty_ptr = try arena.allocator().create(ir.Ty);
    elem_ty_ptr.* = .Int;
    const arr = try lowerExprPtrExpected(arena, ctx, array_length.arr.*, .{ .Array = elem_ty_ptr });
    return .{ .ArrayLength = .{
        .arr = arr,
        .ty = .Int,
        .layout = layout.intConstant(),
    } };
}

/// ADR-015 R9.2 lower a typed-tree `array-set` into a Core IR `ArraySet`.
/// Returns `unit`; bounds violations are checked at runtime against the
/// existing `array_oob` panic marker.
pub fn lowerArraySet(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, array_set: ttree.ArraySet) LowerError!ir.Expr {
    const elem_ty_ptr = try arena.allocator().create(ir.Ty);
    elem_ty_ptr.* = .Int;
    const arr = try lowerExprPtrExpected(arena, ctx, array_set.arr.*, .{ .Array = elem_ty_ptr });
    const idx = try lowerExprPtrExpected(arena, ctx, array_set.idx.*, .Int);
    const value = try lowerExprPtrExpected(arena, ctx, array_set.value.*, .Int);
    return .{ .ArraySet = .{
        .arr = arr,
        .idx = idx,
        .value = value,
        .ty = .Unit,
        .layout = layout.intConstant(),
    } };
}

/// ADR-015 option C / R10 lower a typed-tree `ref-make` into a Core IR
/// `RefMake`. The element type ttree-side carries the frontend's choice;
/// here we re-resolve it through `typeExprToTy` so downstream layers see
/// canonical Core IR `Ty.Int`/`Ty.Bool`/`Ty.Adt(option, ...)` etc.
pub fn lowerRefMake(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, ref_make: ttree.RefMake) LowerError!ir.Expr {
    const lowered_type_expr = try lowerTypeExpr(arena, ref_make.elem_ty);
    const elem_ty = try type_ops.typeExprToTy(arena, lowered_type_expr);
    const elem_ty_ptr = try arena.allocator().create(ir.Ty);
    elem_ty_ptr.* = elem_ty;
    const init = try lowerExprPtrExpected(arena, ctx, ref_make.init.*, elem_ty);
    return .{ .RefMake = .{
        .elem_ty = elem_ty,
        .init = init,
        .ty = .{ .Ref = elem_ty_ptr },
        .layout = layout.structPack(),
    } };
}

/// ADR-015 option C / R10 lower a typed-tree `ref-get` into a Core IR
/// `RefGet`. Element type is determined from the target's lowered type; we
/// fall back to a fresh `Ty.Int` for the unannotated case.
pub fn lowerRefGet(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, ref_get: ttree.RefGet) LowerError!ir.Expr {
    const target = try lowerExprPtr(arena, ctx, ref_get.target.*);
    const elem_ty: ir.Ty = switch (exprTy(target.*)) {
        .Ref => |inner| inner.*,
        else => .Int,
    };
    return .{ .RefGet = .{
        .target = target,
        .ty = elem_ty,
        .layout = layout.intConstant(),
    } };
}

/// ADR-015 option C / R10 lower a typed-tree `ref-set` into a Core IR
/// `RefSet`. The value's expected type is taken from the target's element
/// type when present.
pub fn lowerRefSet(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, ref_set: ttree.RefSet) LowerError!ir.Expr {
    const target = try lowerExprPtr(arena, ctx, ref_set.target.*);
    const elem_ty: ?ir.Ty = switch (exprTy(target.*)) {
        .Ref => |inner| inner.*,
        else => null,
    };
    const value = if (elem_ty) |elt|
        try lowerExprPtrExpected(arena, ctx, ref_set.value.*, elt)
    else
        try lowerExprPtr(arena, ctx, ref_set.value.*);
    return .{ .RefSet = .{
        .target = target,
        .value = value,
        .ty = .Unit,
        .layout = layout.intConstant(),
    } };
}

/// ADR-015 R9.2 lower a typed-tree `array-make` into a Core IR `ArrayMake`.
/// Size is constant; init expression must be `int`-typed.
pub fn lowerArrayMake(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, array_make: ttree.ArrayMake) LowerError!ir.Expr {
    const elem_ty_ptr = try arena.allocator().create(ir.Ty);
    elem_ty_ptr.* = .Int;
    const init = try lowerExprPtrExpected(arena, ctx, array_make.init.*, .Int);
    return .{ .ArrayMake = .{
        .elem_ty = .Int,
        .size = array_make.size,
        .init = init,
        .ty = .{ .Array = elem_ty_ptr },
        .layout = layout.structPack(),
    } };
}

fn ttreeExprLoc(expr: ttree.Expr) ttree.Loc {
    return switch (expr) {
        .Lambda => |value| value.loc,
        .Constant => ttree.Loc.unknown,
        .App => |value| value.loc,
        .Let => |value| value.loc,
        .LetRecGroup => |value| value.loc,
        .Assert => |value| value.loc,
        .If => |value| value.loc,
        .Prim => |value| value.loc,
        .Var => |value| value.loc,
        .Ctor => |value| value.loc,
        .Match => |value| value.loc,
        .Tuple => |value| value.loc,
        .TupleProj => |value| value.loc,
        .Record => |value| value.loc,
        .RecordField => |value| value.loc,
        .RecordUpdate => |value| value.loc,
        .FieldSet => |value| value.loc,
        .ArrayLit => |value| value.loc,
        .ArrayGet => |value| value.loc,
        .ArrayLength => |value| value.loc,
        .ArraySet => |value| value.loc,
        .ArrayMake => |value| value.loc,
        .RefMake => |value| value.loc,
        .RefGet => |value| value.loc,
        .RefSet => |value| value.loc,
    };
}

fn lowerLoc(arena: *std.heap.ArenaAllocator, loc: ttree.Loc) LowerError!?ir.Loc {
    if (loc.isUnknown()) return null;
    return .{
        .file = try arena.allocator().dupe(u8, loc.file),
        .line = loc.line,
        .col = loc.col,
        .end_line = loc.end_line,
        .end_col = loc.end_col,
    };
}

fn setCoreLoc(arena: *std.heap.ArenaAllocator, expr: *ir.Expr, loc: ttree.Loc) LowerError!void {
    const lowered = try lowerLoc(arena, loc);
    switch (expr.*) {
        .Lambda => |*value| value.loc = lowered,
        .Constant => |*value| value.loc = lowered,
        .App => |*value| value.loc = lowered,
        .Let => |*value| value.loc = lowered,
        .LetGroup => |*value| value.loc = lowered,
        .Assert => |*value| value.loc = lowered,
        .If => |*value| value.loc = lowered,
        .Prim => |*value| value.loc = lowered,
        .Var => |*value| value.loc = lowered,
        .Ctor => |*value| value.loc = lowered,
        .Match => |*value| value.loc = lowered,
        .Tuple => |*value| value.loc = lowered,
        .TupleProj => |*value| value.loc = lowered,
        .Record => |*value| value.loc = lowered,
        .RecordField => |*value| value.loc = lowered,
        .RecordUpdate => |*value| value.loc = lowered,
        .AccountFieldSet => |*value| value.loc = lowered,
        .ArrayLit => |*value| value.loc = lowered,
        .ArrayGet => |*value| value.loc = lowered,
        .ArrayLength => |*value| value.loc = lowered,
        .ArraySet => |*value| value.loc = lowered,
        .ArrayMake => |*value| value.loc = lowered,
        .RefMake => |*value| value.loc = lowered,
        .RefGet => |*value| value.loc = lowered,
        .RefSet => |*value| value.loc = lowered,
    }
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
