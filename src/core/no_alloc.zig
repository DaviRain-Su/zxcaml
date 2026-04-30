//! Static no-allocation analysis for Core IR functions.
//!
//! RESPONSIBILITIES:
//! - Walk Core IR expression trees and report Core nodes that lower to arena allocation sites.
//! - Check transitive calls between top-level functions in the same Core module.
//! - Keep diagnostics in terms of Core IR node names so `omlz check --no-alloc` can explain failures.

const std = @import("std");
const ir = @import("ir.zig");
const layout = @import("layout.zig");

/// Allocation kinds that the no_alloc pass can prove are arena allocation sites.
pub const AllocationKind = enum {
    Tuple,
    Record,
    RecordUpdate,
    ConstructorPayload,
    LambdaCapture,
};

/// The Core IR site that made a function fail no_alloc analysis.
pub const Site = struct {
    function_name: []const u8,
    kind: AllocationKind,
    detail: ?[]const u8 = null,
};

/// Module-level no_alloc result.
pub const Result = union(enum) {
    Pass,
    Fail: Site,
};

const Status = enum {
    Visiting,
    Pass,
    Fail,
};

const BindingSnapshot = struct {
    name: []const u8,
    existed: bool,
};

const CheckError = std.mem.Allocator.Error;
const StringSet = std.StringHashMap(void);

const Analyzer = struct {
    allocator: std.mem.Allocator,
    module: ir.Module,
    top_level: std.StringHashMap(*const ir.Let),
    status: std.StringHashMap(Status),
    failures: std.StringHashMap(Site),

    fn init(allocator: std.mem.Allocator, module: ir.Module) Analyzer {
        return .{
            .allocator = allocator,
            .module = module,
            .top_level = std.StringHashMap(*const ir.Let).init(allocator),
            .status = std.StringHashMap(Status).init(allocator),
            .failures = std.StringHashMap(Site).init(allocator),
        };
    }

    fn deinit(self: *Analyzer) void {
        self.failures.deinit();
        self.status.deinit();
        self.top_level.deinit();
    }

    fn buildTopLevelIndex(self: *Analyzer) CheckError!void {
        for (self.module.decls) |*decl| {
            switch (decl.*) {
                .Let => |*let_decl| try self.top_level.put(let_decl.name, let_decl),
            }
        }
    }

    fn analyzeModule(self: *Analyzer) CheckError!Result {
        try self.buildTopLevelIndex();
        for (self.module.decls) |decl| {
            const let_decl = switch (decl) {
                .Let => |value| value,
            };
            if (try self.analyzeTopLevel(let_decl.name)) |site| {
                return .{ .Fail = site };
            }
        }
        return .Pass;
    }

    fn analyzeTopLevel(self: *Analyzer, name: []const u8) CheckError!?Site {
        if (self.status.get(name)) |state| {
            return switch (state) {
                .Visiting, .Pass => null,
                .Fail => self.failures.get(name).?,
            };
        }

        const let_decl = self.top_level.get(name) orelse return null;
        try self.status.put(name, .Visiting);

        var scope = StringSet.init(self.allocator);
        defer scope.deinit();

        const failure = switch (let_decl.value.*) {
            .Lambda => |lambda| try self.checkLambda(let_decl.name, lambda, &scope, true),
            else => try self.checkExpr(let_decl.name, let_decl.value.*, &scope),
        };

        if (failure) |site| {
            try self.failures.put(name, site);
            try self.status.put(name, .Fail);
            return site;
        }

        try self.status.put(name, .Pass);
        return null;
    }

    fn checkLambda(self: *Analyzer, function_name: []const u8, lambda_expr: ir.Lambda, scope: *StringSet, is_top_level: bool) CheckError!?Site {
        if (!is_top_level) {
            if (lambda_expr.layout.region == .Arena and lambda_expr.layout.repr == .Boxed) {
                return Site{ .function_name = function_name, .kind = .LambdaCapture };
            }

            var shadowed = StringSet.init(self.allocator);
            defer shadowed.deinit();
            for (lambda_expr.params) |param| try shadowed.put(param.name, {});
            if (try exprCapturesAny(self.allocator, lambda_expr.body.*, scope, &shadowed)) {
                return Site{ .function_name = function_name, .kind = .LambdaCapture };
            }
        }

        var snapshots = std.ArrayList(BindingSnapshot).empty;
        defer snapshots.deinit(self.allocator);
        for (lambda_expr.params) |param| {
            try pushBinding(self.allocator, scope, &snapshots, param.name);
        }
        defer restoreBindings(scope, snapshots.items);

        return self.checkExpr(function_name, lambda_expr.body.*, scope);
    }

    fn checkExpr(self: *Analyzer, function_name: []const u8, expr: ir.Expr, scope: *StringSet) CheckError!?Site {
        switch (expr) {
            .Lambda => |lambda_expr| return self.checkLambda(function_name, lambda_expr, scope, false),
            .Constant, .Var => return null,
            .App => |app| {
                if (try self.checkExpr(function_name, app.callee.*, scope)) |site| return site;
                for (app.args) |arg| {
                    if (try self.checkExpr(function_name, arg.*, scope)) |site| return site;
                }
                if (app.callee.* == .Var) {
                    const callee = app.callee.Var.name;
                    if (try self.analyzeTopLevel(callee)) |site| return site;
                }
                return null;
            },
            .Let => |let_expr| {
                if (try self.checkExpr(function_name, let_expr.value.*, scope)) |site| return site;
                var snapshots = std.ArrayList(BindingSnapshot).empty;
                defer snapshots.deinit(self.allocator);
                try pushBinding(self.allocator, scope, &snapshots, let_expr.name);
                defer restoreBindings(scope, snapshots.items);
                return self.checkExpr(function_name, let_expr.body.*, scope);
            },
            .If => |if_expr| {
                if (try self.checkExpr(function_name, if_expr.cond.*, scope)) |site| return site;
                if (try self.checkExpr(function_name, if_expr.then_branch.*, scope)) |site| return site;
                return self.checkExpr(function_name, if_expr.else_branch.*, scope);
            },
            .Prim => |prim| {
                for (prim.args) |arg| {
                    if (try self.checkExpr(function_name, arg.*, scope)) |site| return site;
                }
                return null;
            },
            .Ctor => |ctor_expr| {
                for (ctor_expr.args) |arg| {
                    if (try self.checkExpr(function_name, arg.*, scope)) |site| return site;
                }
                if (ctor_expr.args.len > 0) {
                    return Site{ .function_name = function_name, .kind = .ConstructorPayload, .detail = ctor_expr.name };
                }
                return null;
            },
            .Match => |match_expr| {
                if (try self.checkExpr(function_name, match_expr.scrutinee.*, scope)) |site| return site;
                for (match_expr.arms) |arm| {
                    var snapshots = std.ArrayList(BindingSnapshot).empty;
                    defer snapshots.deinit(self.allocator);
                    try pushPatternBindings(self.allocator, scope, &snapshots, arm.pattern);
                    defer restoreBindings(scope, snapshots.items);

                    if (arm.guard) |guard| {
                        if (try self.checkExpr(function_name, guard.*, scope)) |site| return site;
                    }
                    if (try self.checkExpr(function_name, arm.body.*, scope)) |site| return site;
                }
                return null;
            },
            .Tuple => |tuple_expr| {
                for (tuple_expr.items) |item| {
                    if (try self.checkExpr(function_name, item.*, scope)) |site| return site;
                }
                return Site{ .function_name = function_name, .kind = .Tuple };
            },
            .TupleProj => |tuple_proj| return self.checkExpr(function_name, tuple_proj.tuple_expr.*, scope),
            .Record => |record_expr| {
                for (record_expr.fields) |field| {
                    if (try self.checkExpr(function_name, field.value.*, scope)) |site| return site;
                }
                return Site{ .function_name = function_name, .kind = .Record };
            },
            .RecordField => |record_field| return self.checkExpr(function_name, record_field.record_expr.*, scope),
            .RecordUpdate => |record_update| {
                if (try self.checkExpr(function_name, record_update.base_expr.*, scope)) |site| return site;
                for (record_update.fields) |field| {
                    if (try self.checkExpr(function_name, field.value.*, scope)) |site| return site;
                }
                return Site{ .function_name = function_name, .kind = .RecordUpdate };
            },
            .AccountFieldSet => |field_set| {
                if (try self.checkExpr(function_name, field_set.account_expr.*, scope)) |site| return site;
                return self.checkExpr(function_name, field_set.value.*, scope);
            },
        }
    }
};

/// Checks every top-level Core IR declaration and returns the first allocation site found.
pub fn checkModule(allocator: std.mem.Allocator, module: ir.Module) CheckError!Result {
    var analyzer = Analyzer.init(allocator, module);
    defer analyzer.deinit();
    return analyzer.analyzeModule();
}

/// Returns a stable Core IR node label for an allocation kind.
pub fn nodeLabel(kind: AllocationKind) []const u8 {
    return switch (kind) {
        .Tuple => "Core.Tuple",
        .Record => "Core.Record",
        .RecordUpdate => "Core.RecordUpdate",
        .ConstructorPayload => "Core.Constr(payload)",
        .LambdaCapture => "Core.Lambda(captures)",
    };
}

fn exprCapturesAny(allocator: std.mem.Allocator, expr: ir.Expr, visible: *const StringSet, shadowed: *StringSet) CheckError!bool {
    switch (expr) {
        .Var => |var_ref| return visible.contains(var_ref.name) and !shadowed.contains(var_ref.name),
        .Constant => return false,
        .Lambda => |lambda_expr| {
            var snapshots = std.ArrayList(BindingSnapshot).empty;
            defer snapshots.deinit(allocator);
            for (lambda_expr.params) |param| try pushBinding(allocator, shadowed, &snapshots, param.name);
            defer restoreBindings(shadowed, snapshots.items);
            return exprCapturesAny(allocator, lambda_expr.body.*, visible, shadowed);
        },
        .App => |app| {
            if (try exprCapturesAny(allocator, app.callee.*, visible, shadowed)) return true;
            for (app.args) |arg| {
                if (try exprCapturesAny(allocator, arg.*, visible, shadowed)) return true;
            }
            return false;
        },
        .Let => |let_expr| {
            if (try exprCapturesAny(allocator, let_expr.value.*, visible, shadowed)) return true;
            var snapshots = std.ArrayList(BindingSnapshot).empty;
            defer snapshots.deinit(allocator);
            try pushBinding(allocator, shadowed, &snapshots, let_expr.name);
            defer restoreBindings(shadowed, snapshots.items);
            return exprCapturesAny(allocator, let_expr.body.*, visible, shadowed);
        },
        .If => |if_expr| {
            return try exprCapturesAny(allocator, if_expr.cond.*, visible, shadowed) or
                try exprCapturesAny(allocator, if_expr.then_branch.*, visible, shadowed) or
                try exprCapturesAny(allocator, if_expr.else_branch.*, visible, shadowed);
        },
        .Prim => |prim| {
            for (prim.args) |arg| {
                if (try exprCapturesAny(allocator, arg.*, visible, shadowed)) return true;
            }
            return false;
        },
        .Ctor => |ctor_expr| {
            for (ctor_expr.args) |arg| {
                if (try exprCapturesAny(allocator, arg.*, visible, shadowed)) return true;
            }
            return false;
        },
        .Match => |match_expr| {
            if (try exprCapturesAny(allocator, match_expr.scrutinee.*, visible, shadowed)) return true;
            for (match_expr.arms) |arm| {
                var snapshots = std.ArrayList(BindingSnapshot).empty;
                defer snapshots.deinit(allocator);
                try pushPatternBindings(allocator, shadowed, &snapshots, arm.pattern);
                defer restoreBindings(shadowed, snapshots.items);

                if (arm.guard) |guard| {
                    if (try exprCapturesAny(allocator, guard.*, visible, shadowed)) return true;
                }
                if (try exprCapturesAny(allocator, arm.body.*, visible, shadowed)) return true;
            }
            return false;
        },
        .Tuple => |tuple_expr| {
            for (tuple_expr.items) |item| {
                if (try exprCapturesAny(allocator, item.*, visible, shadowed)) return true;
            }
            return false;
        },
        .TupleProj => |tuple_proj| return exprCapturesAny(allocator, tuple_proj.tuple_expr.*, visible, shadowed),
        .Record => |record_expr| {
            for (record_expr.fields) |field| {
                if (try exprCapturesAny(allocator, field.value.*, visible, shadowed)) return true;
            }
            return false;
        },
        .RecordField => |record_field| return exprCapturesAny(allocator, record_field.record_expr.*, visible, shadowed),
        .RecordUpdate => |record_update| {
            if (try exprCapturesAny(allocator, record_update.base_expr.*, visible, shadowed)) return true;
            for (record_update.fields) |field| {
                if (try exprCapturesAny(allocator, field.value.*, visible, shadowed)) return true;
            }
            return false;
        },
        .AccountFieldSet => |field_set| {
            return try exprCapturesAny(allocator, field_set.account_expr.*, visible, shadowed) or
                try exprCapturesAny(allocator, field_set.value.*, visible, shadowed);
        },
    }
}

fn pushBinding(
    allocator: std.mem.Allocator,
    scope: *StringSet,
    snapshots: *std.ArrayList(BindingSnapshot),
    name: []const u8,
) CheckError!void {
    const existed = scope.contains(name);
    try scope.put(name, {});
    try snapshots.append(allocator, .{ .name = name, .existed = existed });
}

fn restoreBindings(scope: *StringSet, snapshots: []const BindingSnapshot) void {
    var index = snapshots.len;
    while (index > 0) {
        index -= 1;
        if (!snapshots[index].existed) {
            _ = scope.remove(snapshots[index].name);
        }
    }
}

fn pushPatternBindings(
    allocator: std.mem.Allocator,
    scope: *StringSet,
    snapshots: *std.ArrayList(BindingSnapshot),
    pattern: ir.Pattern,
) CheckError!void {
    switch (pattern) {
        .Wildcard, .Constant => {},
        .Var => |var_pattern| try pushBinding(allocator, scope, snapshots, var_pattern.name),
        .Alias => |alias| {
            try pushPatternBindings(allocator, scope, snapshots, alias.pattern.*);
            try pushBinding(allocator, scope, snapshots, alias.name);
        },
        .Ctor => |ctor_pattern| {
            for (ctor_pattern.args) |arg| try pushPatternBindings(allocator, scope, snapshots, arg);
        },
        .Tuple => |items| {
            for (items) |item| try pushPatternBindings(allocator, scope, snapshots, item);
        },
        .Record => |fields| {
            for (fields) |field| try pushPatternBindings(allocator, scope, snapshots, field.pattern);
        },
    }
}

fn exprPtr(arena_allocator: std.mem.Allocator, expr: ir.Expr) !*const ir.Expr {
    const ptr = try arena_allocator.create(ir.Expr);
    ptr.* = expr;
    return ptr;
}

fn intExpr(arena_allocator: std.mem.Allocator, value: i64) !*const ir.Expr {
    return exprPtr(arena_allocator, .{ .Constant = .{
        .value = .{ .Int = value },
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
}

fn topLambda(arena_allocator: std.mem.Allocator, body: *const ir.Expr) !*const ir.Expr {
    const params = try arena_allocator.alloc(ir.Param, 1);
    params[0] = .{ .name = "_input", .ty = .Int };
    const ret_ty = try arena_allocator.create(ir.Ty);
    ret_ty.* = .Int;
    const param_tys = try arena_allocator.alloc(ir.Ty, 1);
    param_tys[0] = .Int;
    return exprPtr(arena_allocator, .{ .Lambda = .{
        .params = params,
        .body = body,
        .ty = .{ .Arrow = .{ .params = param_tys, .ret = ret_ty } },
        .layout = layout.topLevelLambda(),
    } });
}

fn moduleWithDecls(arena_allocator: std.mem.Allocator, decls: []const ir.Decl) !ir.Module {
    const owned = try arena_allocator.alloc(ir.Decl, decls.len);
    @memcpy(owned, decls);
    return .{ .decls = owned };
}

test "no_alloc passes pure arithmetic function" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    const args = try arena_allocator.alloc(*const ir.Expr, 2);
    args[0] = try intExpr(arena_allocator, 1);
    args[1] = try intExpr(arena_allocator, 2);
    const body = try exprPtr(arena_allocator, .{ .Prim = .{
        .op = .Add,
        .args = args,
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const module = try moduleWithDecls(arena_allocator, &.{
        .{ .Let = .{ .name = "entrypoint", .value = try topLambda(arena_allocator, body), .ty = .Int, .layout = layout.topLevelLambda() } },
    });

    const result = try checkModule(std.testing.allocator, module);
    try std.testing.expect(result == .Pass);
}

test "no_alloc reports tuple allocation site" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    const items = try arena_allocator.alloc(*const ir.Expr, 2);
    items[0] = try intExpr(arena_allocator, 1);
    items[1] = try intExpr(arena_allocator, 2);
    const tuple_ty = try arena_allocator.alloc(ir.Ty, 2);
    tuple_ty[0] = .Int;
    tuple_ty[1] = .Int;
    const body = try exprPtr(arena_allocator, .{ .Tuple = .{
        .items = items,
        .ty = .{ .Tuple = tuple_ty },
        .layout = layout.structPack(),
    } });
    const module = try moduleWithDecls(arena_allocator, &.{
        .{ .Let = .{ .name = "entrypoint", .value = try topLambda(arena_allocator, body), .ty = .Int, .layout = layout.topLevelLambda() } },
    });

    const result = try checkModule(std.testing.allocator, module);
    try std.testing.expect(result == .Fail);
    try std.testing.expectEqual(AllocationKind.Tuple, result.Fail.kind);
    try std.testing.expectEqualStrings("entrypoint", result.Fail.function_name);
}

test "no_alloc reports transitive callee allocation site" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    const items = try arena_allocator.alloc(*const ir.Expr, 2);
    items[0] = try intExpr(arena_allocator, 1);
    items[1] = try intExpr(arena_allocator, 2);
    const tuple_ty = try arena_allocator.alloc(ir.Ty, 2);
    tuple_ty[0] = .Int;
    tuple_ty[1] = .Int;
    const tuple_body = try exprPtr(arena_allocator, .{ .Tuple = .{
        .items = items,
        .ty = .{ .Tuple = tuple_ty },
        .layout = layout.structPack(),
    } });

    const ret_ty = try arena_allocator.create(ir.Ty);
    ret_ty.* = .Int;
    const callee = try exprPtr(arena_allocator, .{ .Var = .{
        .name = "make_pair",
        .ty = .{ .Arrow = .{ .params = &.{}, .ret = ret_ty } },
        .layout = layout.topLevelLambda(),
    } });
    const call_body = try exprPtr(arena_allocator, .{ .App = .{
        .callee = callee,
        .args = &.{},
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const module = try moduleWithDecls(arena_allocator, &.{
        .{ .Let = .{ .name = "entrypoint", .value = try topLambda(arena_allocator, call_body), .ty = .Int, .layout = layout.topLevelLambda() } },
        .{ .Let = .{ .name = "make_pair", .value = try topLambda(arena_allocator, tuple_body), .ty = .Int, .layout = layout.topLevelLambda() } },
    });

    const result = try checkModule(std.testing.allocator, module);
    try std.testing.expect(result == .Fail);
    try std.testing.expectEqual(AllocationKind.Tuple, result.Fail.kind);
    try std.testing.expectEqualStrings("make_pair", result.Fail.function_name);
}

test "no_alloc reports lambda capture allocation site" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    const captured_var = try exprPtr(arena_allocator, .{ .Var = .{
        .name = "x",
        .ty = .Int,
        .layout = layout.intConstant(),
    } });
    const nested_ret_ty = try arena_allocator.create(ir.Ty);
    nested_ret_ty.* = .Int;
    const nested_lambda = try exprPtr(arena_allocator, .{ .Lambda = .{
        .params = &.{},
        .body = captured_var,
        .ty = .{ .Arrow = .{ .params = &.{}, .ret = nested_ret_ty } },
        .layout = layout.closure(),
    } });
    const let_body = try exprPtr(arena_allocator, .{ .Let = .{
        .name = "x",
        .value = try intExpr(arena_allocator, 7),
        .body = nested_lambda,
        .ty = nested_lambda.Lambda.ty,
        .layout = layout.closure(),
    } });
    const module = try moduleWithDecls(arena_allocator, &.{
        .{ .Let = .{ .name = "entrypoint", .value = try topLambda(arena_allocator, let_body), .ty = .Int, .layout = layout.topLevelLambda() } },
    });

    const result = try checkModule(std.testing.allocator, module);
    try std.testing.expect(result == .Fail);
    try std.testing.expectEqual(AllocationKind.LambdaCapture, result.Fail.kind);
}
