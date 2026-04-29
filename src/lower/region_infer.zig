//! Escape analysis for Core IR region inference.
//!
//! RESPONSIBILITIES:
//! - Walk Core IR function bodies and conservatively identify let-bound values
//!   that escape their enclosing function scope.
//! - Refine layouts for non-escaping primitive let-bound values to `Stack`.
//! - Preserve soundness by keeping escaping let-bound values in `Arena`.

const std = @import("std");
const ir = @import("../core/ir.zig");
const layout = @import("../core/layout.zig");

/// Errors produced by the Core IR region inference pass.
pub const InferError = std.mem.Allocator.Error;

/// Refines Core IR layouts by marking non-escaping primitive lets as stack values.
pub fn inferModule(arena: *std.heap.ArenaAllocator, module: ir.Module) InferError!ir.Module {
    const allocator = arena.allocator();
    const decls = try allocator.alloc(ir.Decl, module.decls.len);
    for (module.decls, 0..) |decl, index| {
        decls[index] = switch (decl) {
            .Let => |let_decl| .{ .Let = try inferTopLevelLet(arena, let_decl) },
        };
    }
    return .{
        .decls = decls,
        .type_decls = module.type_decls,
        .tuple_type_decls = module.tuple_type_decls,
        .record_type_decls = module.record_type_decls,
        .externals = module.externals,
    };
}

fn inferTopLevelLet(arena: *std.heap.ArenaAllocator, let_decl: ir.Let) InferError!ir.Let {
    const value = try inferExprPtr(arena, let_decl.value.*, false);
    return .{
        .name = let_decl.name,
        .value = value,
        .ty = let_decl.ty,
        .layout = let_decl.layout,
        .is_rec = let_decl.is_rec,
    };
}

fn inferExprPtr(arena: *std.heap.ArenaAllocator, expr: ir.Expr, escape_context: bool) InferError!*const ir.Expr {
    const allocator = arena.allocator();
    const ptr = try allocator.create(ir.Expr);
    ptr.* = try inferExpr(arena, expr, escape_context);
    return ptr;
}

fn inferExpr(arena: *std.heap.ArenaAllocator, expr: ir.Expr, escape_context: bool) InferError!ir.Expr {
    return switch (expr) {
        .Lambda => |lambda| .{ .Lambda = try inferLambda(arena, lambda) },
        .Constant => expr,
        .App => |app| .{ .App = .{
            .callee = try inferExprPtr(arena, app.callee.*, false),
            .args = try inferExprPtrs(arena, app.args, true),
            .ty = app.ty,
            .layout = if (escape_context and app.layout.region == .Stack) arenaLayout(app.layout) else app.layout,
        } },
        .Let => |let_expr| blk: {
            var ctx = AnalyzeContext.init(arena.allocator());
            defer ctx.deinit();
            try ctx.analyzeExpr(let_expr.body.*, escape_context);
            const binding_escapes = ctx.bindingEscapes(let_expr.name);
            try ctx.analyzeExpr(let_expr.value.*, binding_escapes);

            var clone = CloneContext.init(arena.allocator(), &ctx.escapes);
            defer clone.deinit();
            break :blk .{ .Let = try clone.cloneLetExpr(let_expr, escape_context) };
        },
        .If => |if_expr| .{ .If = .{
            .cond = try inferExprPtr(arena, if_expr.cond.*, false),
            .then_branch = try inferExprPtr(arena, if_expr.then_branch.*, escape_context),
            .else_branch = try inferExprPtr(arena, if_expr.else_branch.*, escape_context),
            .ty = if_expr.ty,
            .layout = if_expr.layout,
        } },
        .Prim => |prim| .{ .Prim = .{
            .op = prim.op,
            .args = try inferExprPtrs(arena, prim.args, false),
            .ty = prim.ty,
            .layout = if (escape_context and prim.layout.region == .Stack) arenaLayout(prim.layout) else prim.layout,
        } },
        .Var => expr,
        .Ctor => |ctor| .{ .Ctor = .{
            .name = ctor.name,
            .args = try inferExprPtrs(arena, ctor.args, escape_context),
            .ty = ctor.ty,
            .layout = if (escape_context and ctor.layout.region == .Stack) arenaLayout(ctor.layout) else ctor.layout,
            .tag = ctor.tag,
            .type_name = ctor.type_name,
        } },
        .Match => |match_expr| .{ .Match = .{
            .scrutinee = try inferExprPtr(arena, match_expr.scrutinee.*, escape_context),
            .arms = try inferArms(arena, match_expr.arms, escape_context),
            .ty = match_expr.ty,
            .layout = match_expr.layout,
        } },
        .Tuple => |tuple_expr| .{ .Tuple = .{
            .items = try inferExprPtrs(arena, tuple_expr.items, escape_context),
            .ty = tuple_expr.ty,
            .layout = if (escape_context and tuple_expr.layout.region == .Stack) arenaLayout(tuple_expr.layout) else tuple_expr.layout,
        } },
        .TupleProj => |tuple_proj| .{ .TupleProj = .{
            .tuple_expr = try inferExprPtr(arena, tuple_proj.tuple_expr.*, false),
            .index = tuple_proj.index,
            .ty = tuple_proj.ty,
            .layout = tuple_proj.layout,
        } },
        .Record => |record_expr| .{ .Record = .{
            .fields = try inferRecordFields(arena, record_expr.fields, escape_context),
            .ty = record_expr.ty,
            .layout = if (escape_context and record_expr.layout.region == .Stack) arenaLayout(record_expr.layout) else record_expr.layout,
        } },
        .RecordField => |record_field| .{ .RecordField = .{
            .record_expr = try inferExprPtr(arena, record_field.record_expr.*, false),
            .field_name = record_field.field_name,
            .ty = record_field.ty,
            .layout = record_field.layout,
        } },
        .RecordUpdate => |record_update| .{ .RecordUpdate = .{
            .base_expr = try inferExprPtr(arena, record_update.base_expr.*, escape_context),
            .fields = try inferRecordFields(arena, record_update.fields, escape_context),
            .ty = record_update.ty,
            .layout = if (escape_context and record_update.layout.region == .Stack) arenaLayout(record_update.layout) else record_update.layout,
        } },
        .AccountFieldSet => |field_set| .{ .AccountFieldSet = .{
            .account_expr = try inferExprPtr(arena, field_set.account_expr.*, true),
            .field_name = field_set.field_name,
            .value = try inferExprPtr(arena, field_set.value.*, true),
            .ty = field_set.ty,
            .layout = field_set.layout,
        } },
    };
}

fn inferLambda(arena: *std.heap.ArenaAllocator, lambda: ir.Lambda) InferError!ir.Lambda {
    var ctx = AnalyzeContext.init(arena.allocator());
    defer ctx.deinit();
    try ctx.analyzeExpr(lambda.body.*, true);

    var clone = CloneContext.init(arena.allocator(), &ctx.escapes);
    defer clone.deinit();

    return .{
        .params = lambda.params,
        .body = try clone.cloneExprPtr(lambda.body.*, true),
        .ty = lambda.ty,
        .layout = lambda.layout,
    };
}

fn inferExprPtrs(arena: *std.heap.ArenaAllocator, exprs: []const *const ir.Expr, escape_context: bool) InferError![]const *const ir.Expr {
    const allocator = arena.allocator();
    const out = try allocator.alloc(*const ir.Expr, exprs.len);
    for (exprs, 0..) |expr, index| {
        out[index] = try inferExprPtr(arena, expr.*, escape_context);
    }
    return out;
}

fn inferArms(arena: *std.heap.ArenaAllocator, arms: []const ir.Arm, escape_context: bool) InferError![]const ir.Arm {
    const allocator = arena.allocator();
    const out = try allocator.alloc(ir.Arm, arms.len);
    for (arms, 0..) |arm, index| {
        out[index] = .{
            .pattern = arm.pattern,
            .guard = if (arm.guard) |guard| try inferExprPtr(arena, guard.*, false) else null,
            .body = try inferExprPtr(arena, arm.body.*, escape_context),
        };
    }
    return out;
}

fn inferRecordFields(arena: *std.heap.ArenaAllocator, fields: []const ir.RecordExprField, escape_context: bool) InferError![]const ir.RecordExprField {
    const allocator = arena.allocator();
    const out = try allocator.alloc(ir.RecordExprField, fields.len);
    for (fields, 0..) |field, index| {
        out[index] = .{
            .name = field.name,
            .value = try inferExprPtr(arena, field.value.*, escape_context),
        };
    }
    return out;
}

const AnalyzeContext = struct {
    allocator: std.mem.Allocator,
    escapes: std.StringHashMap(bool),

    fn init(allocator: std.mem.Allocator) AnalyzeContext {
        return .{
            .allocator = allocator,
            .escapes = std.StringHashMap(bool).init(allocator),
        };
    }

    fn deinit(self: *AnalyzeContext) void {
        self.escapes.deinit();
    }

    fn ensureBinding(self: *AnalyzeContext, name: []const u8) InferError!void {
        if (!self.escapes.contains(name)) try self.escapes.put(name, false);
    }

    fn markEscape(self: *AnalyzeContext, name: []const u8) void {
        if (self.escapes.getPtr(name)) |value| value.* = true;
    }

    fn bindingEscapes(self: *const AnalyzeContext, name: []const u8) bool {
        return self.escapes.get(name) orelse false;
    }

    fn analyzeExpr(self: *AnalyzeContext, expr: ir.Expr, escape_context: bool) InferError!void {
        switch (expr) {
            .Lambda => |lambda| try self.markLambdaCaptures(lambda),
            .Constant => {},
            .App => |app| {
                try self.analyzeExpr(app.callee.*, false);
                for (app.args) |arg| try self.analyzeExpr(arg.*, true);
            },
            .Let => |let_expr| {
                try self.ensureBinding(let_expr.name);
                try self.analyzeExpr(let_expr.body.*, escape_context);
                const value_escapes = self.bindingEscapes(let_expr.name);
                try self.analyzeExpr(let_expr.value.*, value_escapes);
            },
            .If => |if_expr| {
                try self.analyzeExpr(if_expr.cond.*, false);
                try self.analyzeExpr(if_expr.then_branch.*, escape_context);
                try self.analyzeExpr(if_expr.else_branch.*, escape_context);
            },
            .Prim => |prim| {
                for (prim.args) |arg| try self.analyzeExpr(arg.*, false);
            },
            .Var => |var_ref| if (escape_context) self.markEscape(var_ref.name),
            .Ctor => |ctor| {
                for (ctor.args) |arg| try self.analyzeExpr(arg.*, escape_context);
            },
            .Match => |match_expr| {
                try self.analyzeExpr(match_expr.scrutinee.*, escape_context);
                for (match_expr.arms) |arm| {
                    if (arm.guard) |guard| try self.analyzeExpr(guard.*, false);
                    try self.analyzeExpr(arm.body.*, escape_context);
                }
            },
            .Tuple => |tuple_expr| {
                for (tuple_expr.items) |item| try self.analyzeExpr(item.*, escape_context);
            },
            .TupleProj => |tuple_proj| try self.analyzeExpr(tuple_proj.tuple_expr.*, false),
            .Record => |record_expr| {
                for (record_expr.fields) |field| try self.analyzeExpr(field.value.*, escape_context);
            },
            .RecordField => |record_field| try self.analyzeExpr(record_field.record_expr.*, false),
            .RecordUpdate => |record_update| {
                try self.analyzeExpr(record_update.base_expr.*, escape_context);
                for (record_update.fields) |field| try self.analyzeExpr(field.value.*, escape_context);
            },
            .AccountFieldSet => |field_set| {
                try self.analyzeExpr(field_set.account_expr.*, true);
                try self.analyzeExpr(field_set.value.*, true);
            },
        }
    }

    fn markLambdaCaptures(self: *AnalyzeContext, lambda: ir.Lambda) InferError!void {
        var collector = FreeVarCollector.init(self.allocator, self);
        defer collector.deinit();
        for (lambda.params) |param| try collector.bind(param.name);
        try collector.visit(lambda.body.*);
    }
};

const FreeVarCollector = struct {
    allocator: std.mem.Allocator,
    analyzer: *AnalyzeContext,
    bound: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator, analyzer: *AnalyzeContext) FreeVarCollector {
        return .{
            .allocator = allocator,
            .analyzer = analyzer,
            .bound = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *FreeVarCollector) void {
        self.bound.deinit();
    }

    fn bind(self: *FreeVarCollector, name: []const u8) InferError!void {
        try self.bound.put(name, {});
    }

    fn visit(self: *FreeVarCollector, expr: ir.Expr) InferError!void {
        switch (expr) {
            .Lambda => |lambda| {
                for (lambda.params) |param| try self.bind(param.name);
                try self.visit(lambda.body.*);
            },
            .Constant => {},
            .App => |app| {
                try self.visit(app.callee.*);
                for (app.args) |arg| try self.visit(arg.*);
            },
            .Let => |let_expr| {
                try self.visit(let_expr.value.*);
                try self.bind(let_expr.name);
                try self.visit(let_expr.body.*);
            },
            .If => |if_expr| {
                try self.visit(if_expr.cond.*);
                try self.visit(if_expr.then_branch.*);
                try self.visit(if_expr.else_branch.*);
            },
            .Prim => |prim| {
                for (prim.args) |arg| try self.visit(arg.*);
            },
            .Var => |var_ref| {
                if (!self.bound.contains(var_ref.name)) self.analyzer.markEscape(var_ref.name);
            },
            .Ctor => |ctor| {
                for (ctor.args) |arg| try self.visit(arg.*);
            },
            .Match => |match_expr| {
                try self.visit(match_expr.scrutinee.*);
                for (match_expr.arms) |arm| {
                    try self.bindPattern(arm.pattern);
                    if (arm.guard) |guard| try self.visit(guard.*);
                    try self.visit(arm.body.*);
                }
            },
            .Tuple => |tuple_expr| {
                for (tuple_expr.items) |item| try self.visit(item.*);
            },
            .TupleProj => |tuple_proj| try self.visit(tuple_proj.tuple_expr.*),
            .Record => |record_expr| {
                for (record_expr.fields) |field| try self.visit(field.value.*);
            },
            .RecordField => |record_field| try self.visit(record_field.record_expr.*),
            .RecordUpdate => |record_update| {
                try self.visit(record_update.base_expr.*);
                for (record_update.fields) |field| try self.visit(field.value.*);
            },
            .AccountFieldSet => |field_set| {
                try self.visit(field_set.account_expr.*);
                try self.visit(field_set.value.*);
            },
        }
    }

    fn bindPattern(self: *FreeVarCollector, pattern: ir.Pattern) InferError!void {
        switch (pattern) {
            .Wildcard => {},
            .Var => |var_pattern| try self.bind(var_pattern.name),
            .Ctor => |ctor| for (ctor.args) |arg| try self.bindPattern(arg),
            .Tuple => |items| for (items) |item| try self.bindPattern(item),
            .Record => |fields| for (fields) |field| try self.bindPattern(field.pattern),
        }
    }
};

const CloneContext = struct {
    allocator: std.mem.Allocator,
    escapes: *const std.StringHashMap(bool),
    layouts: std.StringHashMap(layout.Layout),

    fn init(allocator: std.mem.Allocator, escapes: *const std.StringHashMap(bool)) CloneContext {
        return .{
            .allocator = allocator,
            .escapes = escapes,
            .layouts = std.StringHashMap(layout.Layout).init(allocator),
        };
    }

    fn deinit(self: *CloneContext) void {
        self.layouts.deinit();
    }

    fn cloneLetExpr(self: *CloneContext, let_expr: ir.LetExpr, escape_context: bool) InferError!ir.LetExpr {
        const binding_escapes = self.escapes.get(let_expr.name) orelse false;
        const binding_layout = inferBindingLayout(let_expr.value.*, exprLayout(let_expr.value.*), binding_escapes);
        const previous = self.layouts.get(let_expr.name);
        try self.layouts.put(let_expr.name, binding_layout);
        defer restoreLayout(&self.layouts, let_expr.name, previous);

        const cloned_value = try self.cloneExprPtr(let_expr.value.*, binding_escapes);
        const adjusted_value = try self.forceExprLayoutPtr(cloned_value, binding_layout);
        const cloned_body = try self.cloneExprPtr(let_expr.body.*, escape_context);
        return .{
            .name = let_expr.name,
            .value = adjusted_value,
            .body = cloned_body,
            .ty = let_expr.ty,
            .layout = exprLayout(cloned_body.*),
            .is_rec = let_expr.is_rec,
        };
    }

    fn cloneExprPtr(self: *CloneContext, expr: ir.Expr, escape_context: bool) InferError!*const ir.Expr {
        const ptr = try self.allocator.create(ir.Expr);
        ptr.* = try self.cloneExpr(expr, escape_context);
        return ptr;
    }

    fn cloneExprPtrs(self: *CloneContext, exprs: []const *const ir.Expr, escape_context: bool) InferError![]const *const ir.Expr {
        const out = try self.allocator.alloc(*const ir.Expr, exprs.len);
        for (exprs, 0..) |expr, index| {
            out[index] = try self.cloneExprPtr(expr.*, escape_context);
        }
        return out;
    }

    fn cloneExpr(self: *CloneContext, expr: ir.Expr, escape_context: bool) InferError!ir.Expr {
        return switch (expr) {
            .Lambda => |lambda| .{ .Lambda = try inferLambdaFromAllocator(self.allocator, lambda) },
            .Constant => expr,
            .App => |app| .{ .App = .{
                .callee = try self.cloneExprPtr(app.callee.*, false),
                .args = try self.cloneExprPtrs(app.args, true),
                .ty = app.ty,
                .layout = if (escape_context and app.layout.region == .Stack) arenaLayout(app.layout) else app.layout,
            } },
            .Let => |let_expr| .{ .Let = try self.cloneLetExpr(let_expr, escape_context) },
            .If => |if_expr| .{ .If = .{
                .cond = try self.cloneExprPtr(if_expr.cond.*, false),
                .then_branch = try self.cloneExprPtr(if_expr.then_branch.*, escape_context),
                .else_branch = try self.cloneExprPtr(if_expr.else_branch.*, escape_context),
                .ty = if_expr.ty,
                .layout = if_expr.layout,
            } },
            .Prim => |prim| .{ .Prim = .{
                .op = prim.op,
                .args = try self.cloneExprPtrs(prim.args, false),
                .ty = prim.ty,
                .layout = if (escape_context and prim.layout.region == .Stack) arenaLayout(prim.layout) else prim.layout,
            } },
            .Var => |var_ref| .{ .Var = .{
                .name = var_ref.name,
                .ty = var_ref.ty,
                .layout = self.layouts.get(var_ref.name) orelse var_ref.layout,
            } },
            .Ctor => |ctor| .{ .Ctor = .{
                .name = ctor.name,
                .args = try self.cloneExprPtrs(ctor.args, escape_context),
                .ty = ctor.ty,
                .layout = if (escape_context and ctor.layout.region == .Stack) arenaLayout(ctor.layout) else ctor.layout,
                .tag = ctor.tag,
                .type_name = ctor.type_name,
            } },
            .Match => |match_expr| .{ .Match = .{
                .scrutinee = try self.cloneExprPtr(match_expr.scrutinee.*, escape_context),
                .arms = try self.cloneArms(match_expr.arms, escape_context),
                .ty = match_expr.ty,
                .layout = match_expr.layout,
            } },
            .Tuple => |tuple_expr| .{ .Tuple = .{
                .items = try self.cloneExprPtrs(tuple_expr.items, escape_context),
                .ty = tuple_expr.ty,
                .layout = if (escape_context and tuple_expr.layout.region == .Stack) arenaLayout(tuple_expr.layout) else tuple_expr.layout,
            } },
            .TupleProj => |tuple_proj| .{ .TupleProj = .{
                .tuple_expr = try self.cloneExprPtr(tuple_proj.tuple_expr.*, false),
                .index = tuple_proj.index,
                .ty = tuple_proj.ty,
                .layout = tuple_proj.layout,
            } },
            .Record => |record_expr| .{ .Record = .{
                .fields = try self.cloneRecordFields(record_expr.fields, escape_context),
                .ty = record_expr.ty,
                .layout = if (escape_context and record_expr.layout.region == .Stack) arenaLayout(record_expr.layout) else record_expr.layout,
            } },
            .RecordField => |record_field| .{ .RecordField = .{
                .record_expr = try self.cloneExprPtr(record_field.record_expr.*, false),
                .field_name = record_field.field_name,
                .ty = record_field.ty,
                .layout = record_field.layout,
            } },
            .RecordUpdate => |record_update| .{ .RecordUpdate = .{
                .base_expr = try self.cloneExprPtr(record_update.base_expr.*, escape_context),
                .fields = try self.cloneRecordFields(record_update.fields, escape_context),
                .ty = record_update.ty,
                .layout = if (escape_context and record_update.layout.region == .Stack) arenaLayout(record_update.layout) else record_update.layout,
            } },
            .AccountFieldSet => |field_set| .{ .AccountFieldSet = .{
                .account_expr = try self.cloneExprPtr(field_set.account_expr.*, true),
                .field_name = field_set.field_name,
                .value = try self.cloneExprPtr(field_set.value.*, true),
                .ty = field_set.ty,
                .layout = field_set.layout,
            } },
        };
    }

    fn cloneArms(self: *CloneContext, arms: []const ir.Arm, escape_context: bool) InferError![]const ir.Arm {
        const out = try self.allocator.alloc(ir.Arm, arms.len);
        for (arms, 0..) |arm, index| {
            out[index] = .{
                .pattern = arm.pattern,
                .guard = if (arm.guard) |guard| try self.cloneExprPtr(guard.*, false) else null,
                .body = try self.cloneExprPtr(arm.body.*, escape_context),
            };
        }
        return out;
    }

    fn cloneRecordFields(self: *CloneContext, fields: []const ir.RecordExprField, escape_context: bool) InferError![]const ir.RecordExprField {
        const out = try self.allocator.alloc(ir.RecordExprField, fields.len);
        for (fields, 0..) |field, index| {
            out[index] = .{
                .name = field.name,
                .value = try self.cloneExprPtr(field.value.*, escape_context),
            };
        }
        return out;
    }

    fn forceExprLayoutPtr(self: *CloneContext, expr: *const ir.Expr, new_layout: layout.Layout) InferError!*const ir.Expr {
        const ptr = try self.allocator.create(ir.Expr);
        ptr.* = forceExprLayout(expr.*, new_layout);
        return ptr;
    }
};

fn inferLambdaFromAllocator(allocator: std.mem.Allocator, lambda: ir.Lambda) InferError!ir.Lambda {
    var ctx = AnalyzeContext.init(allocator);
    defer ctx.deinit();
    try ctx.analyzeExpr(lambda.body.*, true);

    var clone = CloneContext.init(allocator, &ctx.escapes);
    defer clone.deinit();
    return .{
        .params = lambda.params,
        .body = try clone.cloneExprPtr(lambda.body.*, true),
        .ty = lambda.ty,
        .layout = lambda.layout,
    };
}

fn restoreLayout(map: *std.StringHashMap(layout.Layout), name: []const u8, previous: ?layout.Layout) void {
    if (previous) |value| {
        map.put(name, value) catch unreachable;
    } else {
        _ = map.remove(name);
    }
}

fn inferBindingLayout(value: ir.Expr, original: layout.Layout, escapes: bool) layout.Layout {
    if (escapes) return arenaLayout(original);
    if (isPrimitiveStackCandidate(value)) return .{ .region = .Stack, .repr = original.repr };
    return original;
}

fn isPrimitiveStackCandidate(expr: ir.Expr) bool {
    return switch (expr) {
        .Constant => true,
        .Prim => true,
        else => false,
    };
}

fn arenaLayout(original: layout.Layout) layout.Layout {
    return .{ .region = .Arena, .repr = original.repr };
}

fn forceExprLayout(expr: ir.Expr, new_layout: layout.Layout) ir.Expr {
    return switch (expr) {
        .Lambda => |lambda| .{ .Lambda = .{
            .params = lambda.params,
            .body = lambda.body,
            .ty = lambda.ty,
            .layout = new_layout,
        } },
        .Constant => |constant| .{ .Constant = .{
            .value = constant.value,
            .ty = constant.ty,
            .layout = new_layout,
        } },
        .App => |app| .{ .App = .{
            .callee = app.callee,
            .args = app.args,
            .ty = app.ty,
            .layout = new_layout,
        } },
        .Let => |let_expr| .{ .Let = .{
            .name = let_expr.name,
            .value = let_expr.value,
            .body = let_expr.body,
            .ty = let_expr.ty,
            .layout = new_layout,
            .is_rec = let_expr.is_rec,
        } },
        .If => |if_expr| .{ .If = .{
            .cond = if_expr.cond,
            .then_branch = if_expr.then_branch,
            .else_branch = if_expr.else_branch,
            .ty = if_expr.ty,
            .layout = new_layout,
        } },
        .Prim => |prim| .{ .Prim = .{
            .op = prim.op,
            .args = prim.args,
            .ty = prim.ty,
            .layout = new_layout,
        } },
        .Var => |var_ref| .{ .Var = .{
            .name = var_ref.name,
            .ty = var_ref.ty,
            .layout = new_layout,
        } },
        .Ctor => |ctor| .{ .Ctor = .{
            .name = ctor.name,
            .args = ctor.args,
            .ty = ctor.ty,
            .layout = new_layout,
            .tag = ctor.tag,
            .type_name = ctor.type_name,
        } },
        .Match => |match_expr| .{ .Match = .{
            .scrutinee = match_expr.scrutinee,
            .arms = match_expr.arms,
            .ty = match_expr.ty,
            .layout = new_layout,
        } },
        .Tuple => |tuple_expr| .{ .Tuple = .{
            .items = tuple_expr.items,
            .ty = tuple_expr.ty,
            .layout = new_layout,
        } },
        .TupleProj => |tuple_proj| .{ .TupleProj = .{
            .tuple_expr = tuple_proj.tuple_expr,
            .index = tuple_proj.index,
            .ty = tuple_proj.ty,
            .layout = new_layout,
        } },
        .Record => |record_expr| .{ .Record = .{
            .fields = record_expr.fields,
            .ty = record_expr.ty,
            .layout = new_layout,
        } },
        .RecordField => |record_field| .{ .RecordField = .{
            .record_expr = record_field.record_expr,
            .field_name = record_field.field_name,
            .ty = record_field.ty,
            .layout = new_layout,
        } },
        .RecordUpdate => |record_update| .{ .RecordUpdate = .{
            .base_expr = record_update.base_expr,
            .fields = record_update.fields,
            .ty = record_update.ty,
            .layout = new_layout,
        } },
        .AccountFieldSet => |field_set| .{ .AccountFieldSet = .{
            .account_expr = field_set.account_expr,
            .field_name = field_set.field_name,
            .value = field_set.value,
            .ty = field_set.ty,
            .layout = new_layout,
        } },
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
        .Tuple => |tuple_expr| tuple_expr.layout,
        .TupleProj => |tuple_proj| tuple_proj.layout,
        .Record => |record_expr| record_expr.layout,
        .RecordField => |record_field| record_field.layout,
        .RecordUpdate => |record_update| record_update.layout,
        .AccountFieldSet => |field_set| field_set.layout,
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
        .Ctor => |ctor_expr| ctor_expr.ty,
        .Match => |match_expr| match_expr.ty,
        .Tuple => |tuple_expr| tuple_expr.ty,
        .TupleProj => |tuple_proj| tuple_proj.ty,
        .Record => |record_expr| record_expr.ty,
        .RecordField => |record_field| record_field.ty,
        .RecordUpdate => |record_update| record_update.ty,
        .AccountFieldSet => |field_set| field_set.ty,
    };
}

fn expectLayoutRegion(expr: *const ir.Expr, expected: layout.Region) !void {
    try std.testing.expectEqual(expected, exprLayout(expr.*).region);
}

fn makeExpr(arena: *std.heap.ArenaAllocator, expr: ir.Expr) !*const ir.Expr {
    const ptr = try arena.allocator().create(ir.Expr);
    ptr.* = expr;
    return ptr;
}

fn intConst(arena: *std.heap.ArenaAllocator, value: i64) !*const ir.Expr {
    return makeExpr(arena, .{ .Constant = .{
        .value = .{ .Int = value },
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
}

fn varRef(arena: *std.heap.ArenaAllocator, name: []const u8, ty: ir.Ty) !*const ir.Expr {
    return makeExpr(arena, .{ .Var = .{
        .name = name,
        .ty = ty,
        .layout = layout.intConstant(),
    } });
}

fn primAdd(arena: *std.heap.ArenaAllocator, lhs: *const ir.Expr, rhs: *const ir.Expr) !*const ir.Expr {
    const args = try arena.allocator().alloc(*const ir.Expr, 2);
    args[0] = lhs;
    args[1] = rhs;
    return makeExpr(arena, .{ .Prim = .{
        .op = .Add,
        .args = args,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
}

fn letExpr(arena: *std.heap.ArenaAllocator, name: []const u8, value: *const ir.Expr, body: *const ir.Expr) !*const ir.Expr {
    return makeExpr(arena, .{ .Let = .{
        .name = name,
        .value = value,
        .body = body,
        .ty = exprTy(body.*),
        .layout = exprLayout(body.*),
    } });
}

fn arrowTy(arena: *std.heap.ArenaAllocator, params: []const ir.Ty, ret: ir.Ty) !ir.Ty {
    const param_copy = try arena.allocator().alloc(ir.Ty, params.len);
    @memcpy(param_copy, params);
    const ret_ptr = try arena.allocator().create(ir.Ty);
    ret_ptr.* = ret;
    return .{ .Arrow = .{ .params = param_copy, .ret = ret_ptr } };
}

fn moduleWithBody(arena: *std.heap.ArenaAllocator, body: *const ir.Expr) !ir.Module {
    const params = try arena.allocator().alloc(ir.Param, 1);
    params[0] = .{ .name = "_input", .ty = .Unit };
    const lambda_ty = try arrowTy(arena, &.{.Unit}, exprTy(body.*));
    const lambda = try makeExpr(arena, .{ .Lambda = .{
        .params = params,
        .body = body,
        .ty = lambda_ty,
        .layout = layout.topLevelLambda(),
    } });
    const decls = try arena.allocator().alloc(ir.Decl, 1);
    decls[0] = .{ .Let = .{
        .name = "entrypoint",
        .value = lambda,
        .ty = lambda_ty,
        .layout = layout.topLevelLambda(),
    } };
    return .{ .decls = decls };
}

fn inferredEntrypointBody(arena: *std.heap.ArenaAllocator, body: *const ir.Expr) !*const ir.Expr {
    const module = try moduleWithBody(arena, body);
    const inferred = try inferModule(arena, module);
    const entrypoint = switch (inferred.decls[0]) {
        .Let => |value| value,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    return lambda.body;
}

test "escape analysis marks non-escaping primitive lets as stack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const x_value = try intConst(&arena, 1);
    const x_use = try varRef(&arena, "x", .Int);
    const y_value = try primAdd(&arena, x_use, try intConst(&arena, 2));
    const body = try letExpr(&arena, "x", x_value, try letExpr(&arena, "y", y_value, try intConst(&arena, 0)));

    const inferred = try inferredEntrypointBody(&arena, body);
    const x_let = switch (inferred.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectLayoutRegion(x_let.value, .Stack);
    const y_let = switch (x_let.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectLayoutRegion(y_let.value, .Stack);
}

test "escape analysis keeps function arguments in arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const f_ty = try arrowTy(&arena, &.{.Int}, .Int);
    const args = try arena.allocator().alloc(*const ir.Expr, 1);
    args[0] = try varRef(&arena, "x", .Int);
    const app = try makeExpr(&arena, .{ .App = .{
        .callee = try varRef(&arena, "f", f_ty),
        .args = args,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const body = try letExpr(&arena, "x", try intConst(&arena, 1), app);

    const inferred = try inferredEntrypointBody(&arena, body);
    const x_let = switch (inferred.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectLayoutRegion(x_let.value, .Arena);
    const inferred_app = switch (x_let.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectLayoutRegion(inferred_app.args[0], .Arena);
}

test "escape analysis keeps closure captures in arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lambda_ty = try arrowTy(&arena, &.{}, .Int);
    const captured_body = try varRef(&arena, "x", .Int);
    const closure = try makeExpr(&arena, .{ .Lambda = .{
        .params = &.{},
        .body = captured_body,
        .ty = lambda_ty,
        .layout = layout.closure(),
    } });
    const body = try letExpr(&arena, "x", try intConst(&arena, 1), try letExpr(&arena, "f", closure, try intConst(&arena, 0)));

    const inferred = try inferredEntrypointBody(&arena, body);
    const x_let = switch (inferred.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectLayoutRegion(x_let.value, .Arena);
}

test "escape analysis propagates through escaping tuples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const items = try arena.allocator().alloc(*const ir.Expr, 2);
    items[0] = try varRef(&arena, "x", .Int);
    items[1] = try intConst(&arena, 2);
    const tuple_ty_items = try arena.allocator().alloc(ir.Ty, 2);
    tuple_ty_items[0] = .Int;
    tuple_ty_items[1] = .Int;
    const tuple_value = try makeExpr(&arena, .{ .Tuple = .{
        .items = items,
        .ty = .{ .Tuple = tuple_ty_items },
        .layout = layout.structPack(),
    } });
    const body = try letExpr(&arena, "x", try intConst(&arena, 1), try letExpr(&arena, "pair", tuple_value, try varRef(&arena, "pair", .{ .Tuple = tuple_ty_items })));

    const inferred = try inferredEntrypointBody(&arena, body);
    const x_let = switch (inferred.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectLayoutRegion(x_let.value, .Arena);
    const pair_let = switch (x_let.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectLayoutRegion(pair_let.value, .Arena);
    const tuple = switch (pair_let.value.*) {
        .Tuple => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectLayoutRegion(tuple.items[0], .Arena);
}

test "escape analysis propagates through escaping match scrutinees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const arms = try arena.allocator().alloc(ir.Arm, 1);
    arms[0] = .{ .pattern = .Wildcard, .body = try intConst(&arena, 0) };
    const match_expr = try makeExpr(&arena, .{ .Match = .{
        .scrutinee = try varRef(&arena, "x", .Int),
        .arms = arms,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const body = try letExpr(&arena, "x", try intConst(&arena, 1), match_expr);

    const inferred = try inferredEntrypointBody(&arena, body);
    const x_let = switch (inferred.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectLayoutRegion(x_let.value, .Arena);
    const inferred_match = switch (x_let.body.*) {
        .Match => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectLayoutRegion(inferred_match.scrutinee, .Arena);
}
