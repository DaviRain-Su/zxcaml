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

/// Errors that can occur while lowering the frontend mirror to Core IR.
pub const LowerError = std.mem.Allocator.Error || error{
    UnsupportedNode,
    UnboundVariable,
};

const BindingInfo = struct {
    ty: ir.Ty,
    layout: layout.Layout,
};

const ScopedBinding = struct {
    name: []const u8,
    previous: ?BindingInfo,
};

/// Lowers a frontend typed-tree module into an arena-owned Core IR module.
pub fn lowerModule(arena: *std.heap.ArenaAllocator, module: ttree.Module) LowerError!ir.Module {
    var decls = std.ArrayList(ir.Decl).empty;
    errdefer decls.deinit(arena.allocator());

    var scope = std.StringHashMap(BindingInfo).init(arena.allocator());
    defer scope.deinit();

    for (module.decls) |decl| {
        const lowered = try lowerDecl(arena, &scope, decl);
        try decls.append(arena.allocator(), lowered);
        switch (lowered) {
            .Let => |let_decl| try scope.put(let_decl.name, .{
                .ty = let_decl.ty,
                .layout = let_decl.layout,
            }),
        }
    }

    return .{ .decls = try decls.toOwnedSlice(arena.allocator()) };
}

fn lowerDecl(arena: *std.heap.ArenaAllocator, scope: *std.StringHashMap(BindingInfo), decl: ttree.Decl) LowerError!ir.Decl {
    return switch (decl) {
        .Let => |let_decl| blk: {
            const value = try lowerExprPtr(arena, scope, let_decl.body);
            break :blk .{ .Let = .{
                .name = try arena.allocator().dupe(u8, let_decl.name),
                .value = value,
                .ty = exprTy(value.*),
                .layout = exprLayout(value.*),
            } };
        },
    };
}

fn lowerLambda(arena: *std.heap.ArenaAllocator, scope: *std.StringHashMap(BindingInfo), lambda: ttree.Lambda) LowerError!ir.Lambda {
    var params = std.ArrayList(ir.Param).empty;
    errdefer params.deinit(arena.allocator());

    var inserted_params = std.ArrayList(ScopedBinding).empty;
    defer inserted_params.deinit(arena.allocator());

    for (lambda.params) |param_name| {
        const owned_name = try arena.allocator().dupe(u8, param_name);
        try params.append(arena.allocator(), .{
            .name = owned_name,
            .ty = .Unit,
        });
        const previous = scope.get(owned_name);
        try scope.put(owned_name, .{
            .ty = .Unit,
            .layout = layout.unitValue(),
        });
        try inserted_params.append(arena.allocator(), .{ .name = owned_name, .previous = previous });
    }
    defer {
        var index = inserted_params.items.len;
        while (index > 0) {
            index -= 1;
            const inserted = inserted_params.items[index];
            if (inserted.previous) |binding| {
                scope.getPtr(inserted.name).?.* = binding;
            } else {
                _ = scope.remove(inserted.name);
            }
        }
    }

    const owned_params = try params.toOwnedSlice(arena.allocator());
    const body = try lowerExprPtr(arena, scope, lambda.body.*);
    const lambda_ty = try makeArrowTy(arena, owned_params, exprTy(body.*));

    return .{
        .params = owned_params,
        .body = body,
        .ty = lambda_ty,
        .layout = layout.topLevelLambda(),
    };
}

fn lowerExprPtr(arena: *std.heap.ArenaAllocator, scope: *std.StringHashMap(BindingInfo), expr: ttree.Expr) LowerError!*const ir.Expr {
    const ptr = try arena.allocator().create(ir.Expr);
    ptr.* = try lowerExpr(arena, scope, expr);
    return ptr;
}

fn lowerExpr(arena: *std.heap.ArenaAllocator, scope: *std.StringHashMap(BindingInfo), expr: ttree.Expr) LowerError!ir.Expr {
    return switch (expr) {
        .Lambda => |lambda| .{ .Lambda = try lowerLambda(arena, scope, lambda) },
        .Constant => |constant| .{ .Constant = lowerConstant(constant) },
        .Let => |let_expr| .{ .Let = try lowerLetExpr(arena, scope, let_expr) },
        .Var => |var_ref| .{ .Var = try lowerVar(arena, scope, var_ref) },
    };
}

fn lowerLetExpr(arena: *std.heap.ArenaAllocator, scope: *std.StringHashMap(BindingInfo), let_expr: ttree.LetExpr) LowerError!ir.LetExpr {
    const value = try lowerExprPtr(arena, scope, let_expr.value.*);
    const owned_name = try arena.allocator().dupe(u8, let_expr.name);

    const previous = scope.get(owned_name);
    try scope.put(owned_name, .{
        .ty = exprTy(value.*),
        .layout = exprLayout(value.*),
    });
    defer {
        if (previous) |binding| {
            scope.getPtr(owned_name).?.* = binding;
        } else {
            _ = scope.remove(owned_name);
        }
    }

    const body = try lowerExprPtr(arena, scope, let_expr.body.*);
    return .{
        .name = owned_name,
        .value = value,
        .body = body,
        .ty = exprTy(body.*),
        .layout = exprLayout(body.*),
    };
}

fn lowerVar(arena: *std.heap.ArenaAllocator, scope: *std.StringHashMap(BindingInfo), var_ref: ttree.Var) LowerError!ir.Var {
    const binding = scope.get(var_ref.name) orelse return error.UnboundVariable;
    return .{
        .name = try arena.allocator().dupe(u8, var_ref.name),
        .ty = binding.ty,
        .layout = binding.layout,
    };
}

fn lowerConstant(constant: ttree.Constant) ir.Constant {
    return switch (constant) {
        .Int => |value| .{
            .value = value,
            .ty = .Int,
            .layout = layout.intConstant(),
        },
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

fn exprTy(expr: ir.Expr) ir.Ty {
    return switch (expr) {
        .Lambda => |lambda| lambda.ty,
        .Constant => |constant| constant.ty,
        .Let => |let_expr| let_expr.ty,
        .Var => |var_ref| var_ref.ty,
    };
}

fn exprLayout(expr: ir.Expr) layout.Layout {
    return switch (expr) {
        .Lambda => |lambda| lambda.layout,
        .Constant => |constant| constant.layout,
        .Let => |let_expr| let_expr.layout,
        .Var => |var_ref| var_ref.layout,
    };
}

test "lower M0 constant module through ANF to Core IR" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.2 (module (let entrypoint (lambda (_input) (const-int 0)))))",
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
    try std.testing.expectEqual(@as(i64, 0), constant.value);
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
        "(zxcaml-cir 0.2 (module (let x (const-int 1)) (let entrypoint (lambda (_input) (let y (const-int 7) (var x))))))",
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
