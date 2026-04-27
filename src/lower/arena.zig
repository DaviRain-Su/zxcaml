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
};

/// Lowers a Core IR module with the P1 arena strategy.
pub fn lowerModule(allocator: std.mem.Allocator, module: ir.Module) LowerError!lir.LModule {
    const entrypoint = findEntrypoint(module) orelse return error.EntrypointNotFound;
    return .{ .entrypoint = try lowerLet(allocator, entrypoint) };
}

fn lowerBackend(ptr: *anyopaque, module: ir.Module) anyerror!lir.LModule {
    const self: *ArenaStrategy = @ptrCast(@alignCast(ptr));
    return lowerModule(self.allocator, module);
}

fn findEntrypoint(module: ir.Module) ?ir.Let {
    for (module.decls) |decl| {
        switch (decl) {
            .Let => |let_decl| {
                if (std.mem.eql(u8, let_decl.name, "entrypoint")) return let_decl;
            },
        }
    }
    return null;
}

fn lowerLet(allocator: std.mem.Allocator, let_decl: ir.Let) LowerError!lir.LFunc {
    return .{
        .name = try allocator.dupe(u8, let_decl.name),
        .body = try lowerExpr(let_decl.lambda.body),
        .calling_convention = .ArenaThreaded,
        .source_span = .unavailable,
    };
}

fn lowerExpr(expr: ir.Expr) LowerError!lir.LExpr {
    return switch (expr) {
        .Constant => |constant| .{ .Constant = .{ .Int = constant.value } },
    };
}

test "ArenaStrategy lowers M0 entrypoint constant and records arena threading" {
    const decls = [_]ir.Decl{.{ .Let = .{
        .name = "entrypoint",
        .lambda = .{
            .params = &.{},
            .body = .{ .Constant = .{
                .value = 0,
                .ty = .Int,
                .layout = @import("../core/layout.zig").intConstant(),
            } },
            .ty = .Unit,
            .layout = @import("../core/layout.zig").topLevelLambda(),
        },
    } }};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var impl: ArenaStrategy = .{ .allocator = arena.allocator() };
    const lowered = try impl.loweringStrategy().lowerModule(.{ .decls = &decls });

    try std.testing.expectEqualStrings("entrypoint", lowered.entrypoint.name);
    try std.testing.expectEqual(lir.CallingConvention.ArenaThreaded, lowered.entrypoint.calling_convention);
    const constant = switch (lowered.entrypoint.body) {
        .Constant => |value| value,
    };
    switch (constant) {
        .Int => |value| try std.testing.expectEqual(@as(i64, 0), value),
    }
}
