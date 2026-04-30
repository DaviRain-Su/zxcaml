//! Constant folding for Core IR optimization.
//!
//! RESPONSIBILITIES:
//! - Walk Core IR bottom-up and evaluate primitive operations whose operands
//!   are compile-time constants.
//! - Replace constant-condition `if` expressions and known-scrutinee matches
//!   with the selected branch while preserving division-by-zero runtime checks.
//! - Clone the folded tree into the caller-provided arena without mutating the
//!   original ANF output.

const std = @import("std");
const ir = @import("ir.zig");
const layout = @import("layout.zig");

/// Errors produced by the Core IR constant folding pass.
pub const FoldError = std.mem.Allocator.Error;

const EnvEntry = struct {
    value: ?*const ir.Expr,
    can_inline: bool = false,
};

const EnvChange = struct {
    name: []const u8,
    existed: bool,
    previous: EnvEntry = .{ .value = null },
};

const PatternMatchResult = enum {
    no_match,
    matched,
    unsafe,
};

const FoldEnv = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap(EnvEntry),
    changes: std.ArrayList(EnvChange),

    fn init(allocator: std.mem.Allocator) FoldEnv {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(EnvEntry).init(allocator),
            .changes = std.ArrayList(EnvChange).empty,
        };
    }

    fn deinit(self: *FoldEnv) void {
        self.changes.deinit(self.allocator);
        self.bindings.deinit();
    }

    fn mark(self: *const FoldEnv) usize {
        return self.changes.items.len;
    }

    fn bindKnown(self: *FoldEnv, name: []const u8, value: *const ir.Expr, can_inline: bool) FoldError!void {
        try self.push(name, .{ .value = value, .can_inline = can_inline });
    }

    fn shadow(self: *FoldEnv, name: []const u8) FoldError!void {
        try self.push(name, .{ .value = null });
    }

    fn getKnown(self: *const FoldEnv, name: []const u8) ?*const ir.Expr {
        const entry = self.bindings.get(name) orelse return null;
        return entry.value;
    }

    fn getInline(self: *const FoldEnv, name: []const u8) ?*const ir.Expr {
        const entry = self.bindings.get(name) orelse return null;
        if (!entry.can_inline) return null;
        return entry.value;
    }

    fn restore(self: *FoldEnv, mark_index: usize) void {
        while (self.changes.items.len > mark_index) {
            const change = self.changes.pop().?;
            if (change.existed) {
                self.bindings.getPtr(change.name).?.* = change.previous;
            } else {
                _ = self.bindings.remove(change.name);
            }
        }
    }

    fn push(self: *FoldEnv, name: []const u8, entry: EnvEntry) FoldError!void {
        if (self.bindings.get(name)) |previous| {
            try self.changes.append(self.allocator, .{
                .name = name,
                .existed = true,
                .previous = previous,
            });
        } else {
            try self.changes.append(self.allocator, .{
                .name = name,
                .existed = false,
            });
        }
        try self.bindings.put(name, entry);
    }
};

const FoldContext = struct {
    arena: *std.heap.ArenaAllocator,
    env: *FoldEnv,

    fn allocator(self: *FoldContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn foldDecl(self: *FoldContext, decl: ir.Decl) FoldError!ir.Decl {
        return switch (decl) {
            .Let => |let_decl| .{ .Let = .{
                .name = let_decl.name,
                .value = try self.foldExprPtr(let_decl.value.*),
                .ty = let_decl.ty,
                .layout = let_decl.layout,
                .is_rec = let_decl.is_rec,
            } },
        };
    }

    fn foldExprPtr(self: *FoldContext, expr: ir.Expr) FoldError!*const ir.Expr {
        const ptr = try self.allocator().create(ir.Expr);
        ptr.* = try self.foldExpr(expr);
        return ptr;
    }

    fn foldExprPtrs(self: *FoldContext, exprs: []const *const ir.Expr) FoldError![]const *const ir.Expr {
        const out = try self.allocator().alloc(*const ir.Expr, exprs.len);
        for (exprs, 0..) |expr, index| {
            out[index] = try self.foldExprPtr(expr.*);
        }
        return out;
    }

    fn foldExpr(self: *FoldContext, expr: ir.Expr) FoldError!ir.Expr {
        return switch (expr) {
            .Lambda => |lambda| .{ .Lambda = try self.foldLambda(lambda) },
            .Constant => expr,
            .App => |app| .{ .App = .{
                .callee = try self.foldExprPtr(app.callee.*),
                .args = try self.foldExprPtrs(app.args),
                .ty = app.ty,
                .layout = app.layout,
            } },
            .Let => |let_expr| .{ .Let = try self.foldLetExpr(let_expr) },
            .If => |if_expr| try self.foldIf(if_expr),
            .Prim => |prim| try self.foldPrim(prim),
            .Var => |var_ref| if (self.env.getInline(var_ref.name)) |known| blk: {
                if (isInlineKnownValue(known.*)) break :blk known.*;
                break :blk expr;
            } else expr,
            .Ctor => |ctor| .{ .Ctor = .{
                .name = ctor.name,
                .args = try self.foldExprPtrs(ctor.args),
                .ty = ctor.ty,
                .layout = ctor.layout,
                .tag = ctor.tag,
                .type_name = ctor.type_name,
            } },
            .Match => |match_expr| try self.foldMatch(match_expr),
            .Tuple => |tuple_expr| .{ .Tuple = .{
                .items = try self.foldExprPtrs(tuple_expr.items),
                .ty = tuple_expr.ty,
                .layout = tuple_expr.layout,
            } },
            .TupleProj => |tuple_proj| .{ .TupleProj = .{
                .tuple_expr = try self.foldExprPtr(tuple_proj.tuple_expr.*),
                .index = tuple_proj.index,
                .ty = tuple_proj.ty,
                .layout = tuple_proj.layout,
            } },
            .Record => |record_expr| .{ .Record = .{
                .fields = try self.foldRecordFields(record_expr.fields),
                .ty = record_expr.ty,
                .layout = record_expr.layout,
            } },
            .RecordField => |record_field| .{ .RecordField = .{
                .record_expr = try self.foldExprPtr(record_field.record_expr.*),
                .field_name = record_field.field_name,
                .ty = record_field.ty,
                .layout = record_field.layout,
            } },
            .RecordUpdate => |record_update| .{ .RecordUpdate = .{
                .base_expr = try self.foldExprPtr(record_update.base_expr.*),
                .fields = try self.foldRecordFields(record_update.fields),
                .ty = record_update.ty,
                .layout = record_update.layout,
            } },
            .AccountFieldSet => |field_set| .{ .AccountFieldSet = .{
                .account_expr = try self.foldExprPtr(field_set.account_expr.*),
                .field_name = field_set.field_name,
                .value = try self.foldExprPtr(field_set.value.*),
                .ty = field_set.ty,
                .layout = field_set.layout,
            } },
        };
    }

    fn foldLambda(self: *FoldContext, lambda: ir.Lambda) FoldError!ir.Lambda {
        const mark_index = self.env.mark();
        for (lambda.params) |param| try self.env.shadow(param.name);
        const body = try self.foldExprPtr(lambda.body.*);
        self.env.restore(mark_index);
        return .{
            .params = lambda.params,
            .body = body,
            .ty = lambda.ty,
            .layout = lambda.layout,
        };
    }

    fn foldLetExpr(self: *FoldContext, let_expr: ir.LetExpr) FoldError!ir.LetExpr {
        const folded_value = try self.foldExprPtr(let_expr.value.*);
        const mark_index = self.env.mark();
        if (!let_expr.is_rec and isKnownValue(folded_value.*)) {
            try self.env.bindKnown(let_expr.name, folded_value, false);
        } else {
            try self.env.shadow(let_expr.name);
        }
        const folded_body = try self.foldExprPtr(let_expr.body.*);
        self.env.restore(mark_index);
        return .{
            .name = let_expr.name,
            .value = folded_value,
            .body = folded_body,
            .ty = exprTy(folded_body.*),
            .layout = exprLayout(folded_body.*),
            .is_rec = let_expr.is_rec,
        };
    }

    fn foldIf(self: *FoldContext, if_expr: ir.IfExpr) FoldError!ir.Expr {
        const cond = try self.foldExprPtr(if_expr.cond.*);
        const then_branch = try self.foldExprPtr(if_expr.then_branch.*);
        const else_branch = try self.foldExprPtr(if_expr.else_branch.*);

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

    fn foldPrim(self: *FoldContext, prim: ir.Prim) FoldError!ir.Expr {
        const args = try self.foldExprPtrs(prim.args);
        const folded = try self.tryFoldPrim(prim, args);
        if (folded) |value| return value;
        return .{ .Prim = .{
            .op = prim.op,
            .args = args,
            .ty = prim.ty,
            .layout = prim.layout,
        } };
    }

    fn tryFoldPrim(self: *FoldContext, prim: ir.Prim, args: []const *const ir.Expr) FoldError!?ir.Expr {
        if (prim.op == .StringConcat) {
            if (args.len != 2) return null;
            const left = stringConstant(args[0].*) orelse return null;
            const right = stringConstant(args[1].*) orelse return null;
            const out = try self.allocator().alloc(u8, left.len + right.len);
            @memcpy(out[0..left.len], left);
            @memcpy(out[left.len..], right);
            return .{ .Constant = .{
                .value = .{ .String = out },
                .ty = prim.ty,
                .layout = prim.layout,
            } };
        }

        if (args.len != 2) return null;
        const lhs = intConstant(args[0].*) orelse return null;
        const rhs = intConstant(args[1].*) orelse return null;

        return switch (prim.op) {
            .Add => intExpr(wrappingAdd(lhs, rhs), prim.ty, prim.layout),
            .Sub => intExpr(wrappingSub(lhs, rhs), prim.ty, prim.layout),
            .Mul => intExpr(wrappingMul(lhs, rhs), prim.ty, prim.layout),
            .Div => if (rhs == 0) null else intExpr(truncatingDiv(lhs, rhs), prim.ty, prim.layout),
            .Mod => if (rhs == 0) null else intExpr(truncatingMod(lhs, rhs), prim.ty, prim.layout),
            .Eq => boolExpr(lhs == rhs),
            .Ne => boolExpr(lhs != rhs),
            .Lt => boolExpr(lhs < rhs),
            .Le => boolExpr(lhs <= rhs),
            .Gt => boolExpr(lhs > rhs),
            .Ge => boolExpr(lhs >= rhs),
            .StringLength, .StringGet, .StringSub, .StringConcat, .CharCode, .CharChr => null,
        };
    }

    fn foldMatch(self: *FoldContext, match_expr: ir.Match) FoldError!ir.Expr {
        const scrutinee = try self.foldExprPtr(match_expr.scrutinee.*);
        const match_value = if (scrutinee.* == .Var)
            self.env.getKnown(scrutinee.Var.name) orelse scrutinee
        else
            scrutinee;

        if (match_value.* == .Ctor and isKnownValue(match_value.*)) {
            for (match_expr.arms) |arm| {
                const mark_index = self.env.mark();
                switch (try self.patternMatches(arm.pattern, match_value)) {
                    .no_match => {},
                    .unsafe => {
                        self.env.restore(mark_index);
                        break;
                    },
                    .matched => {
                        if (arm.guard) |guard| {
                            const folded_guard = try self.foldExprPtr(guard.*);
                            if (boolValue(folded_guard.*)) |guard_value| {
                                if (!guard_value) {
                                    self.env.restore(mark_index);
                                    continue;
                                }
                            } else {
                                self.env.restore(mark_index);
                                break;
                            }
                        }

                        const body = try self.foldExprPtr(arm.body.*);
                        self.env.restore(mark_index);
                        return body.*;
                    },
                }
                self.env.restore(mark_index);
            }
        }

        return .{ .Match = .{
            .scrutinee = scrutinee,
            .arms = try self.foldArms(match_expr.arms),
            .ty = match_expr.ty,
            .layout = match_expr.layout,
        } };
    }

    fn foldArms(self: *FoldContext, arms: []const ir.Arm) FoldError![]const ir.Arm {
        const out = try self.allocator().alloc(ir.Arm, arms.len);
        for (arms, 0..) |arm, index| {
            const mark_index = self.env.mark();
            try self.shadowPatternBindings(arm.pattern);
            out[index] = .{
                .pattern = try self.clonePattern(arm.pattern),
                .guard = if (arm.guard) |guard| try self.foldExprPtr(guard.*) else null,
                .body = try self.foldExprPtr(arm.body.*),
            };
            self.env.restore(mark_index);
        }
        return out;
    }

    fn foldRecordFields(self: *FoldContext, fields: []const ir.RecordExprField) FoldError![]const ir.RecordExprField {
        const out = try self.allocator().alloc(ir.RecordExprField, fields.len);
        for (fields, 0..) |field, index| {
            out[index] = .{
                .name = field.name,
                .value = try self.foldExprPtr(field.value.*),
            };
        }
        return out;
    }

    fn patternMatches(self: *FoldContext, pattern: ir.Pattern, value: *const ir.Expr) FoldError!PatternMatchResult {
        return switch (pattern) {
            .Wildcard => .matched,
            .Var => |var_pattern| blk: {
                if (!isSimpleConstantValue(value.*)) break :blk .unsafe;
                try self.env.bindKnown(var_pattern.name, value, true);
                break :blk .matched;
            },
            .Constant => |constant| if (patternConstantMatches(constant, value.*)) .matched else .no_match,
            .Ctor => |ctor_pattern| blk: {
                const ctor_value = switch (value.*) {
                    .Ctor => |ctor| ctor,
                    else => break :blk .no_match,
                };
                if (!std.mem.eql(u8, ctor_pattern.name, ctor_value.name)) break :blk .no_match;
                if (ctor_pattern.args.len != ctor_value.args.len) break :blk .no_match;
                for (ctor_pattern.args, 0..) |arg_pattern, index| {
                    switch (try self.patternMatches(arg_pattern, ctor_value.args[index])) {
                        .matched => {},
                        .no_match => break :blk .no_match,
                        .unsafe => break :blk .unsafe,
                    }
                }
                break :blk .matched;
            },
            .Tuple => |patterns| blk: {
                const tuple_value = switch (value.*) {
                    .Tuple => |tuple_expr| tuple_expr,
                    else => break :blk .no_match,
                };
                if (patterns.len != tuple_value.items.len) break :blk .no_match;
                for (patterns, 0..) |item_pattern, index| {
                    switch (try self.patternMatches(item_pattern, tuple_value.items[index])) {
                        .matched => {},
                        .no_match => break :blk .no_match,
                        .unsafe => break :blk .unsafe,
                    }
                }
                break :blk .matched;
            },
            .Record => |fields| blk: {
                const record_value = switch (value.*) {
                    .Record => |record_expr| record_expr,
                    else => break :blk .no_match,
                };
                for (fields) |field_pattern| {
                    const field_value = findRecordField(record_value.fields, field_pattern.name) orelse break :blk .no_match;
                    switch (try self.patternMatches(field_pattern.pattern, field_value)) {
                        .matched => {},
                        .no_match => break :blk .no_match,
                        .unsafe => break :blk .unsafe,
                    }
                }
                break :blk .matched;
            },
            .Alias => |alias| blk: {
                switch (try self.patternMatches(alias.pattern.*, value)) {
                    .matched => {},
                    .no_match => break :blk .no_match,
                    .unsafe => break :blk .unsafe,
                }
                if (!isSimpleConstantValue(value.*)) break :blk .unsafe;
                try self.env.bindKnown(alias.name, value, true);
                break :blk .matched;
            },
        };
    }

    fn shadowPatternBindings(self: *FoldContext, pattern: ir.Pattern) FoldError!void {
        switch (pattern) {
            .Wildcard, .Constant => {},
            .Var => |var_pattern| try self.env.shadow(var_pattern.name),
            .Ctor => |ctor_pattern| {
                for (ctor_pattern.args) |arg| try self.shadowPatternBindings(arg);
            },
            .Tuple => |items| {
                for (items) |item| try self.shadowPatternBindings(item);
            },
            .Record => |fields| {
                for (fields) |field| try self.shadowPatternBindings(field.pattern);
            },
            .Alias => |alias| {
                try self.shadowPatternBindings(alias.pattern.*);
                try self.env.shadow(alias.name);
            },
        }
    }

    fn clonePattern(self: *FoldContext, pattern: ir.Pattern) FoldError!ir.Pattern {
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

    fn clonePatterns(self: *FoldContext, patterns: []const ir.Pattern) FoldError![]const ir.Pattern {
        const out = try self.allocator().alloc(ir.Pattern, patterns.len);
        for (patterns, 0..) |pattern, index| {
            out[index] = try self.clonePattern(pattern);
        }
        return out;
    }

    fn cloneRecordPatternFields(self: *FoldContext, fields: []const ir.RecordPatternField) FoldError![]const ir.RecordPatternField {
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

/// Returns a Core IR module with constant-foldable expressions replaced.
pub fn foldModule(arena: *std.heap.ArenaAllocator, module: ir.Module) FoldError!ir.Module {
    const allocator = arena.allocator();
    const decls = try allocator.alloc(ir.Decl, module.decls.len);

    var env = FoldEnv.init(allocator);
    defer env.deinit();
    var ctx: FoldContext = .{ .arena = arena, .env = &env };

    for (module.decls, 0..) |decl, index| {
        decls[index] = try ctx.foldDecl(decl);
    }

    return .{
        .decls = decls,
        .type_decls = module.type_decls,
        .tuple_type_decls = module.tuple_type_decls,
        .record_type_decls = module.record_type_decls,
        .externals = module.externals,
    };
}

fn intConstant(expr: ir.Expr) ?i64 {
    return switch (expr) {
        .Constant => |constant| switch (constant.value) {
            .Int => |value| value,
            .String => null,
        },
        else => null,
    };
}

fn stringConstant(expr: ir.Expr) ?[]const u8 {
    return switch (expr) {
        .Constant => |constant| switch (constant.value) {
            .String => |value| value,
            .Int => null,
        },
        else => null,
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

fn isKnownValue(expr: ir.Expr) bool {
    return switch (expr) {
        .Constant => true,
        .Ctor => |ctor| blk: {
            for (ctor.args) |arg| {
                if (!isKnownValue(arg.*)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn isInlineKnownValue(expr: ir.Expr) bool {
    return switch (expr) {
        .Constant => true,
        .Ctor => boolValue(expr) != null,
        else => false,
    };
}

fn isSimpleConstantValue(expr: ir.Expr) bool {
    return expr == .Constant;
}

fn patternConstantMatches(pattern: ir.PatternConstant, expr: ir.Expr) bool {
    const constant = switch (expr) {
        .Constant => |value| value.value,
        else => return false,
    };
    return switch (pattern) {
        .Int => |expected| switch (constant) {
            .Int => |actual| actual == expected,
            .String => false,
        },
        .Char => |expected| switch (constant) {
            .Int => |actual| actual == expected,
            .String => false,
        },
        .String => |expected| switch (constant) {
            .String => |actual| std.mem.eql(u8, actual, expected),
            .Int => false,
        },
    };
}

fn findRecordField(fields: []const ir.RecordExprField, name: []const u8) ?*const ir.Expr {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

fn intExpr(value: i64, ty: ir.Ty, expr_layout: layout.Layout) ir.Expr {
    return .{ .Constant = .{
        .value = .{ .Int = value },
        .ty = ty,
        .layout = expr_layout,
    } };
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

fn wrappingAdd(lhs: i64, rhs: i64) i64 {
    const result = @addWithOverflow(lhs, rhs);
    return result[0];
}

fn wrappingSub(lhs: i64, rhs: i64) i64 {
    const result = @subWithOverflow(lhs, rhs);
    return result[0];
}

fn wrappingMul(lhs: i64, rhs: i64) i64 {
    const result = @mulWithOverflow(lhs, rhs);
    return result[0];
}

fn truncatingDiv(lhs: i64, rhs: i64) i64 {
    if (lhs == std.math.minInt(i64) and rhs == -1) return std.math.minInt(i64);
    return @divTrunc(lhs, rhs);
}

fn truncatingMod(lhs: i64, rhs: i64) i64 {
    if (lhs == std.math.minInt(i64) and rhs == -1) return 0;
    return @rem(lhs, rhs);
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

fn intPtr(arena: *std.heap.ArenaAllocator, value: i64) !*const ir.Expr {
    return exprPtr(arena, intExpr(value, .Int, layout.intConstant()));
}

fn stringPtr(arena: *std.heap.ArenaAllocator, value: []const u8) !*const ir.Expr {
    return exprPtr(arena, .{ .Constant = .{
        .value = .{ .String = try arena.allocator().dupe(u8, value) },
        .ty = .String,
        .layout = layout.defaultFor(.StringLiteral),
    } });
}

fn binaryPrimPtr(arena: *std.heap.ArenaAllocator, op: ir.PrimOp, lhs: i64, rhs: i64, ty: ir.Ty) !*const ir.Expr {
    const args = try arena.allocator().alloc(*const ir.Expr, 2);
    args[0] = try intPtr(arena, lhs);
    args[1] = try intPtr(arena, rhs);
    return exprPtr(arena, .{ .Prim = .{
        .op = op,
        .args = args,
        .ty = ty,
        .layout = layout.intConstant(),
    } });
}

fn foldTopExpr(arena: *std.heap.ArenaAllocator, value: *const ir.Expr) !*const ir.Expr {
    const decls = try arena.allocator().alloc(ir.Decl, 1);
    decls[0] = .{ .Let = .{
        .name = "entrypoint",
        .value = value,
        .ty = exprTy(value.*),
        .layout = exprLayout(value.*),
    } };
    const folded = try foldModule(arena, .{ .decls = decls });
    return folded.decls[0].Let.value;
}

test "const_fold folds integer primitives and nested expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cases = [_]struct {
        op: ir.PrimOp,
        lhs: i64,
        rhs: i64,
        expected: i64,
    }{
        .{ .op = .Add, .lhs = 1, .rhs = 2, .expected = 3 },
        .{ .op = .Sub, .lhs = 7, .rhs = 4, .expected = 3 },
        .{ .op = .Mul, .lhs = 6, .rhs = 7, .expected = 42 },
        .{ .op = .Div, .lhs = 7, .rhs = 2, .expected = 3 },
        .{ .op = .Mod, .lhs = 7, .rhs = 2, .expected = 1 },
    };

    for (cases) |case| {
        const folded = try foldTopExpr(&arena, try binaryPrimPtr(&arena, case.op, case.lhs, case.rhs, .Int));
        try std.testing.expectEqual(case.expected, folded.Constant.value.Int);
    }

    const inner_args = try arena.allocator().alloc(*const ir.Expr, 2);
    inner_args[0] = try intPtr(&arena, 1);
    inner_args[1] = try intPtr(&arena, 2);
    const inner = try exprPtr(&arena, .{ .Prim = .{
        .op = .Add,
        .args = inner_args,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const outer_args = try arena.allocator().alloc(*const ir.Expr, 2);
    outer_args[0] = inner;
    outer_args[1] = try intPtr(&arena, 3);
    const outer = try exprPtr(&arena, .{ .Prim = .{
        .op = .Mul,
        .args = outer_args,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const nested = try foldTopExpr(&arena, outer);
    try std.testing.expectEqual(@as(i64, 9), nested.Constant.value.Int);
}

test "const_fold folds comparisons to boolean constructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cases = [_]struct {
        op: ir.PrimOp,
        lhs: i64,
        rhs: i64,
        expected: bool,
    }{
        .{ .op = .Eq, .lhs = 3, .rhs = 3, .expected = true },
        .{ .op = .Ne, .lhs = 3, .rhs = 4, .expected = true },
        .{ .op = .Lt, .lhs = 2, .rhs = 3, .expected = true },
        .{ .op = .Le, .lhs = 3, .rhs = 3, .expected = true },
        .{ .op = .Gt, .lhs = 4, .rhs = 3, .expected = true },
        .{ .op = .Ge, .lhs = 3, .rhs = 3, .expected = true },
    };

    for (cases) |case| {
        const folded = try foldTopExpr(&arena, try binaryPrimPtr(&arena, case.op, case.lhs, case.rhs, .Bool));
        try std.testing.expectEqual(case.expected, boolValue(folded.*).?);
    }
}

test "const_fold preserves division and modulo by zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const div_zero = try foldTopExpr(&arena, try binaryPrimPtr(&arena, .Div, 1, 0, .Int));
    try std.testing.expect(div_zero.* == .Prim);
    try std.testing.expectEqual(ir.PrimOp.Div, div_zero.Prim.op);

    const mod_zero = try foldTopExpr(&arena, try binaryPrimPtr(&arena, .Mod, 1, 0, .Int));
    try std.testing.expect(mod_zero.* == .Prim);
    try std.testing.expectEqual(ir.PrimOp.Mod, mod_zero.Prim.op);
}

test "const_fold folds constant if conditions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const folded = try foldTopExpr(&arena, try exprPtr(&arena, .{ .If = .{
        .cond = try exprPtr(&arena, boolExpr(true)),
        .then_branch = try intPtr(&arena, 11),
        .else_branch = try intPtr(&arena, 22),
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expectEqual(@as(i64, 11), folded.Constant.value.Int);
}

test "const_fold folds known constructor matches and substitutes payload bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const some_args = try arena.allocator().alloc(*const ir.Expr, 1);
    some_args[0] = try intPtr(&arena, 1);
    const scrutinee = try exprPtr(&arena, .{ .Ctor = .{
        .name = "Some",
        .args = some_args,
        .ty = .{ .Adt = .{ .name = "option", .params = &.{.Int} } },
        .layout = layout.ctor(1),
        .tag = 1,
    } });

    const some_pattern_args = try arena.allocator().alloc(ir.Pattern, 1);
    some_pattern_args[0] = .{ .Var = .{
        .name = "x",
        .ty = .Int,
        .layout = layout.intConstant(),
    } };
    const arms = try arena.allocator().alloc(ir.Arm, 2);
    arms[0] = .{
        .pattern = .{ .Ctor = .{ .name = "Some", .args = some_pattern_args, .tag = 1 } },
        .body = try exprPtr(&arena, .{ .Var = .{
            .name = "x",
            .ty = .Int,
            .layout = layout.intConstant(),
        } }),
    };
    arms[1] = .{
        .pattern = .{ .Ctor = .{ .name = "None", .args = &.{}, .tag = 0 } },
        .body = try intPtr(&arena, 0),
    };

    const folded = try foldTopExpr(&arena, try exprPtr(&arena, .{ .Match = .{
        .scrutinee = scrutinee,
        .arms = arms,
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expectEqual(@as(i64, 1), folded.Constant.value.Int);
}

test "const_fold preserves matches when payload bindings are not simple constants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const option_int_ty = ir.Ty{ .Adt = .{ .name = "option", .params = &.{.Int} } };
    const option_option_int_ty = ir.Ty{ .Adt = .{ .name = "option", .params = &.{option_int_ty} } };

    const inner_some_args = try arena.allocator().alloc(*const ir.Expr, 1);
    inner_some_args[0] = try intPtr(&arena, 1);
    const inner_some = try exprPtr(&arena, .{ .Ctor = .{
        .name = "Some",
        .args = inner_some_args,
        .ty = option_int_ty,
        .layout = layout.ctor(1),
        .tag = 1,
    } });

    const outer_some_args = try arena.allocator().alloc(*const ir.Expr, 1);
    outer_some_args[0] = inner_some;
    const outer_some = try exprPtr(&arena, .{ .Ctor = .{
        .name = "Some",
        .args = outer_some_args,
        .ty = option_option_int_ty,
        .layout = layout.ctor(1),
        .tag = 1,
    } });

    const inner_some_pattern_args = try arena.allocator().alloc(ir.Pattern, 1);
    inner_some_pattern_args[0] = .{ .Var = .{
        .name = "y",
        .ty = .Int,
        .layout = layout.intConstant(),
    } };
    const inner_arms = try arena.allocator().alloc(ir.Arm, 2);
    inner_arms[0] = .{
        .pattern = .{ .Ctor = .{ .name = "Some", .args = inner_some_pattern_args, .tag = 1 } },
        .body = try exprPtr(&arena, .{ .Var = .{
            .name = "y",
            .ty = .Int,
            .layout = layout.intConstant(),
        } }),
    };
    inner_arms[1] = .{
        .pattern = .{ .Ctor = .{ .name = "None", .args = &.{}, .tag = 0 } },
        .body = try intPtr(&arena, 0),
    };
    const inner_match = try exprPtr(&arena, .{ .Match = .{
        .scrutinee = try exprPtr(&arena, .{ .Var = .{
            .name = "x",
            .ty = option_int_ty,
            .layout = layout.ctor(1),
        } }),
        .arms = inner_arms,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });

    const outer_some_pattern_args = try arena.allocator().alloc(ir.Pattern, 1);
    outer_some_pattern_args[0] = .{ .Var = .{
        .name = "x",
        .ty = option_int_ty,
        .layout = layout.ctor(1),
    } };
    const outer_arms = try arena.allocator().alloc(ir.Arm, 2);
    outer_arms[0] = .{
        .pattern = .{ .Ctor = .{ .name = "Some", .args = outer_some_pattern_args, .tag = 1 } },
        .body = inner_match,
    };
    outer_arms[1] = .{
        .pattern = .{ .Ctor = .{ .name = "None", .args = &.{}, .tag = 0 } },
        .body = try intPtr(&arena, 0),
    };

    const folded = try foldTopExpr(&arena, try exprPtr(&arena, .{ .Match = .{
        .scrutinee = outer_some,
        .arms = outer_arms,
        .ty = .Int,
        .layout = layout.intConstant(),
    } }));

    try std.testing.expect(folded.* == .Match);
    try std.testing.expect(folded.Match.arms[0].body.* == .Match);
    try std.testing.expect(folded.Match.arms[0].body.Match.scrutinee.* == .Var);
    try std.testing.expectEqualStrings("x", folded.Match.arms[0].body.Match.scrutinee.Var.name);
}

test "const_fold folds string concatenation constants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = try arena.allocator().alloc(*const ir.Expr, 2);
    args[0] = try stringPtr(&arena, "hello");
    args[1] = try stringPtr(&arena, " world");
    const folded = try foldTopExpr(&arena, try exprPtr(&arena, .{ .Prim = .{
        .op = .StringConcat,
        .args = args,
        .ty = .String,
        .layout = layout.defaultFor(.StringLiteral),
    } }));

    try std.testing.expectEqualStrings("hello world", folded.Constant.value.String);
}
