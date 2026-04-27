//! ArenaStrategy lowers Core IR into the P1 arena-threaded Lowered IR.
//!
//! RESPONSIBILITIES:
//! - Implement the only P1 lowering strategy described by ADR-007.
//! - Preserve M0 integer constants while moving backend input to Lowered IR.
//! - Mark every lowered function as taking `arena: *Arena` implicitly first.

const std = @import("std");
const ir = @import("../core/ir.zig");
const lir = @import("lir.zig");
const strategy = @import("strategy.zig");

/// M0 ArenaStrategy implementation over an allocator-owned output arena.
pub const ArenaStrategy = struct {
    allocator: std.mem.Allocator,

    const vtable: strategy.VTable = .{
        .lowerModule = lowerBackend,
    };

    /// Returns this strategy behind the lowering extension-point trait.
    pub fn loweringStrategy(self: *ArenaStrategy) strategy.LoweringStrategy {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

/// Errors produced while lowering unsupported M0 Core IR shapes.
pub const LowerError = std.mem.Allocator.Error || error{
    EntrypointNotFound,
    UnsupportedDecl,
    UnsupportedExpr,
    UnsupportedEntrypoint,
};

const CaptureSet = []const ir.Param;

const LowerContext = struct {
    bound: std.StringHashMap(ir.Ty),
    rec_captures: std.StringHashMap(CaptureSet),

    fn init(allocator: std.mem.Allocator) LowerContext {
        return .{
            .bound = std.StringHashMap(ir.Ty).init(allocator),
            .rec_captures = std.StringHashMap(CaptureSet).init(allocator),
        };
    }

    fn deinit(self: *LowerContext) void {
        self.rec_captures.deinit();
        self.bound.deinit();
    }
};

const BindingSnapshot = struct {
    name: []const u8,
    previous: ?ir.Ty,
};

/// Lowers a Core IR module with the P1 arena strategy.
pub fn lowerModule(allocator: std.mem.Allocator, module: ir.Module) LowerError!lir.LModule {
    const entrypoint_index = findEntrypointIndex(module) orelse return error.EntrypointNotFound;
    var functions = std.ArrayList(lir.LFunc).empty;
    errdefer functions.deinit(allocator);
    for (module.decls, 0..) |decl, index| {
        if (index == entrypoint_index) continue;
        const let_decl = switch (decl) {
            .Let => |value| value,
        };
        switch (let_decl.value.*) {
            .Lambda => |lambda| {
                try functions.append(allocator, try lowerFunction(allocator, let_decl.name, lambda, &.{}));
                try collectNestedFunctionsInLambda(allocator, lambda, &functions);
            },
            else => {},
        }
    }
    const entrypoint = switch (module.decls[entrypoint_index]) {
        .Let => |value| value,
    };
    const entry_lambda = switch (entrypoint.value.*) {
        .Lambda => |lambda| lambda,
        else => return error.UnsupportedEntrypoint,
    };
    try collectNestedFunctionsInLambda(allocator, entry_lambda, &functions);
    return .{
        .entrypoint = try lowerEntrypointLet(allocator, module, entrypoint_index),
        .functions = try functions.toOwnedSlice(allocator),
    };
}

fn lowerBackend(ptr: *anyopaque, module: ir.Module) anyerror!lir.LModule {
    const self: *ArenaStrategy = @ptrCast(@alignCast(ptr));
    return lowerModule(self.allocator, module);
}

fn findEntrypointIndex(module: ir.Module) ?usize {
    for (module.decls, 0..) |decl, index| {
        switch (decl) {
            .Let => |let_decl| {
                if (std.mem.eql(u8, let_decl.name, "entrypoint")) return index;
            },
        }
    }
    return null;
}

fn lowerEntrypointLet(allocator: std.mem.Allocator, module: ir.Module, entrypoint_index: usize) LowerError!lir.LFunc {
    const let_decl = switch (module.decls[entrypoint_index]) {
        .Let => |value| value,
    };
    const lambda = switch (let_decl.value.*) {
        .Lambda => |value| value,
        else => return error.UnsupportedEntrypoint,
    };

    var ctx = LowerContext.init(allocator);
    defer ctx.deinit();
    for (lambda.params) |param| {
        try ctx.bound.put(param.name, param.ty);
    }
    var top_index: usize = 0;
    while (top_index < entrypoint_index) : (top_index += 1) {
        const top_level = switch (module.decls[top_index]) {
            .Let => |value| value,
        };
        switch (top_level.value.*) {
            .Lambda => {},
            else => try ctx.bound.put(top_level.name, top_level.ty),
        }
    }

    var body = try lowerExprPtrWithContext(allocator, lambda.body.*, &ctx);
    var index = entrypoint_index;
    while (index > 0) {
        index -= 1;
        const top_level = switch (module.decls[index]) {
            .Let => |value| value,
        };
        switch (top_level.value.*) {
            .Lambda => continue,
            else => {},
        }
        const let_body = try allocator.create(lir.LExpr);
        let_body.* = body.*;
        body = try allocator.create(lir.LExpr);
        body.* = .{ .Let = .{
            .name = try allocator.dupe(u8, top_level.name),
            .value = try lowerExprPtr(allocator, top_level.value.*),
            .body = let_body,
            .is_rec = top_level.is_rec,
        } };
    }

    return .{
        .name = try allocator.dupe(u8, let_decl.name),
        .body = body.*,
        .calling_convention = .ArenaThreaded,
        .source_span = .unavailable,
    };
}

fn lowerFunction(allocator: std.mem.Allocator, name: []const u8, lambda: ir.Lambda, captures: CaptureSet) LowerError!lir.LFunc {
    var ctx = LowerContext.init(allocator);
    defer ctx.deinit();
    try ctx.rec_captures.put(name, captures);
    for (captures) |capture| {
        try ctx.bound.put(capture.name, capture.ty);
    }
    for (lambda.params) |param| {
        try ctx.bound.put(param.name, param.ty);
    }

    const params = try concatParams(allocator, captures, lambda.params);
    return .{
        .name = try allocator.dupe(u8, name),
        .params = try lowerParams(allocator, params),
        .body = (try lowerExprPtrWithContext(allocator, lambda.body.*, &ctx)).*,
        .calling_convention = .ArenaThreaded,
        .source_span = .unavailable,
    };
}

fn collectNestedFunctionsInLambda(allocator: std.mem.Allocator, lambda: ir.Lambda, functions: *std.ArrayList(lir.LFunc)) LowerError!void {
    var bound = std.StringHashMap(ir.Ty).init(allocator);
    defer bound.deinit();
    for (lambda.params) |param| {
        try bound.put(param.name, param.ty);
    }
    try collectNestedFunctions(allocator, lambda.body.*, functions, &bound);
}

fn collectNestedFunctions(allocator: std.mem.Allocator, expr: ir.Expr, functions: *std.ArrayList(lir.LFunc), bound: *std.StringHashMap(ir.Ty)) LowerError!void {
    switch (expr) {
        .Lambda => |lambda| {
            const snapshots = try pushParams(allocator, bound, lambda.params);
            defer restoreBound(bound, snapshots);
            try collectNestedFunctions(allocator, lambda.body.*, functions, bound);
        },
        .Let => |let_expr| {
            switch (let_expr.value.*) {
                .Lambda => |lambda| {
                    if (let_expr.is_rec) {
                        const captures = try recursiveCaptures(allocator, let_expr.name, lambda, bound);
                        try functions.append(allocator, try lowerFunction(allocator, let_expr.name, lambda, captures));
                    }
                    const snapshots = try pushParams(allocator, bound, lambda.params);
                    defer restoreBound(bound, snapshots);
                    try collectNestedFunctions(allocator, lambda.body.*, functions, bound);
                },
                else => try collectNestedFunctions(allocator, let_expr.value.*, functions, bound),
            }
            const previous = bound.get(let_expr.name);
            try bound.put(let_expr.name, exprTy(let_expr.value.*));
            defer restoreSingleBound(bound, let_expr.name, previous);
            try collectNestedFunctions(allocator, let_expr.body.*, functions, bound);
        },
        .If => |if_expr| {
            try collectNestedFunctions(allocator, if_expr.cond.*, functions, bound);
            try collectNestedFunctions(allocator, if_expr.then_branch.*, functions, bound);
            try collectNestedFunctions(allocator, if_expr.else_branch.*, functions, bound);
        },
        .Prim => |prim| for (prim.args) |arg| try collectNestedFunctions(allocator, arg.*, functions, bound),
        .App => |app| {
            try collectNestedFunctions(allocator, app.callee.*, functions, bound);
            for (app.args) |arg| try collectNestedFunctions(allocator, arg.*, functions, bound);
        },
        .Ctor => |ctor| for (ctor.args) |arg| try collectNestedFunctions(allocator, arg.*, functions, bound),
        .Match => |match_expr| {
            try collectNestedFunctions(allocator, match_expr.scrutinee.*, functions, bound);
            for (match_expr.arms) |arm| try collectNestedFunctions(allocator, arm.body.*, functions, bound);
        },
        .Constant, .Var => {},
    }
}

fn lowerExprPtr(allocator: std.mem.Allocator, expr: ir.Expr) LowerError!*lir.LExpr {
    var ctx = LowerContext.init(allocator);
    defer ctx.deinit();
    return lowerExprPtrWithContext(allocator, expr, &ctx);
}

fn lowerExprPtrWithContext(allocator: std.mem.Allocator, expr: ir.Expr, ctx: *LowerContext) LowerError!*lir.LExpr {
    const ptr = try allocator.create(lir.LExpr);
    ptr.* = try lowerExpr(allocator, expr, ctx);
    return ptr;
}

fn lowerExpr(allocator: std.mem.Allocator, expr: ir.Expr, ctx: *LowerContext) LowerError!lir.LExpr {
    return switch (expr) {
        .Constant => |constant| .{ .Constant = switch (constant.value) {
            .Int => |value| .{ .Int = value },
            .String => |value| .{ .String = try allocator.dupe(u8, value) },
        } },
        .App => |app| try lowerApp(allocator, app, ctx),
        .Let => |let_expr| blk: {
            if (let_expr.is_rec) {
                switch (let_expr.value.*) {
                    .Lambda => |lambda| {
                        const captures = try recursiveCaptures(allocator, let_expr.name, lambda, &ctx.bound);
                        const previous_captures = ctx.rec_captures.get(let_expr.name);
                        try ctx.rec_captures.put(let_expr.name, captures);
                        defer restoreRecCaptures(&ctx.rec_captures, let_expr.name, previous_captures);
                        break :blk (try lowerExprPtrWithContext(allocator, let_expr.body.*, ctx)).*;
                    },
                    else => {},
                }
            }
            const value = try lowerExprPtrWithContext(allocator, let_expr.value.*, ctx);
            const previous = ctx.bound.get(let_expr.name);
            try ctx.bound.put(let_expr.name, exprTy(let_expr.value.*));
            defer restoreSingleBound(&ctx.bound, let_expr.name, previous);
            break :blk .{ .Let = .{
                .name = try allocator.dupe(u8, let_expr.name),
                .value = value,
                .body = try lowerExprPtrWithContext(allocator, let_expr.body.*, ctx),
                .is_rec = let_expr.is_rec,
            } };
        },
        .If => |if_expr| .{ .If = .{
            .cond = try lowerExprPtrWithContext(allocator, if_expr.cond.*, ctx),
            .then_branch = try lowerExprPtrWithContext(allocator, if_expr.then_branch.*, ctx),
            .else_branch = try lowerExprPtrWithContext(allocator, if_expr.else_branch.*, ctx),
        } },
        .Prim => |prim| .{ .Prim = .{
            .op = lowerPrimOp(prim.op),
            .args = try lowerExprPtrs(allocator, prim.args, ctx),
        } },
        .Var => |var_ref| .{ .Var = .{ .name = try allocator.dupe(u8, var_ref.name) } },
        .Ctor => |ctor_expr| .{ .Ctor = .{
            .name = try allocator.dupe(u8, ctor_expr.name),
            .args = try lowerExprPtrs(allocator, ctor_expr.args, ctx),
            .ty = try lowerTy(allocator, ctor_expr.ty),
            .layout = ctor_expr.layout,
        } },
        .Match => |match_expr| .{ .Match = .{
            .scrutinee = try lowerExprPtrWithContext(allocator, match_expr.scrutinee.*, ctx),
            .arms = try lowerArms(allocator, match_expr.arms, ctx),
        } },
        .Lambda => error.UnsupportedExpr,
    };
}

fn lowerApp(allocator: std.mem.Allocator, app: ir.App, ctx: *LowerContext) LowerError!lir.LExpr {
    var args = std.ArrayList(*const lir.LExpr).empty;
    errdefer args.deinit(allocator);

    switch (app.callee.*) {
        .Var => |callee| if (ctx.rec_captures.get(callee.name)) |captures| {
            for (captures) |capture| {
                const capture_expr = try allocator.create(lir.LExpr);
                capture_expr.* = .{ .Var = .{ .name = try allocator.dupe(u8, capture.name) } };
                try args.append(allocator, capture_expr);
            }
        },
        else => {},
    }
    for (app.args) |arg| {
        try args.append(allocator, try lowerExprPtrWithContext(allocator, arg.*, ctx));
    }

    return .{ .App = .{
        .callee = try lowerExprPtrWithContext(allocator, app.callee.*, ctx),
        .args = try args.toOwnedSlice(allocator),
    } };
}

fn recursiveCaptures(
    allocator: std.mem.Allocator,
    self_name: []const u8,
    lambda: ir.Lambda,
    bound: *std.StringHashMap(ir.Ty),
) LowerError!CaptureSet {
    var excluded = std.StringHashMap(void).init(allocator);
    defer excluded.deinit();
    try excluded.put(self_name, {});
    for (lambda.params) |param| {
        try excluded.put(param.name, {});
    }

    var captures = std.ArrayList(ir.Param).empty;
    errdefer captures.deinit(allocator);
    try collectCaptures(allocator, lambda.body.*, bound, &excluded, &captures);
    return captures.toOwnedSlice(allocator);
}

fn collectCaptures(
    allocator: std.mem.Allocator,
    expr: ir.Expr,
    bound: *std.StringHashMap(ir.Ty),
    excluded: *std.StringHashMap(void),
    captures: *std.ArrayList(ir.Param),
) LowerError!void {
    switch (expr) {
        .Var => |var_ref| {
            if (excluded.contains(var_ref.name)) return;
            const ty = bound.get(var_ref.name) orelse return;
            if (containsCapture(captures.items, var_ref.name)) return;
            try captures.append(allocator, .{
                .name = try allocator.dupe(u8, var_ref.name),
                .ty = ty,
            });
        },
        .Lambda => |lambda| {
            const snapshots = try pushExcludedParams(allocator, excluded, lambda.params);
            defer restoreExcluded(excluded, snapshots);
            try collectCaptures(allocator, lambda.body.*, bound, excluded, captures);
        },
        .Let => |let_expr| {
            try collectCaptures(allocator, let_expr.value.*, bound, excluded, captures);
            const previous = excluded.get(let_expr.name);
            try excluded.put(let_expr.name, {});
            defer restoreSingleExcluded(excluded, let_expr.name, previous != null);
            try collectCaptures(allocator, let_expr.body.*, bound, excluded, captures);
        },
        .App => |app| {
            try collectCaptures(allocator, app.callee.*, bound, excluded, captures);
            for (app.args) |arg| try collectCaptures(allocator, arg.*, bound, excluded, captures);
        },
        .If => |if_expr| {
            try collectCaptures(allocator, if_expr.cond.*, bound, excluded, captures);
            try collectCaptures(allocator, if_expr.then_branch.*, bound, excluded, captures);
            try collectCaptures(allocator, if_expr.else_branch.*, bound, excluded, captures);
        },
        .Prim => |prim| for (prim.args) |arg| try collectCaptures(allocator, arg.*, bound, excluded, captures),
        .Ctor => |ctor| for (ctor.args) |arg| try collectCaptures(allocator, arg.*, bound, excluded, captures),
        .Match => |match_expr| {
            try collectCaptures(allocator, match_expr.scrutinee.*, bound, excluded, captures);
            for (match_expr.arms) |arm| {
                try collectCaptures(allocator, arm.body.*, bound, excluded, captures);
            }
        },
        .Constant => {},
    }
}

fn containsCapture(captures: []const ir.Param, name: []const u8) bool {
    for (captures) |capture| {
        if (std.mem.eql(u8, capture.name, name)) return true;
    }
    return false;
}

fn concatParams(allocator: std.mem.Allocator, captures: CaptureSet, params: []const ir.Param) LowerError![]const ir.Param {
    const out = try allocator.alloc(ir.Param, captures.len + params.len);
    @memcpy(out[0..captures.len], captures);
    @memcpy(out[captures.len..], params);
    return out;
}

fn pushParams(allocator: std.mem.Allocator, bound: *std.StringHashMap(ir.Ty), params: []const ir.Param) LowerError![]const BindingSnapshot {
    const snapshots = try allocator.alloc(BindingSnapshot, params.len);
    for (params, 0..) |param, index| {
        snapshots[index] = .{ .name = param.name, .previous = bound.get(param.name) };
        try bound.put(param.name, param.ty);
    }
    return snapshots;
}

fn restoreBound(bound: *std.StringHashMap(ir.Ty), snapshots: []const BindingSnapshot) void {
    var index = snapshots.len;
    while (index > 0) {
        index -= 1;
        restoreSingleBound(bound, snapshots[index].name, snapshots[index].previous);
    }
}

fn restoreSingleBound(bound: *std.StringHashMap(ir.Ty), name: []const u8, previous: ?ir.Ty) void {
    if (previous) |ty| {
        bound.getPtr(name).?.* = ty;
    } else {
        _ = bound.remove(name);
    }
}

fn restoreRecCaptures(map: *std.StringHashMap(CaptureSet), name: []const u8, previous: ?CaptureSet) void {
    if (previous) |captures| {
        map.getPtr(name).?.* = captures;
    } else {
        _ = map.remove(name);
    }
}

const ExcludedSnapshot = struct {
    name: []const u8,
    existed: bool,
};

fn pushExcludedParams(allocator: std.mem.Allocator, excluded: *std.StringHashMap(void), params: []const ir.Param) LowerError![]const ExcludedSnapshot {
    const snapshots = try allocator.alloc(ExcludedSnapshot, params.len);
    for (params, 0..) |param, index| {
        snapshots[index] = .{ .name = param.name, .existed = excluded.contains(param.name) };
        try excluded.put(param.name, {});
    }
    return snapshots;
}

fn restoreExcluded(excluded: *std.StringHashMap(void), snapshots: []const ExcludedSnapshot) void {
    var index = snapshots.len;
    while (index > 0) {
        index -= 1;
        restoreSingleExcluded(excluded, snapshots[index].name, snapshots[index].existed);
    }
}

fn restoreSingleExcluded(excluded: *std.StringHashMap(void), name: []const u8, existed: bool) void {
    if (!existed) _ = excluded.remove(name);
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
        .Ctor => |ctor| ctor.ty,
        .Match => |match_expr| match_expr.ty,
    };
}

fn lowerParams(allocator: std.mem.Allocator, params: []const ir.Param) LowerError![]const lir.LParam {
    const lowered = try allocator.alloc(lir.LParam, params.len);
    for (params, 0..) |param, index| {
        lowered[index] = .{
            .name = try allocator.dupe(u8, param.name),
            .ty = try lowerTy(allocator, param.ty),
        };
    }
    return lowered;
}

fn lowerPrimOp(op: ir.PrimOp) lir.LPrimOp {
    return switch (op) {
        .Add => .Add,
        .Sub => .Sub,
        .Mul => .Mul,
        .Div => .Div,
        .Mod => .Mod,
        .Eq => .Eq,
        .Ne => .Ne,
        .Lt => .Lt,
        .Le => .Le,
        .Gt => .Gt,
        .Ge => .Ge,
    };
}

fn lowerArms(allocator: std.mem.Allocator, arms: []const ir.Arm, ctx: *LowerContext) LowerError![]const lir.LArm {
    const lowered = try allocator.alloc(lir.LArm, arms.len);
    for (arms, 0..) |arm, index| {
        lowered[index] = .{
            .pattern = try lowerPattern(allocator, arm.pattern),
            .body = try lowerExprPtrWithContext(allocator, arm.body.*, ctx),
        };
    }
    return lowered;
}

fn lowerPattern(allocator: std.mem.Allocator, pattern: ir.Pattern) LowerError!lir.LPattern {
    return switch (pattern) {
        .Wildcard => .Wildcard,
        .Var => |var_pattern| .{ .Var = try allocator.dupe(u8, var_pattern.name) },
        .Ctor => |ctor_pattern| .{ .Ctor = .{
            .name = try allocator.dupe(u8, ctor_pattern.name),
            .args = try lowerPatterns(allocator, ctor_pattern.args),
        } },
    };
}

fn lowerPatterns(allocator: std.mem.Allocator, patterns: []const ir.Pattern) LowerError![]const lir.LPattern {
    const lowered = try allocator.alloc(lir.LPattern, patterns.len);
    for (patterns, 0..) |pattern, index| {
        lowered[index] = try lowerPattern(allocator, pattern);
    }
    return lowered;
}

fn lowerExprPtrs(allocator: std.mem.Allocator, exprs: []const *const ir.Expr, ctx: *LowerContext) LowerError![]const *const lir.LExpr {
    const lowered = try allocator.alloc(*const lir.LExpr, exprs.len);
    for (exprs, 0..) |expr, index| {
        lowered[index] = try lowerExprPtrWithContext(allocator, expr.*, ctx);
    }
    return lowered;
}

fn lowerTy(allocator: std.mem.Allocator, ty: ir.Ty) LowerError!lir.LTy {
    return switch (ty) {
        .Int => .Int,
        .Bool => .Bool,
        .Unit => .Unit,
        .String => .String,
        .Arrow => error.UnsupportedExpr,
        .Adt => |adt| .{ .Adt = .{
            .name = try allocator.dupe(u8, adt.name),
            .params = try lowerTySlice(allocator, adt.params),
        } },
    };
}

fn lowerTySlice(allocator: std.mem.Allocator, tys: []const ir.Ty) LowerError![]const lir.LTy {
    const lowered = try allocator.alloc(lir.LTy, tys.len);
    for (tys, 0..) |ty, index| {
        lowered[index] = try lowerTy(allocator, ty);
    }
    return lowered;
}

fn makeExpr(comptime expr: ir.Expr) *const ir.Expr {
    const S = struct {
        const value = expr;
    };
    return &S.value;
}

test "ArenaStrategy lowers M0 entrypoint constant and records arena threading" {
    const decls = [_]ir.Decl{.{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Constant = .{
                .value = .{ .Int = 0 },
                .ty = .Int,
                .layout = @import("../core/layout.zig").intConstant(),
            } }),
            .ty = .Unit,
            .layout = @import("../core/layout.zig").topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = @import("../core/layout.zig").topLevelLambda(),
    } }};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var impl: ArenaStrategy = .{ .allocator = arena.allocator() };
    const lowered = try impl.loweringStrategy().lowerModule(.{ .decls = &decls });

    try std.testing.expectEqualStrings("entrypoint", lowered.entrypoint.name);
    try std.testing.expectEqual(lir.CallingConvention.ArenaThreaded, lowered.entrypoint.calling_convention);
    const constant = switch (lowered.entrypoint.body) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (constant) {
        .Int => |value| try std.testing.expectEqual(@as(i64, 0), value),
        .String => return error.TestUnexpectedResult,
    }
}

test "ArenaStrategy wraps previous top-level lets around entrypoint body" {
    const layout = @import("../core/layout.zig");
    const decls = [_]ir.Decl{
        .{ .Let = .{
            .name = "x",
            .value = makeExpr(.{ .Constant = .{
                .value = .{ .Int = 1 },
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Int,
            .layout = layout.intConstant(),
        } },
        .{ .Let = .{
            .name = "entrypoint",
            .value = makeExpr(.{ .Lambda = .{
                .params = &.{},
                .body = makeExpr(.{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } }),
                .ty = .Unit,
                .layout = layout.topLevelLambda(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lowered = try lowerModule(arena.allocator(), .{ .decls = &decls });
    const top_let = switch (lowered.entrypoint.body) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("x", top_let.name);
    _ = switch (top_let.body.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
}

test "ArenaStrategy threads captures into nested recursive functions" {
    const layout = @import("../core/layout.zig");
    const loop_lambda = comptime ir.Expr{ .Lambda = .{
        .params = &.{.{ .name = "n", .ty = .Int }},
        .body = makeExpr(.{ .If = .{
            .cond = makeExpr(.{ .Prim = .{
                .op = .Le,
                .args = &.{
                    makeExpr(.{ .Var = .{ .name = "n", .ty = .Int, .layout = layout.intConstant() } }),
                    makeExpr(.{ .Constant = .{ .value = .{ .Int = 0 }, .ty = .Int, .layout = layout.intConstant() } }),
                },
                .ty = .Bool,
                .layout = layout.intConstant(),
            } }),
            .then_branch = makeExpr(.{ .Var = .{ .name = "base", .ty = .Int, .layout = layout.intConstant() } }),
            .else_branch = makeExpr(.{ .App = .{
                .callee = makeExpr(.{ .Var = .{ .name = "loop", .ty = .Unit, .layout = layout.topLevelLambda() } }),
                .args = &.{makeExpr(.{ .Prim = .{
                    .op = .Sub,
                    .args = &.{
                        makeExpr(.{ .Var = .{ .name = "n", .ty = .Int, .layout = layout.intConstant() } }),
                        makeExpr(.{ .Constant = .{ .value = .{ .Int = 1 }, .ty = .Int, .layout = layout.intConstant() } }),
                    },
                    .ty = .Int,
                    .layout = layout.intConstant(),
                } })},
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Int,
            .layout = layout.intConstant(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{.{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Let = .{
                .name = "base",
                .value = makeExpr(.{ .Constant = .{ .value = .{ .Int = 2 }, .ty = .Int, .layout = layout.intConstant() } }),
                .body = makeExpr(.{ .Let = .{
                    .name = "loop",
                    .value = &loop_lambda,
                    .body = makeExpr(.{ .App = .{
                        .callee = makeExpr(.{ .Var = .{ .name = "loop", .ty = .Unit, .layout = layout.topLevelLambda() } }),
                        .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 3 }, .ty = .Int, .layout = layout.intConstant() } })},
                        .ty = .Int,
                        .layout = layout.intConstant(),
                    } }),
                    .ty = .Int,
                    .layout = layout.intConstant(),
                    .is_rec = true,
                } }),
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } }};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lowered = try lowerModule(arena.allocator(), .{ .decls = &decls });
    try std.testing.expectEqual(@as(usize, 1), lowered.functions.len);
    try std.testing.expectEqualStrings("loop", lowered.functions[0].name);
    try std.testing.expectEqual(@as(usize, 2), lowered.functions[0].params.len);
    try std.testing.expectEqualStrings("base", lowered.functions[0].params[0].name);
    try std.testing.expectEqualStrings("n", lowered.functions[0].params[1].name);

    const base_let = switch (lowered.entrypoint.body) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const call = switch (base_let.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
    try std.testing.expectEqualStrings("base", switch (call.args[0].*) {
        .Var => |value| value.name,
        else => return error.TestUnexpectedResult,
    });
}
