const std = @import("std");
const ir = @import("../ir.zig");
const context = @import("context.zig");

const LowerError = context.LowerError;

pub fn markTailCallsInFunction(arena: *std.heap.ArenaAllocator, value: *const ir.Expr, function_name: []const u8) LowerError!*const ir.Expr {
    return switch (value.*) {
        .Lambda => |lambda| blk: {
            var marked_lambda = lambda;
            var scope = TailCallScope{ .function_name = function_name };
            for (lambda.params) |param| {
                scope = scope.shadowedByName(param.name);
            }
            marked_lambda.body = try markTailPosition(arena, lambda.body, scope);
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .Lambda = marked_lambda };
            break :blk marked;
        },
        else => value,
    };
}

const TailCallScope = struct {
    function_name: []const u8,
    self_binding_visible: bool = true,

    fn shadowedByName(self: TailCallScope, name: []const u8) TailCallScope {
        if (!self.self_binding_visible or !std.mem.eql(u8, name, self.function_name)) return self;
        return .{
            .function_name = self.function_name,
            .self_binding_visible = false,
        };
    }

    fn shadowedByPattern(self: TailCallScope, pattern: ir.Pattern) TailCallScope {
        if (!self.self_binding_visible or !patternBindsName(pattern, self.function_name)) return self;
        return .{
            .function_name = self.function_name,
            .self_binding_visible = false,
        };
    }
};

pub fn patternBindsName(pattern: ir.Pattern, name: []const u8) bool {
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

pub fn markTailPosition(arena: *std.heap.ArenaAllocator, expr: *const ir.Expr, scope: TailCallScope) LowerError!*const ir.Expr {
    return switch (expr.*) {
        .App => |app| blk: {
            var marked_app = app;
            marked_app.is_tail_call = isSelfCall(app, scope);
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .App = marked_app };
            break :blk marked;
        },
        .If => |if_expr| blk: {
            var marked_if = if_expr;
            marked_if.then_branch = try markTailPosition(arena, if_expr.then_branch, scope);
            marked_if.else_branch = try markTailPosition(arena, if_expr.else_branch, scope);
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .If = marked_if };
            break :blk marked;
        },
        .Let => |let_expr| blk: {
            var marked_let = let_expr;
            marked_let.body = try markTailPosition(arena, let_expr.body, scope.shadowedByName(let_expr.name));
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .Let = marked_let };
            break :blk marked;
        },
        .LetGroup => |group| blk: {
            var marked_group = group;
            var body_scope = scope;
            for (group.bindings) |binding| body_scope = body_scope.shadowedByName(binding.name);
            marked_group.body = try markTailPosition(arena, group.body, body_scope);
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .LetGroup = marked_group };
            break :blk marked;
        },
        .Assert => expr,
        .Match => |match_expr| blk: {
            const arms = try arena.allocator().alloc(ir.Arm, match_expr.arms.len);
            for (match_expr.arms, 0..) |arm, index| {
                arms[index] = .{
                    .pattern = arm.pattern,
                    .guard = arm.guard,
                    .body = try markTailPosition(arena, arm.body, scope.shadowedByPattern(arm.pattern)),
                };
            }
            var marked_match = match_expr;
            marked_match.arms = arms;
            const marked = try arena.allocator().create(ir.Expr);
            marked.* = .{ .Match = marked_match };
            break :blk marked;
        },
        .Lambda, .Constant, .Prim, .Var, .Ctor, .Tuple, .TupleProj, .Record, .RecordField, .RecordUpdate, .AccountFieldSet => expr,
    };
}

pub fn isSelfCall(app: ir.App, scope: TailCallScope) bool {
    if (!scope.self_binding_visible) return false;
    return switch (app.callee.*) {
        .Var => |callee| std.mem.eql(u8, callee.name, scope.function_name),
        else => false,
    };
}
