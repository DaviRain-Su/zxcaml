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

const ScopedBinding = struct {
    name: []const u8,
    previous: ?BindingInfo,
};

const LowerContext = struct {
    scope: std.StringHashMap(BindingInfo),
    next_temp: usize = 0,
};

/// Lowers a frontend typed-tree module into an arena-owned Core IR module.
pub fn lowerModule(arena: *std.heap.ArenaAllocator, module: ttree.Module) LowerError!ir.Module {
    var decls = std.ArrayList(ir.Decl).empty;
    errdefer decls.deinit(arena.allocator());

    var ctx: LowerContext = .{ .scope = std.StringHashMap(BindingInfo).init(arena.allocator()) };
    defer ctx.scope.deinit();

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

    return .{ .decls = try decls.toOwnedSlice(arena.allocator()) };
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
        const param_ty: ir.Ty = if (std.mem.startsWith(u8, param_name, "_")) .Unit else .Int;
        const param_layout = if (std.mem.startsWith(u8, param_name, "_")) layout.unitValue() else layout.intConstant();
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
    const ptr = try arena.allocator().create(ir.Expr);
    ptr.* = try lowerExpr(arena, ctx, expr);
    return ptr;
}

fn lowerExpr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, expr: ttree.Expr) LowerError!ir.Expr {
    return switch (expr) {
        .Lambda => |lambda| .{ .Lambda = try lowerLambda(arena, ctx, lambda) },
        .Constant => |constant| .{ .Constant = try lowerConstant(arena, constant) },
        .App => |app| try lowerApp(arena, ctx, app),
        .Let => |let_expr| .{ .Let = try lowerLetExpr(arena, ctx, let_expr) },
        .If => |if_expr| try lowerIf(arena, ctx, if_expr),
        .Prim => |prim| try lowerPrim(arena, ctx, prim),
        .Var => |var_ref| .{ .Var = try lowerVar(arena, ctx, var_ref) },
        .Ctor => |ctor_expr| try lowerCtor(arena, ctx, ctor_expr),
        .Match => |match_expr| try lowerMatch(arena, ctx, match_expr),
    };
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

    const value = try lowerExprPtr(arena, ctx, let_expr.value.*);
    if (!let_expr.is_rec) {
        try ctx.scope.put(owned_name, .{
            .ty = exprTy(value.*),
            .layout = exprLayout(value.*),
        });
    }
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
    const cond = try lowerExprPtr(arena, ctx, if_expr.cond.*);
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

fn lowerCtor(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, ctor_expr: ttree.Ctor) LowerError!ir.Expr {
    try validateCtor(ctor_expr.name, ctor_expr.args.len);

    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    var wrappers = std.ArrayList(struct {
        name: []const u8,
        value: *const ir.Expr,
    }).empty;
    errdefer wrappers.deinit(arena.allocator());

    for (ctor_expr.args) |arg| {
        if (isAtomicTtree(arg)) {
            try args.append(arena.allocator(), try lowerExprPtr(arena, ctx, arg));
        } else {
            const value = try lowerExprPtr(arena, ctx, arg);
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
    const ctor_ty = try ctorTy(arena, ctor_expr.name, owned_args);
    const ctor_layout = layout.ctor(owned_args.len);
    var current = try arena.allocator().create(ir.Expr);
    current.* = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, ctor_expr.name),
        .args = owned_args,
        .ty = ctor_ty,
        .layout = ctor_layout,
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

    const scrutinee_value = try lowerExprPtr(arena, ctx, match_expr.scrutinee.*);
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
        const body = try lowerExprPtr(arena, ctx, arm.body.*);
        try arms.append(arena.allocator(), .{
            .pattern = lowered_pattern,
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
    };
}

fn lowerCtorPattern(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    ctor_pattern: ttree.CtorPattern,
    matched_ty: ir.Ty,
    inserted: *std.ArrayList(ScopedBinding),
) LowerError!ir.Pattern {
    try validateCtor(ctor_pattern.name, ctor_pattern.args.len);
    const payload_ty = try ctorPatternPayloadTy(ctor_pattern.name, matched_ty);
    const payload_layout = layout.intConstant();

    var args = std.ArrayList(ir.Pattern).empty;
    errdefer args.deinit(arena.allocator());
    for (ctor_pattern.args) |arg| {
        switch (arg) {
            .Ctor => return error.UnsupportedPattern,
            .Wildcard, .Var => try args.append(arena.allocator(), try lowerPattern(arena, ctx, arg, payload_ty, payload_layout, inserted)),
        }
    }

    return .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, ctor_pattern.name),
        .args = try args.toOwnedSlice(arena.allocator()),
    } };
}

fn validateCtor(name: []const u8, arg_count: usize) LowerError!void {
    if (std.mem.eql(u8, name, "None")) {
        if (arg_count != 0) return error.UnsupportedCtorArity;
        return;
    }
    if (std.mem.eql(u8, name, "Some") or std.mem.eql(u8, name, "Ok") or std.mem.eql(u8, name, "Error")) {
        if (arg_count != 1) return error.UnsupportedCtorArity;
        return;
    }
    return error.UnsupportedCtor;
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

fn ctorPatternPayloadTy(name: []const u8, matched_ty: ir.Ty) LowerError!ir.Ty {
    const adt = switch (matched_ty) {
        .Adt => |value| value,
        else => return error.UnsupportedPattern,
    };

    if (std.mem.eql(u8, name, "Some")) {
        if (adt.params.len != 1) return error.UnsupportedPattern;
        return adt.params[0];
    }
    if (std.mem.eql(u8, name, "Ok")) {
        if (adt.params.len != 2) return error.UnsupportedPattern;
        return adt.params[0];
    }
    if (std.mem.eql(u8, name, "Error")) {
        if (adt.params.len != 2) return error.UnsupportedPattern;
        return adt.params[1];
    }
    if (std.mem.eql(u8, name, "None")) return .Unit;
    return error.UnsupportedPattern;
}

fn ctorTy(arena: *std.heap.ArenaAllocator, name: []const u8, args: []const *const ir.Expr) LowerError!ir.Ty {
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
        .App => |app| app.ty,
        .Let => |let_expr| let_expr.ty,
        .If => |if_expr| if_expr.ty,
        .Prim => |prim| prim.ty,
        .Var => |var_ref| var_ref.ty,
        .Ctor => |ctor_expr| ctor_expr.ty,
        .Match => |match_expr| match_expr.ty,
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
