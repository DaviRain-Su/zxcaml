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
};

/// Lowers a frontend typed-tree module into an arena-owned Core IR module.
pub fn lowerModule(arena: *std.heap.ArenaAllocator, module: ttree.Module) LowerError!ir.Module {
    var decls = std.ArrayList(ir.Decl).empty;
    errdefer decls.deinit(arena.allocator());

    for (module.decls) |decl| {
        try decls.append(arena.allocator(), try lowerDecl(arena, decl));
    }

    return .{ .decls = try decls.toOwnedSlice(arena.allocator()) };
}

fn lowerDecl(arena: *std.heap.ArenaAllocator, decl: ttree.Decl) LowerError!ir.Decl {
    return switch (decl) {
        .Let => |let_decl| blk: {
            const lambda = switch (let_decl.body) {
                .Lambda => |value| value,
                else => return error.UnsupportedNode,
            };

            break :blk .{ .Let = .{
                .name = try arena.allocator().dupe(u8, let_decl.name),
                .lambda = try lowerLambda(arena, lambda),
            } };
        },
    };
}

fn lowerLambda(arena: *std.heap.ArenaAllocator, lambda: ttree.Lambda) LowerError!ir.Lambda {
    var params = std.ArrayList(ir.Param).empty;
    errdefer params.deinit(arena.allocator());

    for (lambda.params) |param_name| {
        try params.append(arena.allocator(), .{
            .name = try arena.allocator().dupe(u8, param_name),
            .ty = .Unit,
        });
    }

    const owned_params = try params.toOwnedSlice(arena.allocator());
    const body = try lowerExpr(lambda.body.*);
    const lambda_ty = try makeArrowTy(arena, owned_params, exprTy(body));

    return .{
        .params = owned_params,
        .body = body,
        .ty = lambda_ty,
        .layout = layout.topLevelLambda(),
    };
}

fn lowerExpr(expr: ttree.Expr) LowerError!ir.Expr {
    return switch (expr) {
        .Constant => |constant| .{ .Constant = lowerConstant(constant) },
        else => error.UnsupportedNode,
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
        .Constant => |constant| constant.ty,
    };
}

test "lower M0 constant module through ANF to Core IR" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.1 (module (let entrypoint (lambda (_input) (const-int 0)))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);

    const let_decl = switch (module.decls[0]) {
        .Let => |value| value,
    };
    try std.testing.expectEqualStrings("entrypoint", let_decl.name);
    try std.testing.expectEqual(layout.Layout{ .region = .Arena, .repr = .Flat }, let_decl.lambda.layout);
    try std.testing.expectEqual(@as(usize, 1), let_decl.lambda.params.len);
    try std.testing.expectEqualStrings("_input", let_decl.lambda.params[0].name);

    const constant = switch (let_decl.lambda.body) {
        .Constant => |value| value,
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
