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
                try functions.append(allocator, try lowerFunction(allocator, let_decl.name, lambda));
                try collectNestedFunctions(allocator, lambda.body.*, &functions);
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
    try collectNestedFunctions(allocator, entry_lambda.body.*, &functions);
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

    var body = try lowerExprPtr(allocator, lambda.body.*);
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

fn lowerFunction(allocator: std.mem.Allocator, name: []const u8, lambda: ir.Lambda) LowerError!lir.LFunc {
    return .{
        .name = try allocator.dupe(u8, name),
        .params = try lowerParams(allocator, lambda.params),
        .body = (try lowerExprPtr(allocator, lambda.body.*)).*,
        .calling_convention = .ArenaThreaded,
        .source_span = .unavailable,
    };
}

fn collectNestedFunctions(allocator: std.mem.Allocator, expr: ir.Expr, functions: *std.ArrayList(lir.LFunc)) LowerError!void {
    switch (expr) {
        .Lambda => |lambda| try collectNestedFunctions(allocator, lambda.body.*, functions),
        .Let => |let_expr| {
            switch (let_expr.value.*) {
                .Lambda => |lambda| {
                    if (let_expr.is_rec) {
                        try functions.append(allocator, try lowerFunction(allocator, let_expr.name, lambda));
                    }
                    try collectNestedFunctions(allocator, lambda.body.*, functions);
                },
                else => try collectNestedFunctions(allocator, let_expr.value.*, functions),
            }
            try collectNestedFunctions(allocator, let_expr.body.*, functions);
        },
        .If => |if_expr| {
            try collectNestedFunctions(allocator, if_expr.cond.*, functions);
            try collectNestedFunctions(allocator, if_expr.then_branch.*, functions);
            try collectNestedFunctions(allocator, if_expr.else_branch.*, functions);
        },
        .Prim => |prim| for (prim.args) |arg| try collectNestedFunctions(allocator, arg.*, functions),
        .App => |app| {
            try collectNestedFunctions(allocator, app.callee.*, functions);
            for (app.args) |arg| try collectNestedFunctions(allocator, arg.*, functions);
        },
        .Ctor => |ctor| for (ctor.args) |arg| try collectNestedFunctions(allocator, arg.*, functions),
        .Match => |match_expr| {
            try collectNestedFunctions(allocator, match_expr.scrutinee.*, functions);
            for (match_expr.arms) |arm| try collectNestedFunctions(allocator, arm.body.*, functions);
        },
        .Constant, .Var => {},
    }
}

fn lowerExprPtr(allocator: std.mem.Allocator, expr: ir.Expr) LowerError!*lir.LExpr {
    const ptr = try allocator.create(lir.LExpr);
    ptr.* = try lowerExpr(allocator, expr);
    return ptr;
}

fn lowerExpr(allocator: std.mem.Allocator, expr: ir.Expr) LowerError!lir.LExpr {
    return switch (expr) {
        .Constant => |constant| .{ .Constant = switch (constant.value) {
            .Int => |value| .{ .Int = value },
            .String => |value| .{ .String = try allocator.dupe(u8, value) },
        } },
        .App => |app| .{ .App = .{
            .callee = try lowerExprPtr(allocator, app.callee.*),
            .args = try lowerExprPtrs(allocator, app.args),
        } },
        .Let => |let_expr| blk: {
            if (let_expr.is_rec) {
                switch (let_expr.value.*) {
                    .Lambda => break :blk (try lowerExprPtr(allocator, let_expr.body.*)).*,
                    else => {},
                }
            }
            break :blk .{ .Let = .{
                .name = try allocator.dupe(u8, let_expr.name),
                .value = try lowerExprPtr(allocator, let_expr.value.*),
                .body = try lowerExprPtr(allocator, let_expr.body.*),
                .is_rec = let_expr.is_rec,
            } };
        },
        .If => |if_expr| .{ .If = .{
            .cond = try lowerExprPtr(allocator, if_expr.cond.*),
            .then_branch = try lowerExprPtr(allocator, if_expr.then_branch.*),
            .else_branch = try lowerExprPtr(allocator, if_expr.else_branch.*),
        } },
        .Prim => |prim| .{ .Prim = .{
            .op = lowerPrimOp(prim.op),
            .args = try lowerExprPtrs(allocator, prim.args),
        } },
        .Var => |var_ref| .{ .Var = .{ .name = try allocator.dupe(u8, var_ref.name) } },
        .Ctor => |ctor_expr| .{ .Ctor = .{
            .name = try allocator.dupe(u8, ctor_expr.name),
            .args = try lowerExprPtrs(allocator, ctor_expr.args),
            .ty = try lowerTy(allocator, ctor_expr.ty),
            .layout = ctor_expr.layout,
        } },
        .Match => |match_expr| .{ .Match = .{
            .scrutinee = try lowerExprPtr(allocator, match_expr.scrutinee.*),
            .arms = try lowerArms(allocator, match_expr.arms),
        } },
        .Lambda => error.UnsupportedExpr,
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

fn lowerArms(allocator: std.mem.Allocator, arms: []const ir.Arm) LowerError![]const lir.LArm {
    const lowered = try allocator.alloc(lir.LArm, arms.len);
    for (arms, 0..) |arm, index| {
        lowered[index] = .{
            .pattern = try lowerPattern(allocator, arm.pattern),
            .body = try lowerExprPtr(allocator, arm.body.*),
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

fn lowerExprPtrs(allocator: std.mem.Allocator, exprs: []const *const ir.Expr) LowerError![]const *const lir.LExpr {
    const lowered = try allocator.alloc(*const lir.LExpr, exprs.len);
    for (exprs, 0..) |expr, index| {
        lowered[index] = try lowerExprPtr(allocator, expr.*);
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
