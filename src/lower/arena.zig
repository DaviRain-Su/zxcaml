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
const core_types = @import("../core/types.zig");

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
    UnsupportedEntrypoint,
};

const CaptureSet = []const ir.Param;

const LowerContext = struct {
    bound: std.StringHashMap(ir.Ty),
    rec_captures: std.StringHashMap(CaptureSet),
    closure_bound: std.StringHashMap(void),
    functions: ?*std.ArrayList(lir.LFunc) = null,
    next_closure_id: ?*usize = null,

    fn init(allocator: std.mem.Allocator) LowerContext {
        return .{
            .bound = std.StringHashMap(ir.Ty).init(allocator),
            .rec_captures = std.StringHashMap(CaptureSet).init(allocator),
            .closure_bound = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *LowerContext) void {
        self.closure_bound.deinit();
        self.rec_captures.deinit();
        self.bound.deinit();
    }
};

const BindingSnapshot = struct {
    name: []const u8,
    previous: ?ir.Ty,
};

/// Lowers a Core IR module with the P1 arena strategy.
pub fn lowerModule(allocator: std.mem.Allocator, module: ir.Module) LowerError!lir.LModule {
    const entrypoint_index = findEntrypointIndex(module) orelse return error.EntrypointNotFound;
    var functions = std.ArrayList(lir.LFunc).empty;
    errdefer functions.deinit(allocator);
    var next_closure_id: usize = 0;
    for (module.decls, 0..) |decl, index| {
        if (index == entrypoint_index) continue;
        const let_decl = switch (decl) {
            .Let => |value| value,
        };
        switch (let_decl.value.*) {
            .Lambda => |lambda| {
                try functions.append(allocator, try lowerFunction(allocator, let_decl.name, lambda, &.{}, &functions, &next_closure_id));
                try collectNestedFunctionsInLambda(allocator, lambda, &functions, &next_closure_id);
            },
            else => {},
        }
    }
    const entrypoint = switch (module.decls[entrypoint_index]) {
        .Let => |value| value,
    };
    const entry_lambda = switch (entrypoint.value.*) {
        .Lambda => |lambda| lambda,
        else => return error.UnsupportedEntrypoint,
    };
    try collectNestedFunctionsInLambda(allocator, entry_lambda, &functions, &next_closure_id);
    return .{
        .entrypoint = try lowerEntrypointLet(allocator, module, entrypoint_index, &functions, &next_closure_id),
        .functions = try functions.toOwnedSlice(allocator),
        .type_decls = try lowerTypeDecls(allocator, module.type_decls),
        .tuple_type_decls = try lowerTupleTypeDecls(allocator, module.tuple_type_decls),
        .record_type_decls = try lowerRecordTypeDecls(allocator, module.record_type_decls),
        .externals = try lowerExternalDecls(allocator, module.externals),
    };
}

fn lowerTypeDecls(allocator: std.mem.Allocator, decls: []const core_types.VariantType) LowerError![]const lir.LVariantType {
    const lowered = try allocator.alloc(lir.LVariantType, decls.len);
    for (decls, 0..) |decl, decl_index| {
        const variants = try allocator.alloc(lir.LVariantCtor, decl.variants.len);
        for (decl.variants, 0..) |variant, variant_index| {
            variants[variant_index] = .{
                .name = try allocator.dupe(u8, variant.name),
                .tag = variant.tag,
                .payload_types = try lowerTypeExprs(allocator, variant.payload_types),
            };
        }
        lowered[decl_index] = .{
            .name = try allocator.dupe(u8, decl.name),
            .params = try dupeStringSlice(allocator, decl.params),
            .variants = variants,
            .is_recursive = decl.is_recursive,
        };
    }
    return lowered;
}

fn lowerTupleTypeDecls(allocator: std.mem.Allocator, decls: []const core_types.TupleType) LowerError![]const lir.LTupleType {
    const lowered = try allocator.alloc(lir.LTupleType, decls.len);
    for (decls, 0..) |decl, decl_index| {
        lowered[decl_index] = .{
            .name = try allocator.dupe(u8, decl.name),
            .params = try dupeStringSlice(allocator, decl.params),
            .items = try lowerTypeExprs(allocator, decl.items),
            .is_recursive = decl.is_recursive,
        };
    }
    return lowered;
}

fn lowerRecordTypeDecls(allocator: std.mem.Allocator, decls: []const core_types.RecordType) LowerError![]const lir.LRecordType {
    const lowered = try allocator.alloc(lir.LRecordType, decls.len);
    for (decls, 0..) |decl, decl_index| {
        const fields = try allocator.alloc(lir.LRecordTypeField, decl.fields.len);
        for (decl.fields, 0..) |field, field_index| {
            fields[field_index] = .{
                .name = try allocator.dupe(u8, field.name),
                .ty = try lowerTypeExpr(allocator, field.ty),
                .is_mutable = field.is_mutable,
            };
        }
        lowered[decl_index] = .{
            .name = try allocator.dupe(u8, decl.name),
            .params = try dupeStringSlice(allocator, decl.params),
            .fields = fields,
            .is_recursive = decl.is_recursive,
        };
    }
    return lowered;
}

fn lowerExternalDecls(allocator: std.mem.Allocator, decls: []const ir.ExternalDecl) LowerError![]const lir.LExternalDecl {
    const lowered = try allocator.alloc(lir.LExternalDecl, decls.len);
    for (decls, 0..) |decl, index| {
        lowered[index] = .{
            .name = try allocator.dupe(u8, decl.name),
            .ty = try lowerTy(allocator, decl.ty),
            .symbol = try allocator.dupe(u8, decl.symbol),
        };
    }
    return lowered;
}

fn lowerTypeExprs(allocator: std.mem.Allocator, exprs: []const core_types.TypeExpr) LowerError![]const lir.LTypeExpr {
    const lowered = try allocator.alloc(lir.LTypeExpr, exprs.len);
    for (exprs, 0..) |expr, index| {
        lowered[index] = try lowerTypeExpr(allocator, expr);
    }
    return lowered;
}

fn lowerTypeExpr(allocator: std.mem.Allocator, expr: core_types.TypeExpr) LowerError!lir.LTypeExpr {
    return switch (expr) {
        .TypeVar => |name| .{ .TypeVar = try allocator.dupe(u8, name) },
        .TypeRef => |ref| .{ .TypeRef = .{
            .name = try allocator.dupe(u8, ref.name),
            .args = try lowerTypeExprs(allocator, ref.args),
        } },
        .RecursiveRef => |ref| .{ .RecursiveRef = .{
            .name = try allocator.dupe(u8, ref.name),
            .args = try lowerTypeExprs(allocator, ref.args),
        } },
        .Tuple => |items| .{ .Tuple = try lowerTypeExprs(allocator, items) },
    };
}

fn dupeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) LowerError![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        out[index] = try allocator.dupe(u8, value);
    }
    return out;
}

fn lowerBackend(ptr: *anyopaque, module: ir.Module) anyerror!lir.LModule {
    const self: *ArenaStrategy = @ptrCast(@alignCast(ptr));
    return lowerModule(self.allocator, module);
}

fn findEntrypointIndex(module: ir.Module) ?usize {
    for (module.decls, 0..) |decl, index| {
        switch (decl) {
            .Let => |let_decl| {
                if (std.mem.eql(u8, let_decl.name, "entrypoint")) return index;
            },
        }
    }
    return null;
}

fn lowerEntrypointLet(
    allocator: std.mem.Allocator,
    module: ir.Module,
    entrypoint_index: usize,
    functions: *std.ArrayList(lir.LFunc),
    next_closure_id: *usize,
) LowerError!lir.LFunc {
    const let_decl = switch (module.decls[entrypoint_index]) {
        .Let => |value| value,
    };
    const lambda = switch (let_decl.value.*) {
        .Lambda => |value| value,
        else => return error.UnsupportedEntrypoint,
    };

    var ctx = LowerContext.init(allocator);
    defer ctx.deinit();
    ctx.functions = functions;
    ctx.next_closure_id = next_closure_id;
    for (lambda.params) |param| {
        try ctx.bound.put(param.name, param.ty);
        if (isClosureTy(param.ty)) try ctx.closure_bound.put(param.name, {});
    }
    var top_index: usize = 0;
    while (top_index < entrypoint_index) : (top_index += 1) {
        const top_level = switch (module.decls[top_index]) {
            .Let => |value| value,
        };
        switch (top_level.value.*) {
            .Lambda => {},
            else => try ctx.bound.put(top_level.name, top_level.ty),
        }
    }

    var body = try lowerExprPtrWithContext(allocator, lambda.body.*, &ctx);
    var index = entrypoint_index;
    while (index > 0) {
        index -= 1;
        const top_level = switch (module.decls[index]) {
            .Let => |value| value,
        };
        switch (top_level.value.*) {
            .Lambda => continue,
            else => {},
        }
        const let_body = try allocator.create(lir.LExpr);
        let_body.* = body.*;
        body = try allocator.create(lir.LExpr);
        body.* = .{ .Let = .{
            .name = try allocator.dupe(u8, top_level.name),
            .value = try lowerExprPtr(allocator, top_level.value.*),
            .body = let_body,
            .ty = try lowerTy(allocator, top_level.ty),
            .layout = top_level.layout,
            .is_rec = top_level.is_rec,
        } };
    }

    return .{
        .name = try allocator.dupe(u8, let_decl.name),
        .params = try lowerParams(allocator, lambda.params),
        .body = body.*,
        .return_ty = try lowerTy(allocator, exprTy(lambda.body.*)),
        .calling_convention = .ArenaThreaded,
        .source_span = .unavailable,
    };
}

fn lowerFunction(
    allocator: std.mem.Allocator,
    name: []const u8,
    lambda: ir.Lambda,
    captures: CaptureSet,
    functions: *std.ArrayList(lir.LFunc),
    next_closure_id: *usize,
) LowerError!lir.LFunc {
    var ctx = LowerContext.init(allocator);
    defer ctx.deinit();
    ctx.functions = functions;
    ctx.next_closure_id = next_closure_id;
    try ctx.rec_captures.put(name, captures);
    for (captures) |capture| {
        try ctx.bound.put(capture.name, capture.ty);
        if (isClosureTy(capture.ty)) try ctx.closure_bound.put(capture.name, {});
    }
    for (lambda.params) |param| {
        try ctx.bound.put(param.name, param.ty);
        if (isClosureTy(param.ty)) try ctx.closure_bound.put(param.name, {});
    }

    const params = try concatParams(allocator, captures, lambda.params);
    return .{
        .name = try allocator.dupe(u8, name),
        .params = try lowerParams(allocator, params),
        .body = (try lowerExprPtrWithContext(allocator, lambda.body.*, &ctx)).*,
        .return_ty = try lowerTy(allocator, exprTy(lambda.body.*)),
        .calling_convention = .ArenaThreaded,
        .source_span = .unavailable,
    };
}

fn lowerClosureFunction(
    allocator: std.mem.Allocator,
    name: []const u8,
    lambda: ir.Lambda,
    captures: CaptureSet,
    functions: *std.ArrayList(lir.LFunc),
    next_closure_id: *usize,
) LowerError!lir.LFunc {
    var ctx = LowerContext.init(allocator);
    defer ctx.deinit();
    ctx.functions = functions;
    ctx.next_closure_id = next_closure_id;
    try ctx.rec_captures.put(name, captures);
    try ctx.closure_bound.put(name, {});
    for (captures) |capture| {
        try ctx.bound.put(capture.name, capture.ty);
        if (isClosureTy(capture.ty)) try ctx.closure_bound.put(capture.name, {});
    }
    for (lambda.params) |param| {
        try ctx.bound.put(param.name, param.ty);
        if (isClosureTy(param.ty)) try ctx.closure_bound.put(param.name, {});
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .params = try lowerParams(allocator, lambda.params),
        .captures = try lowerParams(allocator, captures),
        .body = (try lowerExprPtrWithContext(allocator, lambda.body.*, &ctx)).*,
        .return_ty = try lowerTy(allocator, exprTy(lambda.body.*)),
        .calling_convention = .Closure,
        .source_span = .unavailable,
    };
}

fn collectNestedFunctionsInLambda(
    allocator: std.mem.Allocator,
    lambda: ir.Lambda,
    functions: *std.ArrayList(lir.LFunc),
    next_closure_id: *usize,
) LowerError!void {
    var bound = std.StringHashMap(ir.Ty).init(allocator);
    defer bound.deinit();
    for (lambda.params) |param| {
        try bound.put(param.name, param.ty);
    }
    try collectNestedFunctions(allocator, lambda.body.*, functions, next_closure_id, &bound);
}

fn collectNestedFunctions(
    allocator: std.mem.Allocator,
    expr: ir.Expr,
    functions: *std.ArrayList(lir.LFunc),
    next_closure_id: *usize,
    bound: *std.StringHashMap(ir.Ty),
) LowerError!void {
    switch (expr) {
        .Lambda => |lambda| {
            const snapshots = try pushParams(allocator, bound, lambda.params);
            defer restoreBound(bound, snapshots);
            try collectNestedFunctions(allocator, lambda.body.*, functions, next_closure_id, bound);
        },
        .Let => |let_expr| {
            switch (let_expr.value.*) {
                .Lambda => |lambda| {
                    if (let_expr.is_rec) {
                        const captures = try recursiveCaptures(allocator, let_expr.name, lambda, bound);
                        try functions.append(allocator, try lowerFunction(allocator, let_expr.name, lambda, captures, functions, next_closure_id));
                        if (recBindingEscapes(let_expr.name, let_expr.body.*)) {
                            try functions.append(allocator, try lowerClosureFunction(allocator, let_expr.name, lambda, captures, functions, next_closure_id));
                        }
                    }
                    const snapshots = try pushParams(allocator, bound, lambda.params);
                    defer restoreBound(bound, snapshots);
                    try collectNestedFunctions(allocator, lambda.body.*, functions, next_closure_id, bound);
                },
                else => try collectNestedFunctions(allocator, let_expr.value.*, functions, next_closure_id, bound),
            }
            const previous = bound.get(let_expr.name);
            try bound.put(let_expr.name, exprTy(let_expr.value.*));
            defer restoreSingleBound(bound, let_expr.name, previous);
            try collectNestedFunctions(allocator, let_expr.body.*, functions, next_closure_id, bound);
        },
        .If => |if_expr| {
            try collectNestedFunctions(allocator, if_expr.cond.*, functions, next_closure_id, bound);
            try collectNestedFunctions(allocator, if_expr.then_branch.*, functions, next_closure_id, bound);
            try collectNestedFunctions(allocator, if_expr.else_branch.*, functions, next_closure_id, bound);
        },
        .Prim => |prim| for (prim.args) |arg| try collectNestedFunctions(allocator, arg.*, functions, next_closure_id, bound),
        .App => |app| {
            try collectNestedFunctions(allocator, app.callee.*, functions, next_closure_id, bound);
            for (app.args) |arg| try collectNestedFunctions(allocator, arg.*, functions, next_closure_id, bound);
        },
        .Ctor => |ctor| for (ctor.args) |arg| try collectNestedFunctions(allocator, arg.*, functions, next_closure_id, bound),
        .Tuple => |tuple_expr| for (tuple_expr.items) |item| try collectNestedFunctions(allocator, item.*, functions, next_closure_id, bound),
        .TupleProj => |tuple_proj| try collectNestedFunctions(allocator, tuple_proj.tuple_expr.*, functions, next_closure_id, bound),
        .Record => |record_expr| for (record_expr.fields) |field| try collectNestedFunctions(allocator, field.value.*, functions, next_closure_id, bound),
        .RecordField => |record_field| try collectNestedFunctions(allocator, record_field.record_expr.*, functions, next_closure_id, bound),
        .RecordUpdate => |record_update| {
            try collectNestedFunctions(allocator, record_update.base_expr.*, functions, next_closure_id, bound);
            for (record_update.fields) |field| try collectNestedFunctions(allocator, field.value.*, functions, next_closure_id, bound);
        },
        .AccountFieldSet => |field_set| {
            try collectNestedFunctions(allocator, field_set.account_expr.*, functions, next_closure_id, bound);
            try collectNestedFunctions(allocator, field_set.value.*, functions, next_closure_id, bound);
        },
        .Match => |match_expr| {
            try collectNestedFunctions(allocator, match_expr.scrutinee.*, functions, next_closure_id, bound);
            for (match_expr.arms) |arm| {
                const snapshots = try pushPatternBindings(allocator, bound, arm.pattern);
                defer restoreBound(bound, snapshots);
                if (arm.guard) |guard_expr| try collectNestedFunctions(allocator, guard_expr.*, functions, next_closure_id, bound);
                try collectNestedFunctions(allocator, arm.body.*, functions, next_closure_id, bound);
            }
        },
        .Constant, .Var => {},
    }
}

fn lowerExprPtr(allocator: std.mem.Allocator, expr: ir.Expr) LowerError!*lir.LExpr {
    var ctx = LowerContext.init(allocator);
    defer ctx.deinit();
    return lowerExprPtrWithContext(allocator, expr, &ctx);
}

fn lowerExprPtrWithContext(allocator: std.mem.Allocator, expr: ir.Expr, ctx: *LowerContext) LowerError!*lir.LExpr {
    const ptr = try allocator.create(lir.LExpr);
    ptr.* = try lowerExpr(allocator, expr, ctx);
    return ptr;
}

fn lowerExpr(allocator: std.mem.Allocator, expr: ir.Expr, ctx: *LowerContext) LowerError!lir.LExpr {
    return switch (expr) {
        .Lambda => |lambda| (try lowerAnonymousClosureExpr(allocator, lambda, ctx)).*,
        .Constant => |constant| .{ .Constant = switch (constant.value) {
            .Int => |value| .{ .Int = value },
            .String => |value| .{ .String = try allocator.dupe(u8, value) },
        } },
        .App => |app| try lowerApp(allocator, app, ctx),
        .Let => |let_expr| blk: {
            if (let_expr.is_rec) {
                switch (let_expr.value.*) {
                    .Lambda => |lambda| {
                        const captures = try recursiveCaptures(allocator, let_expr.name, lambda, &ctx.bound);
                        const previous_captures = ctx.rec_captures.get(let_expr.name);
                        try ctx.rec_captures.put(let_expr.name, captures);
                        defer restoreRecCaptures(&ctx.rec_captures, let_expr.name, previous_captures);
                        if (recBindingEscapes(let_expr.name, let_expr.body.*)) {
                            const closure_expr = try lowerClosureExpr(allocator, let_expr.name, captures);
                            const previous_bound = ctx.bound.get(let_expr.name);
                            const had_closure = ctx.closure_bound.contains(let_expr.name);
                            try ctx.bound.put(let_expr.name, exprTy(let_expr.value.*));
                            try ctx.closure_bound.put(let_expr.name, {});
                            defer {
                                restoreSingleBound(&ctx.bound, let_expr.name, previous_bound);
                                restoreSingleClosureBound(&ctx.closure_bound, let_expr.name, had_closure);
                            }
                            break :blk .{ .Let = .{
                                .name = try allocator.dupe(u8, let_expr.name),
                                .value = closure_expr,
                                .body = try lowerExprPtrWithContext(allocator, let_expr.body.*, ctx),
                                .ty = try lowerTy(allocator, exprTy(let_expr.value.*)),
                                .layout = exprLayout(let_expr.value.*),
                                .is_rec = true,
                            } };
                        }
                        break :blk (try lowerExprPtrWithContext(allocator, let_expr.body.*, ctx)).*;
                    },
                    else => {},
                }
            }
            const value = try lowerExprPtrWithContext(allocator, let_expr.value.*, ctx);
            const previous = ctx.bound.get(let_expr.name);
            try ctx.bound.put(let_expr.name, exprTy(let_expr.value.*));
            const closure_binding = isClosureTy(exprTy(let_expr.value.*));
            const had_closure = ctx.closure_bound.contains(let_expr.name);
            if (closure_binding) try ctx.closure_bound.put(let_expr.name, {});
            defer restoreSingleBound(&ctx.bound, let_expr.name, previous);
            defer {
                if (closure_binding) restoreSingleClosureBound(&ctx.closure_bound, let_expr.name, had_closure);
            }
            break :blk .{ .Let = .{
                .name = try allocator.dupe(u8, let_expr.name),
                .value = value,
                .body = try lowerExprPtrWithContext(allocator, let_expr.body.*, ctx),
                .ty = try lowerTy(allocator, exprTy(let_expr.value.*)),
                .layout = exprLayout(let_expr.value.*),
                .is_rec = let_expr.is_rec,
            } };
        },
        .If => |if_expr| .{ .If = .{
            .cond = try lowerExprPtrWithContext(allocator, if_expr.cond.*, ctx),
            .then_branch = try lowerExprPtrWithContext(allocator, if_expr.then_branch.*, ctx),
            .else_branch = try lowerExprPtrWithContext(allocator, if_expr.else_branch.*, ctx),
        } },
        .Prim => |prim| .{ .Prim = .{
            .op = lowerPrimOp(prim.op),
            .args = try lowerExprPtrs(allocator, prim.args, ctx),
        } },
        .Var => |var_ref| .{ .Var = .{ .name = try allocator.dupe(u8, var_ref.name) } },
        .Ctor => |ctor_expr| .{ .Ctor = .{
            .name = try allocator.dupe(u8, ctor_expr.name),
            .args = try lowerExprPtrs(allocator, ctor_expr.args, ctx),
            .ty = try lowerTy(allocator, ctor_expr.ty),
            .layout = ctor_expr.layout,
            .tag = ctor_expr.tag,
            .type_name = if (ctor_expr.type_name) |name| try allocator.dupe(u8, name) else null,
        } },
        .Match => |match_expr| .{ .Match = .{
            .scrutinee = try lowerExprPtrWithContext(allocator, match_expr.scrutinee.*, ctx),
            .arms = try lowerArms(allocator, match_expr.arms, ctx),
        } },
        .Tuple => |tuple_expr| .{ .Tuple = .{
            .items = try lowerExprPtrs(allocator, tuple_expr.items, ctx),
            .ty = try lowerTy(allocator, tuple_expr.ty),
        } },
        .TupleProj => |tuple_proj| .{ .TupleProj = .{
            .tuple_expr = try lowerExprPtrWithContext(allocator, tuple_proj.tuple_expr.*, ctx),
            .index = tuple_proj.index,
        } },
        .Record => |record_expr| .{ .Record = .{
            .fields = try lowerRecordExprFields(allocator, record_expr.fields, ctx),
            .ty = try lowerTy(allocator, record_expr.ty),
        } },
        .RecordField => |record_field| .{ .RecordField = .{
            .record_expr = try lowerExprPtrWithContext(allocator, record_field.record_expr.*, ctx),
            .field_name = try allocator.dupe(u8, record_field.field_name),
            .record_ty = try lowerTy(allocator, exprTy(record_field.record_expr.*)),
        } },
        .RecordUpdate => |record_update| .{ .RecordUpdate = .{
            .base_expr = try lowerExprPtrWithContext(allocator, record_update.base_expr.*, ctx),
            .fields = try lowerRecordExprFields(allocator, record_update.fields, ctx),
            .ty = try lowerTy(allocator, record_update.ty),
        } },
        .AccountFieldSet => |field_set| .{ .AccountFieldSet = .{
            .account_expr = try lowerExprPtrWithContext(allocator, field_set.account_expr.*, ctx),
            .field_name = try allocator.dupe(u8, field_set.field_name),
            .value = try lowerExprPtrWithContext(allocator, field_set.value.*, ctx),
        } },
    };
}

fn lowerRecordExprFields(allocator: std.mem.Allocator, fields: []const ir.RecordExprField, ctx: *LowerContext) LowerError![]const lir.LRecordExprField {
    const lowered = try allocator.alloc(lir.LRecordExprField, fields.len);
    for (fields, 0..) |field, index| {
        lowered[index] = .{
            .name = try allocator.dupe(u8, field.name),
            .value = try lowerExprPtrWithContext(allocator, field.value.*, ctx),
        };
    }
    return lowered;
}

fn lowerApp(allocator: std.mem.Allocator, app: ir.App, ctx: *LowerContext) LowerError!lir.LExpr {
    var args = std.ArrayList(*const lir.LExpr).empty;
    errdefer args.deinit(allocator);

    var kind: lir.LCallKind = .Direct;
    switch (app.callee.*) {
        .Var => |callee| {
            if (ctx.closure_bound.contains(callee.name) and ctx.rec_captures.get(callee.name) == null) {
                kind = .Closure;
            } else if (ctx.rec_captures.get(callee.name)) |captures| {
                for (captures) |capture| {
                    const capture_expr = try allocator.create(lir.LExpr);
                    capture_expr.* = .{ .Var = .{ .name = try allocator.dupe(u8, capture.name) } };
                    try args.append(allocator, capture_expr);
                }
            }
        },
        else => {},
    }
    for (app.args) |arg| {
        try args.append(allocator, try lowerExprPtrWithContext(allocator, arg.*, ctx));
    }

    return .{ .App = .{
        .callee = try lowerExprPtrWithContext(allocator, app.callee.*, ctx),
        .args = try args.toOwnedSlice(allocator),
        .ty = try lowerTy(allocator, app.ty),
        .callee_ty = try lowerTy(allocator, exprTy(app.callee.*)),
        .kind = kind,
        .is_tail_call = app.is_tail_call,
    } };
}

fn lowerAnonymousClosureExpr(allocator: std.mem.Allocator, lambda: ir.Lambda, ctx: *LowerContext) LowerError!*lir.LExpr {
    const functions = ctx.functions orelse return error.UnsupportedExpr;
    const next_closure_id = ctx.next_closure_id orelse return error.UnsupportedExpr;
    const name = try std.fmt.allocPrint(allocator, "__lambda_{d}", .{next_closure_id.*});
    next_closure_id.* += 1;
    const captures = try lambdaCaptures(allocator, lambda, &ctx.bound);
    try functions.append(allocator, try lowerClosureFunction(allocator, name, lambda, captures, functions, next_closure_id));
    return lowerClosureExpr(allocator, name, captures);
}

fn lowerClosureExpr(allocator: std.mem.Allocator, name: []const u8, captures: CaptureSet) LowerError!*lir.LExpr {
    const capture_values = try allocator.alloc(lir.LClosureCapture, captures.len);
    for (captures, 0..) |capture, index| {
        capture_values[index] = .{
            .name = try allocator.dupe(u8, capture.name),
            .ty = try lowerTy(allocator, capture.ty),
        };
    }
    const ptr = try allocator.create(lir.LExpr);
    ptr.* = .{ .Closure = .{
        .name = try allocator.dupe(u8, name),
        .captures = capture_values,
    } };
    return ptr;
}

fn recursiveCaptures(
    allocator: std.mem.Allocator,
    self_name: []const u8,
    lambda: ir.Lambda,
    bound: *std.StringHashMap(ir.Ty),
) LowerError!CaptureSet {
    var excluded = std.StringHashMap(void).init(allocator);
    defer excluded.deinit();
    try excluded.put(self_name, {});
    for (lambda.params) |param| {
        try excluded.put(param.name, {});
    }

    var captures = std.ArrayList(ir.Param).empty;
    errdefer captures.deinit(allocator);
    try collectCaptures(allocator, lambda.body.*, bound, &excluded, &captures);
    return captures.toOwnedSlice(allocator);
}

fn lambdaCaptures(
    allocator: std.mem.Allocator,
    lambda: ir.Lambda,
    bound: *std.StringHashMap(ir.Ty),
) LowerError!CaptureSet {
    var excluded = std.StringHashMap(void).init(allocator);
    defer excluded.deinit();
    for (lambda.params) |param| {
        try excluded.put(param.name, {});
    }

    var captures = std.ArrayList(ir.Param).empty;
    errdefer captures.deinit(allocator);
    try collectCaptures(allocator, lambda.body.*, bound, &excluded, &captures);
    return captures.toOwnedSlice(allocator);
}

fn collectCaptures(
    allocator: std.mem.Allocator,
    expr: ir.Expr,
    bound: *std.StringHashMap(ir.Ty),
    excluded: *std.StringHashMap(void),
    captures: *std.ArrayList(ir.Param),
) LowerError!void {
    switch (expr) {
        .Var => |var_ref| {
            if (excluded.contains(var_ref.name)) return;
            const ty = bound.get(var_ref.name) orelse return;
            if (containsCapture(captures.items, var_ref.name)) return;
            try captures.append(allocator, .{
                .name = try allocator.dupe(u8, var_ref.name),
                .ty = ty,
            });
        },
        .Lambda => |lambda| {
            const snapshots = try pushExcludedParams(allocator, excluded, lambda.params);
            defer restoreExcluded(excluded, snapshots);
            try collectCaptures(allocator, lambda.body.*, bound, excluded, captures);
        },
        .Let => |let_expr| {
            try collectCaptures(allocator, let_expr.value.*, bound, excluded, captures);
            const previous = excluded.get(let_expr.name);
            try excluded.put(let_expr.name, {});
            defer restoreSingleExcluded(excluded, let_expr.name, previous != null);
            try collectCaptures(allocator, let_expr.body.*, bound, excluded, captures);
        },
        .App => |app| {
            try collectCaptures(allocator, app.callee.*, bound, excluded, captures);
            for (app.args) |arg| try collectCaptures(allocator, arg.*, bound, excluded, captures);
        },
        .If => |if_expr| {
            try collectCaptures(allocator, if_expr.cond.*, bound, excluded, captures);
            try collectCaptures(allocator, if_expr.then_branch.*, bound, excluded, captures);
            try collectCaptures(allocator, if_expr.else_branch.*, bound, excluded, captures);
        },
        .Prim => |prim| for (prim.args) |arg| try collectCaptures(allocator, arg.*, bound, excluded, captures),
        .Ctor => |ctor| for (ctor.args) |arg| try collectCaptures(allocator, arg.*, bound, excluded, captures),
        .Tuple => |tuple_expr| for (tuple_expr.items) |item| try collectCaptures(allocator, item.*, bound, excluded, captures),
        .TupleProj => |tuple_proj| try collectCaptures(allocator, tuple_proj.tuple_expr.*, bound, excluded, captures),
        .Record => |record_expr| for (record_expr.fields) |field| try collectCaptures(allocator, field.value.*, bound, excluded, captures),
        .RecordField => |record_field| try collectCaptures(allocator, record_field.record_expr.*, bound, excluded, captures),
        .RecordUpdate => |record_update| {
            try collectCaptures(allocator, record_update.base_expr.*, bound, excluded, captures);
            for (record_update.fields) |field| try collectCaptures(allocator, field.value.*, bound, excluded, captures);
        },
        .AccountFieldSet => |field_set| {
            try collectCaptures(allocator, field_set.account_expr.*, bound, excluded, captures);
            try collectCaptures(allocator, field_set.value.*, bound, excluded, captures);
        },
        .Match => |match_expr| {
            try collectCaptures(allocator, match_expr.scrutinee.*, bound, excluded, captures);
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard_expr| try collectCaptures(allocator, guard_expr.*, bound, excluded, captures);
                try collectCaptures(allocator, arm.body.*, bound, excluded, captures);
            }
        },
        .Constant => {},
    }
}

fn containsCapture(captures: []const ir.Param, name: []const u8) bool {
    for (captures) |capture| {
        if (std.mem.eql(u8, capture.name, name)) return true;
    }
    return false;
}

fn concatParams(allocator: std.mem.Allocator, captures: CaptureSet, params: []const ir.Param) LowerError![]const ir.Param {
    const out = try allocator.alloc(ir.Param, captures.len + params.len);
    @memcpy(out[0..captures.len], captures);
    @memcpy(out[captures.len..], params);
    return out;
}

fn pushParams(allocator: std.mem.Allocator, bound: *std.StringHashMap(ir.Ty), params: []const ir.Param) LowerError![]const BindingSnapshot {
    const snapshots = try allocator.alloc(BindingSnapshot, params.len);
    for (params, 0..) |param, index| {
        snapshots[index] = .{ .name = param.name, .previous = bound.get(param.name) };
        try bound.put(param.name, param.ty);
    }
    return snapshots;
}

fn pushPatternBindings(
    allocator: std.mem.Allocator,
    bound: *std.StringHashMap(ir.Ty),
    pattern: ir.Pattern,
) LowerError![]const BindingSnapshot {
    var snapshots = std.ArrayList(BindingSnapshot).empty;
    errdefer snapshots.deinit(allocator);
    try pushPatternBindingsInto(allocator, bound, pattern, &snapshots);
    return snapshots.toOwnedSlice(allocator);
}

fn pushPatternBindingsInto(
    allocator: std.mem.Allocator,
    bound: *std.StringHashMap(ir.Ty),
    pattern: ir.Pattern,
    snapshots: *std.ArrayList(BindingSnapshot),
) LowerError!void {
    switch (pattern) {
        .Var => |var_pattern| {
            try snapshots.append(allocator, .{ .name = var_pattern.name, .previous = bound.get(var_pattern.name) });
            try bound.put(var_pattern.name, var_pattern.ty);
        },
        .Alias => |alias| {
            try pushPatternBindingsInto(allocator, bound, alias.pattern.*, snapshots);
            try snapshots.append(allocator, .{ .name = alias.name, .previous = bound.get(alias.name) });
            try bound.put(alias.name, alias.ty);
        },
        .Ctor => |ctor_pattern| for (ctor_pattern.args) |arg| try pushPatternBindingsInto(allocator, bound, arg, snapshots),
        .Tuple => |items| for (items) |item| try pushPatternBindingsInto(allocator, bound, item, snapshots),
        .Record => |fields| for (fields) |field| try pushPatternBindingsInto(allocator, bound, field.pattern, snapshots),
        .Wildcard, .Constant => {},
    }
}

fn restoreBound(bound: *std.StringHashMap(ir.Ty), snapshots: []const BindingSnapshot) void {
    var index = snapshots.len;
    while (index > 0) {
        index -= 1;
        restoreSingleBound(bound, snapshots[index].name, snapshots[index].previous);
    }
}

fn restoreSingleBound(bound: *std.StringHashMap(ir.Ty), name: []const u8, previous: ?ir.Ty) void {
    if (previous) |ty| {
        bound.getPtr(name).?.* = ty;
    } else {
        _ = bound.remove(name);
    }
}

fn restoreSingleClosureBound(bound: *std.StringHashMap(void), name: []const u8, existed: bool) void {
    if (!existed) _ = bound.remove(name);
}

fn restoreRecCaptures(map: *std.StringHashMap(CaptureSet), name: []const u8, previous: ?CaptureSet) void {
    if (previous) |captures| {
        map.getPtr(name).?.* = captures;
    } else {
        _ = map.remove(name);
    }
}

const ExcludedSnapshot = struct {
    name: []const u8,
    existed: bool,
};

fn pushExcludedParams(allocator: std.mem.Allocator, excluded: *std.StringHashMap(void), params: []const ir.Param) LowerError![]const ExcludedSnapshot {
    const snapshots = try allocator.alloc(ExcludedSnapshot, params.len);
    for (params, 0..) |param, index| {
        snapshots[index] = .{ .name = param.name, .existed = excluded.contains(param.name) };
        try excluded.put(param.name, {});
    }
    return snapshots;
}

fn restoreExcluded(excluded: *std.StringHashMap(void), snapshots: []const ExcludedSnapshot) void {
    var index = snapshots.len;
    while (index > 0) {
        index -= 1;
        restoreSingleExcluded(excluded, snapshots[index].name, snapshots[index].existed);
    }
}

fn restoreSingleExcluded(excluded: *std.StringHashMap(void), name: []const u8, existed: bool) void {
    if (!existed) _ = excluded.remove(name);
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

fn exprLayout(expr: ir.Expr) @import("../core/layout.zig").Layout {
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

fn isClosureTy(ty: ir.Ty) bool {
    return switch (ty) {
        .Arrow => true,
        else => false,
    };
}

fn lowerParams(allocator: std.mem.Allocator, params: []const ir.Param) LowerError![]const lir.LParam {
    const lowered = try allocator.alloc(lir.LParam, params.len);
    for (params, 0..) |param, index| {
        lowered[index] = .{
            .name = try allocator.dupe(u8, param.name),
            .ty = try lowerTy(allocator, param.ty),
        };
    }
    return lowered;
}

fn lowerPrimOp(op: ir.PrimOp) lir.LPrimOp {
    return switch (op) {
        .Add => .Add,
        .Sub => .Sub,
        .Mul => .Mul,
        .Div => .Div,
        .Mod => .Mod,
        .Eq => .Eq,
        .Ne => .Ne,
        .Lt => .Lt,
        .Le => .Le,
        .Gt => .Gt,
        .Ge => .Ge,
        .StringLength => .StringLength,
        .StringGet => .StringGet,
        .StringSub => .StringSub,
        .StringConcat => .StringConcat,
        .CharCode => .CharCode,
        .CharChr => .CharChr,
    };
}

fn lowerArms(allocator: std.mem.Allocator, arms: []const ir.Arm, ctx: *LowerContext) LowerError![]const lir.LArm {
    const lowered = try allocator.alloc(lir.LArm, arms.len);
    for (arms, 0..) |arm, index| {
        const snapshots = try pushPatternBindings(allocator, &ctx.bound, arm.pattern);
        defer restoreBound(&ctx.bound, snapshots);
        lowered[index] = .{
            .pattern = try lowerPattern(allocator, arm.pattern),
            .guard = if (arm.guard) |guard| try lowerExprPtrWithContext(allocator, guard.*, ctx) else null,
            .body = try lowerExprPtrWithContext(allocator, arm.body.*, ctx),
        };
    }
    return lowered;
}

fn lowerPattern(allocator: std.mem.Allocator, pattern: ir.Pattern) LowerError!lir.LPattern {
    return switch (pattern) {
        .Wildcard => .Wildcard,
        .Var => |var_pattern| .{ .Var = try allocator.dupe(u8, var_pattern.name) },
        .Constant => |constant| .{ .Constant = try lowerPatternConstant(allocator, constant) },
        .Alias => |alias| blk: {
            const child = try allocator.create(lir.LPattern);
            child.* = try lowerPattern(allocator, alias.pattern.*);
            break :blk .{ .Alias = .{
                .pattern = child,
                .name = try allocator.dupe(u8, alias.name),
            } };
        },
        .Ctor => |ctor_pattern| .{ .Ctor = .{
            .name = try allocator.dupe(u8, ctor_pattern.name),
            .args = try lowerPatterns(allocator, ctor_pattern.args),
            .tag = ctor_pattern.tag,
            .type_name = if (ctor_pattern.type_name) |name| try allocator.dupe(u8, name) else null,
        } },
        .Tuple => |items| .{ .Tuple = try lowerPatterns(allocator, items) },
        .Record => |fields| .{ .Record = try lowerRecordPatternFields(allocator, fields) },
    };
}

fn lowerPatternConstant(allocator: std.mem.Allocator, constant: ir.PatternConstant) LowerError!lir.LPatternConstant {
    return switch (constant) {
        .Int => |value| .{ .Int = value },
        .Char => |value| .{ .Char = value },
        .String => |value| .{ .String = try allocator.dupe(u8, value) },
    };
}

fn lowerRecordPatternFields(allocator: std.mem.Allocator, fields: []const ir.RecordPatternField) LowerError![]const lir.LRecordPatternField {
    const lowered = try allocator.alloc(lir.LRecordPatternField, fields.len);
    for (fields, 0..) |field, index| {
        lowered[index] = .{
            .name = try allocator.dupe(u8, field.name),
            .pattern = try lowerPattern(allocator, field.pattern),
        };
    }
    return lowered;
}

fn lowerPatterns(allocator: std.mem.Allocator, patterns: []const ir.Pattern) LowerError![]const lir.LPattern {
    const lowered = try allocator.alloc(lir.LPattern, patterns.len);
    for (patterns, 0..) |pattern, index| {
        lowered[index] = try lowerPattern(allocator, pattern);
    }
    return lowered;
}

fn lowerExprPtrs(allocator: std.mem.Allocator, exprs: []const *const ir.Expr, ctx: *LowerContext) LowerError![]const *const lir.LExpr {
    const lowered = try allocator.alloc(*const lir.LExpr, exprs.len);
    for (exprs, 0..) |expr, index| {
        lowered[index] = try lowerExprPtrWithContext(allocator, expr.*, ctx);
    }
    return lowered;
}

fn lowerTy(allocator: std.mem.Allocator, ty: ir.Ty) LowerError!lir.LTy {
    return switch (ty) {
        .Int => .Int,
        .Bool => .Bool,
        .Unit => .Unit,
        .String => .String,
        .Var => |name| .{ .Var = try allocator.dupe(u8, name) },
        .Arrow => |arrow| blk: {
            const ret = try allocator.create(lir.LTy);
            ret.* = try lowerTy(allocator, arrow.ret.*);
            break :blk .{ .Closure = .{
                .params = try lowerTySlice(allocator, arrow.params),
                .ret = ret,
            } };
        },
        .Adt => |adt| .{ .Adt = .{
            .name = try allocator.dupe(u8, adt.name),
            .params = try lowerTySlice(allocator, adt.params),
        } },
        .Tuple => |items| .{ .Tuple = try lowerTySlice(allocator, items) },
        .Record => |record| .{ .Record = .{
            .name = try allocator.dupe(u8, record.name),
            .params = try lowerTySlice(allocator, record.params),
        } },
    };
}

fn recBindingEscapes(name: []const u8, expr: ir.Expr) bool {
    return switch (expr) {
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        .App => |app| blk: {
            const direct_self_call = switch (app.callee.*) {
                .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
                else => false,
            };
            if (!direct_self_call and recBindingEscapes(name, app.callee.*)) break :blk true;
            for (app.args) |arg| {
                if (recBindingEscapes(name, arg.*)) break :blk true;
            }
            break :blk false;
        },
        .Let => |let_expr| recBindingEscapes(name, let_expr.value.*) or
            (!std.mem.eql(u8, let_expr.name, name) and recBindingEscapes(name, let_expr.body.*)),
        .Lambda => |lambda| !paramBindsName(lambda.params, name) and recBindingEscapes(name, lambda.body.*),
        .If => |if_expr| recBindingEscapes(name, if_expr.cond.*) or
            recBindingEscapes(name, if_expr.then_branch.*) or
            recBindingEscapes(name, if_expr.else_branch.*),
        .Prim => |prim| blk: {
            for (prim.args) |arg| {
                if (recBindingEscapes(name, arg.*)) break :blk true;
            }
            break :blk false;
        },
        .Ctor => |ctor| blk: {
            for (ctor.args) |arg| {
                if (recBindingEscapes(name, arg.*)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple_expr| blk: {
            for (tuple_expr.items) |item| {
                if (recBindingEscapes(name, item.*)) break :blk true;
            }
            break :blk false;
        },
        .TupleProj => |tuple_proj| recBindingEscapes(name, tuple_proj.tuple_expr.*),
        .Record => |record_expr| blk: {
            for (record_expr.fields) |field| {
                if (recBindingEscapes(name, field.value.*)) break :blk true;
            }
            break :blk false;
        },
        .RecordField => |record_field| recBindingEscapes(name, record_field.record_expr.*),
        .RecordUpdate => |record_update| blk: {
            if (recBindingEscapes(name, record_update.base_expr.*)) break :blk true;
            for (record_update.fields) |field| {
                if (recBindingEscapes(name, field.value.*)) break :blk true;
            }
            break :blk false;
        },
        .AccountFieldSet => |field_set| recBindingEscapes(name, field_set.account_expr.*) or recBindingEscapes(name, field_set.value.*),
        .Match => |match_expr| blk: {
            if (recBindingEscapes(name, match_expr.scrutinee.*)) break :blk true;
            for (match_expr.arms) |arm| {
                if (!patternBindsName(arm.pattern, name)) {
                    if (arm.guard) |guard_expr| {
                        if (recBindingEscapes(name, guard_expr.*)) break :blk true;
                    }
                }
                if (!patternBindsName(arm.pattern, name) and recBindingEscapes(name, arm.body.*)) break :blk true;
            }
            break :blk false;
        },
        .Constant => false,
    };
}

fn paramBindsName(params: []const ir.Param, name: []const u8) bool {
    for (params) |param| {
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn patternBindsName(pattern: ir.Pattern, name: []const u8) bool {
    return switch (pattern) {
        .Var => |var_pattern| std.mem.eql(u8, var_pattern.name, name),
        .Alias => |alias| std.mem.eql(u8, alias.name, name) or patternBindsName(alias.pattern.*, name),
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
        .Wildcard, .Constant => false,
    };
}

fn lowerTySlice(allocator: std.mem.Allocator, tys: []const ir.Ty) LowerError![]const lir.LTy {
    const lowered = try allocator.alloc(lir.LTy, tys.len);
    for (tys, 0..) |ty, index| {
        lowered[index] = try lowerTy(allocator, ty);
    }
    return lowered;
}

fn makeExpr(comptime expr: ir.Expr) *const ir.Expr {
    const S = struct {
        const value = expr;
    };
    return &S.value;
}

test "ArenaStrategy lowers M0 entrypoint constant and records arena threading" {
    const decls = [_]ir.Decl{.{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Constant = .{
                .value = .{ .Int = 0 },
                .ty = .Int,
                .layout = @import("../core/layout.zig").intConstant(),
            } }),
            .ty = .Unit,
            .layout = @import("../core/layout.zig").topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = @import("../core/layout.zig").topLevelLambda(),
    } }};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var impl: ArenaStrategy = .{ .allocator = arena.allocator() };
    const lowered = try impl.loweringStrategy().lowerModule(.{ .decls = &decls });

    try std.testing.expectEqualStrings("entrypoint", lowered.entrypoint.name);
    try std.testing.expectEqual(lir.CallingConvention.ArenaThreaded, lowered.entrypoint.calling_convention);
    const constant = switch (lowered.entrypoint.body) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (constant) {
        .Int => |value| try std.testing.expectEqual(@as(i64, 0), value),
        .String => return error.TestUnexpectedResult,
    }
}

test "ArenaStrategy wraps previous top-level lets around entrypoint body" {
    const layout = @import("../core/layout.zig");
    const decls = [_]ir.Decl{
        .{ .Let = .{
            .name = "x",
            .value = makeExpr(.{ .Constant = .{
                .value = .{ .Int = 1 },
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Int,
            .layout = layout.intConstant(),
        } },
        .{ .Let = .{
            .name = "entrypoint",
            .value = makeExpr(.{ .Lambda = .{
                .params = &.{},
                .body = makeExpr(.{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } }),
                .ty = .Unit,
                .layout = layout.topLevelLambda(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lowered = try lowerModule(arena.allocator(), .{ .decls = &decls });
    const top_let = switch (lowered.entrypoint.body) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("x", top_let.name);
    _ = switch (top_let.body.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
}

test "ArenaStrategy preserves Stack-region let storage metadata" {
    const layout = @import("../core/layout.zig");
    const decls = [_]ir.Decl{.{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Let = .{
                .name = "x",
                .value = makeExpr(.{ .Constant = .{
                    .value = .{ .Int = 1 },
                    .ty = .Int,
                    .layout = .{ .region = .Stack, .repr = .Flat },
                } }),
                .body = makeExpr(.{ .Var = .{ .name = "x", .ty = .Int, .layout = .{ .region = .Stack, .repr = .Flat } } }),
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } }};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lowered = try lowerModule(arena.allocator(), .{ .decls = &decls });
    const stack_let = switch (lowered.entrypoint.body) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@import("../core/layout.zig").Region.Stack, stack_let.layout.region);
    try std.testing.expectEqual(lir.LTy.Int, stack_let.ty);
}

test "ArenaStrategy threads captures into nested recursive functions" {
    const layout = @import("../core/layout.zig");
    const loop_lambda = comptime ir.Expr{ .Lambda = .{
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
            .then_branch = makeExpr(.{ .Var = .{ .name = "base", .ty = .Int, .layout = layout.intConstant() } }),
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
    } };
    const decls = [_]ir.Decl{.{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Let = .{
                .name = "base",
                .value = makeExpr(.{ .Constant = .{ .value = .{ .Int = 2 }, .ty = .Int, .layout = layout.intConstant() } }),
                .body = makeExpr(.{ .Let = .{
                    .name = "loop",
                    .value = &loop_lambda,
                    .body = makeExpr(.{ .App = .{
                        .callee = makeExpr(.{ .Var = .{ .name = "loop", .ty = .Unit, .layout = layout.topLevelLambda() } }),
                        .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 3 }, .ty = .Int, .layout = layout.intConstant() } })},
                        .ty = .Int,
                        .layout = layout.intConstant(),
                    } }),
                    .ty = .Int,
                    .layout = layout.intConstant(),
                    .is_rec = true,
                } }),
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } }};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lowered = try lowerModule(arena.allocator(), .{ .decls = &decls });
    try std.testing.expectEqual(@as(usize, 1), lowered.functions.len);
    try std.testing.expectEqualStrings("loop", lowered.functions[0].name);
    try std.testing.expectEqual(@as(usize, 2), lowered.functions[0].params.len);
    try std.testing.expectEqualStrings("base", lowered.functions[0].params[0].name);
    try std.testing.expectEqualStrings("n", lowered.functions[0].params[1].name);

    const base_let = switch (lowered.entrypoint.body) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const call = switch (base_let.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
    try std.testing.expectEqualStrings("base", switch (call.args[0].*) {
        .Var => |value| value.name,
        else => return error.TestUnexpectedResult,
    });
}
