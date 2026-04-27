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
    OutOfMemory,
};

const Value = union(enum) {
    Int: i64,
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
                    .Lambda => continue,
                    else => {},
                }
                try env.put(let_decl.name, try evalTopLevelValue(let_decl.value.*, &env));
            },
        }
    }

    const entry = entrypoint orelse return error.EntrypointNotFound;
    const lambda = switch (entry.value.*) {
        .Lambda => |value| value,
        else => return error.UnsupportedTopLevelValue,
    };
    return valueToU64(try evalExpr(lambda.body.*, &env));
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
        error.NotImplemented => "interpreter does not yet implement source emission",
        else => "interpreter failed",
    };
}

fn evalBackend(_: *anyopaque, module: ir.Module) anyerror!u64 {
    return evalModule(module);
}

fn evalTopLevelValue(expr: ir.Expr, env: *std.StringHashMap(Value)) EvalError!Value {
    return switch (expr) {
        .Constant, .Let, .Var => evalExpr(expr, env),
        .Lambda => error.UnsupportedTopLevelValue,
    };
}

fn evalExpr(expr: ir.Expr, env: *std.StringHashMap(Value)) EvalError!Value {
    return switch (expr) {
        .Constant => |constant| .{ .Int = constant.value },
        .Let => |let_expr| evalLet(let_expr, env),
        .Var => |var_ref| env.get(var_ref.name) orelse error.UnboundVariable,
        .Lambda => error.UnsupportedExpr,
    };
}

fn evalLet(let_expr: ir.LetExpr, env: *std.StringHashMap(Value)) EvalError!Value {
    const value = try evalExpr(let_expr.value.*, env);
    const previous = env.get(let_expr.name);
    try env.put(let_expr.name, value);
    defer {
        if (previous) |binding| {
            env.getPtr(let_expr.name).?.* = binding;
        } else {
            _ = env.remove(let_expr.name);
        }
    }
    return evalExpr(let_expr.body.*, env);
}

fn valueToU64(value: Value) EvalError!u64 {
    return switch (value) {
        .Int => |int| std.math.cast(u64, int) orelse error.NegativeIntegerResultUnsupported,
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
                .value = value,
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

test "interpreter evaluates top-level and nested let variable bindings" {
    const x_decl: ir.Decl = .{ .Let = .{
        .name = "x",
        .value = makeExpr(.{ .Constant = .{
            .value = 1,
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
                    .value = 7,
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
