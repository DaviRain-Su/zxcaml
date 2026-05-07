const std = @import("std");

const ir = @import("../src/core/ir.zig");
const layout = @import("../src/core/layout.zig");
const pass = @import("../src/core/anf/secp_recover_direct.zig");

const account_ty: ir.Ty = .{ .Record = .{ .name = "account", .params = &.{} } };

fn exprPtr(arena: *std.heap.ArenaAllocator, expr: ir.Expr) !*const ir.Expr {
    const ptr = try arena.allocator().create(ir.Expr);
    ptr.* = expr;
    return ptr;
}

fn retPtr(arena: *std.heap.ArenaAllocator, ty: ir.Ty) !*const ir.Ty {
    const ptr = try arena.allocator().create(ir.Ty);
    ptr.* = ty;
    return ptr;
}

fn varPtr(arena: *std.heap.ArenaAllocator, name: []const u8, ty: ir.Ty) !*const ir.Expr {
    return exprPtr(arena, .{ .Var = .{
        .name = name,
        .ty = ty,
        .layout = layoutForTy(ty),
    } });
}

fn intPtr(arena: *std.heap.ArenaAllocator, value: i64) !*const ir.Expr {
    return exprPtr(arena, .{ .Constant = .{
        .value = .{ .Int = value },
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
}

fn arrowTy(arena: *std.heap.ArenaAllocator, params: []const ir.Ty, ret: ir.Ty) !ir.Ty {
    const owned_params = try arena.allocator().alloc(ir.Ty, params.len);
    @memcpy(owned_params, params);
    return .{ .Arrow = .{
        .params = owned_params,
        .ret = try retPtr(arena, ret),
    } };
}

fn appPtr(arena: *std.heap.ArenaAllocator, callee_name: []const u8, args: []const *const ir.Expr, ret: ir.Ty) !*const ir.Expr {
    const arg_tys = try arena.allocator().alloc(ir.Ty, args.len);
    for (args, 0..) |arg, index| arg_tys[index] = exprTy(arg.*);
    const owned_args = try arena.allocator().alloc(*const ir.Expr, args.len);
    @memcpy(owned_args, args);
    return exprPtr(arena, .{ .App = .{
        .callee = try varPtr(arena, callee_name, try arrowTy(arena, arg_tys, ret)),
        .args = owned_args,
        .ty = ret,
        .layout = layoutForTy(ret),
    } });
}

fn recoverApp(arena: *std.heap.ArenaAllocator, callee_name: []const u8) !*const ir.Expr {
    const hash = try varPtr(arena, "hash", .String);
    const recid = try varPtr(arena, "recid", .Int);
    const sig = try varPtr(arena, "sig", .String);
    return appPtr(arena, callee_name, &.{ hash, recid, sig }, .String);
}

fn recoverLet(arena: *std.heap.ArenaAllocator, callee_name: []const u8, body: *const ir.Expr) !*const ir.Expr {
    return exprPtr(arena, .{ .Let = .{
        .name = "r",
        .value = try recoverApp(arena, callee_name),
        .body = body,
        .ty = exprTy(body.*),
        .layout = exprLayout(body.*),
    } });
}

fn rewriteTop(arena: *std.heap.ArenaAllocator, expr: *const ir.Expr, externals: []const ir.ExternalDecl) !*const ir.Expr {
    const decls = try arena.allocator().alloc(ir.Decl, 1);
    decls[0] = .{ .Let = .{
        .name = "entry",
        .value = expr,
        .ty = exprTy(expr.*),
        .layout = exprLayout(expr.*),
    } };
    const module = try pass.rewriteSecpRecoverIntoAccountWrite(arena, .{
        .decls = decls,
        .externals = externals,
    });
    return module.decls[0].Let.value;
}

fn expectDirectApp(expr: ir.Expr) !ir.App {
    const app = switch (expr) {
        .App => |value| value,
        else => return error.ExpectedDirectApp,
    };
    const callee = switch (app.callee.*) {
        .Var => |value| value,
        else => return error.ExpectedDirectApp,
    };
    try std.testing.expectEqualStrings(pass.direct_intrinsic_name, callee.name);
    try std.testing.expectEqual(@as(usize, 4), app.args.len);
    return app;
}

fn expectPreservedRecoverLet(expr: ir.Expr) !void {
    const let_expr = switch (expr) {
        .Let => |value| value,
        else => return error.ExpectedRecoverLet,
    };
    try std.testing.expectEqualStrings("r", let_expr.name);
}

fn expectVarName(expr: ir.Expr, expected: []const u8) !void {
    const var_ref = switch (expr) {
        .Var => |value| value,
        else => return error.ExpectedVar,
    };
    try std.testing.expectEqualStrings(expected, var_ref.name);
}

test "positive — set_account_data form rewrites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const acc = try varPtr(&arena, "acc", account_ty);
    const r = try varPtr(&arena, "r", .String);
    const set_data = try appPtr(&arena, "set_account_data", &.{ acc, r }, .Unit);
    const rewritten = try rewriteTop(&arena, try recoverLet(&arena, "Crypto.secp256k1_recover", set_data), &.{});

    const app = try expectDirectApp(rewritten.*);
    try expectVarName(app.args[0].*, "acc");
}

test "positive — AccountFieldSet data form rewrites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const acc = try varPtr(&arena, "acc", account_ty);
    const r = try varPtr(&arena, "r", .String);
    const field_set = try exprPtr(&arena, .{ .AccountFieldSet = .{
        .account_expr = acc,
        .field_name = "data",
        .value = r,
        .ty = .Unit,
        .layout = layout.unitValue(),
    } });
    const externals = [_]ir.ExternalDecl{.{ .name = "recover", .ty = try arrowTy(&arena, &.{ .String, .Int, .String }, .String), .symbol = "sol_secp256k1_recover_alloc" }};
    const rewritten = try rewriteTop(&arena, try recoverLet(&arena, "recover", field_set), &externals);

    const app = try expectDirectApp(rewritten.*);
    try expectVarName(app.args[0].*, "acc");
}

test "negative — multi-use r is preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tuple_items = try arena.allocator().alloc(*const ir.Expr, 2);
    tuple_items[0] = try varPtr(&arena, "r", .String);
    tuple_items[1] = try varPtr(&arena, "r", .String);
    const tuple_ty = try arena.allocator().alloc(ir.Ty, 2);
    tuple_ty[0] = .String;
    tuple_ty[1] = .String;
    const body = try exprPtr(&arena, .{ .Tuple = .{
        .items = tuple_items,
        .ty = .{ .Tuple = tuple_ty },
        .layout = layout.structPack(),
    } });
    const rewritten = try rewriteTop(&arena, try recoverLet(&arena, "Crypto.secp256k1_recover", body), &.{});

    try expectPreservedRecoverLet(rewritten.*);
}

test "negative — unused r and ignore r are preserved" {
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const rewritten = try rewriteTop(&arena, try recoverLet(&arena, "Crypto.secp256k1_recover", try intPtr(&arena, 0)), &.{});
        try expectPreservedRecoverLet(rewritten.*);
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const ignored = try exprPtr(&arena, .{ .Let = .{
            .name = "_",
            .value = try varPtr(&arena, "r", .String),
            .body = try intPtr(&arena, 0),
            .ty = .Int,
            .layout = layout.intConstant(),
        } });
        const rewritten = try rewriteTop(&arena, try recoverLet(&arena, "Crypto.secp256k1_recover", ignored), &.{});
        try expectPreservedRecoverLet(rewritten.*);
    }
}

test "negative — different field lamports is preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const field_set = try exprPtr(&arena, .{ .AccountFieldSet = .{
        .account_expr = try varPtr(&arena, "acc", account_ty),
        .field_name = "lamports",
        .value = try varPtr(&arena, "r", .String),
        .ty = .Unit,
        .layout = layout.unitValue(),
    } });
    const rewritten = try rewriteTop(&arena, try recoverLet(&arena, "Crypto.secp256k1_recover", field_set), &.{});

    try expectPreservedRecoverLet(rewritten.*);
}

test "secp_recover_direct: unrelated App consumer preserves alloc form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const r = try varPtr(&arena, "r", .String);
    const unrelated = try appPtr(&arena, "hash", &.{r}, .String);
    const externals = [_]ir.ExternalDecl{.{ .name = "recover", .ty = try arrowTy(&arena, &.{ .String, .Int, .String }, .String), .symbol = "sol_secp256k1_recover_alloc" }};
    const rewritten = try rewriteTop(&arena, try recoverLet(&arena, "recover", unrelated), &externals);

    const let_expr = switch (rewritten.*) {
        .Let => |value| value,
        else => return error.ExpectedRecoverLet,
    };
    try std.testing.expectEqualStrings("r", let_expr.name);

    const recover_app = switch (let_expr.value.*) {
        .App => |value| value,
        else => return error.ExpectedRecoverLet,
    };
    const recover_callee = switch (recover_app.callee.*) {
        .Var => |value| value,
        else => return error.ExpectedRecoverLet,
    };
    try std.testing.expectEqualStrings("recover", recover_callee.name);

    const unrelated_app = switch (let_expr.body.*) {
        .App => |value| value,
        else => return error.ExpectedDirectApp,
    };
    const unrelated_callee = switch (unrelated_app.callee.*) {
        .Var => |value| value,
        else => return error.ExpectedDirectApp,
    };
    try std.testing.expectEqualStrings("hash", unrelated_callee.name);
    try std.testing.expectEqual(@as(usize, 1), unrelated_app.args.len);
    try expectVarName(unrelated_app.args[0].*, "r");
}

test "negative — different syscall producer is preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const acc = try varPtr(&arena, "acc", account_ty);
    const r = try varPtr(&arena, "r", .String);
    const set_data = try appPtr(&arena, "set_account_data", &.{ acc, r }, .Unit);
    const rewritten = try rewriteTop(&arena, try recoverLet(&arena, "Crypto.sha256", set_data), &.{});

    try expectPreservedRecoverLet(rewritten.*);
}

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
        .Tuple => |tuple| tuple.ty,
        .TupleProj => |tuple_proj| tuple_proj.ty,
        .Record => |record| record.ty,
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
        .Tuple => |tuple| tuple.layout,
        .TupleProj => |tuple_proj| tuple_proj.layout,
        .Record => |record| record.layout,
        .RecordField => |record_field| record_field.layout,
        .RecordUpdate => |record_update| record_update.layout,
        .AccountFieldSet => |field_set| field_set.layout,
    };
}

fn layoutForTy(ty: ir.Ty) layout.Layout {
    return switch (ty) {
        .Int, .Bool => layout.intConstant(),
        .Unit => layout.unitValue(),
        .String => layout.defaultFor(.StringLiteral),
        .Arrow => layout.closure(),
        .Tuple, .Record => layout.structPack(),
        .Adt, .Var => layout.defaultFor(.Aggregate),
    };
}
