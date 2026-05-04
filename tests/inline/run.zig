const std = @import("std");
const ir = @import("../../src/core/ir.zig");
const layout = @import("../../src/core/layout.zig");
const inline_pass = @import("../../src/core/inline.zig");

const inlineModule = inline_pass.inlineModule;

fn exprTy(expr: ir.Expr) ir.Ty {
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
        .Ctor => |ctor| ctor.ty,
        .Match => |match_expr| match_expr.ty,
        .Tuple => |tuple_expr| tuple_expr.ty,
        .TupleProj => |tuple_proj| tuple_proj.ty,
        .Record => |record_expr| record_expr.ty,
        .RecordField => |record_field| record_field.ty,
        .RecordUpdate => |record_update| record_update.ty,
        .AccountFieldSet => |field_set| field_set.ty,
    };
}

fn exprLayout(expr: ir.Expr) layout.Layout {
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
        .Ctor => |ctor| ctor.layout,
        .Match => |match_expr| match_expr.layout,
        .Tuple => |tuple_expr| tuple_expr.layout,
        .TupleProj => |tuple_proj| tuple_proj.layout,
        .Record => |record_expr| record_expr.layout,
        .RecordField => |record_field| record_field.layout,
        .RecordUpdate => |record_update| record_update.layout,
        .AccountFieldSet => |field_set| field_set.layout,
    };
}

fn exprPtr(arena: *std.heap.ArenaAllocator, expr: ir.Expr) !*const ir.Expr {
    const ptr = try arena.allocator().create(ir.Expr);
    ptr.* = expr;
    return ptr;
}

fn intPtr(arena: *std.heap.ArenaAllocator, value: i64) !*const ir.Expr {
    return exprPtr(arena, .{ .Constant = .{
        .value = .{ .Int = value },
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
}

fn stringPtr(arena: *std.heap.ArenaAllocator, value: []const u8) !*const ir.Expr {
    return exprPtr(arena, .{ .Constant = .{
        .value = .{ .String = value },
        .ty = .String,
        .layout = layout.defaultFor(.StringLiteral),
    } });
}

fn layoutForTy(ty: ir.Ty) layout.Layout {
    return switch (ty) {
        .Int, .Bool => layout.intConstant(),
        .Unit => layout.unitValue(),
        .String => layout.defaultFor(.StringLiteral),
        .Tuple, .Record => layout.structPack(),
        .Arrow => layout.topLevelLambda(),
        .Var, .Adt => layout.defaultFor(.Aggregate),
    };
}

fn varPtr(arena: *std.heap.ArenaAllocator, name: []const u8) !*const ir.Expr {
    return typedVarPtr(arena, name, .Int);
}

fn typedVarPtr(arena: *std.heap.ArenaAllocator, name: []const u8, ty: ir.Ty) !*const ir.Expr {
    return exprPtr(arena, .{ .Var = .{
        .name = name,
        .ty = ty,
        .layout = layoutForTy(ty),
    } });
}

fn primAddPtr(arena: *std.heap.ArenaAllocator, lhs: *const ir.Expr, rhs: *const ir.Expr) !*const ir.Expr {
    const args = try arena.allocator().alloc(*const ir.Expr, 2);
    args[0] = lhs;
    args[1] = rhs;
    return exprPtr(arena, .{ .Prim = .{
        .op = .Add,
        .args = args,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
}

fn appPtr(arena: *std.heap.ArenaAllocator, callee_name: []const u8, args: []const *const ir.Expr, ty: ir.Ty) !*const ir.Expr {
    return appPtrWithReturn(arena, callee_name, args, ty, .Int);
}

fn appPtrWithReturn(arena: *std.heap.ArenaAllocator, callee_name: []const u8, args: []const *const ir.Expr, callee_ty: ir.Ty, ret_ty: ir.Ty) !*const ir.Expr {
    const owned_args = try arena.allocator().alloc(*const ir.Expr, args.len);
    @memcpy(owned_args, args);
    return exprPtr(arena, .{ .App = .{
        .callee = try exprPtr(arena, .{ .Var = .{
            .name = callee_name,
            .ty = callee_ty,
            .layout = layout.topLevelLambda(),
        } }),
        .args = owned_args,
        .ty = ret_ty,
        .layout = layoutForTy(ret_ty),
    } });
}

fn intToIntTy(arena: *std.heap.ArenaAllocator) !ir.Ty {
    return arrowTy(arena, &.{.Int}, .Int);
}

fn arrowTy(arena: *std.heap.ArenaAllocator, params: []const ir.Ty, ret: ir.Ty) !ir.Ty {
    const param_tys = try arena.allocator().alloc(ir.Ty, params.len);
    @memcpy(param_tys, params);
    const ret_ty = try arena.allocator().create(ir.Ty);
    ret_ty.* = ret;
    return .{ .Arrow = .{ .params = param_tys, .ret = ret_ty } };
}

fn tupleTy(arena: *std.heap.ArenaAllocator, items: []const ir.Ty) !ir.Ty {
    const item_tys = try arena.allocator().alloc(ir.Ty, items.len);
    @memcpy(item_tys, items);
    return .{ .Tuple = item_tys };
}

fn recordTy(name: []const u8) ir.Ty {
    return .{ .Record = .{ .name = name, .params = &.{} } };
}

fn lambdaPtr(arena: *std.heap.ArenaAllocator, param_name: []const u8, body: *const ir.Expr) !*const ir.Expr {
    return lambdaPtrWithTypes(arena, &.{.{ .name = param_name, .ty = .Int }}, try intToIntTy(arena), body);
}

fn lambdaPtrWithTypes(arena: *std.heap.ArenaAllocator, params: []const ir.Param, ty: ir.Ty, body: *const ir.Expr) !*const ir.Expr {
    const owned_params = try arena.allocator().alloc(ir.Param, params.len);
    @memcpy(owned_params, params);
    return exprPtr(arena, .{ .Lambda = .{
        .params = owned_params,
        .body = body,
        .ty = ty,
        .layout = layout.topLevelLambda(),
    } });
}

fn tuplePtr(arena: *std.heap.ArenaAllocator, items: []const *const ir.Expr, ty: ir.Ty) !*const ir.Expr {
    const owned_items = try arena.allocator().alloc(*const ir.Expr, items.len);
    @memcpy(owned_items, items);
    return exprPtr(arena, .{ .Tuple = .{
        .items = owned_items,
        .ty = ty,
        .layout = layout.structPack(),
    } });
}

fn recordPtr(arena: *std.heap.ArenaAllocator, fields: []const ir.RecordExprField, ty: ir.Ty) !*const ir.Expr {
    const owned_fields = try arena.allocator().alloc(ir.RecordExprField, fields.len);
    @memcpy(owned_fields, fields);
    return exprPtr(arena, .{ .Record = .{
        .fields = owned_fields,
        .ty = ty,
        .layout = layout.structPack(),
    } });
}

fn inlineTopExpr(arena: *std.heap.ArenaAllocator, value: *const ir.Expr) !*const ir.Expr {
    const decls = try arena.allocator().alloc(ir.Decl, 1);
    decls[0] = .{ .Let = .{
        .name = "entrypoint",
        .value = value,
        .ty = exprTy(value.*),
        .layout = exprLayout(value.*),
    } };
    const inlined = try inlineModule(arena, .{ .decls = decls });
    return inlined.decls[0].Let.value;
}

test "inline inlines small functions and enables constant folding" {
    const const_fold = @import("../../src/core/const_fold.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const f_body = try primAddPtr(&arena, try varPtr(&arena, "x"), try intPtr(&arena, 1));
    const f_lambda = try lambdaPtr(&arena, "x", f_body);
    const call = try appPtr(&arena, "f", &.{try intPtr(&arena, 5)}, try intToIntTy(&arena));

    const decls = try arena.allocator().alloc(ir.Decl, 2);
    decls[0] = .{ .Let = .{
        .name = "f",
        .value = f_lambda,
        .ty = exprTy(f_lambda.*),
        .layout = layout.topLevelLambda(),
    } };
    decls[1] = .{ .Let = .{
        .name = "entrypoint",
        .value = call,
        .ty = .Int,
        .layout = layout.intConstant(),
    } };

    const inlined = try inlineModule(&arena, .{ .decls = decls });
    try std.testing.expect(inlined.decls[1].Let.value.* == .Prim);

    const folded = try const_fold.foldModule(&arena, inlined);
    try std.testing.expect(folded.decls[1].Let.value.* == .Constant);
    try std.testing.expectEqual(@as(i64, 6), folded.decls[1].Let.value.Constant.value.Int);
}

test "inline does not inline multiple-expression functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body = try exprPtr(&arena, .{ .Let = .{
        .name = "y",
        .value = try intPtr(&arena, 1),
        .body = try varPtr(&arena, "x"),
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const function = try lambdaPtr(&arena, "x", body);
    const call = try appPtr(&arena, "f", &.{try intPtr(&arena, 5)}, try intToIntTy(&arena));

    const inlined = try inlineTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
        .name = "f",
        .value = function,
        .body = call,
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expect(inlined.* == .Let);
    try std.testing.expect(inlined.Let.body.* == .App);
}

test "inline alpha-renames nested binders to avoid argument capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const inner_params = try arena.allocator().alloc(ir.Param, 1);
    inner_params[0] = .{ .name = "y", .ty = .Int };
    const inner_lambda = try exprPtr(&arena, .{ .Lambda = .{
        .params = inner_params,
        .body = try varPtr(&arena, "x"),
        .ty = try intToIntTy(&arena),
        .layout = layout.closure(),
    } });
    const outer_lambda = try lambdaPtr(&arena, "x", inner_lambda);
    const call = try appPtr(&arena, "f", &.{try varPtr(&arena, "y")}, try intToIntTy(&arena));

    const inlined = try inlineTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
        .name = "f",
        .value = outer_lambda,
        .body = call,
        .ty = exprTy(inner_lambda.*),
        .layout = layout.closure(),
    } }));

    try std.testing.expect(inlined.* == .Let);
    try std.testing.expect(inlined.Let.body.* == .Lambda);
    const lambda = inlined.Let.body.Lambda;
    try std.testing.expect(!std.mem.eql(u8, "y", lambda.params[0].name));
    try std.testing.expect(lambda.body.* == .Var);
    try std.testing.expectEqualStrings("y", lambda.body.Var.name);
}

test "inline skips calls when captured variables would be shadowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const f_body = try primAddPtr(&arena, try varPtr(&arena, "x"), try varPtr(&arena, "y"));
    const f_lambda = try lambdaPtr(&arena, "x", f_body);
    const call = try appPtr(&arena, "f", &.{try intPtr(&arena, 5)}, try intToIntTy(&arena));

    const inner_shadow = try exprPtr(&arena, .{ .Let = .{
        .name = "y",
        .value = try intPtr(&arena, 2),
        .body = call,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const define_f = try exprPtr(&arena, .{ .Let = .{
        .name = "f",
        .value = f_lambda,
        .body = inner_shadow,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const outer_y = try exprPtr(&arena, .{ .Let = .{
        .name = "y",
        .value = try intPtr(&arena, 1),
        .body = define_f,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });

    const inlined = try inlineTopExpr(&arena, outer_y);
    const app = inlined.Let.body.Let.body.Let.body;
    try std.testing.expect(app.* == .App);
}

test "inline accepts string-typed function with app body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const string_length_ty = try arrowTy(&arena, &.{.String}, .Int);
    const f_ty = try arrowTy(&arena, &.{.String}, .Int);
    const f_body = try appPtrWithReturn(
        &arena,
        "String.length",
        &.{try typedVarPtr(&arena, "x", .String)},
        string_length_ty,
        .Int,
    );
    const f_lambda = try lambdaPtrWithTypes(&arena, &.{.{ .name = "x", .ty = .String }}, f_ty, f_body);
    const call = try appPtrWithReturn(&arena, "f", &.{try stringPtr(&arena, "hello")}, f_ty, .Int);

    const inlined = try inlineTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
        .name = "f",
        .value = f_lambda,
        .body = call,
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expect(inlined.* == .Let);
    try std.testing.expect(inlined.Let.body.* == .App);
    const app = inlined.Let.body.App;
    try std.testing.expect(app.callee.* == .Var);
    try std.testing.expectEqualStrings("String.length", app.callee.Var.name);
    try std.testing.expect(app.args[0].* == .Constant);
    try std.testing.expectEqualStrings("hello", app.args[0].Constant.value.String);
}

test "inline accepts forwarding app body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const g_ty = try intToIntTy(&arena);
    const f_ty = try intToIntTy(&arena);
    const f_body = try appPtrWithReturn(&arena, "g", &.{try varPtr(&arena, "x")}, g_ty, .Int);
    const f_lambda = try lambdaPtrWithTypes(&arena, &.{.{ .name = "x", .ty = .Int }}, f_ty, f_body);
    const call = try appPtrWithReturn(&arena, "f", &.{try intPtr(&arena, 7)}, f_ty, .Int);

    const inlined = try inlineTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
        .name = "f",
        .value = f_lambda,
        .body = call,
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expect(inlined.* == .Let);
    try std.testing.expect(inlined.Let.body.* == .App);
    const app = inlined.Let.body.App;
    try std.testing.expect(app.callee.* == .Var);
    try std.testing.expectEqualStrings("g", app.callee.Var.name);
    try std.testing.expect(app.args[0].* == .Constant);
    try std.testing.expectEqual(@as(i64, 7), app.args[0].Constant.value.Int);
}

test "inline skips higher-order calls through function parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const h_param_ty = try intToIntTy(&arena);
    const apply_ty = try arrowTy(&arena, &.{h_param_ty}, .Int);
    const apply_body = try appPtrWithReturn(&arena, "h", &.{try intPtr(&arena, 3)}, h_param_ty, .Int);
    const apply_lambda = try lambdaPtrWithTypes(&arena, &.{.{ .name = "h", .ty = h_param_ty }}, apply_ty, apply_body);
    const g_ty = try intToIntTy(&arena);
    const call = try appPtrWithReturn(&arena, "apply", &.{try typedVarPtr(&arena, "g", g_ty)}, apply_ty, .Int);

    const inlined = try inlineTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
        .name = "apply",
        .value = apply_lambda,
        .body = call,
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expect(inlined.* == .Let);
    try std.testing.expect(inlined.Let.body.* == .App);
    try std.testing.expectEqualStrings("apply", inlined.Let.body.App.callee.Var.name);
}

test "inline skips backend intrinsic helper bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const account_ty = recordTy("account");
    const helper_ty = try arrowTy(&arena, &.{ account_ty, .String }, .Unit);
    const helper_lambda = try lambdaPtrWithTypes(
        &arena,
        &.{ .{ .name = "account", .ty = account_ty }, .{ .name = "bytes", .ty = .String } },
        helper_ty,
        try exprPtr(&arena, .{ .Ctor = .{
            .name = "()",
            .args = &.{},
            .ty = .Unit,
            .layout = layout.unitValue(),
            .tag = 0,
        } }),
    );
    const call = try appPtrWithReturn(
        &arena,
        "set_account_data",
        &.{ try typedVarPtr(&arena, "account", account_ty), try stringPtr(&arena, "data") },
        helper_ty,
        .Unit,
    );

    const inlined = try inlineTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
        .name = "set_account_data",
        .value = helper_lambda,
        .body = call,
        .ty = .Unit,
        .layout = layout.unitValue(),
    } }));

    try std.testing.expect(inlined.* == .Let);
    try std.testing.expect(inlined.Let.body.* == .App);
    try std.testing.expectEqualStrings("set_account_data", inlined.Let.body.App.callee.Var.name);
}

test "inline accepts tuple and record return types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const pair_ty = try tupleTy(&arena, &.{ .Int, .Int });
    const record_ty = recordTy("box");
    const make_pair_ty = try arrowTy(&arena, &.{.Int}, pair_ty);
    const make_box_ty = try arrowTy(&arena, &.{.Int}, record_ty);

    const pair_body = try tuplePtr(&arena, &.{ try varPtr(&arena, "x"), try intPtr(&arena, 1) }, pair_ty);
    const pair_lambda = try lambdaPtrWithTypes(&arena, &.{.{ .name = "x", .ty = .Int }}, make_pair_ty, pair_body);
    const pair_call = try appPtrWithReturn(&arena, "make_pair", &.{try intPtr(&arena, 41)}, make_pair_ty, pair_ty);

    const box_body = try recordPtr(&arena, &.{.{ .name = "value", .value = try varPtr(&arena, "x") }}, record_ty);
    const box_lambda = try lambdaPtrWithTypes(&arena, &.{.{ .name = "x", .ty = .Int }}, make_box_ty, box_body);
    const box_call = try appPtrWithReturn(&arena, "make_box", &.{try intPtr(&arena, 42)}, make_box_ty, record_ty);

    const expr = try exprPtr(&arena, .{ .Let = .{
        .name = "make_pair",
        .value = pair_lambda,
        .body = try exprPtr(&arena, .{ .Let = .{
            .name = "pair",
            .value = pair_call,
            .body = try exprPtr(&arena, .{ .Let = .{
                .name = "make_box",
                .value = box_lambda,
                .body = box_call,
                .ty = record_ty,
                .layout = layout.structPack(),
            } }),
            .ty = record_ty,
            .layout = layout.structPack(),
        } }),
        .ty = record_ty,
        .layout = layout.structPack(),
    } });

    const inlined = try inlineTopExpr(&arena, expr);
    try std.testing.expect(inlined.* == .Let);
    try std.testing.expect(inlined.Let.body.* == .Let);
    try std.testing.expect(inlined.Let.body.Let.value.* == .Tuple);
    try std.testing.expect(inlined.Let.body.Let.body.* == .Let);
    try std.testing.expect(inlined.Let.body.Let.body.Let.body.* == .Record);
}
