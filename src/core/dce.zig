//! Dead-code elimination for Core IR optimization.
//!
//! RESPONSIBILITIES:
//! - Walk Core IR after constant folding and remove unused pure `let` bindings.
//! - Preserve bindings whose value may perform side effects or observable
//!   traps, conservatively treating function applications, account field
//!   mutation, and division/modulo by zero as effectful.
//! - Eliminate constant-condition `if` branches that remain after earlier passes.
//! - Clone the optimized tree into the caller-provided arena without mutating
//!   the original Core IR.

const std = @import("std");
const ir = @import("ir.zig");
const layout = @import("layout.zig");

/// Errors produced by the Core IR dead-code elimination pass.
pub const DceError = std.mem.Allocator.Error;

const DceContext = struct {
    arena: *std.heap.ArenaAllocator,

    fn allocator(self: *DceContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn eliminateDecl(self: *DceContext, decl: ir.Decl) DceError!ir.Decl {
        return switch (decl) {
            .Let => |let_decl| .{ .Let = .{
                .name = let_decl.name,
                .value = try self.eliminateExprPtr(let_decl.value.*),
                .ty = let_decl.ty,
                .layout = let_decl.layout,
                .is_rec = let_decl.is_rec,
            } },
        };
    }

    fn eliminateExprPtr(self: *DceContext, expr: ir.Expr) DceError!*const ir.Expr {
        const ptr = try self.allocator().create(ir.Expr);
        ptr.* = try self.eliminateExpr(expr);
        return ptr;
    }

    fn eliminateExprPtrs(self: *DceContext, exprs: []const *const ir.Expr) DceError![]const *const ir.Expr {
        const out = try self.allocator().alloc(*const ir.Expr, exprs.len);
        for (exprs, 0..) |expr, index| {
            out[index] = try self.eliminateExprPtr(expr.*);
        }
        return out;
    }

    fn eliminateExpr(self: *DceContext, expr: ir.Expr) DceError!ir.Expr {
        return switch (expr) {
            .Lambda => |lambda| .{ .Lambda = .{
                .params = lambda.params,
                .body = try self.eliminateExprPtr(lambda.body.*),
                .ty = lambda.ty,
                .layout = lambda.layout,
            } },
            .Constant => expr,
            .App => |app| .{ .App = .{
                .callee = try self.eliminateExprPtr(app.callee.*),
                .args = try self.eliminateExprPtrs(app.args),
                .ty = app.ty,
                .layout = app.layout,
            } },
            .Let => |let_expr| try self.eliminateLet(let_expr),
            .If => |if_expr| try self.eliminateIf(if_expr),
            .Prim => |prim| .{ .Prim = .{
                .op = prim.op,
                .args = try self.eliminateExprPtrs(prim.args),
                .ty = prim.ty,
                .layout = prim.layout,
            } },
            .Var => expr,
            .Ctor => |ctor| .{ .Ctor = .{
                .name = ctor.name,
                .args = try self.eliminateExprPtrs(ctor.args),
                .ty = ctor.ty,
                .layout = ctor.layout,
                .tag = ctor.tag,
                .type_name = ctor.type_name,
            } },
            .Match => |match_expr| .{ .Match = .{
                .scrutinee = try self.eliminateExprPtr(match_expr.scrutinee.*),
                .arms = try self.eliminateArms(match_expr.arms),
                .ty = match_expr.ty,
                .layout = match_expr.layout,
            } },
            .Tuple => |tuple_expr| .{ .Tuple = .{
                .items = try self.eliminateExprPtrs(tuple_expr.items),
                .ty = tuple_expr.ty,
                .layout = tuple_expr.layout,
            } },
            .TupleProj => |tuple_proj| .{ .TupleProj = .{
                .tuple_expr = try self.eliminateExprPtr(tuple_proj.tuple_expr.*),
                .index = tuple_proj.index,
                .ty = tuple_proj.ty,
                .layout = tuple_proj.layout,
            } },
            .Record => |record_expr| .{ .Record = .{
                .fields = try self.eliminateRecordFields(record_expr.fields),
                .ty = record_expr.ty,
                .layout = record_expr.layout,
            } },
            .RecordField => |record_field| .{ .RecordField = .{
                .record_expr = try self.eliminateExprPtr(record_field.record_expr.*),
                .field_name = record_field.field_name,
                .ty = record_field.ty,
                .layout = record_field.layout,
            } },
            .RecordUpdate => |record_update| .{ .RecordUpdate = .{
                .base_expr = try self.eliminateExprPtr(record_update.base_expr.*),
                .fields = try self.eliminateRecordFields(record_update.fields),
                .ty = record_update.ty,
                .layout = record_update.layout,
            } },
            .AccountFieldSet => |field_set| .{ .AccountFieldSet = .{
                .account_expr = try self.eliminateExprPtr(field_set.account_expr.*),
                .field_name = field_set.field_name,
                .value = try self.eliminateExprPtr(field_set.value.*),
                .ty = field_set.ty,
                .layout = field_set.layout,
            } },
        };
    }

    fn eliminateLet(self: *DceContext, let_expr: ir.LetExpr) DceError!ir.Expr {
        const value = try self.eliminateExprPtr(let_expr.value.*);
        const body = try self.eliminateExprPtr(let_expr.body.*);

        if (!containsFreeName(body.*, let_expr.name) and !hasSideEffects(value.*)) {
            return body.*;
        }

        return .{ .Let = .{
            .name = let_expr.name,
            .value = value,
            .body = body,
            .ty = exprTy(body.*),
            .layout = exprLayout(body.*),
            .is_rec = let_expr.is_rec,
        } };
    }

    fn eliminateIf(self: *DceContext, if_expr: ir.IfExpr) DceError!ir.Expr {
        const cond = try self.eliminateExprPtr(if_expr.cond.*);
        const then_branch = try self.eliminateExprPtr(if_expr.then_branch.*);
        const else_branch = try self.eliminateExprPtr(if_expr.else_branch.*);

        if (boolValue(cond.*)) |value| {
            return if (value) then_branch.* else else_branch.*;
        }

        return .{ .If = .{
            .cond = cond,
            .then_branch = then_branch,
            .else_branch = else_branch,
            .ty = if_expr.ty,
            .layout = if_expr.layout,
        } };
    }

    fn eliminateArms(self: *DceContext, arms: []const ir.Arm) DceError![]const ir.Arm {
        const out = try self.allocator().alloc(ir.Arm, arms.len);
        for (arms, 0..) |arm, index| {
            out[index] = .{
                .pattern = try self.clonePattern(arm.pattern),
                .guard = if (arm.guard) |guard| try self.eliminateExprPtr(guard.*) else null,
                .body = try self.eliminateExprPtr(arm.body.*),
            };
        }
        return out;
    }

    fn eliminateRecordFields(self: *DceContext, fields: []const ir.RecordExprField) DceError![]const ir.RecordExprField {
        const out = try self.allocator().alloc(ir.RecordExprField, fields.len);
        for (fields, 0..) |field, index| {
            out[index] = .{
                .name = field.name,
                .value = try self.eliminateExprPtr(field.value.*),
            };
        }
        return out;
    }

    fn clonePattern(self: *DceContext, pattern: ir.Pattern) DceError!ir.Pattern {
        return switch (pattern) {
            .Wildcard => .Wildcard,
            .Var => |var_pattern| .{ .Var = var_pattern },
            .Constant => |constant| .{ .Constant = constant },
            .Ctor => |ctor_pattern| .{ .Ctor = .{
                .name = ctor_pattern.name,
                .args = try self.clonePatterns(ctor_pattern.args),
                .tag = ctor_pattern.tag,
                .type_name = ctor_pattern.type_name,
            } },
            .Tuple => |items| .{ .Tuple = try self.clonePatterns(items) },
            .Record => |fields| .{ .Record = try self.cloneRecordPatternFields(fields) },
            .Alias => |alias| blk: {
                const nested = try self.allocator().create(ir.Pattern);
                nested.* = try self.clonePattern(alias.pattern.*);
                break :blk .{ .Alias = .{
                    .pattern = nested,
                    .name = alias.name,
                    .ty = alias.ty,
                    .layout = alias.layout,
                } };
            },
        };
    }

    fn clonePatterns(self: *DceContext, patterns: []const ir.Pattern) DceError![]const ir.Pattern {
        const out = try self.allocator().alloc(ir.Pattern, patterns.len);
        for (patterns, 0..) |pattern, index| {
            out[index] = try self.clonePattern(pattern);
        }
        return out;
    }

    fn cloneRecordPatternFields(self: *DceContext, fields: []const ir.RecordPatternField) DceError![]const ir.RecordPatternField {
        const out = try self.allocator().alloc(ir.RecordPatternField, fields.len);
        for (fields, 0..) |field, index| {
            out[index] = .{
                .name = field.name,
                .pattern = try self.clonePattern(field.pattern),
            };
        }
        return out;
    }
};

/// Returns a Core IR module with unused pure let bindings removed.
pub fn eliminateModule(arena: *std.heap.ArenaAllocator, module: ir.Module) DceError!ir.Module {
    const allocator = arena.allocator();
    const decls = try allocator.alloc(ir.Decl, module.decls.len);

    var ctx: DceContext = .{ .arena = arena };
    for (module.decls, 0..) |decl, index| {
        decls[index] = try ctx.eliminateDecl(decl);
    }

    return .{
        .decls = decls,
        .type_decls = module.type_decls,
        .tuple_type_decls = module.tuple_type_decls,
        .record_type_decls = module.record_type_decls,
        .externals = module.externals,
    };
}

fn containsFreeName(expr: ir.Expr, name: []const u8) bool {
    return switch (expr) {
        .Lambda => |lambda| blk: {
            for (lambda.params) |param| {
                if (std.mem.eql(u8, param.name, name)) break :blk false;
            }
            break :blk containsFreeName(lambda.body.*, name);
        },
        .Constant => false,
        .App => |app| containsFreeName(app.callee.*, name) or anyExprContainsFreeName(app.args, name),
        .Let => |let_expr| blk: {
            if (!let_expr.is_rec and containsFreeName(let_expr.value.*, name)) break :blk true;
            if (let_expr.is_rec and !std.mem.eql(u8, let_expr.name, name) and containsFreeName(let_expr.value.*, name)) break :blk true;
            if (std.mem.eql(u8, let_expr.name, name)) break :blk false;
            break :blk containsFreeName(let_expr.body.*, name);
        },
        .If => |if_expr| containsFreeName(if_expr.cond.*, name) or
            containsFreeName(if_expr.then_branch.*, name) or
            containsFreeName(if_expr.else_branch.*, name),
        .Prim => |prim| anyExprContainsFreeName(prim.args, name),
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        .Ctor => |ctor| anyExprContainsFreeName(ctor.args, name),
        .Match => |match_expr| blk: {
            if (containsFreeName(match_expr.scrutinee.*, name)) break :blk true;
            for (match_expr.arms) |arm| {
                if (patternBindsName(arm.pattern, name)) continue;
                if (arm.guard) |guard| {
                    if (containsFreeName(guard.*, name)) break :blk true;
                }
                if (containsFreeName(arm.body.*, name)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple_expr| anyExprContainsFreeName(tuple_expr.items, name),
        .TupleProj => |tuple_proj| containsFreeName(tuple_proj.tuple_expr.*, name),
        .Record => |record_expr| anyRecordFieldContainsFreeName(record_expr.fields, name),
        .RecordField => |record_field| containsFreeName(record_field.record_expr.*, name),
        .RecordUpdate => |record_update| containsFreeName(record_update.base_expr.*, name) or
            anyRecordFieldContainsFreeName(record_update.fields, name),
        .AccountFieldSet => |field_set| containsFreeName(field_set.account_expr.*, name) or
            containsFreeName(field_set.value.*, name),
    };
}

fn anyExprContainsFreeName(exprs: []const *const ir.Expr, name: []const u8) bool {
    for (exprs) |expr| {
        if (containsFreeName(expr.*, name)) return true;
    }
    return false;
}

fn anyRecordFieldContainsFreeName(fields: []const ir.RecordExprField, name: []const u8) bool {
    for (fields) |field| {
        if (containsFreeName(field.value.*, name)) return true;
    }
    return false;
}

fn patternBindsName(pattern: ir.Pattern, name: []const u8) bool {
    return switch (pattern) {
        .Wildcard, .Constant => false,
        .Var => |var_pattern| std.mem.eql(u8, var_pattern.name, name),
        .Ctor => |ctor_pattern| blk: {
            for (ctor_pattern.args) |arg| {
                if (patternBindsName(arg, name)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |items| blk: {
            for (items) |item| {
                if (patternBindsName(item, name)) break :blk true;
            }
            break :blk false;
        },
        .Record => |fields| blk: {
            for (fields) |field| {
                if (patternBindsName(field.pattern, name)) break :blk true;
            }
            break :blk false;
        },
        .Alias => |alias| std.mem.eql(u8, alias.name, name) or patternBindsName(alias.pattern.*, name),
    };
}

fn hasSideEffects(expr: ir.Expr) bool {
    return switch (expr) {
        .Lambda, .Constant, .Var => false,
        .App, .AccountFieldSet => true,
        .Let => |let_expr| hasSideEffects(let_expr.value.*) or hasSideEffects(let_expr.body.*),
        .If => |if_expr| if (boolValue(if_expr.cond.*)) |value|
            hasSideEffects(if_expr.cond.*) or if (value) hasSideEffects(if_expr.then_branch.*) else hasSideEffects(if_expr.else_branch.*)
        else
            hasSideEffects(if_expr.cond.*) or hasSideEffects(if_expr.then_branch.*) or hasSideEffects(if_expr.else_branch.*),
        .Prim => |prim| primMayTrap(prim.op) or anyExprHasSideEffects(prim.args),
        .Ctor => |ctor| anyExprHasSideEffects(ctor.args),
        .Match => |match_expr| hasSideEffects(match_expr.scrutinee.*) or anyArmHasSideEffects(match_expr.arms),
        .Tuple => |tuple_expr| anyExprHasSideEffects(tuple_expr.items),
        .TupleProj => |tuple_proj| hasSideEffects(tuple_proj.tuple_expr.*),
        .Record => |record_expr| anyRecordFieldHasSideEffects(record_expr.fields),
        .RecordField => |record_field| hasSideEffects(record_field.record_expr.*),
        .RecordUpdate => |record_update| hasSideEffects(record_update.base_expr.*) or anyRecordFieldHasSideEffects(record_update.fields),
    };
}

fn anyExprHasSideEffects(exprs: []const *const ir.Expr) bool {
    for (exprs) |expr| {
        if (hasSideEffects(expr.*)) return true;
    }
    return false;
}

fn anyRecordFieldHasSideEffects(fields: []const ir.RecordExprField) bool {
    for (fields) |field| {
        if (hasSideEffects(field.value.*)) return true;
    }
    return false;
}

fn anyArmHasSideEffects(arms: []const ir.Arm) bool {
    for (arms) |arm| {
        if (arm.guard) |guard| {
            if (hasSideEffects(guard.*)) return true;
        }
        if (hasSideEffects(arm.body.*)) return true;
    }
    return false;
}

fn primMayTrap(op: ir.PrimOp) bool {
    return switch (op) {
        .Div, .Mod => true,
        else => false,
    };
}

fn boolValue(expr: ir.Expr) ?bool {
    return switch (expr) {
        .Ctor => |ctor| if (ctor.args.len == 0 and std.mem.eql(u8, ctor.name, "true"))
            true
        else if (ctor.args.len == 0 and std.mem.eql(u8, ctor.name, "false"))
            false
        else
            null,
        else => null,
    };
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

fn intExpr(value: i64) ir.Expr {
    return .{ .Constant = .{
        .value = .{ .Int = value },
        .ty = .Int,
        .layout = layout.intConstant(),
    } };
}

fn intPtr(arena: *std.heap.ArenaAllocator, value: i64) !*const ir.Expr {
    return exprPtr(arena, intExpr(value));
}

fn boolExpr(value: bool) ir.Expr {
    return .{ .Ctor = .{
        .name = if (value) "true" else "false",
        .args = &.{},
        .ty = .Bool,
        .layout = layout.ctor(0),
        .tag = if (value) 1 else 0,
        .type_name = null,
    } };
}

fn varPtr(arena: *std.heap.ArenaAllocator, name: []const u8) !*const ir.Expr {
    return exprPtr(arena, .{ .Var = .{
        .name = name,
        .ty = .Int,
        .layout = layout.intConstant(),
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

fn primPtr(arena: *std.heap.ArenaAllocator, op: ir.PrimOp, lhs: *const ir.Expr, rhs: *const ir.Expr) !*const ir.Expr {
    const args = try arena.allocator().alloc(*const ir.Expr, 2);
    args[0] = lhs;
    args[1] = rhs;
    return exprPtr(arena, .{ .Prim = .{
        .op = op,
        .args = args,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
}

fn emptyAppPtr(arena: *std.heap.ArenaAllocator) !*const ir.Expr {
    return exprPtr(arena, .{ .App = .{
        .callee = try exprPtr(arena, .{ .Var = .{
            .name = "effect",
            .ty = .Int,
            .layout = layout.topLevelLambda(),
        } }),
        .args = &.{},
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
}

fn dceTopExpr(arena: *std.heap.ArenaAllocator, value: *const ir.Expr) !*const ir.Expr {
    const decls = try arena.allocator().alloc(ir.Decl, 1);
    decls[0] = .{ .Let = .{
        .name = "entrypoint",
        .value = value,
        .ty = exprTy(value.*),
        .layout = exprLayout(value.*),
    } };
    const eliminated = try eliminateModule(arena, .{ .decls = decls });
    return eliminated.decls[0].Let.value;
}

test "dce removes unused pure let bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const eliminated = try dceTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
        .name = "unused",
        .value = try intPtr(&arena, 1),
        .body = try intPtr(&arena, 42),
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expect(eliminated.* == .Constant);
    try std.testing.expectEqual(@as(i64, 42), eliminated.Constant.value.Int);
}

test "dce preserves used let bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const eliminated = try dceTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
        .name = "x",
        .value = try intPtr(&arena, 1),
        .body = try primAddPtr(&arena, try varPtr(&arena, "x"), try intPtr(&arena, 1)),
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expect(eliminated.* == .Let);
    try std.testing.expectEqualStrings("x", eliminated.Let.name);
    try std.testing.expect(eliminated.Let.body.* == .Prim);
}

test "dce removes nested unused bindings while preserving used outer bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const inner = try exprPtr(&arena, .{ .Let = .{
        .name = "y",
        .value = try intPtr(&arena, 2),
        .body = try varPtr(&arena, "x"),
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const eliminated = try dceTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
        .name = "x",
        .value = try intPtr(&arena, 1),
        .body = inner,
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expect(eliminated.* == .Let);
    try std.testing.expectEqualStrings("x", eliminated.Let.name);
    try std.testing.expect(eliminated.Let.body.* == .Var);
    try std.testing.expectEqualStrings("x", eliminated.Let.body.Var.name);
}

test "dce preserves unused bindings with side-effectful applications" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const eliminated = try dceTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
        .name = "unused",
        .value = try emptyAppPtr(&arena),
        .body = try intPtr(&arena, 42),
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expect(eliminated.* == .Let);
    try std.testing.expect(eliminated.Let.value.* == .App);
    try std.testing.expect(eliminated.Let.body.* == .Constant);
}

test "dce preserves unused bindings with potentially trapping div and mod" {
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        // Regression for source shape: let x = 1 / 0 in 42
        const eliminated = try dceTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
            .name = "x",
            .value = try primPtr(&arena, .Div, try intPtr(&arena, 1), try intPtr(&arena, 0)),
            .body = try intPtr(&arena, 42),
            .ty = .Int,
            .layout = layout.intConstant(),
        } }));

        try std.testing.expect(eliminated.* == .Let);
        try std.testing.expect(eliminated.Let.value.* == .Prim);
        try std.testing.expectEqual(ir.PrimOp.Div, eliminated.Let.value.Prim.op);
    }

    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const eliminated = try dceTopExpr(&arena, try exprPtr(&arena, .{ .Let = .{
            .name = "x",
            .value = try primPtr(&arena, .Mod, try intPtr(&arena, 1), try intPtr(&arena, 0)),
            .body = try intPtr(&arena, 42),
            .ty = .Int,
            .layout = layout.intConstant(),
        } }));

        try std.testing.expect(eliminated.* == .Let);
        try std.testing.expect(eliminated.Let.value.* == .Prim);
        try std.testing.expectEqual(ir.PrimOp.Mod, eliminated.Let.value.Prim.op);
    }
}

test "dce eliminates constant-condition if branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const eliminated = try dceTopExpr(&arena, try exprPtr(&arena, .{ .If = .{
        .cond = try exprPtr(&arena, boolExpr(false)),
        .then_branch = try emptyAppPtr(&arena),
        .else_branch = try intPtr(&arena, 2),
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expect(eliminated.* == .Constant);
    try std.testing.expectEqual(@as(i64, 2), eliminated.Constant.value.Int);
}
