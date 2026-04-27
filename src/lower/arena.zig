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
    return .{ .entrypoint = try lowerLet(allocator, module, entrypoint_index) };
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

fn lowerLet(allocator: std.mem.Allocator, module: ir.Module, entrypoint_index: usize) LowerError!lir.LFunc {
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
        const let_body = try allocator.create(lir.LExpr);
        let_body.* = body.*;
        body = try allocator.create(lir.LExpr);
        body.* = .{ .Let = .{
            .name = try allocator.dupe(u8, top_level.name),
            .value = try lowerExprPtr(allocator, top_level.value.*),
            .body = let_body,
        } };
    }

    return .{
        .name = try allocator.dupe(u8, let_decl.name),
        .body = body.*,
        .calling_convention = .ArenaThreaded,
        .source_span = .unavailable,
    };
}

fn lowerExprPtr(allocator: std.mem.Allocator, expr: ir.Expr) LowerError!*lir.LExpr {
    const ptr = try allocator.create(lir.LExpr);
    ptr.* = try lowerExpr(allocator, expr);
    return ptr;
}

fn lowerExpr(allocator: std.mem.Allocator, expr: ir.Expr) LowerError!lir.LExpr {
    return switch (expr) {
        .Constant => |constant| .{ .Constant = .{ .Int = constant.value } },
        .Let => |let_expr| .{ .Let = .{
            .name = try allocator.dupe(u8, let_expr.name),
            .value = try lowerExprPtr(allocator, let_expr.value.*),
            .body = try lowerExprPtr(allocator, let_expr.body.*),
        } },
        .Var => |var_ref| .{ .Var = .{ .name = try allocator.dupe(u8, var_ref.name) } },
        .Lambda => error.UnsupportedExpr,
    };
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
                .value = 0,
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
    }
}

test "ArenaStrategy wraps previous top-level lets around entrypoint body" {
    const layout = @import("../core/layout.zig");
    const decls = [_]ir.Decl{
        .{ .Let = .{
            .name = "x",
            .value = makeExpr(.{ .Constant = .{
                .value = 1,
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
