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
};

/// Evaluates a Core IR module by invoking its top-level `entrypoint` lambda.
pub fn evalModule(module: ir.Module) EvalError!u64 {
    const entrypoint = findEntrypoint(module) orelse return error.EntrypointNotFound;
    return evalExpr(entrypoint.lambda.body);
}

/// Returns the user-facing diagnostic for an interpreter error.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EntrypointNotFound => "interpreter does not yet implement module without entrypoint",
        error.NegativeIntegerResultUnsupported => "interpreter does not yet implement negative int results",
        error.UnsupportedDecl => "interpreter does not yet implement declaration node",
        error.UnsupportedExpr => "interpreter does not yet implement expression node",
        error.NotImplemented => "interpreter does not yet implement source emission",
        else => "interpreter failed",
    };
}

fn evalBackend(_: *anyopaque, module: ir.Module) anyerror!u64 {
    return evalModule(module);
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

fn evalExpr(expr: ir.Expr) EvalError!u64 {
    return switch (expr) {
        .Constant => |constant| evalConstant(constant),
    };
}

fn evalConstant(constant: ir.Constant) EvalError!u64 {
    return std.math.cast(u64, constant.value) orelse error.NegativeIntegerResultUnsupported;
}

fn testLet(name: []const u8, value: i64) ir.Decl {
    return .{ .Let = .{
        .name = name,
        .lambda = .{
            .params = &.{},
            .body = .{ .Constant = .{
                .value = value,
                .ty = .Int,
                .layout = layout.intConstant(),
            } },
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        },
    } };
}

test "interpreter evaluates M0 integer constants directly from Core IR" {
    const zero_decls = [_]ir.Decl{testLet("entrypoint", 0)};
    const answer_decls = [_]ir.Decl{testLet("entrypoint", 42)};

    try std.testing.expectEqual(@as(u64, 0), try evalModule(.{ .decls = &zero_decls }));
    try std.testing.expectEqual(@as(u64, 42), try evalModule(.{ .decls = &answer_decls }));
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
