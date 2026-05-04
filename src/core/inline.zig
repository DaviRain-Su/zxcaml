//! Function inlining for Core IR optimization.
//!
//! RESPONSIBILITIES:
//! - Identify small Core IR lambda bindings and inline known call sites.
//! - Clone inlined bodies with alpha-renaming so call-site variables are not
//!   captured by binders inside the inlined function body.
//! - Preserve lexical shadowing by only inlining captured variables when the
//!   call-site scope still refers to the same binding identity.
//! - Leave recursive and multi-expression functions untouched.

const std = @import("std");
const build_options = @import("build_options");
const ir = @import("ir.zig");
const layout = @import("layout.zig");

/// Errors produced by the Core IR function inlining pass.
pub const InlineError = std.mem.Allocator.Error;

pub const max_small_body_nodes = build_options.inline_max_nodes;

const Capture = struct {
    name: []const u8,
    binding_id: ?usize,
};

const SmallFunction = struct {
    lambda: ir.Lambda,
    captures: []const Capture,
};

const FunctionEnvEntry = struct {
    function: ?SmallFunction = null,
};

const FunctionEnvChange = struct {
    name: []const u8,
    existed: bool,
    previous: FunctionEnvEntry = .{},
};

const ScopeChange = struct {
    name: []const u8,
    existed: bool,
    previous: usize = 0,
};

const NameBinding = union(enum) {
    Rename: []const u8,
    Substitute: *const ir.Expr,
};

const NameBindingChange = struct {
    name: []const u8,
    existed: bool,
    previous: NameBinding = .{ .Rename = "" },
};

const InlineContext = struct {
    arena: *std.heap.ArenaAllocator,
    functions: std.StringHashMap(FunctionEnvEntry),
    function_changes: std.ArrayList(FunctionEnvChange),
    scope: std.StringHashMap(usize),
    scope_changes: std.ArrayList(ScopeChange),
    next_binding_id: usize = 1,
    next_fresh_id: usize = 1,

    fn init(arena: *std.heap.ArenaAllocator) InlineContext {
        const arena_allocator = arena.allocator();
        return .{
            .arena = arena,
            .functions = std.StringHashMap(FunctionEnvEntry).init(arena_allocator),
            .function_changes = std.ArrayList(FunctionEnvChange).empty,
            .scope = std.StringHashMap(usize).init(arena_allocator),
            .scope_changes = std.ArrayList(ScopeChange).empty,
        };
    }

    fn deinit(self: *InlineContext) void {
        const arena_allocator = self.allocator();
        self.scope_changes.deinit(arena_allocator);
        self.scope.deinit();
        self.function_changes.deinit(arena_allocator);
        self.functions.deinit();
    }

    fn allocator(self: *InlineContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn functionMark(self: *const InlineContext) usize {
        return self.function_changes.items.len;
    }

    fn scopeMark(self: *const InlineContext) usize {
        return self.scope_changes.items.len;
    }

    fn restoreFunctions(self: *InlineContext, mark_index: usize) void {
        while (self.function_changes.items.len > mark_index) {
            const change = self.function_changes.pop().?;
            if (change.existed) {
                self.functions.getPtr(change.name).?.* = change.previous;
            } else {
                _ = self.functions.remove(change.name);
            }
        }
    }

    fn restoreScope(self: *InlineContext, mark_index: usize) void {
        while (self.scope_changes.items.len > mark_index) {
            const change = self.scope_changes.pop().?;
            if (change.existed) {
                self.scope.getPtr(change.name).?.* = change.previous;
            } else {
                _ = self.scope.remove(change.name);
            }
        }
    }

    fn pushFunction(self: *InlineContext, name: []const u8, function: SmallFunction) InlineError!void {
        try self.pushFunctionEntry(name, .{ .function = function });
    }

    fn shadowFunction(self: *InlineContext, name: []const u8) InlineError!void {
        try self.pushFunctionEntry(name, .{ .function = null });
    }

    fn pushFunctionEntry(self: *InlineContext, name: []const u8, entry: FunctionEnvEntry) InlineError!void {
        if (self.functions.get(name)) |previous| {
            try self.function_changes.append(self.allocator(), .{
                .name = name,
                .existed = true,
                .previous = previous,
            });
        } else {
            try self.function_changes.append(self.allocator(), .{
                .name = name,
                .existed = false,
            });
        }
        try self.functions.put(name, entry);
    }

    fn pushScopeBinding(self: *InlineContext, name: []const u8) InlineError!usize {
        const id = self.next_binding_id;
        self.next_binding_id += 1;
        if (self.scope.get(name)) |previous| {
            try self.scope_changes.append(self.allocator(), .{
                .name = name,
                .existed = true,
                .previous = previous,
            });
        } else {
            try self.scope_changes.append(self.allocator(), .{
                .name = name,
                .existed = false,
            });
        }
        try self.scope.put(name, id);
        return id;
    }

    fn collectTopLevelFunctions(self: *InlineContext, decls: []const ir.Decl) InlineError!void {
        for (decls) |decl| switch (decl) {
            .Let => |let_decl| {
                if (let_decl.is_rec) continue;
                if (try self.smallFunctionFromBinding(let_decl.name, let_decl.value.*)) |function| {
                    try self.pushFunction(let_decl.name, function);
                }
            },
            .LetGroup => |group| for (group.bindings) |binding| {
                try self.shadowFunction(binding.name);
            },
        };
    }

    fn inlineDecl(self: *InlineContext, decl: ir.Decl) InlineError!ir.Decl {
        return switch (decl) {
            .Let => |let_decl| blk: {
                const mark = self.functionMark();
                try self.shadowFunction(let_decl.name);
                const value = try self.inlineExprPtr(let_decl.value.*);
                self.restoreFunctions(mark);

                if (!let_decl.is_rec) {
                    if (try self.smallFunctionFromBinding(let_decl.name, value.*)) |function| {
                        try self.pushFunction(let_decl.name, function);
                    } else {
                        try self.shadowFunction(let_decl.name);
                    }
                } else {
                    try self.shadowFunction(let_decl.name);
                }

                break :blk .{ .Let = .{
                    .name = let_decl.name,
                    .value = value,
                    .ty = let_decl.ty,
                    .layout = let_decl.layout,
                    .is_rec = let_decl.is_rec,
                } };
            },
            .LetGroup => |group| blk: {
                const mark = self.functionMark();
                for (group.bindings) |binding| try self.shadowFunction(binding.name);
                const bindings = try self.inlineLetGroupBindings(group.bindings);
                self.restoreFunctions(mark);
                for (group.bindings) |binding| try self.shadowFunction(binding.name);
                break :blk .{ .LetGroup = .{ .bindings = bindings } };
            },
        };
    }

    fn inlineExprPtr(self: *InlineContext, expr: ir.Expr) InlineError!*const ir.Expr {
        const ptr = try self.allocator().create(ir.Expr);
        ptr.* = try self.inlineExpr(expr);
        return ptr;
    }

    fn inlineExprPtrs(self: *InlineContext, exprs: []const *const ir.Expr) InlineError![]const *const ir.Expr {
        const out = try self.allocator().alloc(*const ir.Expr, exprs.len);
        for (exprs, 0..) |expr, index| {
            out[index] = try self.inlineExprPtr(expr.*);
        }
        return out;
    }

    fn inlineExpr(self: *InlineContext, expr: ir.Expr) InlineError!ir.Expr {
        return switch (expr) {
            .Lambda => |lambda| try self.inlineLambda(lambda),
            .Constant => expr,
            .App => |app| try self.inlineApp(app),
            .Let => |let_expr| try self.inlineLet(let_expr),
            .LetGroup => |group| .{ .LetGroup = try self.inlineLetGroup(group) },
            .Assert => |assert_expr| .{ .Assert = .{
                .condition = try self.inlineExprPtr(assert_expr.condition.*),
                .ty = assert_expr.ty,
                .layout = assert_expr.layout,
            } },
            .If => |if_expr| .{ .If = .{
                .cond = try self.inlineExprPtr(if_expr.cond.*),
                .then_branch = try self.inlineExprPtr(if_expr.then_branch.*),
                .else_branch = try self.inlineExprPtr(if_expr.else_branch.*),
                .ty = if_expr.ty,
                .layout = if_expr.layout,
            } },
            .Prim => |prim| .{ .Prim = .{
                .op = prim.op,
                .args = try self.inlineExprPtrs(prim.args),
                .ty = prim.ty,
                .layout = prim.layout,
            } },
            .Var => expr,
            .Ctor => |ctor| .{ .Ctor = .{
                .name = ctor.name,
                .args = try self.inlineExprPtrs(ctor.args),
                .ty = ctor.ty,
                .layout = ctor.layout,
                .tag = ctor.tag,
                .type_name = ctor.type_name,
            } },
            .Match => |match_expr| .{ .Match = .{
                .scrutinee = try self.inlineExprPtr(match_expr.scrutinee.*),
                .arms = try self.inlineArms(match_expr.arms),
                .ty = match_expr.ty,
                .layout = match_expr.layout,
            } },
            .Tuple => |tuple_expr| .{ .Tuple = .{
                .items = try self.inlineExprPtrs(tuple_expr.items),
                .ty = tuple_expr.ty,
                .layout = tuple_expr.layout,
            } },
            .TupleProj => |tuple_proj| .{ .TupleProj = .{
                .tuple_expr = try self.inlineExprPtr(tuple_proj.tuple_expr.*),
                .index = tuple_proj.index,
                .ty = tuple_proj.ty,
                .layout = tuple_proj.layout,
            } },
            .Record => |record_expr| .{ .Record = .{
                .fields = try self.inlineRecordFields(record_expr.fields),
                .ty = record_expr.ty,
                .layout = record_expr.layout,
            } },
            .RecordField => |record_field| .{ .RecordField = .{
                .record_expr = try self.inlineExprPtr(record_field.record_expr.*),
                .field_name = record_field.field_name,
                .ty = record_field.ty,
                .layout = record_field.layout,
            } },
            .RecordUpdate => |record_update| .{ .RecordUpdate = .{
                .base_expr = try self.inlineExprPtr(record_update.base_expr.*),
                .fields = try self.inlineRecordFields(record_update.fields),
                .ty = record_update.ty,
                .layout = record_update.layout,
            } },
            .AccountFieldSet => |field_set| .{ .AccountFieldSet = .{
                .account_expr = try self.inlineExprPtr(field_set.account_expr.*),
                .field_name = field_set.field_name,
                .value = try self.inlineExprPtr(field_set.value.*),
                .ty = field_set.ty,
                .layout = field_set.layout,
            } },
        };
    }

    fn inlineLetGroupBindings(self: *InlineContext, bindings: []const ir.LetGroupBinding) InlineError![]const ir.LetGroupBinding {
        const out = try self.allocator().alloc(ir.LetGroupBinding, bindings.len);
        for (bindings, 0..) |binding, index| {
            out[index] = .{
                .name = binding.name,
                .value = try self.inlineExprPtr(binding.value.*),
                .ty = binding.ty,
                .layout = binding.layout,
            };
        }
        return out;
    }

    fn inlineLetGroup(self: *InlineContext, group: ir.LetGroupExpr) InlineError!ir.LetGroupExpr {
        const function_mark = self.functionMark();
        for (group.bindings) |binding| try self.shadowFunction(binding.name);
        const bindings = try self.inlineLetGroupBindings(group.bindings);
        const body = try self.inlineExprPtr(group.body.*);
        self.restoreFunctions(function_mark);
        return .{
            .bindings = bindings,
            .body = body,
            .ty = group.ty,
            .layout = group.layout,
        };
    }

    fn inlineLambda(self: *InlineContext, lambda: ir.Lambda) InlineError!ir.Expr {
        const scope_mark = self.scopeMark();
        const function_mark = self.functionMark();
        for (lambda.params) |param| {
            _ = try self.pushScopeBinding(param.name);
            try self.shadowFunction(param.name);
        }
        const body = try self.inlineExprPtr(lambda.body.*);
        self.restoreFunctions(function_mark);
        self.restoreScope(scope_mark);
        return .{ .Lambda = .{
            .params = lambda.params,
            .body = body,
            .ty = lambda.ty,
            .layout = lambda.layout,
        } };
    }

    fn inlineApp(self: *InlineContext, app: ir.App) InlineError!ir.Expr {
        const callee = try self.inlineExprPtr(app.callee.*);
        const args = try self.inlineExprPtrs(app.args);

        if (callee.* == .Var) {
            if (self.functions.get(callee.Var.name)) |entry| {
                if (entry.function) |function| {
                    if (function.lambda.params.len == args.len and self.canInlineAtCall(function) and allInlineArgs(args)) {
                        return try self.instantiate(function.lambda, args);
                    }
                }
            }
        }

        return .{ .App = .{
            .callee = callee,
            .args = args,
            .ty = app.ty,
            .layout = app.layout,
            .is_tail_call = app.is_tail_call,
        } };
    }

    fn inlineLet(self: *InlineContext, let_expr: ir.LetExpr) InlineError!ir.Expr {
        if (let_expr.is_rec) {
            const scope_mark = self.scopeMark();
            const function_mark = self.functionMark();
            _ = try self.pushScopeBinding(let_expr.name);
            try self.shadowFunction(let_expr.name);
            const value = try self.inlineExprPtr(let_expr.value.*);
            const body = try self.inlineExprPtr(let_expr.body.*);
            self.restoreFunctions(function_mark);
            self.restoreScope(scope_mark);
            return .{ .Let = .{
                .name = let_expr.name,
                .value = value,
                .body = body,
                .ty = exprTy(body.*),
                .layout = exprLayout(body.*),
                .is_rec = true,
            } };
        }

        const value = try self.inlineExprPtr(let_expr.value.*);
        const scope_mark = self.scopeMark();
        const function_mark = self.functionMark();
        _ = try self.pushScopeBinding(let_expr.name);
        if (try self.smallFunctionFromBinding(let_expr.name, value.*)) |function| {
            try self.pushFunction(let_expr.name, function);
        } else {
            try self.shadowFunction(let_expr.name);
        }
        const body = try self.inlineExprPtr(let_expr.body.*);
        self.restoreFunctions(function_mark);
        self.restoreScope(scope_mark);

        return .{ .Let = .{
            .name = let_expr.name,
            .value = value,
            .body = body,
            .ty = exprTy(body.*),
            .layout = exprLayout(body.*),
            .is_rec = false,
        } };
    }

    fn inlineArms(self: *InlineContext, arms: []const ir.Arm) InlineError![]const ir.Arm {
        const out = try self.allocator().alloc(ir.Arm, arms.len);
        for (arms, 0..) |arm, index| {
            const scope_mark = self.scopeMark();
            const function_mark = self.functionMark();
            try self.pushPatternScope(arm.pattern);
            out[index] = .{
                .pattern = try clonePattern(self.allocator(), arm.pattern),
                .guard = if (arm.guard) |guard| try self.inlineExprPtr(guard.*) else null,
                .body = try self.inlineExprPtr(arm.body.*),
            };
            self.restoreFunctions(function_mark);
            self.restoreScope(scope_mark);
        }
        return out;
    }

    fn inlineRecordFields(self: *InlineContext, fields: []const ir.RecordExprField) InlineError![]const ir.RecordExprField {
        const out = try self.allocator().alloc(ir.RecordExprField, fields.len);
        for (fields, 0..) |field, index| {
            out[index] = .{
                .name = field.name,
                .value = try self.inlineExprPtr(field.value.*),
            };
        }
        return out;
    }

    fn pushPatternScope(self: *InlineContext, pattern: ir.Pattern) InlineError!void {
        switch (pattern) {
            .Wildcard, .Constant => {},
            .Var => |var_pattern| {
                _ = try self.pushScopeBinding(var_pattern.name);
                try self.shadowFunction(var_pattern.name);
            },
            .Ctor => |ctor_pattern| {
                for (ctor_pattern.args) |arg| try self.pushPatternScope(arg);
            },
            .Tuple => |items| {
                for (items) |item| try self.pushPatternScope(item);
            },
            .Record => |fields| {
                for (fields) |field| try self.pushPatternScope(field.pattern);
            },
            .Alias => |alias| {
                try self.pushPatternScope(alias.pattern.*);
                _ = try self.pushScopeBinding(alias.name);
                try self.shadowFunction(alias.name);
            },
        }
    }

    fn smallFunctionFromBinding(self: *InlineContext, name: []const u8, expr: ir.Expr) InlineError!?SmallFunction {
        if (isBackendIntrinsicFunction(name)) return null;
        return self.smallFunctionFromExpr(expr);
    }

    fn smallFunctionFromExpr(self: *InlineContext, expr: ir.Expr) InlineError!?SmallFunction {
        const lambda = switch (expr) {
            .Lambda => |lambda| lambda,
            else => return null,
        };
        if (!lambdaTypesInlineSafe(lambda)) return null;
        if (containsLet(lambda.body.*)) return null;
        if (containsAppOrMutation(lambda.body.*)) return null;
        if (containsAppThroughParam(lambda.body.*, lambda.params)) return null;
        const count = boundedNodeCount(lambda.body.*, max_small_body_nodes) orelse return null;
        if (count > max_small_body_nodes) return null;

        const captures = try self.collectCaptures(lambda);
        return .{ .lambda = lambda, .captures = captures };
    }

    fn collectCaptures(self: *InlineContext, lambda: ir.Lambda) InlineError![]const Capture {
        var free_names = std.StringHashMap(void).init(self.allocator());
        defer free_names.deinit();
        var free_changes = std.ArrayList(NameSetChange).empty;
        defer free_changes.deinit(self.allocator());

        var bound = std.StringHashMap(void).init(self.allocator());
        defer bound.deinit();
        var bound_changes = std.ArrayList(NameSetChange).empty;
        defer bound_changes.deinit(self.allocator());

        for (lambda.params) |param| try pushNameSet(self.allocator(), &bound, &bound_changes, param.name);
        try collectFreeNames(self.allocator(), lambda.body.*, &bound, &bound_changes, &free_names, &free_changes);

        const captures = try self.allocator().alloc(Capture, free_names.count());
        var iter = free_names.iterator();
        var index: usize = 0;
        while (iter.next()) |entry| : (index += 1) {
            const name = entry.key_ptr.*;
            captures[index] = .{
                .name = name,
                .binding_id = self.scope.get(name),
            };
        }
        return captures;
    }

    fn canInlineAtCall(self: *InlineContext, function: SmallFunction) bool {
        for (function.captures) |capture| {
            const current = self.scope.get(capture.name);
            if (capture.binding_id) |expected| {
                if (current == null or current.? != expected) return false;
            } else if (current != null) {
                return false;
            }
        }
        return true;
    }

    fn instantiate(self: *InlineContext, lambda: ir.Lambda, args: []const *const ir.Expr) InlineError!ir.Expr {
        var alpha = AlphaContext.init(self);
        defer alpha.deinit();

        const mark = alpha.mark();
        for (lambda.params, 0..) |param, index| {
            try alpha.pushBinding(param.name, .{ .Substitute = args[index] });
        }
        const body = try alpha.cloneExpr(lambda.body.*);
        alpha.restore(mark);
        return body;
    }

    fn freshName(self: *InlineContext, base: []const u8) InlineError![]const u8 {
        const id = self.next_fresh_id;
        self.next_fresh_id += 1;
        return std.fmt.allocPrint(self.allocator(), "{s}__inl{d}", .{ base, id });
    }
};

const AlphaContext = struct {
    inline_ctx: *InlineContext,
    bindings: std.StringHashMap(NameBinding),
    changes: std.ArrayList(NameBindingChange),

    fn init(inline_ctx: *InlineContext) AlphaContext {
        return .{
            .inline_ctx = inline_ctx,
            .bindings = std.StringHashMap(NameBinding).init(inline_ctx.allocator()),
            .changes = std.ArrayList(NameBindingChange).empty,
        };
    }

    fn deinit(self: *AlphaContext) void {
        self.changes.deinit(self.allocator());
        self.bindings.deinit();
    }

    fn allocator(self: *AlphaContext) std.mem.Allocator {
        return self.inline_ctx.allocator();
    }

    fn mark(self: *const AlphaContext) usize {
        return self.changes.items.len;
    }

    fn restore(self: *AlphaContext, mark_index: usize) void {
        while (self.changes.items.len > mark_index) {
            const change = self.changes.pop().?;
            if (change.existed) {
                self.bindings.getPtr(change.name).?.* = change.previous;
            } else {
                _ = self.bindings.remove(change.name);
            }
        }
    }

    fn pushBinding(self: *AlphaContext, name: []const u8, binding: NameBinding) InlineError!void {
        if (self.bindings.get(name)) |previous| {
            try self.changes.append(self.allocator(), .{
                .name = name,
                .existed = true,
                .previous = previous,
            });
        } else {
            try self.changes.append(self.allocator(), .{
                .name = name,
                .existed = false,
            });
        }
        try self.bindings.put(name, binding);
    }

    fn freshName(self: *AlphaContext, base: []const u8) InlineError![]const u8 {
        return self.inline_ctx.freshName(base);
    }

    fn cloneExprPtr(self: *AlphaContext, expr: ir.Expr) InlineError!*const ir.Expr {
        const ptr = try self.allocator().create(ir.Expr);
        ptr.* = try self.cloneExpr(expr);
        return ptr;
    }

    fn cloneExprPtrs(self: *AlphaContext, exprs: []const *const ir.Expr) InlineError![]const *const ir.Expr {
        const out = try self.allocator().alloc(*const ir.Expr, exprs.len);
        for (exprs, 0..) |expr, index| {
            out[index] = try self.cloneExprPtr(expr.*);
        }
        return out;
    }

    fn cloneExpr(self: *AlphaContext, expr: ir.Expr) InlineError!ir.Expr {
        return switch (expr) {
            .Lambda => |lambda| try self.cloneLambda(lambda),
            .Constant => expr,
            .App => |app| .{ .App = .{
                .callee = try self.cloneExprPtr(app.callee.*),
                .args = try self.cloneExprPtrs(app.args),
                .ty = app.ty,
                .layout = app.layout,
                .is_tail_call = app.is_tail_call,
            } },
            .Let => |let_expr| try self.cloneLet(let_expr),
            .LetGroup => expr,
            .Assert => |assert_expr| .{ .Assert = .{
                .condition = try self.cloneExprPtr(assert_expr.condition.*),
                .ty = assert_expr.ty,
                .layout = assert_expr.layout,
            } },
            .If => |if_expr| .{ .If = .{
                .cond = try self.cloneExprPtr(if_expr.cond.*),
                .then_branch = try self.cloneExprPtr(if_expr.then_branch.*),
                .else_branch = try self.cloneExprPtr(if_expr.else_branch.*),
                .ty = if_expr.ty,
                .layout = if_expr.layout,
            } },
            .Prim => |prim| .{ .Prim = .{
                .op = prim.op,
                .args = try self.cloneExprPtrs(prim.args),
                .ty = prim.ty,
                .layout = prim.layout,
            } },
            .Var => |var_ref| blk: {
                if (self.bindings.get(var_ref.name)) |binding| switch (binding) {
                    .Rename => |name| break :blk .{ .Var = .{
                        .name = name,
                        .ty = var_ref.ty,
                        .layout = var_ref.layout,
                    } },
                    .Substitute => |replacement| break :blk replacement.*,
                };
                break :blk expr;
            },
            .Ctor => |ctor| .{ .Ctor = .{
                .name = ctor.name,
                .args = try self.cloneExprPtrs(ctor.args),
                .ty = ctor.ty,
                .layout = ctor.layout,
                .tag = ctor.tag,
                .type_name = ctor.type_name,
            } },
            .Match => |match_expr| .{ .Match = .{
                .scrutinee = try self.cloneExprPtr(match_expr.scrutinee.*),
                .arms = try self.cloneArms(match_expr.arms),
                .ty = match_expr.ty,
                .layout = match_expr.layout,
            } },
            .Tuple => |tuple_expr| .{ .Tuple = .{
                .items = try self.cloneExprPtrs(tuple_expr.items),
                .ty = tuple_expr.ty,
                .layout = tuple_expr.layout,
            } },
            .TupleProj => |tuple_proj| .{ .TupleProj = .{
                .tuple_expr = try self.cloneExprPtr(tuple_proj.tuple_expr.*),
                .index = tuple_proj.index,
                .ty = tuple_proj.ty,
                .layout = tuple_proj.layout,
            } },
            .Record => |record_expr| .{ .Record = .{
                .fields = try self.cloneRecordFields(record_expr.fields),
                .ty = record_expr.ty,
                .layout = record_expr.layout,
            } },
            .RecordField => |record_field| .{ .RecordField = .{
                .record_expr = try self.cloneExprPtr(record_field.record_expr.*),
                .field_name = record_field.field_name,
                .ty = record_field.ty,
                .layout = record_field.layout,
            } },
            .RecordUpdate => |record_update| .{ .RecordUpdate = .{
                .base_expr = try self.cloneExprPtr(record_update.base_expr.*),
                .fields = try self.cloneRecordFields(record_update.fields),
                .ty = record_update.ty,
                .layout = record_update.layout,
            } },
            .AccountFieldSet => |field_set| .{ .AccountFieldSet = .{
                .account_expr = try self.cloneExprPtr(field_set.account_expr.*),
                .field_name = field_set.field_name,
                .value = try self.cloneExprPtr(field_set.value.*),
                .ty = field_set.ty,
                .layout = field_set.layout,
            } },
        };
    }

    fn cloneLambda(self: *AlphaContext, lambda: ir.Lambda) InlineError!ir.Expr {
        const mark_index = self.mark();
        const params = try self.allocator().alloc(ir.Param, lambda.params.len);
        for (lambda.params, 0..) |param, index| {
            const fresh = try self.freshName(param.name);
            try self.pushBinding(param.name, .{ .Rename = fresh });
            params[index] = .{ .name = fresh, .ty = param.ty };
        }
        const body = try self.cloneExprPtr(lambda.body.*);
        self.restore(mark_index);
        return .{ .Lambda = .{
            .params = params,
            .body = body,
            .ty = lambda.ty,
            .layout = lambda.layout,
        } };
    }

    fn cloneLet(self: *AlphaContext, let_expr: ir.LetExpr) InlineError!ir.Expr {
        if (let_expr.is_rec) {
            const mark_index = self.mark();
            const fresh = try self.freshName(let_expr.name);
            try self.pushBinding(let_expr.name, .{ .Rename = fresh });
            const value = try self.cloneExprPtr(let_expr.value.*);
            const body = try self.cloneExprPtr(let_expr.body.*);
            self.restore(mark_index);
            return .{ .Let = .{
                .name = fresh,
                .value = value,
                .body = body,
                .ty = exprTy(body.*),
                .layout = exprLayout(body.*),
                .is_rec = true,
            } };
        }

        const value = try self.cloneExprPtr(let_expr.value.*);
        const mark_index = self.mark();
        const fresh = try self.freshName(let_expr.name);
        try self.pushBinding(let_expr.name, .{ .Rename = fresh });
        const body = try self.cloneExprPtr(let_expr.body.*);
        self.restore(mark_index);
        return .{ .Let = .{
            .name = fresh,
            .value = value,
            .body = body,
            .ty = exprTy(body.*),
            .layout = exprLayout(body.*),
            .is_rec = false,
        } };
    }

    fn cloneArms(self: *AlphaContext, arms: []const ir.Arm) InlineError![]const ir.Arm {
        const out = try self.allocator().alloc(ir.Arm, arms.len);
        for (arms, 0..) |arm, index| {
            const mark_index = self.mark();
            out[index] = .{
                .pattern = try self.clonePatternAndBind(arm.pattern),
                .guard = if (arm.guard) |guard| try self.cloneExprPtr(guard.*) else null,
                .body = try self.cloneExprPtr(arm.body.*),
            };
            self.restore(mark_index);
        }
        return out;
    }

    fn clonePatternAndBind(self: *AlphaContext, pattern: ir.Pattern) InlineError!ir.Pattern {
        return switch (pattern) {
            .Wildcard => .Wildcard,
            .Constant => |constant| .{ .Constant = constant },
            .Var => |var_pattern| blk: {
                const fresh = try self.freshName(var_pattern.name);
                try self.pushBinding(var_pattern.name, .{ .Rename = fresh });
                break :blk .{ .Var = .{
                    .name = fresh,
                    .ty = var_pattern.ty,
                    .layout = var_pattern.layout,
                } };
            },
            .Ctor => |ctor_pattern| .{ .Ctor = .{
                .name = ctor_pattern.name,
                .args = try self.clonePatternsAndBind(ctor_pattern.args),
                .tag = ctor_pattern.tag,
                .type_name = ctor_pattern.type_name,
            } },
            .Tuple => |items| .{ .Tuple = try self.clonePatternsAndBind(items) },
            .Record => |fields| .{ .Record = try self.cloneRecordPatternsAndBind(fields) },
            .Alias => |alias| blk: {
                const nested = try self.allocator().create(ir.Pattern);
                nested.* = try self.clonePatternAndBind(alias.pattern.*);
                const fresh = try self.freshName(alias.name);
                try self.pushBinding(alias.name, .{ .Rename = fresh });
                break :blk .{ .Alias = .{
                    .pattern = nested,
                    .name = fresh,
                    .ty = alias.ty,
                    .layout = alias.layout,
                } };
            },
        };
    }

    fn clonePatternsAndBind(self: *AlphaContext, patterns: []const ir.Pattern) InlineError![]const ir.Pattern {
        const out = try self.allocator().alloc(ir.Pattern, patterns.len);
        for (patterns, 0..) |pattern, index| {
            out[index] = try self.clonePatternAndBind(pattern);
        }
        return out;
    }

    fn cloneRecordPatternsAndBind(self: *AlphaContext, fields: []const ir.RecordPatternField) InlineError![]const ir.RecordPatternField {
        const out = try self.allocator().alloc(ir.RecordPatternField, fields.len);
        for (fields, 0..) |field, index| {
            out[index] = .{
                .name = field.name,
                .pattern = try self.clonePatternAndBind(field.pattern),
            };
        }
        return out;
    }

    fn cloneRecordFields(self: *AlphaContext, fields: []const ir.RecordExprField) InlineError![]const ir.RecordExprField {
        const out = try self.allocator().alloc(ir.RecordExprField, fields.len);
        for (fields, 0..) |field, index| {
            out[index] = .{
                .name = field.name,
                .value = try self.cloneExprPtr(field.value.*),
            };
        }
        return out;
    }
};

/// Returns a Core IR module with known calls to small functions inlined.
pub fn inlineModule(arena: *std.heap.ArenaAllocator, module: ir.Module) InlineError!ir.Module {
    const allocator = arena.allocator();
    const decls = try allocator.alloc(ir.Decl, module.decls.len);

    var ctx = InlineContext.init(arena);
    defer ctx.deinit();
    try ctx.collectTopLevelFunctions(module.decls);

    for (module.decls, 0..) |decl, index| {
        decls[index] = try ctx.inlineDecl(decl);
    }

    return .{
        .decls = decls,
        .type_decls = module.type_decls,
        .tuple_type_decls = module.tuple_type_decls,
        .record_type_decls = module.record_type_decls,
        .externals = module.externals,
    };
}

const NameSetChange = struct {
    name: []const u8,
    existed: bool,
};

fn pushNameSet(
    allocator: std.mem.Allocator,
    set: *std.StringHashMap(void),
    changes: *std.ArrayList(NameSetChange),
    name: []const u8,
) InlineError!void {
    if (set.contains(name)) {
        try changes.append(allocator, .{ .name = name, .existed = true });
    } else {
        try changes.append(allocator, .{ .name = name, .existed = false });
    }
    try set.put(name, {});
}

fn restoreNameSet(set: *std.StringHashMap(void), changes: *std.ArrayList(NameSetChange), mark_index: usize) void {
    while (changes.items.len > mark_index) {
        const change = changes.pop().?;
        if (!change.existed) _ = set.remove(change.name);
    }
}

fn collectFreeNames(
    allocator: std.mem.Allocator,
    expr: ir.Expr,
    bound: *std.StringHashMap(void),
    bound_changes: *std.ArrayList(NameSetChange),
    free_names: *std.StringHashMap(void),
    free_changes: *std.ArrayList(NameSetChange),
) InlineError!void {
    switch (expr) {
        .Lambda => |lambda| {
            const mark = bound_changes.items.len;
            for (lambda.params) |param| try pushNameSet(allocator, bound, bound_changes, param.name);
            try collectFreeNames(allocator, lambda.body.*, bound, bound_changes, free_names, free_changes);
            restoreNameSet(bound, bound_changes, mark);
        },
        .Constant => {},
        .App => |app| {
            try collectFreeNames(allocator, app.callee.*, bound, bound_changes, free_names, free_changes);
            try collectFreeNamesInExprs(allocator, app.args, bound, bound_changes, free_names, free_changes);
        },
        .Let => |let_expr| {
            if (let_expr.is_rec) {
                const mark = bound_changes.items.len;
                try pushNameSet(allocator, bound, bound_changes, let_expr.name);
                try collectFreeNames(allocator, let_expr.value.*, bound, bound_changes, free_names, free_changes);
                try collectFreeNames(allocator, let_expr.body.*, bound, bound_changes, free_names, free_changes);
                restoreNameSet(bound, bound_changes, mark);
            } else {
                try collectFreeNames(allocator, let_expr.value.*, bound, bound_changes, free_names, free_changes);
                const mark = bound_changes.items.len;
                try pushNameSet(allocator, bound, bound_changes, let_expr.name);
                try collectFreeNames(allocator, let_expr.body.*, bound, bound_changes, free_names, free_changes);
                restoreNameSet(bound, bound_changes, mark);
            }
        },
        .LetGroup => |group| {
            const mark = bound_changes.items.len;
            for (group.bindings) |binding| try pushNameSet(allocator, bound, bound_changes, binding.name);
            for (group.bindings) |binding| try collectFreeNames(allocator, binding.value.*, bound, bound_changes, free_names, free_changes);
            try collectFreeNames(allocator, group.body.*, bound, bound_changes, free_names, free_changes);
            restoreNameSet(bound, bound_changes, mark);
        },
        .Assert => |assert_expr| try collectFreeNames(allocator, assert_expr.condition.*, bound, bound_changes, free_names, free_changes),
        .If => |if_expr| {
            try collectFreeNames(allocator, if_expr.cond.*, bound, bound_changes, free_names, free_changes);
            try collectFreeNames(allocator, if_expr.then_branch.*, bound, bound_changes, free_names, free_changes);
            try collectFreeNames(allocator, if_expr.else_branch.*, bound, bound_changes, free_names, free_changes);
        },
        .Prim => |prim| try collectFreeNamesInExprs(allocator, prim.args, bound, bound_changes, free_names, free_changes),
        .Var => |var_ref| {
            if (!bound.contains(var_ref.name)) {
                try pushNameSet(allocator, free_names, free_changes, var_ref.name);
            }
        },
        .Ctor => |ctor| try collectFreeNamesInExprs(allocator, ctor.args, bound, bound_changes, free_names, free_changes),
        .Match => |match_expr| {
            try collectFreeNames(allocator, match_expr.scrutinee.*, bound, bound_changes, free_names, free_changes);
            for (match_expr.arms) |arm| {
                const mark = bound_changes.items.len;
                try pushPatternNames(allocator, bound, bound_changes, arm.pattern);
                if (arm.guard) |guard| try collectFreeNames(allocator, guard.*, bound, bound_changes, free_names, free_changes);
                try collectFreeNames(allocator, arm.body.*, bound, bound_changes, free_names, free_changes);
                restoreNameSet(bound, bound_changes, mark);
            }
        },
        .Tuple => |tuple_expr| try collectFreeNamesInExprs(allocator, tuple_expr.items, bound, bound_changes, free_names, free_changes),
        .TupleProj => |tuple_proj| try collectFreeNames(allocator, tuple_proj.tuple_expr.*, bound, bound_changes, free_names, free_changes),
        .Record => |record_expr| try collectFreeNamesInRecordFields(allocator, record_expr.fields, bound, bound_changes, free_names, free_changes),
        .RecordField => |record_field| try collectFreeNames(allocator, record_field.record_expr.*, bound, bound_changes, free_names, free_changes),
        .RecordUpdate => |record_update| {
            try collectFreeNames(allocator, record_update.base_expr.*, bound, bound_changes, free_names, free_changes);
            try collectFreeNamesInRecordFields(allocator, record_update.fields, bound, bound_changes, free_names, free_changes);
        },
        .AccountFieldSet => |field_set| {
            try collectFreeNames(allocator, field_set.account_expr.*, bound, bound_changes, free_names, free_changes);
            try collectFreeNames(allocator, field_set.value.*, bound, bound_changes, free_names, free_changes);
        },
    }
}

fn collectFreeNamesInExprs(
    allocator: std.mem.Allocator,
    exprs: []const *const ir.Expr,
    bound: *std.StringHashMap(void),
    bound_changes: *std.ArrayList(NameSetChange),
    free_names: *std.StringHashMap(void),
    free_changes: *std.ArrayList(NameSetChange),
) InlineError!void {
    for (exprs) |expr| try collectFreeNames(allocator, expr.*, bound, bound_changes, free_names, free_changes);
}

fn collectFreeNamesInRecordFields(
    allocator: std.mem.Allocator,
    fields: []const ir.RecordExprField,
    bound: *std.StringHashMap(void),
    bound_changes: *std.ArrayList(NameSetChange),
    free_names: *std.StringHashMap(void),
    free_changes: *std.ArrayList(NameSetChange),
) InlineError!void {
    for (fields) |field| try collectFreeNames(allocator, field.value.*, bound, bound_changes, free_names, free_changes);
}

fn pushPatternNames(
    allocator: std.mem.Allocator,
    bound: *std.StringHashMap(void),
    changes: *std.ArrayList(NameSetChange),
    pattern: ir.Pattern,
) InlineError!void {
    switch (pattern) {
        .Wildcard, .Constant => {},
        .Var => |var_pattern| try pushNameSet(allocator, bound, changes, var_pattern.name),
        .Ctor => |ctor_pattern| {
            for (ctor_pattern.args) |arg| try pushPatternNames(allocator, bound, changes, arg);
        },
        .Tuple => |items| {
            for (items) |item| try pushPatternNames(allocator, bound, changes, item);
        },
        .Record => |fields| {
            for (fields) |field| try pushPatternNames(allocator, bound, changes, field.pattern);
        },
        .Alias => |alias| {
            try pushPatternNames(allocator, bound, changes, alias.pattern.*);
            try pushNameSet(allocator, bound, changes, alias.name);
        },
    }
}

fn boundedNodeCount(expr: ir.Expr, max_nodes: usize) ?usize {
    var count: usize = 1;
    switch (expr) {
        .Lambda => |lambda| count += boundedNodeCount(lambda.body.*, max_nodes) orelse return null,
        .Constant, .Var => {},
        .App => |app| {
            count += boundedNodeCount(app.callee.*, max_nodes) orelse return null;
            count += boundedNodeCountInExprs(app.args, max_nodes) orelse return null;
        },
        .Let => |let_expr| {
            count += boundedNodeCount(let_expr.value.*, max_nodes) orelse return null;
            count += boundedNodeCount(let_expr.body.*, max_nodes) orelse return null;
        },
        .LetGroup => return null,
        .Assert => return null,
        .If => |if_expr| {
            count += boundedNodeCount(if_expr.cond.*, max_nodes) orelse return null;
            count += boundedNodeCount(if_expr.then_branch.*, max_nodes) orelse return null;
            count += boundedNodeCount(if_expr.else_branch.*, max_nodes) orelse return null;
        },
        .Prim => |prim| count += boundedNodeCountInExprs(prim.args, max_nodes) orelse return null,
        .Ctor => |ctor| count += boundedNodeCountInExprs(ctor.args, max_nodes) orelse return null,
        .Match => |match_expr| {
            count += boundedNodeCount(match_expr.scrutinee.*, max_nodes) orelse return null;
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| count += boundedNodeCount(guard.*, max_nodes) orelse return null;
                count += boundedNodeCount(arm.body.*, max_nodes) orelse return null;
            }
        },
        .Tuple => |tuple_expr| count += boundedNodeCountInExprs(tuple_expr.items, max_nodes) orelse return null,
        .TupleProj => |tuple_proj| count += boundedNodeCount(tuple_proj.tuple_expr.*, max_nodes) orelse return null,
        .Record => |record_expr| count += boundedNodeCountInRecordFields(record_expr.fields, max_nodes) orelse return null,
        .RecordField => |record_field| count += boundedNodeCount(record_field.record_expr.*, max_nodes) orelse return null,
        .RecordUpdate => |record_update| {
            count += boundedNodeCount(record_update.base_expr.*, max_nodes) orelse return null;
            count += boundedNodeCountInRecordFields(record_update.fields, max_nodes) orelse return null;
        },
        .AccountFieldSet => |field_set| {
            count += boundedNodeCount(field_set.account_expr.*, max_nodes) orelse return null;
            count += boundedNodeCount(field_set.value.*, max_nodes) orelse return null;
        },
    }
    if (count > max_nodes) return null;
    return count;
}

fn boundedNodeCountInExprs(exprs: []const *const ir.Expr, max_nodes: usize) ?usize {
    var count: usize = 0;
    for (exprs) |expr| count += boundedNodeCount(expr.*, max_nodes) orelse return null;
    return count;
}

fn boundedNodeCountInRecordFields(fields: []const ir.RecordExprField, max_nodes: usize) ?usize {
    var count: usize = 0;
    for (fields) |field| count += boundedNodeCount(field.value.*, max_nodes) orelse return null;
    return count;
}

fn containsLet(expr: ir.Expr) bool {
    return switch (expr) {
        .Lambda => |lambda| containsLet(lambda.body.*),
        .Constant, .Var => false,
        .App => |app| containsLet(app.callee.*) or anyContainsLet(app.args),
        .Let => true,
        .LetGroup => true,
        .Assert => |assert_expr| containsLet(assert_expr.condition.*),
        .If => |if_expr| containsLet(if_expr.cond.*) or containsLet(if_expr.then_branch.*) or containsLet(if_expr.else_branch.*),
        .Prim => |prim| anyContainsLet(prim.args),
        .Ctor => |ctor| anyContainsLet(ctor.args),
        .Match => |match_expr| blk: {
            if (containsLet(match_expr.scrutinee.*)) break :blk true;
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| {
                    if (containsLet(guard.*)) break :blk true;
                }
                if (containsLet(arm.body.*)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple_expr| anyContainsLet(tuple_expr.items),
        .TupleProj => |tuple_proj| containsLet(tuple_proj.tuple_expr.*),
        .Record => |record_expr| anyRecordFieldContainsLet(record_expr.fields),
        .RecordField => |record_field| containsLet(record_field.record_expr.*),
        .RecordUpdate => |record_update| containsLet(record_update.base_expr.*) or anyRecordFieldContainsLet(record_update.fields),
        .AccountFieldSet => |field_set| containsLet(field_set.account_expr.*) or containsLet(field_set.value.*),
    };
}

fn anyContainsLet(exprs: []const *const ir.Expr) bool {
    for (exprs) |expr| {
        if (containsLet(expr.*)) return true;
    }
    return false;
}

fn anyRecordFieldContainsLet(fields: []const ir.RecordExprField) bool {
    for (fields) |field| {
        if (containsLet(field.value.*)) return true;
    }
    return false;
}

fn containsAppOrMutation(expr: ir.Expr) bool {
    return switch (expr) {
        .Lambda => |lambda| containsAppOrMutation(lambda.body.*),
        .Constant, .Var => false,
        .App => |app| containsAppOrMutation(app.callee.*) or anyContainsAppOrMutation(app.args),
        .AccountFieldSet => true,
        .Let => |let_expr| containsAppOrMutation(let_expr.value.*) or containsAppOrMutation(let_expr.body.*),
        .LetGroup => true,
        .Assert => true,
        .If => |if_expr| containsAppOrMutation(if_expr.cond.*) or containsAppOrMutation(if_expr.then_branch.*) or containsAppOrMutation(if_expr.else_branch.*),
        .Prim => |prim| anyContainsAppOrMutation(prim.args),
        .Ctor => |ctor| anyContainsAppOrMutation(ctor.args),
        .Match => |match_expr| blk: {
            if (containsAppOrMutation(match_expr.scrutinee.*)) break :blk true;
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| {
                    if (containsAppOrMutation(guard.*)) break :blk true;
                }
                if (containsAppOrMutation(arm.body.*)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple_expr| anyContainsAppOrMutation(tuple_expr.items),
        .TupleProj => |tuple_proj| containsAppOrMutation(tuple_proj.tuple_expr.*),
        .Record => |record_expr| anyRecordFieldContainsAppOrMutation(record_expr.fields),
        .RecordField => |record_field| containsAppOrMutation(record_field.record_expr.*),
        .RecordUpdate => |record_update| containsAppOrMutation(record_update.base_expr.*) or anyRecordFieldContainsAppOrMutation(record_update.fields),
    };
}

fn anyContainsAppOrMutation(exprs: []const *const ir.Expr) bool {
    for (exprs) |expr| {
        if (containsAppOrMutation(expr.*)) return true;
    }
    return false;
}

fn anyRecordFieldContainsAppOrMutation(fields: []const ir.RecordExprField) bool {
    for (fields) |field| {
        if (containsAppOrMutation(field.value.*)) return true;
    }
    return false;
}

fn isBackendIntrinsicFunction(name: []const u8) bool {
    return std.mem.eql(u8, name, "read_u8") or
        std.mem.eql(u8, name, "read_u64_le") or
        std.mem.eql(u8, name, "write_u64_le") or
        std.mem.eql(u8, name, "set_account_data") or
        std.mem.eql(u8, name, "vault_deposit") or
        std.mem.eql(u8, name, "vault_withdraw");
}

fn containsAppThroughParam(expr: ir.Expr, params: []const ir.Param) bool {
    return switch (expr) {
        .Lambda => |lambda| containsAppThroughParam(lambda.body.*, params),
        .Constant, .Var => false,
        .App => |app| blk: {
            if (app.callee.* == .Var and paramNamed(params, app.callee.Var.name)) break :blk true;
            if (containsAppThroughParam(app.callee.*, params)) break :blk true;
            for (app.args) |arg| {
                if (containsAppThroughParam(arg.*, params)) break :blk true;
            }
            break :blk false;
        },
        .Let => |let_expr| containsAppThroughParam(let_expr.value.*, params) or containsAppThroughParam(let_expr.body.*, params),
        .LetGroup => |group| blk: {
            for (group.bindings) |binding| {
                if (containsAppThroughParam(binding.value.*, params)) break :blk true;
            }
            break :blk containsAppThroughParam(group.body.*, params);
        },
        .Assert => |assert_expr| containsAppThroughParam(assert_expr.condition.*, params),
        .If => |if_expr| containsAppThroughParam(if_expr.cond.*, params) or containsAppThroughParam(if_expr.then_branch.*, params) or containsAppThroughParam(if_expr.else_branch.*, params),
        .Prim => |prim| anyContainsAppThroughParam(prim.args, params),
        .Ctor => |ctor| anyContainsAppThroughParam(ctor.args, params),
        .Match => |match_expr| blk: {
            if (containsAppThroughParam(match_expr.scrutinee.*, params)) break :blk true;
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| {
                    if (containsAppThroughParam(guard.*, params)) break :blk true;
                }
                if (containsAppThroughParam(arm.body.*, params)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple_expr| anyContainsAppThroughParam(tuple_expr.items, params),
        .TupleProj => |tuple_proj| containsAppThroughParam(tuple_proj.tuple_expr.*, params),
        .Record => |record_expr| anyRecordFieldContainsAppThroughParam(record_expr.fields, params),
        .RecordField => |record_field| containsAppThroughParam(record_field.record_expr.*, params),
        .RecordUpdate => |record_update| containsAppThroughParam(record_update.base_expr.*, params) or anyRecordFieldContainsAppThroughParam(record_update.fields, params),
        .AccountFieldSet => |field_set| containsAppThroughParam(field_set.account_expr.*, params) or containsAppThroughParam(field_set.value.*, params),
    };
}

fn anyContainsAppThroughParam(exprs: []const *const ir.Expr, params: []const ir.Param) bool {
    for (exprs) |expr| {
        if (containsAppThroughParam(expr.*, params)) return true;
    }
    return false;
}

fn anyRecordFieldContainsAppThroughParam(fields: []const ir.RecordExprField, params: []const ir.Param) bool {
    for (fields) |field| {
        if (containsAppThroughParam(field.value.*, params)) return true;
    }
    return false;
}

fn paramNamed(params: []const ir.Param, name: []const u8) bool {
    for (params) |param| {
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn allInlineArgs(args: []const *const ir.Expr) bool {
    for (args) |arg| {
        if (!isInlineArg(arg.*)) return false;
    }
    return true;
}

fn isInlineArg(expr: ir.Expr) bool {
    return switch (expr) {
        .Constant, .Var => true,
        .Ctor => |ctor| ctor.args.len == 0,
        else => false,
    };
}

fn lambdaTypesInlineSafe(lambda: ir.Lambda) bool {
    for (lambda.params) |param| {
        if (!tyInlineSafe(param.ty)) return false;
    }
    const ret_ty = switch (lambda.ty) {
        .Arrow => |arrow| arrow.ret.*,
        else => return false,
    };
    return tyInlineSafe(ret_ty);
}

fn tyInlineSafe(ty: ir.Ty) bool {
    return switch (ty) {
        .Int, .Bool, .Unit, .String, .Var, .Adt, .Tuple, .Record => true,
        .Arrow => |arrow| blk: {
            for (arrow.params) |param| {
                if (!tyInlineSafe(param)) break :blk false;
            }
            break :blk tyInlineSafe(arrow.ret.*);
        },
    };
}

fn clonePattern(allocator: std.mem.Allocator, pattern: ir.Pattern) InlineError!ir.Pattern {
    return switch (pattern) {
        .Wildcard => .Wildcard,
        .Var => |var_pattern| .{ .Var = var_pattern },
        .Constant => |constant| .{ .Constant = constant },
        .Ctor => |ctor_pattern| .{ .Ctor = .{
            .name = ctor_pattern.name,
            .args = try clonePatterns(allocator, ctor_pattern.args),
            .tag = ctor_pattern.tag,
            .type_name = ctor_pattern.type_name,
        } },
        .Tuple => |items| .{ .Tuple = try clonePatterns(allocator, items) },
        .Record => |fields| .{ .Record = try cloneRecordPatternFields(allocator, fields) },
        .Alias => |alias| blk: {
            const nested = try allocator.create(ir.Pattern);
            nested.* = try clonePattern(allocator, alias.pattern.*);
            break :blk .{ .Alias = .{
                .pattern = nested,
                .name = alias.name,
                .ty = alias.ty,
                .layout = alias.layout,
            } };
        },
    };
}

fn clonePatterns(allocator: std.mem.Allocator, patterns: []const ir.Pattern) InlineError![]const ir.Pattern {
    const out = try allocator.alloc(ir.Pattern, patterns.len);
    for (patterns, 0..) |pattern, index| {
        out[index] = try clonePattern(allocator, pattern);
    }
    return out;
}

fn cloneRecordPatternFields(allocator: std.mem.Allocator, fields: []const ir.RecordPatternField) InlineError![]const ir.RecordPatternField {
    const out = try allocator.alloc(ir.RecordPatternField, fields.len);
    for (fields, 0..) |field, index| {
        out[index] = .{
            .name = field.name,
            .pattern = try clonePattern(allocator, field.pattern),
        };
    }
    return out;
}

fn exprTy(expr: ir.Expr) ir.Ty {
    return switch (expr) {
        .Lambda => |lambda| lambda.ty,
        .Constant => |constant| constant.ty,
        .App => |app| app.ty,
        .Let => |let_expr| let_expr.ty,
        .LetGroup => |group| group.ty,
        .Assert => |assert_expr| assert_expr.ty,
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
        .LetGroup => |group| group.layout,
        .Assert => |assert_expr| assert_expr.layout,
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
