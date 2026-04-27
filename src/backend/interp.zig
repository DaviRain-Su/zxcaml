//! Tree-walk interpreter for Core IR modules.
//!
//! RESPONSIBILITIES:
//! - Execute Core IR directly, without passing through Lowered IR.
//! - Provide the semantic oracle used by `omlz run` and future determinism tests.
//! - Return clear stub errors for Core IR nodes not yet implemented in M0.

const std = @import("std");
const api = @import("api.zig");
const ir = @import("../core/ir.zig");
const layout = @import("../core/layout.zig");

const division_by_zero_marker = "ZXCAML_PANIC:division_by_zero";

/// Stateless M0 interpreter backend.
pub const Interpreter = struct {
    const vtable: api.VTable = .{
        .evalModule = evalBackend,
        .emitModule = api.unsupportedEmitModule,
    };

    /// Returns this interpreter behind the backend extension-point trait.
    pub fn backend(self: *Interpreter) api.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

/// Errors produced by M0 interpreter stubs.
pub const EvalError = error{
    EntrypointNotFound,
    NegativeIntegerResultUnsupported,
    UnsupportedDecl,
    UnsupportedExpr,
    UnsupportedTopLevelValue,
    UnboundVariable,
    MatchFailure,
    ArityMismatch,
    DivisionByZero,
    OutOfMemory,
};

const Value = union(enum) {
    Int: i64,
    Bool: bool,
    String: []const u8,
    Ctor: CtorValue,
    List: *const ListValue,
    Lambda: ir.Lambda,
};

const CtorValue = struct {
    name: []const u8,
    args: []const Value,
};

const ListValue = union(enum) {
    nil,
    cons: Cons,
};

const Cons = struct {
    head: Value,
    tail: *const ListValue,
};

/// Evaluates a Core IR module by invoking its top-level `entrypoint` lambda.
pub fn evalModule(module: ir.Module) EvalError!u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = std.StringHashMap(Value).init(arena.allocator());
    defer env.deinit();

    var entrypoint: ?ir.Let = null;
    for (module.decls) |decl| {
        switch (decl) {
            .Let => |let_decl| {
                if (std.mem.eql(u8, let_decl.name, "entrypoint")) {
                    entrypoint = let_decl;
                    continue;
                }
                switch (let_decl.value.*) {
                    .Lambda => |lambda| {
                        try env.put(let_decl.name, .{ .Lambda = lambda });
                        continue;
                    },
                    else => {},
                }
                try env.put(let_decl.name, try evalTopLevelValue(arena.allocator(), let_decl.value.*, &env));
            },
        }
    }

    const entry = entrypoint orelse return error.EntrypointNotFound;
    const lambda = switch (entry.value.*) {
        .Lambda => |value| value,
        else => return error.UnsupportedTopLevelValue,
    };
    return valueToU64(try evalExpr(arena.allocator(), lambda.body.*, &env));
}

/// Returns the user-facing diagnostic for an interpreter error.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EntrypointNotFound => "interpreter does not yet implement module without entrypoint",
        error.NegativeIntegerResultUnsupported => "interpreter does not yet implement negative int results",
        error.UnsupportedDecl => "interpreter does not yet implement declaration node",
        error.UnsupportedExpr => "interpreter does not yet implement expression node",
        error.UnsupportedTopLevelValue => "interpreter entrypoint must be a function",
        error.UnboundVariable => "interpreter found an unbound variable",
        error.MatchFailure => "interpreter pattern match was non-exhaustive",
        error.ArityMismatch => "interpreter function application arity mismatch",
        error.DivisionByZero => division_by_zero_marker,
        error.NotImplemented => "interpreter does not yet implement source emission",
        else => "interpreter failed",
    };
}

/// Returns a stable panic marker for errors that model user-program panics.
pub fn panicMarker(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.DivisionByZero => division_by_zero_marker,
        else => null,
    };
}

fn evalBackend(_: *anyopaque, module: ir.Module) anyerror!u64 {
    return evalModule(module);
}

fn evalTopLevelValue(allocator: std.mem.Allocator, expr: ir.Expr, env: *std.StringHashMap(Value)) EvalError!Value {
    return switch (expr) {
        .Constant, .Let, .Var, .Ctor, .Match => evalExpr(allocator, expr, env),
        .App, .If, .Prim => evalExpr(allocator, expr, env),
        .Lambda => |lambda| .{ .Lambda = lambda },
    };
}

fn evalExpr(allocator: std.mem.Allocator, expr: ir.Expr, env: *std.StringHashMap(Value)) EvalError!Value {
    return switch (expr) {
        .Constant => |constant| switch (constant.value) {
            .Int => |value| .{ .Int = value },
            .String => |value| .{ .String = value },
        },
        .Let => |let_expr| evalLet(allocator, let_expr, env),
        .Var => |var_ref| env.get(var_ref.name) orelse error.UnboundVariable,
        .App => |app| evalApp(allocator, app, env),
        .If => |if_expr| evalIf(allocator, if_expr, env),
        .Prim => |prim| evalPrim(allocator, prim, env),
        .Ctor => |ctor_expr| evalCtor(allocator, ctor_expr, env),
        .Match => |match_expr| evalMatch(allocator, match_expr, env),
        .Lambda => |lambda| .{ .Lambda = lambda },
    };
}

fn evalApp(allocator: std.mem.Allocator, app: ir.App, env: *std.StringHashMap(Value)) EvalError!Value {
    const callee = try evalExpr(allocator, app.callee.*, env);
    const lambda = switch (callee) {
        .Lambda => |value| value,
        else => return error.UnsupportedExpr,
    };
    if (lambda.params.len != app.args.len) return error.ArityMismatch;

    var inserted = std.ArrayList(EnvBinding).empty;
    defer inserted.deinit(allocator);
    for (lambda.params, app.args) |param, arg| {
        const value = try evalExpr(allocator, arg.*, env);
        const previous = env.get(param.name);
        try env.put(param.name, value);
        try inserted.append(allocator, .{ .name = param.name, .previous = previous });
    }
    defer restoreEnv(env, inserted.items);
    return evalExpr(allocator, lambda.body.*, env);
}

fn evalIf(allocator: std.mem.Allocator, if_expr: ir.IfExpr, env: *std.StringHashMap(Value)) EvalError!Value {
    const cond = try evalExpr(allocator, if_expr.cond.*, env);
    return switch (cond) {
        .Bool => |value| if (value) evalExpr(allocator, if_expr.then_branch.*, env) else evalExpr(allocator, if_expr.else_branch.*, env),
        else => error.UnsupportedExpr,
    };
}

fn evalPrim(allocator: std.mem.Allocator, prim: ir.Prim, env: *std.StringHashMap(Value)) EvalError!Value {
    if (prim.args.len != 2) return error.ArityMismatch;
    const lhs = try intValue(try evalExpr(allocator, prim.args[0].*, env));
    const rhs = try intValue(try evalExpr(allocator, prim.args[1].*, env));
    return switch (prim.op) {
        .Add => .{ .Int = wrappingAdd(lhs, rhs) },
        .Sub => .{ .Int = wrappingSub(lhs, rhs) },
        .Mul => .{ .Int = wrappingMul(lhs, rhs) },
        .Div => .{ .Int = try truncatingDiv(lhs, rhs) },
        .Mod => .{ .Int = try truncatingMod(lhs, rhs) },
        .Eq => .{ .Bool = lhs == rhs },
        .Ne => .{ .Bool = lhs != rhs },
        .Lt => .{ .Bool = lhs < rhs },
        .Le => .{ .Bool = lhs <= rhs },
        .Gt => .{ .Bool = lhs > rhs },
        .Ge => .{ .Bool = lhs >= rhs },
    };
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

fn truncatingDiv(lhs: i64, rhs: i64) EvalError!i64 {
    if (rhs == 0) return error.DivisionByZero;
    if (lhs == std.math.minInt(i64) and rhs == -1) return std.math.minInt(i64);
    return @divTrunc(lhs, rhs);
}

fn truncatingMod(lhs: i64, rhs: i64) EvalError!i64 {
    if (rhs == 0) return error.DivisionByZero;
    if (lhs == std.math.minInt(i64) and rhs == -1) return 0;
    return @rem(lhs, rhs);
}

fn intValue(value: Value) EvalError!i64 {
    return switch (value) {
        .Int => |int| int,
        else => error.UnsupportedExpr,
    };
}

fn evalMatch(allocator: std.mem.Allocator, match_expr: ir.Match, env: *std.StringHashMap(Value)) EvalError!Value {
    const scrutinee = try evalExpr(allocator, match_expr.scrutinee.*, env);
    for (match_expr.arms) |arm| {
        var inserted = std.ArrayList(EnvBinding).empty;
        defer inserted.deinit(allocator);

        if (try patternMatches(allocator, arm.pattern, scrutinee, env, &inserted)) {
            defer restoreEnv(env, inserted.items);
            return evalExpr(allocator, arm.body.*, env);
        }
        restoreEnv(env, inserted.items);
    }
    return error.MatchFailure;
}

fn evalCtor(allocator: std.mem.Allocator, ctor_expr: ir.Ctor, env: *std.StringHashMap(Value)) EvalError!Value {
    if (std.mem.eql(u8, ctor_expr.name, "[]")) {
        if (ctor_expr.args.len != 0) return error.ArityMismatch;
        const list = try allocator.create(ListValue);
        list.* = .nil;
        return .{ .List = list };
    }
    if (std.mem.eql(u8, ctor_expr.name, "::")) {
        if (ctor_expr.args.len != 2) return error.ArityMismatch;
        const head = try evalExpr(allocator, ctor_expr.args[0].*, env);
        const tail = switch (try evalExpr(allocator, ctor_expr.args[1].*, env)) {
            .List => |list| list,
            else => return error.UnsupportedExpr,
        };
        const list = try allocator.create(ListValue);
        list.* = .{ .cons = .{ .head = head, .tail = tail } };
        return .{ .List = list };
    }

    const args = try allocator.alloc(Value, ctor_expr.args.len);
    for (ctor_expr.args, 0..) |arg, index| {
        args[index] = try evalExpr(allocator, arg.*, env);
    }
    return .{ .Ctor = .{
        .name = ctor_expr.name,
        .args = args,
    } };
}

fn evalLet(allocator: std.mem.Allocator, let_expr: ir.LetExpr, env: *std.StringHashMap(Value)) EvalError!Value {
    const value = try evalExpr(allocator, let_expr.value.*, env);
    const previous = env.get(let_expr.name);
    try env.put(let_expr.name, value);
    defer {
        if (previous) |binding| {
            env.getPtr(let_expr.name).?.* = binding;
        } else {
            _ = env.remove(let_expr.name);
        }
    }
    return evalExpr(allocator, let_expr.body.*, env);
}

const EnvBinding = struct {
    name: []const u8,
    previous: ?Value,
};

fn patternMatches(
    allocator: std.mem.Allocator,
    pattern: ir.Pattern,
    value: Value,
    env: *std.StringHashMap(Value),
    inserted: *std.ArrayList(EnvBinding),
) EvalError!bool {
    return switch (pattern) {
        .Wildcard => true,
        .Var => |var_pattern| blk: {
            if (std.mem.eql(u8, var_pattern.name, "_")) break :blk true;
            const previous = env.get(var_pattern.name);
            try env.put(var_pattern.name, value);
            try inserted.append(allocator, .{ .name = var_pattern.name, .previous = previous });
            break :blk true;
        },
        .Ctor => |ctor_pattern| blk: {
            if (try listPatternMatches(allocator, ctor_pattern, value, env, inserted)) |matched| {
                break :blk matched;
            }
            const ctor_value = switch (value) {
                .Ctor => |ctor| ctor,
                else => break :blk false,
            };
            if (!std.mem.eql(u8, ctor_pattern.name, ctor_value.name)) break :blk false;
            if (ctor_pattern.args.len != ctor_value.args.len) break :blk false;
            for (ctor_pattern.args, ctor_value.args) |arg_pattern, arg_value| {
                if (!try patternMatches(allocator, arg_pattern, arg_value, env, inserted)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn listPatternMatches(
    allocator: std.mem.Allocator,
    ctor_pattern: ir.PatternCtor,
    value: Value,
    env: *std.StringHashMap(Value),
    inserted: *std.ArrayList(EnvBinding),
) EvalError!?bool {
    if (!std.mem.eql(u8, ctor_pattern.name, "[]") and !std.mem.eql(u8, ctor_pattern.name, "::")) return null;
    const list = switch (value) {
        .List => |list_value| list_value,
        else => return false,
    };
    switch (list.*) {
        .nil => {
            if (!std.mem.eql(u8, ctor_pattern.name, "[]")) return false;
            return ctor_pattern.args.len == 0;
        },
        .cons => |cell| {
            if (!std.mem.eql(u8, ctor_pattern.name, "::") or ctor_pattern.args.len != 2) return false;
            if (!try patternMatches(allocator, ctor_pattern.args[0], cell.head, env, inserted)) return false;
            if (!try patternMatches(allocator, ctor_pattern.args[1], .{ .List = cell.tail }, env, inserted)) return false;
            return true;
        },
    }
}

fn restoreEnv(env: *std.StringHashMap(Value), inserted: []const EnvBinding) void {
    var index = inserted.len;
    while (index > 0) {
        index -= 1;
        const binding = inserted[index];
        if (binding.previous) |previous| {
            env.getPtr(binding.name).?.* = previous;
        } else {
            _ = env.remove(binding.name);
        }
    }
}

fn valueToU64(value: Value) EvalError!u64 {
    return switch (value) {
        .Int => |int| std.math.cast(u64, int) orelse error.NegativeIntegerResultUnsupported,
        .Bool, .String, .Ctor, .List, .Lambda => error.UnsupportedExpr,
    };
}

fn makeExpr(comptime expr: ir.Expr) *const ir.Expr {
    const S = struct {
        const value = expr;
    };
    return &S.value;
}

fn testLet(comptime name: []const u8, comptime value: i64) ir.Decl {
    return .{ .Let = .{
        .name = name,
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Constant = .{
                .value = .{ .Int = value },
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
}

test "interpreter evaluates M0 integer constants directly from Core IR" {
    const zero_decls = [_]ir.Decl{testLet("entrypoint", 0)};
    const answer_decls = [_]ir.Decl{testLet("entrypoint", 42)};

    try std.testing.expectEqual(@as(u64, 0), try evalModule(.{ .decls = &zero_decls }));
    try std.testing.expectEqual(@as(u64, 42), try evalModule(.{ .decls = &answer_decls }));
}

test "interpreter pins i64 arithmetic wrap edge cases" {
    try std.testing.expectEqual(std.math.minInt(i64), wrappingAdd(std.math.maxInt(i64), 1));
    try std.testing.expectEqual(std.math.maxInt(i64), wrappingSub(std.math.minInt(i64), 1));
    try std.testing.expectEqual(std.math.minInt(i64), wrappingMul(std.math.minInt(i64), -1));
    try std.testing.expectEqual(std.math.minInt(i64), try truncatingDiv(std.math.minInt(i64), -1));
    try std.testing.expectEqual(@as(i64, 0), try truncatingMod(std.math.minInt(i64), -1));
    try std.testing.expectError(error.DivisionByZero, truncatingDiv(0, 0));
    try std.testing.expectError(error.DivisionByZero, truncatingMod(0, 0));
    try std.testing.expectEqualStrings(division_by_zero_marker, panicMarker(error.DivisionByZero).?);
}

test "interpreter evaluates top-level and nested let variable bindings" {
    const x_decl: ir.Decl = .{ .Let = .{
        .name = "x",
        .value = makeExpr(.{ .Constant = .{
            .value = .{ .Int = 1 },
            .ty = .Int,
            .layout = layout.intConstant(),
        } }),
        .ty = .Int,
        .layout = layout.intConstant(),
    } };
    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Let = .{
                .name = "y",
                .value = makeExpr(.{ .Constant = .{
                    .value = .{ .Int = 7 },
                    .ty = .Int,
                    .layout = layout.intConstant(),
                } }),
                .body = makeExpr(.{ .Var = .{
                    .name = "x",
                    .ty = .Int,
                    .layout = layout.intConstant(),
                } }),
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{ x_decl, entrypoint_decl };

    try std.testing.expectEqual(@as(u64, 1), try evalModule(.{ .decls = &decls }));
}

test "interpreter constructs option constructor values inside lets" {
    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Let = .{
                .name = "_",
                .value = makeExpr(.{ .Ctor = .{
                    .name = "Some",
                    .args = &.{makeExpr(.{ .Constant = .{
                        .value = .{ .Int = 1 },
                        .ty = .Int,
                        .layout = layout.intConstant(),
                    } })},
                    .ty = .{ .Adt = .{ .name = "option", .params = &.{.Int} } },
                    .layout = layout.ctor(1),
                } }),
                .body = makeExpr(.{ .Constant = .{
                    .value = .{ .Int = 0 },
                    .ty = .Int,
                    .layout = layout.intConstant(),
                } }),
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{entrypoint_decl};

    try std.testing.expectEqual(@as(u64, 0), try evalModule(.{ .decls = &decls }));
}

test "interpreter can materialize all F10 whitelisted constructors" {
    const option_params = [_]ir.Ty{.Int};
    const result_ok_params = [_]ir.Ty{ .Int, .Unit };
    const result_error_params = [_]ir.Ty{ .Unit, .Int };
    const ctor_exprs = [_]ir.Expr{
        .{ .Ctor = .{ .name = "None", .args = &.{}, .ty = .{ .Adt = .{ .name = "option", .params = &option_params } }, .layout = layout.ctor(0) } },
        .{ .Ctor = .{ .name = "Some", .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 1 }, .ty = .Int, .layout = layout.intConstant() } })}, .ty = .{ .Adt = .{ .name = "option", .params = &option_params } }, .layout = layout.ctor(1) } },
        .{ .Ctor = .{ .name = "Ok", .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 2 }, .ty = .Int, .layout = layout.intConstant() } })}, .ty = .{ .Adt = .{ .name = "result", .params = &result_ok_params } }, .layout = layout.ctor(1) } },
        .{ .Ctor = .{ .name = "Error", .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 3 }, .ty = .Int, .layout = layout.intConstant() } })}, .ty = .{ .Adt = .{ .name = "result", .params = &result_error_params } }, .layout = layout.ctor(1) } },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.StringHashMap(Value).init(arena.allocator());
    defer env.deinit();
    for (ctor_exprs) |expr| {
        const value = try evalExpr(arena.allocator(), expr, &env);
        const ctor_value = switch (value) {
            .Ctor => |ctor| ctor,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(ctor_value.name.len > 0);
    }
}

test "interpreter matches constructor arms top-to-bottom" {
    const option_ty = ir.Ty{ .Adt = .{ .name = "option", .params = &.{.Int} } };
    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Match = .{
                .scrutinee = makeExpr(.{ .Ctor = .{
                    .name = "Some",
                    .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 1 }, .ty = .Int, .layout = layout.intConstant() } })},
                    .ty = option_ty,
                    .layout = layout.ctor(1),
                } }),
                .arms = &.{
                    .{
                        .pattern = .{ .Ctor = .{
                            .name = "Some",
                            .args = &.{.{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } }},
                        } },
                        .body = makeExpr(.{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } }),
                    },
                    .{
                        .pattern = .{ .Ctor = .{ .name = "None", .args = &.{} } },
                        .body = makeExpr(.{ .Constant = .{ .value = .{ .Int = 0 }, .ty = .Int, .layout = layout.intConstant() } }),
                    },
                },
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{entrypoint_decl};

    try std.testing.expectEqual(@as(u64, 1), try evalModule(.{ .decls = &decls }));
}

test "interpreter represents lists as nil/cons values and matches them" {
    const list_ty = ir.Ty{ .Adt = .{ .name = "list", .params = &.{.Int} } };
    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Match = .{
                .scrutinee = makeExpr(.{ .Ctor = .{
                    .name = "::",
                    .args = &.{
                        makeExpr(.{ .Constant = .{ .value = .{ .Int = 6 }, .ty = .Int, .layout = layout.intConstant() } }),
                        makeExpr(.{ .Ctor = .{
                            .name = "[]",
                            .args = &.{},
                            .ty = list_ty,
                            .layout = layout.ctor(0),
                        } }),
                    },
                    .ty = list_ty,
                    .layout = layout.ctor(2),
                } }),
                .arms = &.{
                    .{
                        .pattern = .{ .Ctor = .{ .name = "[]", .args = &.{} } },
                        .body = makeExpr(.{ .Constant = .{ .value = .{ .Int = 0 }, .ty = .Int, .layout = layout.intConstant() } }),
                    },
                    .{
                        .pattern = .{ .Ctor = .{
                            .name = "::",
                            .args = &.{
                                .{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } },
                                .{ .Var = .{ .name = "rest", .ty = list_ty, .layout = layout.ctor(2) } },
                            },
                        } },
                        .body = makeExpr(.{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } }),
                    },
                },
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{entrypoint_decl};

    try std.testing.expectEqual(@as(u64, 6), try evalModule(.{ .decls = &decls }));
}

test "interpreter supports wildcard and variable match patterns" {
    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Match = .{
                .scrutinee = makeExpr(.{ .Constant = .{ .value = .{ .Int = 4 }, .ty = .Int, .layout = layout.intConstant() } }),
                .arms = &.{
                    .{
                        .pattern = .{ .Var = .{ .name = "n", .ty = .Int, .layout = layout.intConstant() } },
                        .body = makeExpr(.{ .Var = .{ .name = "n", .ty = .Int, .layout = layout.intConstant() } }),
                    },
                    .{
                        .pattern = .Wildcard,
                        .body = makeExpr(.{ .Constant = .{ .value = .{ .Int = 0 }, .ty = .Int, .layout = layout.intConstant() } }),
                    },
                },
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{entrypoint_decl};

    try std.testing.expectEqual(@as(u64, 4), try evalModule(.{ .decls = &decls }));
}

test "interpreter evaluates a recursive top-level function" {
    const decls = [_]ir.Decl{
        .{ .Let = .{
            .name = "loop",
            .value = makeExpr(.{ .Lambda = .{
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
                    .then_branch = makeExpr(.{ .Constant = .{ .value = .{ .Int = 7 }, .ty = .Int, .layout = layout.intConstant() } }),
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
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
            .is_rec = true,
        } },
        .{ .Let = .{
            .name = "entrypoint",
            .value = makeExpr(.{ .Lambda = .{
                .params = &.{},
                .body = makeExpr(.{ .App = .{
                    .callee = makeExpr(.{ .Var = .{ .name = "loop", .ty = .Unit, .layout = layout.topLevelLambda() } }),
                    .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 3 }, .ty = .Int, .layout = layout.intConstant() } })},
                    .ty = .Int,
                    .layout = layout.intConstant(),
                } }),
                .ty = .Unit,
                .layout = layout.topLevelLambda(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } },
    };

    try std.testing.expectEqual(@as(u64, 7), try evalModule(.{ .decls = &decls }));
}

test "interpreter backend trait exposes direct eval and rejects source emission" {
    const decls = [_]ir.Decl{testLet("entrypoint", 7)};
    const module = ir.Module{ .decls = &decls };
    var interpreter: Interpreter = .{};
    const backend = interpreter.backend();

    try std.testing.expectEqual(@as(u64, 7), try backend.evalModule(module));
    try std.testing.expectError(error.NotImplemented, backend.emitModule(module));
    try std.testing.expectEqualStrings(
        "interpreter does not yet implement source emission",
        errorMessage(error.NotImplemented),
    );
}

test "interpreter unsupported module shapes raise recognisable stub errors" {
    const missing_entrypoint_decls = [_]ir.Decl{testLet("not_entrypoint", 0)};
    const module_without_entrypoint = ir.Module{ .decls = &missing_entrypoint_decls };

    try std.testing.expectError(error.EntrypointNotFound, evalModule(module_without_entrypoint));
    try std.testing.expectEqualStrings(
        "interpreter does not yet implement module without entrypoint",
        errorMessage(error.EntrypointNotFound),
    );

    const negative_decls = [_]ir.Decl{testLet("entrypoint", -1)};
    try std.testing.expectError(error.NegativeIntegerResultUnsupported, evalModule(.{ .decls = &negative_decls }));
    try std.testing.expectEqualStrings(
        "interpreter does not yet implement negative int results",
        errorMessage(error.NegativeIntegerResultUnsupported),
    );
}
