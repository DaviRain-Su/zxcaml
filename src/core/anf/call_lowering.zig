//! RESPONSIBILITIES:
//! - Lower ttree applications, primitives, variables, constants, and ctors.
//! - Recognize builtin/stdlib call signatures and inline HOF expansions.
//! - Desugar logical operators and list-literal higher-order calls.

const std = @import("std");
const ttree = @import("../../frontend_bridge/ttree.zig");
const ir = @import("../ir.zig");
const layout = @import("../layout.zig");
const context = @import("context.zig");
const rename = @import("rename.zig");
const match_lower = @import("match.zig");
const type_ops = @import("type_ops.zig");
const expr_lowering = @import("expr_lowering.zig");

const LowerError = context.LowerError;
const TypeBindings = context.TypeBindings;
const LowerContext = context.LowerContext;

const freshSyntheticName = rename.freshSyntheticName;
const renameExprVars = rename.renameExprVars;

const ctorTy = match_lower.ctorTy;
const builtinCtorTag = match_lower.builtinCtorTag;
const validateCtor = match_lower.validateCtor;
const bindTypeParamsFromMatchedAdt = match_lower.bindTypeParamsFromMatchedAdt;
const isAtomicTtree = match_lower.isAtomicTtree;
const freshTemp = match_lower.freshTemp;

const typeExprsToTysWithBindings = type_ops.typeExprsToTysWithBindings;
const findRecordDecl = type_ops.findRecordDecl;
const recordTy = type_ops.recordTy;
const recordFieldTy = type_ops.recordFieldTy;
const recordFieldAccessTy = type_ops.recordFieldAccessTy;
const listTy = type_ops.listTy;
const arrayTy = type_ops.arrayTy;
const optionTy = type_ops.optionTy;
const resultTy = type_ops.resultTy;
const tySlice = type_ops.tySlice;
const arrowTy = type_ops.arrowTy;
const layoutForTy = type_ops.layoutForTy;
const makeArrowTyFromPieces = type_ops.makeArrowTyFromPieces;
const exprTy = type_ops.exprTy;
const exprLayout = type_ops.exprLayout;
const tyEql = type_ops.tyEql;
const adoptNullaryCtorBranchTy = type_ops.adoptNullaryCtorBranchTy;

const lowerExprPtr = expr_lowering.lowerExprPtr;
const lowerExprPtrExpected = expr_lowering.lowerExprPtrExpected;

pub fn lowerApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (isVarNamed(app.callee.*, "List.map")) {
        return lowerListMapLiteralApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "List.filter")) {
        return lowerListFilterLiteralApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "List.fold_left")) {
        return lowerListFoldLeftLiteralApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "Array.of_list")) {
        return lowerArrayOfListApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "Option.map") and app.args.len == 2) {
        return lowerOptionMapApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "Option.bind") and app.args.len == 2) {
        return lowerOptionBindApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "Option.fold") and app.args.len == 3) {
        return lowerOptionFoldApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "Result.map") and app.args.len == 2) {
        return lowerResultMapApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "Result.bind") and app.args.len == 2) {
        return lowerResultBindApp(arena, ctx, app);
    }
    if ((isVarNamed(app.callee.*, "Result.map_error") or isVarNamed(app.callee.*, "Result.map_err")) and app.args.len == 2) {
        return lowerResultMapErrorApp(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "&&") and app.args.len == 2) {
        return lowerLogicalAnd(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "||") and app.args.len == 2) {
        return lowerLogicalOr(arena, ctx, app);
    }
    if (isVarNamed(app.callee.*, "not") and app.args.len == 1) {
        return lowerLogicalNot(arena, ctx, app);
    }
    if (app.args.len == 1) {
        if (accountMetaCtorFlags(app.callee.*)) |flags| {
            return lowerAccountMetaCtorApp(arena, ctx, app, flags);
        }
        if (isVarNamed(app.callee.*, "AccountMeta.of_account")) {
            return lowerAccountMetaOfAccountApp(arena, ctx, app);
        }
    }
    if (builtinCallOp(app.callee.*, app.args.len)) |op| {
        return lowerBuiltinCallApp(arena, ctx, app, op);
    }
    if (stdlibCallSignature(arena, app.callee.*, app.args.len)) |signature| {
        return lowerStdlibCallApp(arena, ctx, app, signature);
    }
    const callee = try lowerExprPtr(arena, ctx, app.callee.*);
    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (app.args) |arg| {
        try args.append(arena.allocator(), try lowerExprPtr(arena, ctx, arg));
    }
    const owned_args = try args.toOwnedSlice(arena.allocator());
    const ty = try appReturnTy(arena, exprTy(callee.*), owned_args.len);
    return .{ .App = .{
        .callee = callee,
        .args = owned_args,
        .ty = ty,
        .layout = layoutForTy(ty),
    } };
}

pub fn lowerLogicalAnd(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    const cond = try lowerExprPtrExpected(arena, ctx, app.args[0], .Bool);
    const then_branch = try lowerExprPtrExpected(arena, ctx, app.args[1], .Bool);
    const else_branch = try boolCoreExpr(arena, false);
    return .{ .If = .{
        .cond = cond,
        .then_branch = then_branch,
        .else_branch = else_branch,
        .ty = .Bool,
        .layout = layoutForTy(.Bool),
    } };
}

pub fn lowerLogicalNot(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    // Desugar `not e` into `if e then false else true` so the existing Core IR
    // boolean surface (`If` + constructor literals) handles it without
    // introducing a dedicated `Not` primop.
    const cond = try lowerExprPtrExpected(arena, ctx, app.args[0], .Bool);
    const then_branch = try boolCoreExpr(arena, false);
    const else_branch = try boolCoreExpr(arena, true);
    return .{ .If = .{
        .cond = cond,
        .then_branch = then_branch,
        .else_branch = else_branch,
        .ty = .Bool,
        .layout = layoutForTy(.Bool),
    } };
}

pub fn lowerLogicalOr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    const cond = try lowerExprPtrExpected(arena, ctx, app.args[0], .Bool);
    const then_branch = try boolCoreExpr(arena, true);
    const else_branch = try lowerExprPtrExpected(arena, ctx, app.args[1], .Bool);
    return .{ .If = .{
        .cond = cond,
        .then_branch = then_branch,
        .else_branch = else_branch,
        .ty = .Bool,
        .layout = layoutForTy(.Bool),
    } };
}

pub fn boolCoreExpr(arena: *std.heap.ArenaAllocator, value: bool) LowerError!*const ir.Expr {
    const ptr = try arena.allocator().create(ir.Expr);
    ptr.* = .{ .Ctor = .{
        .name = if (value) "true" else "false",
        .args = &.{},
        .ty = .Bool,
        .layout = layout.ctor(0),
        .tag = if (value) 1 else 0,
        .type_name = null,
    } };
    return ptr;
}

/// Privilege flags carried by the four `AccountMeta.*` constructor helpers.
const AccountMetaFlags = struct {
    is_writable: bool,
    is_signer: bool,
};

fn accountMetaCtorFlags(callee: ttree.Expr) ?AccountMetaFlags {
    const var_ref = switch (callee) {
        .Var => |value| value,
        else => return null,
    };
    if (std.mem.eql(u8, var_ref.name, "AccountMeta.writable"))
        return .{ .is_writable = true, .is_signer = false };
    if (std.mem.eql(u8, var_ref.name, "AccountMeta.signer"))
        return .{ .is_writable = false, .is_signer = true };
    if (std.mem.eql(u8, var_ref.name, "AccountMeta.writable_signer"))
        return .{ .is_writable = true, .is_signer = true };
    if (std.mem.eql(u8, var_ref.name, "AccountMeta.readonly"))
        return .{ .is_writable = false, .is_signer = false };
    return null;
}

/// Desugar `AccountMeta.writable/signer/writable_signer/readonly p` into the
/// equivalent `account_meta` record literal. Downstream consumers (the
/// interpreter, Zig codegen, region inference, no_alloc, determinism) see the
/// exact IR a handwritten `{ pubkey = p; is_writable = ...; is_signer = ... }`
/// produces, so no new runtime symbol is involved.
fn lowerAccountMetaCtorApp(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    app: ttree.App,
    flags: AccountMetaFlags,
) LowerError!ir.Expr {
    const meta_decl = findRecordDecl(ctx.record_type_decls, "account_meta") orelse return error.UnsupportedNode;
    const pubkey_ty = try recordFieldTy(arena, meta_decl, "pubkey");
    const fields = try arena.allocator().alloc(ir.RecordExprField, 3);
    fields[0] = .{
        .name = try arena.allocator().dupe(u8, "pubkey"),
        .value = try lowerExprPtrExpected(arena, ctx, app.args[0], pubkey_ty),
    };
    fields[1] = .{
        .name = try arena.allocator().dupe(u8, "is_writable"),
        .value = try boolCoreExpr(arena, flags.is_writable),
    };
    fields[2] = .{
        .name = try arena.allocator().dupe(u8, "is_signer"),
        .value = try boolCoreExpr(arena, flags.is_signer),
    };
    return .{ .Record = .{
        .fields = fields,
        .ty = try recordTy(arena, meta_decl),
        .layout = layout.structPack(),
    } };
}

/// Desugar `AccountMeta.of_account a` into
/// `{ pubkey = a.key; is_writable = a.is_writable; is_signer = a.is_signer }`,
/// forwarding the account's own privileges into a CPI meta. Variable arguments
/// are projected directly (identical IR to the handwritten record literal);
/// any other argument is bound once to a fresh temp so it is evaluated exactly
/// once, mirroring the `inlineOptionUnaryHof` let-binding precedent.
fn lowerAccountMetaOfAccountApp(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    app: ttree.App,
) LowerError!ir.Expr {
    const meta_decl = findRecordDecl(ctx.record_type_decls, "account_meta") orelse return error.UnsupportedNode;
    const meta_ty = try recordTy(arena, meta_decl);

    const account_value = try lowerExprPtr(arena, ctx, app.args[0]);
    const account_ty = exprTy(account_value.*);
    const account_is_var = account_value.* == .Var;
    const subject_var: ir.Var = if (account_is_var) account_value.Var else .{
        .name = try freshSyntheticName(arena, ctx, "__zxc_meta_account"),
        .ty = account_ty,
        .layout = exprLayout(account_value.*),
    };

    const projections = [_]struct { meta_field: []const u8, account_field: []const u8 }{
        .{ .meta_field = "pubkey", .account_field = "key" },
        .{ .meta_field = "is_writable", .account_field = "is_writable" },
        .{ .meta_field = "is_signer", .account_field = "is_signer" },
    };
    const fields = try arena.allocator().alloc(ir.RecordExprField, projections.len);
    for (projections, 0..) |projection, index| {
        const field_ty = try recordFieldAccessTy(arena, ctx, account_ty, projection.account_field);
        // Fresh Var node per projection keeps the lowered IR tree-shaped, the
        // same shape `lowerRecordField` builds for a handwritten `a.key`.
        const record_ref = try arena.allocator().create(ir.Expr);
        record_ref.* = .{ .Var = subject_var };
        const value = try arena.allocator().create(ir.Expr);
        value.* = .{ .RecordField = .{
            .record_expr = record_ref,
            .field_name = try arena.allocator().dupe(u8, projection.account_field),
            .ty = field_ty,
            .layout = layoutForTy(field_ty),
        } };
        fields[index] = .{
            .name = try arena.allocator().dupe(u8, projection.meta_field),
            .value = value,
        };
    }

    const record_expr: ir.Expr = .{ .Record = .{
        .fields = fields,
        .ty = meta_ty,
        .layout = layout.structPack(),
    } };
    if (account_is_var) return record_expr;

    const record_ptr = try arena.allocator().create(ir.Expr);
    record_ptr.* = record_expr;
    return .{ .Let = .{
        .name = subject_var.name,
        .value = account_value,
        .body = record_ptr,
        .ty = meta_ty,
        .layout = layoutForTy(meta_ty),
    } };
}

pub fn lowerBuiltinCallApp(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    app: ttree.App,
    op: ir.PrimOp,
) LowerError!ir.Expr {
    const arg_tys = try builtinCallArgTys(arena, op);
    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (app.args, 0..) |arg, index| {
        try args.append(arena.allocator(), try lowerExprPtrExpected(arena, ctx, arg, arg_tys[index]));
    }
    const return_ty = builtinCallReturnTy(op);
    return .{ .Prim = .{
        .op = op,
        .args = try args.toOwnedSlice(arena.allocator()),
        .ty = return_ty,
        .layout = layoutForTy(return_ty),
    } };
}

pub fn builtinCallOp(callee: ttree.Expr, arg_count: usize) ?ir.PrimOp {
    const var_ref = switch (callee) {
        .Var => |value| value,
        else => return null,
    };
    if (std.mem.eql(u8, var_ref.name, "String.length") and arg_count == 1) return .StringLength;
    if (std.mem.eql(u8, var_ref.name, "String.get") and arg_count == 2) return .StringGet;
    if (std.mem.eql(u8, var_ref.name, "String.sub") and arg_count == 3) return .StringSub;
    if (std.mem.eql(u8, var_ref.name, "Bytes.length") and arg_count == 1) return .StringLength;
    if (std.mem.eql(u8, var_ref.name, "Bytes.get") and arg_count == 2) return .StringGet;
    if (std.mem.eql(u8, var_ref.name, "Bytes.sub") and arg_count == 3) return .StringSub;
    if (std.mem.eql(u8, var_ref.name, "Bytes.create") and arg_count == 1) return .BytesCreate;
    if (std.mem.eql(u8, var_ref.name, "Bytes.set") and arg_count == 3) return .BytesSet;
    if (std.mem.eql(u8, var_ref.name, "Bytes.blit") and arg_count == 5) return .BytesBlit;
    if (std.mem.eql(u8, var_ref.name, "Bytes.fill") and arg_count == 4) return .BytesFill;
    if (std.mem.eql(u8, var_ref.name, "^") and arg_count == 2) return .StringConcat;
    if (std.mem.eql(u8, var_ref.name, "Char.code") and arg_count == 1) return .CharCode;
    if (std.mem.eql(u8, var_ref.name, "Char.chr") and arg_count == 1) return .CharChr;
    return null;
}

pub fn builtinCallArgTys(arena: *std.heap.ArenaAllocator, op: ir.PrimOp) LowerError![]const ir.Ty {
    return switch (op) {
        .StringLength => try tySlice(arena, &.{.String}),
        .StringGet => try tySlice(arena, &.{ .String, .Int }),
        .StringSub => try tySlice(arena, &.{ .String, .Int, .Int }),
        .StringConcat => try tySlice(arena, &.{ .String, .String }),
        .CharCode, .CharChr => try tySlice(arena, &.{.Int}),
        .BytesCreate => try tySlice(arena, &.{.Int}),
        .BytesSet => try tySlice(arena, &.{ .String, .Int, .Int }),
        .BytesBlit => try tySlice(arena, &.{ .String, .Int, .String, .Int, .Int }),
        .BytesFill => try tySlice(arena, &.{ .String, .Int, .Int, .Int }),
        else => return error.UnsupportedPrim,
    };
}

pub fn builtinCallReturnTy(op: ir.PrimOp) ir.Ty {
    return switch (op) {
        .StringLength, .StringGet, .CharCode, .CharChr => .Int,
        .StringSub, .StringConcat, .BytesCreate => .String,
        .BytesSet, .BytesBlit, .BytesFill => .Unit,
        else => unreachable,
    };
}

const StdlibCallSignature = struct {
    name: []const u8,
    arg_tys: []const ir.Ty,
    return_ty: ir.Ty,
};

pub fn lowerStdlibCallApp(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    app: ttree.App,
    signature: StdlibCallSignature,
) LowerError!ir.Expr {
    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (app.args, 0..) |arg, index| {
        try args.append(arena.allocator(), try lowerExprPtrExpected(arena, ctx, arg, signature.arg_tys[index]));
    }
    const owned_args = try args.toOwnedSlice(arena.allocator());
    const callee_ty = try arrowTy(arena, signature.arg_tys, signature.return_ty);
    const callee = try arena.allocator().create(ir.Expr);
    callee.* = .{ .Var = .{
        .name = try arena.allocator().dupe(u8, signature.name),
        .ty = callee_ty,
        .layout = layout.closure(),
    } };
    return .{ .App = .{
        .callee = callee,
        .args = owned_args,
        .ty = signature.return_ty,
        .layout = layoutForTy(signature.return_ty),
    } };
}

pub fn lowerArrayOfListApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 1) return error.UnsupportedNode;
    var literal_items = std.ArrayList(ttree.Expr).empty;
    defer literal_items.deinit(arena.allocator());
    const list_arg = lowerListLiteralExpr(arena, ctx, app.args[0], &literal_items) catch try lowerExprPtr(arena, ctx, app.args[0]);
    const list_adt = switch (exprTy(list_arg.*)) {
        .Adt => |adt| adt,
        else => return error.UnsupportedNode,
    };
    if (!std.mem.eql(u8, list_adt.name, "list") or list_adt.params.len != 1) return error.UnsupportedNode;

    const return_ty = try arrayTy(arena, list_adt.params[0]);
    const arg_tys = try tySlice(arena, &.{exprTy(list_arg.*)});
    const callee_ty = try arrowTy(arena, arg_tys, return_ty);
    const callee = try arena.allocator().create(ir.Expr);
    callee.* = .{ .Var = .{
        .name = try arena.allocator().dupe(u8, "Array.of_list"),
        .ty = callee_ty,
        .layout = layout.closure(),
    } };
    const args = try arena.allocator().alloc(*const ir.Expr, 1);
    args[0] = list_arg;
    return .{ .App = .{
        .callee = callee,
        .args = args,
        .ty = return_ty,
        .layout = layoutForTy(return_ty),
    } };
}

pub fn lowerListLiteralExpr(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    expr: ttree.Expr,
    items: *std.ArrayList(ttree.Expr),
) LowerError!*const ir.Expr {
    try collectListLiteralItems(arena.allocator(), expr, items);
    if (items.items.len == 0) return error.UnsupportedNode;

    const first_item = try lowerExprPtr(arena, ctx, items.items[items.items.len - 1]);
    const list_ty = try listTy(arena, exprTy(first_item.*));
    var current = try arena.allocator().create(ir.Expr);
    current.* = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "[]"),
        .args = &.{},
        .ty = list_ty,
        .layout = layout.ctor(0),
        .tag = builtinCtorTag("[]"),
    } };

    var index = items.items.len;
    while (index > 0) {
        index -= 1;
        const head = if (index == items.items.len - 1)
            first_item
        else
            try lowerExprPtrExpected(arena, ctx, items.items[index], exprTy(first_item.*));
        const args = try arena.allocator().alloc(*const ir.Expr, 2);
        args[0] = head;
        args[1] = current;
        const next = try arena.allocator().create(ir.Expr);
        next.* = .{ .Ctor = .{
            .name = try arena.allocator().dupe(u8, "::"),
            .args = args,
            .ty = list_ty,
            .layout = layout.ctor(2),
            .tag = builtinCtorTag("::"),
        } };
        current = next;
    }
    return current;
}

pub fn stdlibCallSignature(arena: *std.heap.ArenaAllocator, callee: ttree.Expr, arg_count: usize) ?StdlibCallSignature {
    const var_ref = switch (callee) {
        .Var => |value| value,
        else => return null,
    };
    return makeStdlibCallSignature(arena, var_ref.name, arg_count) catch null;
}

pub fn makeStdlibCallSignature(arena: *std.heap.ArenaAllocator, name: []const u8, arg_count: usize) LowerError!?StdlibCallSignature {
    const int_list = try listTy(arena, .Int);
    const int_option = try optionTy(arena, .Int);
    const int_result = try resultTy(arena, .Int, .Int);
    const bytes_ty: ir.Ty = .String;
    const account_ty: ir.Ty = .{ .Record = .{ .name = "account", .params = &.{} } };
    const clock_ty: ir.Ty = .{ .Record = .{ .name = "clock", .params = &.{} } };
    const account_meta_ty: ir.Ty = .{ .Record = .{ .name = "account_meta", .params = &.{} } };
    const instruction_ty: ir.Ty = .{ .Record = .{ .name = "instruction", .params = &.{} } };
    const account_meta_array_ty = try arrayTy(arena, account_meta_ty);
    const signer_seed_ty = try arrayTy(arena, bytes_ty);
    const signer_seeds_ty = try arrayTy(arena, signer_seed_ty);

    if (std.mem.eql(u8, name, "List.length") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_list}), .return_ty = .Int };
    if (std.mem.eql(u8, name, "List.rev") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_list}), .return_ty = int_list };
    if (std.mem.eql(u8, name, "List.append") and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ int_list, int_list }), .return_ty = int_list };
    if (std.mem.eql(u8, name, "List.hd") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_list}), .return_ty = .Int };
    if (std.mem.eql(u8, name, "List.tl") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_list}), .return_ty = int_list };

    if (std.mem.eql(u8, name, "Option.is_none") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_option}), .return_ty = .Bool };
    if (std.mem.eql(u8, name, "Option.is_some") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_option}), .return_ty = .Bool };
    if (std.mem.eql(u8, name, "Option.value") and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ int_option, .Int }), .return_ty = .Int };
    if (std.mem.eql(u8, name, "Option.get") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_option}), .return_ty = .Int };

    if (std.mem.eql(u8, name, "Result.is_ok") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_result}), .return_ty = .Bool };
    if (std.mem.eql(u8, name, "Result.is_error") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_result}), .return_ty = .Bool };
    if (std.mem.eql(u8, name, "Result.ok") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_result}), .return_ty = int_option };
    if (std.mem.eql(u8, name, "Result.error") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{int_result}), .return_ty = int_option };

    if ((std.mem.eql(u8, name, "Account.key") or std.mem.eql(u8, name, "Account.owner") or std.mem.eql(u8, name, "Account.data")) and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{account_ty}), .return_ty = bytes_ty };
    if ((std.mem.eql(u8, name, "Account.lamports") or std.mem.eql(u8, name, "Account.data_len")) and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{account_ty}), .return_ty = .Int };
    if ((std.mem.eql(u8, name, "Account.is_signer") or std.mem.eql(u8, name, "Account.is_writable") or std.mem.eql(u8, name, "Account.is_executable")) and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{account_ty}), .return_ty = .Bool };
    if ((std.mem.eql(u8, name, "Account.has_key") or std.mem.eql(u8, name, "Account.is_owned_by")) and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ account_ty, bytes_ty }), .return_ty = .Bool };

    if (std.mem.eql(u8, name, "Syscall.sol_log") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.String}), .return_ty = .Unit };
    if (std.mem.eql(u8, name, "Syscall.sol_log_64") and arg_count == 5)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ .Int, .Int, .Int, .Int, .Int }), .return_ty = .Unit };
    if (std.mem.eql(u8, name, "Syscall.sol_log_pubkey") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = .Unit };
    if (std.mem.eql(u8, name, "Syscall.sol_sha256") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Syscall.sol_keccak256") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Crypto.sha256") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Crypto.keccak256") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Syscall.sol_get_clock_sysvar") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = clock_ty };
    if (std.mem.eql(u8, name, "Syscall.sol_get_rent_lamports_per_byte_year") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = .Int };
    if (std.mem.eql(u8, name, "Syscall.sol_log_compute_units") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = .Unit };
    if (std.mem.eql(u8, name, "Syscall.sol_remaining_compute_units") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = .Int };
    if ((std.mem.eql(u8, name, "set_return_data") or std.mem.eql(u8, name, "Cpi.set_return_data") or std.mem.eql(u8, name, "Syscall.sol_set_return_data")) and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{bytes_ty}), .return_ty = .Unit };
    if ((std.mem.eql(u8, name, "get_return_data") or std.mem.eql(u8, name, "Cpi.get_return_data") or std.mem.eql(u8, name, "Syscall.sol_get_return_data")) and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Cpi.get_return_program_id") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Bytes.of_string") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.String}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "Bytes.equal") and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ bytes_ty, bytes_ty }), .return_ty = .Bool };
    if (std.mem.eql(u8, name, "Bytes.compare") and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ bytes_ty, bytes_ty }), .return_ty = .Int };
    if (std.mem.eql(u8, name, "Format.int_to_string") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Int}), .return_ty = .String };
    if (std.mem.eql(u8, name, "Format.hex_of_int") and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ .Int, .Int }), .return_ty = .String };

    if ((std.mem.eql(u8, name, "Fixed.of_scaled") or std.mem.eql(u8, name, "Fixed.to_scaled") or std.mem.eql(u8, name, "Fixed.of_int") or std.mem.eql(u8, name, "Fixed.to_int_trunc") or std.mem.eql(u8, name, "Fixed.to_int_floor") or std.mem.eql(u8, name, "Fixed.to_int_ceil") or std.mem.eql(u8, name, "Fixed.to_int_round") or std.mem.eql(u8, name, "Fixed.neg") or std.mem.eql(u8, name, "Fixed.bps")) and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Int}), .return_ty = .Int };
    if ((std.mem.eql(u8, name, "Fixed.add") or std.mem.eql(u8, name, "Fixed.sub") or std.mem.eql(u8, name, "Fixed.mul") or std.mem.eql(u8, name, "Fixed.div") or std.mem.eql(u8, name, "Fixed.mul_int") or std.mem.eql(u8, name, "Fixed.div_int") or std.mem.eql(u8, name, "Fixed.ratio") or std.mem.eql(u8, name, "Fixed.apply") or std.mem.eql(u8, name, "Amount.fee_bps") or std.mem.eql(u8, name, "Amount.discount_bps") or std.mem.eql(u8, name, "Amount.premium_bps") or std.mem.eql(u8, name, "Amount.apply_rate")) and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ .Int, .Int }), .return_ty = .Int };
    if ((std.mem.eql(u8, name, "Fixed.compare") or std.mem.eql(u8, name, "Fixed.min") or std.mem.eql(u8, name, "Fixed.max")) and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ .Int, .Int }), .return_ty = .Int };
    if (std.mem.eql(u8, name, "Fixed.equal") and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ .Int, .Int }), .return_ty = .Bool };

    if ((std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "Cpi.invoke")) and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{instruction_ty}), .return_ty = .Int };
    if ((std.mem.eql(u8, name, "invoke_signed") or std.mem.eql(u8, name, "Cpi.invoke_signed")) and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ instruction_ty, signer_seeds_ty }), .return_ty = .Int };
    if ((std.mem.eql(u8, name, "create_program_address") or std.mem.eql(u8, name, "Pda.create_program_address")) and arg_count == 2)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ signer_seed_ty, bytes_ty }), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "SplToken.program_id") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Unit}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "SplToken.transfer_data") and arg_count == 1)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{.Int}), .return_ty = bytes_ty };
    if (std.mem.eql(u8, name, "SplToken.transfer_account_metas") and arg_count == 3)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ bytes_ty, bytes_ty, bytes_ty }), .return_ty = account_meta_array_ty };
    if (std.mem.eql(u8, name, "SplToken.transfer_instruction") and arg_count == 4)
        return .{ .name = name, .arg_tys = try tySlice(arena, &.{ bytes_ty, bytes_ty, bytes_ty, .Int }), .return_ty = instruction_ty };

    return null;
}

pub fn lowerListMapLiteralApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 2) return error.UnsupportedNode;
    const lambda = switch (app.args[0]) {
        .Lambda => |value| value,
        else => return error.UnsupportedNode,
    };
    if (lambda.params.len != 1) return error.UnsupportedNode;

    var items = std.ArrayList(ttree.Expr).empty;
    errdefer items.deinit(arena.allocator());
    try collectListLiteralItems(arena.allocator(), app.args[1], &items);

    const list_ty = try listTy(arena, .Int);
    var current = try arena.allocator().create(ir.Expr);
    current.* = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "[]"),
        .args = &.{},
        .ty = list_ty,
        .layout = layout.ctor(0),
        .tag = builtinCtorTag("[]"),
    } };

    var index = items.items.len;
    while (index > 0) {
        index -= 1;
        const elem = try lowerExprPtrExpected(arena, ctx, items.items[index], .Int);
        const source_param_name = try arena.allocator().dupe(u8, lambda.params[0]);
        const lowered_param_name = try freshSyntheticName(arena, ctx, source_param_name);
        const previous = ctx.scope.get(source_param_name);
        try ctx.scope.put(source_param_name, .{ .ty = .Int, .layout = layout.intConstant() });
        const mapped_body_raw = try lowerExprPtrExpected(arena, ctx, lambda.body.*, .Int);
        if (previous) |binding| {
            ctx.scope.getPtr(source_param_name).?.* = binding;
        } else {
            _ = ctx.scope.remove(source_param_name);
        }
        const mapped_body = try renameExprVars(arena, mapped_body_raw, &.{
            .{ .from = source_param_name, .to = lowered_param_name },
        });

        const mapped = try arena.allocator().create(ir.Expr);
        mapped.* = .{ .Let = .{
            .name = lowered_param_name,
            .value = elem,
            .body = mapped_body,
            .ty = exprTy(mapped_body.*),
            .layout = exprLayout(mapped_body.*),
        } };

        const args = try arena.allocator().alloc(*const ir.Expr, 2);
        args[0] = mapped;
        args[1] = current;
        const next = try arena.allocator().create(ir.Expr);
        next.* = .{ .Ctor = .{
            .name = try arena.allocator().dupe(u8, "::"),
            .args = args,
            .ty = list_ty,
            .layout = layout.ctor(2),
            .tag = builtinCtorTag("::"),
        } };
        current = next;
    }

    return current.*;
}

pub fn lowerListFilterLiteralApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 2) return error.UnsupportedNode;
    const lambda = switch (app.args[0]) {
        .Lambda => |value| value,
        else => return error.UnsupportedNode,
    };
    if (lambda.params.len != 1) return error.UnsupportedNode;

    var items = std.ArrayList(ttree.Expr).empty;
    errdefer items.deinit(arena.allocator());
    try collectListLiteralItems(arena.allocator(), app.args[1], &items);

    const list_ty = try listTy(arena, .Int);
    var current = try arena.allocator().create(ir.Expr);
    current.* = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "[]"),
        .args = &.{},
        .ty = list_ty,
        .layout = layout.ctor(0),
        .tag = builtinCtorTag("[]"),
    } };

    var index = items.items.len;
    while (index > 0) {
        index -= 1;
        const elem = try lowerExprPtrExpected(arena, ctx, items.items[index], .Int);
        const source_param_name = try arena.allocator().dupe(u8, lambda.params[0]);
        const lowered_param_name = try freshSyntheticName(arena, ctx, source_param_name);
        const previous = ctx.scope.get(source_param_name);
        try ctx.scope.put(source_param_name, .{ .ty = .Int, .layout = layout.intConstant() });
        const predicate_body_raw = try lowerExprPtrExpected(arena, ctx, lambda.body.*, .Bool);
        if (previous) |binding| {
            ctx.scope.getPtr(source_param_name).?.* = binding;
        } else {
            _ = ctx.scope.remove(source_param_name);
        }
        const predicate_body = try renameExprVars(arena, predicate_body_raw, &.{
            .{ .from = source_param_name, .to = lowered_param_name },
        });

        const item_var = try arena.allocator().create(ir.Expr);
        item_var.* = .{ .Var = .{
            .name = lowered_param_name,
            .ty = .Int,
            .layout = layout.intConstant(),
        } };

        const kept_args = try arena.allocator().alloc(*const ir.Expr, 2);
        kept_args[0] = item_var;
        kept_args[1] = current;
        const kept = try arena.allocator().create(ir.Expr);
        kept.* = .{ .Ctor = .{
            .name = try arena.allocator().dupe(u8, "::"),
            .args = kept_args,
            .ty = list_ty,
            .layout = layout.ctor(2),
            .tag = builtinCtorTag("::"),
        } };

        const filtered = try arena.allocator().create(ir.Expr);
        filtered.* = .{ .If = .{
            .cond = predicate_body,
            .then_branch = kept,
            .else_branch = current,
            .ty = list_ty,
            .layout = layoutForTy(list_ty),
        } };

        const next = try arena.allocator().create(ir.Expr);
        next.* = .{ .Let = .{
            .name = lowered_param_name,
            .value = elem,
            .body = filtered,
            .ty = list_ty,
            .layout = layoutForTy(list_ty),
        } };
        current = next;
    }

    return current.*;
}

pub fn lowerListFoldLeftLiteralApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 3) return error.UnsupportedNode;
    const lambda = switch (app.args[0]) {
        .Lambda => |value| value,
        else => return error.UnsupportedNode,
    };
    if (lambda.params.len != 2) return error.UnsupportedNode;

    var items = std.ArrayList(ttree.Expr).empty;
    errdefer items.deinit(arena.allocator());
    try collectListLiteralItems(arena.allocator(), app.args[2], &items);

    var current = try lowerExprPtrExpected(arena, ctx, app.args[1], .Int);
    for (items.items) |item| {
        const elem = try lowerExprPtrExpected(arena, ctx, item, .Int);
        const source_acc_name = try arena.allocator().dupe(u8, lambda.params[0]);
        const source_item_name = try arena.allocator().dupe(u8, lambda.params[1]);
        const lowered_acc_name = try freshSyntheticName(arena, ctx, source_acc_name);
        const lowered_item_name = try freshSyntheticName(arena, ctx, source_item_name);

        const previous_acc = ctx.scope.get(source_acc_name);
        try ctx.scope.put(source_acc_name, .{ .ty = .Int, .layout = layout.intConstant() });
        const previous_item = ctx.scope.get(source_item_name);
        try ctx.scope.put(source_item_name, .{ .ty = .Int, .layout = layout.intConstant() });

        const folded_body_raw = try lowerExprPtrExpected(arena, ctx, lambda.body.*, .Int);
        const folded_body = try renameExprVars(arena, folded_body_raw, &.{
            .{ .from = source_acc_name, .to = lowered_acc_name },
            .{ .from = source_item_name, .to = lowered_item_name },
        });

        if (previous_item) |binding| {
            ctx.scope.getPtr(source_item_name).?.* = binding;
        } else {
            _ = ctx.scope.remove(source_item_name);
        }
        if (previous_acc) |binding| {
            ctx.scope.getPtr(source_acc_name).?.* = binding;
        } else {
            _ = ctx.scope.remove(source_acc_name);
        }

        const item_let = try arena.allocator().create(ir.Expr);
        item_let.* = .{ .Let = .{
            .name = lowered_item_name,
            .value = elem,
            .body = folded_body,
            .ty = exprTy(folded_body.*),
            .layout = exprLayout(folded_body.*),
        } };

        const acc_let = try arena.allocator().create(ir.Expr);
        acc_let.* = .{ .Let = .{
            .name = lowered_acc_name,
            .value = current,
            .body = item_let,
            .ty = exprTy(item_let.*),
            .layout = exprLayout(item_let.*),
        } };
        current = acc_let;
    }

    return current.*;
}

/// Inline-expand `Option.map f o` into a Core IR Match expression.
/// Mirrors the OCaml stdlib definition `Option.map f = function None -> None | Some x -> Some (f x)`.
pub fn lowerOptionMapApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 2) return error.UnsupportedNode;
    return inlineOptionUnaryHof(arena, ctx, app.args[0], app.args[1], .OptionMap);
}

/// Inline-expand `Option.bind f o` into a Core IR Match expression.
/// Mirrors the OCaml stdlib `Option.bind x f = match x with None -> None | Some v -> f v`.
/// Note: the OCaml stdlib signature is `bind : 'a option -> ('a -> 'b option) -> 'b option`, so
/// the first argument is the option scrutinee. R6b.3 follows that convention.
pub fn lowerOptionBindApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 2) return error.UnsupportedNode;
    // Stdlib: Option.bind x f — first arg is the option scrutinee, second is the continuation.
    return inlineOptionUnaryHof(arena, ctx, app.args[1], app.args[0], .OptionBind);
}

/// Inline-expand `Option.fold ~none:default ~some:g o` (already reordered to positional
/// `(default, g, o)` by the frontend's labelled-argument reorder) into a Core IR Match.
pub fn lowerOptionFoldApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 3) return error.UnsupportedNode;
    return inlineOptionFold(arena, ctx, app.args[0], app.args[1], app.args[2]);
}

/// Inline-expand `Result.map f r` into a Core IR Match expression.
pub fn lowerResultMapApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 2) return error.UnsupportedNode;
    return inlineResultUnaryHof(arena, ctx, app.args[0], app.args[1], .ResultMap);
}

/// Inline-expand `Result.bind f r` into a Core IR Match expression.
/// Mirrors `Result.bind x f = match x with Ok v -> f v | Error e -> Error e`.
pub fn lowerResultBindApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 2) return error.UnsupportedNode;
    // Stdlib: Result.bind x f — first arg is the result scrutinee, second is the continuation.
    return inlineResultUnaryHof(arena, ctx, app.args[1], app.args[0], .ResultBind);
}

/// Inline-expand `Result.map_error f r` (and its alias `Result.map_err`) into a Core IR Match.
pub fn lowerResultMapErrorApp(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, app: ttree.App) LowerError!ir.Expr {
    if (app.args.len != 2) return error.UnsupportedNode;
    return inlineResultUnaryHof(arena, ctx, app.args[0], app.args[1], .ResultMapError);
}

const OptionUnaryHof = enum { OptionMap, OptionBind };
const ResultUnaryHof = enum { ResultMap, ResultBind, ResultMapError };

fn inlineOptionUnaryHof(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    f_arg: ttree.Expr,
    option_arg: ttree.Expr,
    kind: OptionUnaryHof,
) LowerError!ir.Expr {
    // Lower the option scrutinee first so we can read its concrete element type.
    const option_value = try lowerExprPtr(arena, ctx, option_arg);
    const option_ty = exprTy(option_value.*);
    const elem_ty: ir.Ty = optionElemTy(option_ty) orelse .Int;

    // Lower the function arg `f` once, regardless of whether it is a Var, Lambda, or App.
    const f_value = try lowerExprPtr(arena, ctx, f_arg);
    const f_name = try freshSyntheticName(arena, ctx, "__zxc_hof_f");

    // Determine the result type from f's arrow (if known); otherwise keep `Int`.
    const f_ret_ty: ir.Ty = arrowReturnTy(exprTy(f_value.*)) orelse elem_ty;
    const result_ty: ir.Ty = switch (kind) {
        // Option.map : ('a -> 'b) -> 'a option -> 'b option  =>  return option<f_ret_ty>
        .OptionMap => try optionTy(arena, f_ret_ty),
        // Option.bind : ('a -> 'b option) -> 'a option -> 'b option  =>  result is f's return type (an option).
        .OptionBind => f_ret_ty,
    };

    // Bind f under a fresh name so its scope is visible in the Some arm body.
    const f_binding_ty = exprTy(f_value.*);
    const f_binding_layout = exprLayout(f_value.*);
    try ctx.scope.put(f_name, .{ .ty = f_binding_ty, .layout = f_binding_layout });
    defer _ = ctx.scope.remove(f_name);

    // Build a fresh name for the Some payload binding.
    const x_name = try freshSyntheticName(arena, ctx, "__zxc_opt_x");

    // Some arm body: depending on kind it is either `Some (f x)` or `f x`.
    const f_ref = try arena.allocator().create(ir.Expr);
    f_ref.* = .{ .Var = .{
        .name = f_name,
        .ty = f_binding_ty,
        .layout = f_binding_layout,
    } };
    const x_ref = try arena.allocator().create(ir.Expr);
    x_ref.* = .{ .Var = .{
        .name = x_name,
        .ty = elem_ty,
        .layout = layoutForTy(elem_ty),
    } };
    const app_args = try arena.allocator().alloc(*const ir.Expr, 1);
    app_args[0] = x_ref;
    const fx_call = try arena.allocator().create(ir.Expr);
    fx_call.* = .{ .App = .{
        .callee = f_ref,
        .args = app_args,
        .ty = f_ret_ty,
        .layout = layoutForTy(f_ret_ty),
    } };

    const some_body: *const ir.Expr = switch (kind) {
        .OptionMap => blk: {
            const wrapped_args = try arena.allocator().alloc(*const ir.Expr, 1);
            wrapped_args[0] = fx_call;
            const some_ctor = try arena.allocator().create(ir.Expr);
            some_ctor.* = .{ .Ctor = .{
                .name = try arena.allocator().dupe(u8, "Some"),
                .args = wrapped_args,
                .ty = result_ty,
                .layout = layout.ctor(1),
                .tag = match_lower.builtinCtorTag("Some"),
                .type_name = null,
            } };
            break :blk some_ctor;
        },
        .OptionBind => fx_call,
    };

    // None arm body: empty option.
    const none_ctor = try arena.allocator().create(ir.Expr);
    none_ctor.* = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "None"),
        .args = &.{},
        .ty = result_ty,
        .layout = layout.ctor(0),
        .tag = match_lower.builtinCtorTag("None"),
        .type_name = null,
    } };

    // Build a scrutinee var bound to a let-name.
    const scrutinee_name = try freshSyntheticName(arena, ctx, "__zxc_opt_scrut");
    const scrutinee_var = try arena.allocator().create(ir.Expr);
    scrutinee_var.* = .{ .Var = .{
        .name = scrutinee_name,
        .ty = option_ty,
        .layout = exprLayout(option_value.*),
    } };

    // Pattern: Some <x>
    const some_arg_patterns = try arena.allocator().alloc(ir.Pattern, 1);
    some_arg_patterns[0] = .{ .Var = .{
        .name = x_name,
        .ty = elem_ty,
        .layout = layoutForTy(elem_ty),
    } };
    const some_pattern: ir.Pattern = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "Some"),
        .args = some_arg_patterns,
        .tag = match_lower.builtinCtorTag("Some"),
        .type_name = null,
    } };
    const none_pattern: ir.Pattern = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "None"),
        .args = &.{},
        .tag = match_lower.builtinCtorTag("None"),
        .type_name = null,
    } };

    const arms = try arena.allocator().alloc(ir.Arm, 2);
    arms[0] = .{ .pattern = some_pattern, .guard = null, .body = some_body };
    arms[1] = .{ .pattern = none_pattern, .guard = null, .body = none_ctor };

    const match_expr = try arena.allocator().create(ir.Expr);
    match_expr.* = .{ .Match = .{
        .scrutinee = scrutinee_var,
        .arms = arms,
        .ty = result_ty,
        .layout = layoutForTy(result_ty),
    } };

    // Wrap match with `let __zxc_opt_scrut = <option_value> in <match>`.
    const scrut_let = try arena.allocator().create(ir.Expr);
    scrut_let.* = .{ .Let = .{
        .name = scrutinee_name,
        .value = option_value,
        .body = match_expr,
        .ty = result_ty,
        .layout = layoutForTy(result_ty),
    } };

    return .{ .Let = .{
        .name = f_name,
        .value = f_value,
        .body = scrut_let,
        .ty = result_ty,
        .layout = layoutForTy(result_ty),
    } };
}

fn inlineOptionFold(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    default_arg: ttree.Expr,
    some_arg: ttree.Expr,
    option_arg: ttree.Expr,
) LowerError!ir.Expr {
    const option_value = try lowerExprPtr(arena, ctx, option_arg);
    const option_ty = exprTy(option_value.*);
    const elem_ty: ir.Ty = optionElemTy(option_ty) orelse .Int;

    // Lower the some continuation `g : 'a -> 'b`.
    const g_value = try lowerExprPtr(arena, ctx, some_arg);
    const g_binding_ty = exprTy(g_value.*);
    const g_binding_layout = exprLayout(g_value.*);
    const g_ret_ty: ir.Ty = arrowReturnTy(g_binding_ty) orelse .Int;

    // Lower the default value with the expected result type so its `Var` lookups inherit it.
    const default_value = try lowerExprPtrExpected(arena, ctx, default_arg, g_ret_ty);
    const result_ty = g_ret_ty;

    const g_name = try freshSyntheticName(arena, ctx, "__zxc_hof_some");
    try ctx.scope.put(g_name, .{ .ty = g_binding_ty, .layout = g_binding_layout });
    defer _ = ctx.scope.remove(g_name);

    const x_name = try freshSyntheticName(arena, ctx, "__zxc_opt_x");

    const g_ref = try arena.allocator().create(ir.Expr);
    g_ref.* = .{ .Var = .{
        .name = g_name,
        .ty = g_binding_ty,
        .layout = g_binding_layout,
    } };
    const x_ref = try arena.allocator().create(ir.Expr);
    x_ref.* = .{ .Var = .{
        .name = x_name,
        .ty = elem_ty,
        .layout = layoutForTy(elem_ty),
    } };
    const some_call_args = try arena.allocator().alloc(*const ir.Expr, 1);
    some_call_args[0] = x_ref;
    const some_body = try arena.allocator().create(ir.Expr);
    some_body.* = .{ .App = .{
        .callee = g_ref,
        .args = some_call_args,
        .ty = result_ty,
        .layout = layoutForTy(result_ty),
    } };

    const some_arg_patterns = try arena.allocator().alloc(ir.Pattern, 1);
    some_arg_patterns[0] = .{ .Var = .{
        .name = x_name,
        .ty = elem_ty,
        .layout = layoutForTy(elem_ty),
    } };
    const some_pattern: ir.Pattern = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "Some"),
        .args = some_arg_patterns,
        .tag = match_lower.builtinCtorTag("Some"),
        .type_name = null,
    } };
    const none_pattern: ir.Pattern = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "None"),
        .args = &.{},
        .tag = match_lower.builtinCtorTag("None"),
        .type_name = null,
    } };

    const scrutinee_name = try freshSyntheticName(arena, ctx, "__zxc_opt_scrut");
    const scrutinee_var = try arena.allocator().create(ir.Expr);
    scrutinee_var.* = .{ .Var = .{
        .name = scrutinee_name,
        .ty = option_ty,
        .layout = exprLayout(option_value.*),
    } };

    const arms = try arena.allocator().alloc(ir.Arm, 2);
    arms[0] = .{ .pattern = none_pattern, .guard = null, .body = default_value };
    arms[1] = .{ .pattern = some_pattern, .guard = null, .body = some_body };

    const match_expr = try arena.allocator().create(ir.Expr);
    match_expr.* = .{ .Match = .{
        .scrutinee = scrutinee_var,
        .arms = arms,
        .ty = result_ty,
        .layout = layoutForTy(result_ty),
    } };

    const scrut_let = try arena.allocator().create(ir.Expr);
    scrut_let.* = .{ .Let = .{
        .name = scrutinee_name,
        .value = option_value,
        .body = match_expr,
        .ty = result_ty,
        .layout = layoutForTy(result_ty),
    } };

    return .{ .Let = .{
        .name = g_name,
        .value = g_value,
        .body = scrut_let,
        .ty = result_ty,
        .layout = layoutForTy(result_ty),
    } };
}

fn inlineResultUnaryHof(
    arena: *std.heap.ArenaAllocator,
    ctx: *LowerContext,
    f_arg: ttree.Expr,
    result_arg: ttree.Expr,
    kind: ResultUnaryHof,
) LowerError!ir.Expr {
    const result_value = try lowerExprPtr(arena, ctx, result_arg);
    const scrutinee_ty = exprTy(result_value.*);
    const ok_ty: ir.Ty = resultOkTy(scrutinee_ty) orelse .Int;
    const err_ty: ir.Ty = resultErrTy(scrutinee_ty) orelse .Int;

    const f_value = try lowerExprPtr(arena, ctx, f_arg);
    const f_binding_ty = exprTy(f_value.*);
    const f_binding_layout = exprLayout(f_value.*);
    const f_ret_ty: ir.Ty = arrowReturnTy(f_binding_ty) orelse switch (kind) {
        .ResultMap => ok_ty,
        .ResultBind => scrutinee_ty,
        .ResultMapError => err_ty,
    };

    const result_ty: ir.Ty = switch (kind) {
        // Result.map : ('a -> 'b) -> ('a, 'e) result -> ('b, 'e) result
        .ResultMap => try resultTy(arena, f_ret_ty, err_ty),
        // Result.bind : ('a -> ('b, 'e) result) -> ('a, 'e) result -> ('b, 'e) result
        // The first arg `f` returns a result so `f_ret_ty` should already be a result type.
        .ResultBind => f_ret_ty,
        // Result.map_error : ('e -> 'f) -> ('a, 'e) result -> ('a, 'f) result
        .ResultMapError => try resultTy(arena, ok_ty, f_ret_ty),
    };

    const f_name = try freshSyntheticName(arena, ctx, "__zxc_hof_f");
    try ctx.scope.put(f_name, .{ .ty = f_binding_ty, .layout = f_binding_layout });
    defer _ = ctx.scope.remove(f_name);

    const ok_name = try freshSyntheticName(arena, ctx, "__zxc_res_ok");
    const err_name = try freshSyntheticName(arena, ctx, "__zxc_res_err");

    const ok_var = try arena.allocator().create(ir.Expr);
    ok_var.* = .{ .Var = .{
        .name = ok_name,
        .ty = ok_ty,
        .layout = layoutForTy(ok_ty),
    } };
    const err_var = try arena.allocator().create(ir.Expr);
    err_var.* = .{ .Var = .{
        .name = err_name,
        .ty = err_ty,
        .layout = layoutForTy(err_ty),
    } };

    const f_ref = try arena.allocator().create(ir.Expr);
    f_ref.* = .{ .Var = .{
        .name = f_name,
        .ty = f_binding_ty,
        .layout = f_binding_layout,
    } };

    // Helper to build a Ctor expression with a single payload value.
    const ok_body: *const ir.Expr = switch (kind) {
        .ResultMap => blk: {
            const call_args = try arena.allocator().alloc(*const ir.Expr, 1);
            call_args[0] = ok_var;
            const f_call = try arena.allocator().create(ir.Expr);
            f_call.* = .{ .App = .{
                .callee = f_ref,
                .args = call_args,
                .ty = f_ret_ty,
                .layout = layoutForTy(f_ret_ty),
            } };
            const ctor_args = try arena.allocator().alloc(*const ir.Expr, 1);
            ctor_args[0] = f_call;
            const ok_ctor = try arena.allocator().create(ir.Expr);
            ok_ctor.* = .{ .Ctor = .{
                .name = try arena.allocator().dupe(u8, "Ok"),
                .args = ctor_args,
                .ty = result_ty,
                .layout = layout.ctor(1),
                .tag = match_lower.builtinCtorTag("Ok"),
                .type_name = null,
            } };
            break :blk ok_ctor;
        },
        .ResultBind => blk: {
            const call_args = try arena.allocator().alloc(*const ir.Expr, 1);
            call_args[0] = ok_var;
            const f_call = try arena.allocator().create(ir.Expr);
            f_call.* = .{ .App = .{
                .callee = f_ref,
                .args = call_args,
                .ty = result_ty,
                .layout = layoutForTy(result_ty),
            } };
            break :blk f_call;
        },
        .ResultMapError => blk: {
            // Ok case: rewrap value unchanged.
            const ctor_args = try arena.allocator().alloc(*const ir.Expr, 1);
            ctor_args[0] = ok_var;
            const ok_ctor = try arena.allocator().create(ir.Expr);
            ok_ctor.* = .{ .Ctor = .{
                .name = try arena.allocator().dupe(u8, "Ok"),
                .args = ctor_args,
                .ty = result_ty,
                .layout = layout.ctor(1),
                .tag = match_lower.builtinCtorTag("Ok"),
                .type_name = null,
            } };
            break :blk ok_ctor;
        },
    };

    const err_body: *const ir.Expr = switch (kind) {
        .ResultMap, .ResultBind => blk: {
            // Just rewrap the error unchanged.
            const ctor_args = try arena.allocator().alloc(*const ir.Expr, 1);
            ctor_args[0] = err_var;
            const err_ctor = try arena.allocator().create(ir.Expr);
            err_ctor.* = .{ .Ctor = .{
                .name = try arena.allocator().dupe(u8, "Error"),
                .args = ctor_args,
                .ty = result_ty,
                .layout = layout.ctor(1),
                .tag = match_lower.builtinCtorTag("Error"),
                .type_name = null,
            } };
            break :blk err_ctor;
        },
        .ResultMapError => blk: {
            const call_args = try arena.allocator().alloc(*const ir.Expr, 1);
            call_args[0] = err_var;
            const f_call = try arena.allocator().create(ir.Expr);
            f_call.* = .{ .App = .{
                .callee = f_ref,
                .args = call_args,
                .ty = f_ret_ty,
                .layout = layoutForTy(f_ret_ty),
            } };
            const ctor_args = try arena.allocator().alloc(*const ir.Expr, 1);
            ctor_args[0] = f_call;
            const err_ctor = try arena.allocator().create(ir.Expr);
            err_ctor.* = .{ .Ctor = .{
                .name = try arena.allocator().dupe(u8, "Error"),
                .args = ctor_args,
                .ty = result_ty,
                .layout = layout.ctor(1),
                .tag = match_lower.builtinCtorTag("Error"),
                .type_name = null,
            } };
            break :blk err_ctor;
        },
    };

    const ok_arg_patterns = try arena.allocator().alloc(ir.Pattern, 1);
    ok_arg_patterns[0] = .{ .Var = .{
        .name = ok_name,
        .ty = ok_ty,
        .layout = layoutForTy(ok_ty),
    } };
    const err_arg_patterns = try arena.allocator().alloc(ir.Pattern, 1);
    err_arg_patterns[0] = .{ .Var = .{
        .name = err_name,
        .ty = err_ty,
        .layout = layoutForTy(err_ty),
    } };

    const ok_pattern: ir.Pattern = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "Ok"),
        .args = ok_arg_patterns,
        .tag = match_lower.builtinCtorTag("Ok"),
        .type_name = null,
    } };
    const err_pattern: ir.Pattern = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, "Error"),
        .args = err_arg_patterns,
        .tag = match_lower.builtinCtorTag("Error"),
        .type_name = null,
    } };

    const scrutinee_name = try freshSyntheticName(arena, ctx, "__zxc_res_scrut");
    const scrutinee_var = try arena.allocator().create(ir.Expr);
    scrutinee_var.* = .{ .Var = .{
        .name = scrutinee_name,
        .ty = scrutinee_ty,
        .layout = exprLayout(result_value.*),
    } };

    const arms = try arena.allocator().alloc(ir.Arm, 2);
    arms[0] = .{ .pattern = ok_pattern, .guard = null, .body = ok_body };
    arms[1] = .{ .pattern = err_pattern, .guard = null, .body = err_body };

    const match_expr = try arena.allocator().create(ir.Expr);
    match_expr.* = .{ .Match = .{
        .scrutinee = scrutinee_var,
        .arms = arms,
        .ty = result_ty,
        .layout = layoutForTy(result_ty),
    } };

    const scrut_let = try arena.allocator().create(ir.Expr);
    scrut_let.* = .{ .Let = .{
        .name = scrutinee_name,
        .value = result_value,
        .body = match_expr,
        .ty = result_ty,
        .layout = layoutForTy(result_ty),
    } };

    return .{ .Let = .{
        .name = f_name,
        .value = f_value,
        .body = scrut_let,
        .ty = result_ty,
        .layout = layoutForTy(result_ty),
    } };
}

fn optionElemTy(ty: ir.Ty) ?ir.Ty {
    return switch (ty) {
        .Adt => |adt| if (std.mem.eql(u8, adt.name, "option") and adt.params.len == 1) adt.params[0] else null,
        else => null,
    };
}

fn resultOkTy(ty: ir.Ty) ?ir.Ty {
    return switch (ty) {
        .Adt => |adt| if (std.mem.eql(u8, adt.name, "result") and adt.params.len == 2) adt.params[0] else null,
        else => null,
    };
}

fn resultErrTy(ty: ir.Ty) ?ir.Ty {
    return switch (ty) {
        .Adt => |adt| if (std.mem.eql(u8, adt.name, "result") and adt.params.len == 2) adt.params[1] else null,
        else => null,
    };
}

fn arrowReturnTy(ty: ir.Ty) ?ir.Ty {
    return switch (ty) {
        .Arrow => |arrow| arrow.ret.*,
        else => null,
    };
}

pub fn collectListLiteralItems(allocator: std.mem.Allocator, expr: ttree.Expr, items: *std.ArrayList(ttree.Expr)) LowerError!void {
    const ctor = switch (expr) {
        .Ctor => |value| value,
        else => return error.UnsupportedNode,
    };
    if (std.mem.eql(u8, ctor.name, "[]")) {
        if (ctor.args.len != 0) return error.UnsupportedNode;
        return;
    }
    if (!std.mem.eql(u8, ctor.name, "::") or ctor.args.len != 2) return error.UnsupportedNode;
    try items.append(allocator, ctor.args[0]);
    try collectListLiteralItems(allocator, ctor.args[1], items);
}

pub fn isVarNamed(expr: ttree.Expr, name: []const u8) bool {
    return switch (expr) {
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        else => false,
    };
}

pub fn appReturnTy(arena: *std.heap.ArenaAllocator, callee_ty: ir.Ty, arg_count: usize) LowerError!ir.Ty {
    const arrow = switch (callee_ty) {
        .Arrow => |value| value,
        else => return .Int,
    };
    if (arg_count >= arrow.params.len) return arrow.ret.*;
    const remaining = arrow.params[arg_count..];
    return makeArrowTyFromPieces(arena, remaining, arrow.ret.*);
}

pub fn lowerIf(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, if_expr: ttree.IfExpr) LowerError!ir.Expr {
    const cond = try lowerExprPtrExpected(arena, ctx, if_expr.cond.*, .Bool);
    var then_branch = try lowerExprPtr(arena, ctx, if_expr.then_branch.*);
    var else_branch = try lowerExprPtr(arena, ctx, if_expr.else_branch.*);
    // CR-14: a nullary-ctor branch (`None`, `[]`) lowered without an expected
    // type defaults its ADT instantiation; rewrite it to the concrete
    // instantiation produced by the sibling branch so both branches agree.
    if (!tyEql(exprTy(then_branch.*), exprTy(else_branch.*))) {
        if (try adoptNullaryCtorBranchTy(arena, else_branch, exprTy(then_branch.*))) |patched| {
            else_branch = patched;
        } else if (try adoptNullaryCtorBranchTy(arena, then_branch, exprTy(else_branch.*))) |patched| {
            then_branch = patched;
        }
    }
    return .{ .If = .{
        .cond = cond,
        .then_branch = then_branch,
        .else_branch = else_branch,
        .ty = exprTy(then_branch.*),
        .layout = exprLayout(then_branch.*),
    } };
}

pub fn lowerPrim(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, prim: ttree.Prim) LowerError!ir.Expr {
    const op = try lowerPrimOp(prim.op);
    if (prim.args.len != primOpArity(op)) return error.UnsupportedPrimArity;
    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    for (prim.args) |arg| {
        try args.append(arena.allocator(), try lowerExprPtr(arena, ctx, arg));
    }
    const ty = primOpReturnTy(op);
    return .{ .Prim = .{
        .op = op,
        .args = try args.toOwnedSlice(arena.allocator()),
        .ty = ty,
        .layout = layout.intConstant(),
    } };
}

pub fn lowerPrimOp(op: []const u8) LowerError!ir.PrimOp {
    if (std.mem.eql(u8, op, "+")) return .Add;
    if (std.mem.eql(u8, op, "-")) return .Sub;
    if (std.mem.eql(u8, op, "*")) return .Mul;
    if (std.mem.eql(u8, op, "/")) return .Div;
    if (std.mem.eql(u8, op, "mod")) return .Mod;
    if (std.mem.eql(u8, op, "=")) return .Eq;
    if (std.mem.eql(u8, op, "<>")) return .Ne;
    if (std.mem.eql(u8, op, "<")) return .Lt;
    if (std.mem.eql(u8, op, "<=")) return .Le;
    if (std.mem.eql(u8, op, ">")) return .Gt;
    if (std.mem.eql(u8, op, ">=")) return .Ge;
    if (std.mem.eql(u8, op, "land")) return .BitAnd;
    if (std.mem.eql(u8, op, "lor")) return .BitOr;
    if (std.mem.eql(u8, op, "lxor")) return .BitXor;
    if (std.mem.eql(u8, op, "lsl")) return .ShiftLeft;
    if (std.mem.eql(u8, op, "lsr")) return .ShiftRight;
    if (std.mem.eql(u8, op, "lnot")) return .BitNot;
    return error.UnsupportedPrim;
}

pub fn primOpArity(op: ir.PrimOp) usize {
    return switch (op) {
        .StringLength, .CharCode, .CharChr, .BitNot, .BytesCreate => 1,
        .Add, .Sub, .Mul, .Div, .Mod, .Eq, .Ne, .Lt, .Le, .Gt, .Ge, .StringGet, .StringConcat, .BitAnd, .BitOr, .BitXor, .ShiftLeft, .ShiftRight => 2,
        .StringSub, .BytesSet => 3,
        .BytesFill => 4,
        .BytesBlit => 5,
    };
}

pub fn primOpReturnTy(op: ir.PrimOp) ir.Ty {
    return switch (op) {
        .Add, .Sub, .Mul, .Div, .Mod, .StringLength, .StringGet, .CharCode, .CharChr, .BitAnd, .BitOr, .BitXor, .ShiftLeft, .ShiftRight, .BitNot => .Int,
        .Eq, .Ne, .Lt, .Le, .Gt, .Ge => .Bool,
        .StringSub, .StringConcat, .BytesCreate => .String,
        .BytesSet, .BytesBlit, .BytesFill => .Unit,
    };
}

pub fn lowerVar(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, var_ref: ttree.Var) LowerError!ir.Var {
    const binding = ctx.scope.get(var_ref.name) orelse return error.UnboundVariable;
    return .{
        .name = try arena.allocator().dupe(u8, var_ref.name),
        .ty = binding.ty,
        .layout = binding.layout,
    };
}

pub fn lowerVarExpr(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, var_ref: ttree.Var, expected_ty: ?ir.Ty) LowerError!ir.Expr {
    if (ctx.scope.contains(var_ref.name)) {
        var lowered = try lowerVar(arena, ctx, var_ref);
        if (expected_ty) |ty| {
            lowered.ty = ty;
            lowered.layout = layoutForTy(ty);
        }
        return .{ .Var = lowered };
    }
    if (std.mem.eql(u8, var_ref.name, "Fixed.scale") or std.mem.eql(u8, var_ref.name, "Fixed.one")) {
        return .{ .Constant = .{
            .value = .{ .Int = 1000000 },
            .ty = .Int,
            .layout = layout.intConstant(),
        } };
    }
    if (std.mem.eql(u8, var_ref.name, "Fixed.zero")) {
        return .{ .Constant = .{
            .value = .{ .Int = 0 },
            .ty = .Int,
            .layout = layout.intConstant(),
        } };
    }
    if (std.mem.eql(u8, var_ref.name, "max_int")) {
        return .{ .Constant = .{
            .value = .{ .Int = std.math.maxInt(i64) },
            .ty = .Int,
            .layout = layout.intConstant(),
        } };
    }
    if (std.mem.eql(u8, var_ref.name, "min_int")) {
        return .{ .Constant = .{
            .value = .{ .Int = std.math.minInt(i64) },
            .ty = .Int,
            .layout = layout.intConstant(),
        } };
    }
    return error.UnboundVariable;
}

pub fn lowerConstant(arena: *std.heap.ArenaAllocator, constant: ttree.Constant) LowerError!ir.Constant {
    return switch (constant) {
        .Int => |value| .{
            .value = .{ .Int = value },
            .ty = .Int,
            .layout = layout.intConstant(),
        },
        .String => |value| .{
            .value = .{ .String = try arena.allocator().dupe(u8, value) },
            .ty = .String,
            .layout = layout.defaultFor(.StringLiteral),
        },
    };
}

pub fn lowerCtor(arena: *std.heap.ArenaAllocator, ctx: *LowerContext, ctor_expr: ttree.Ctor, expected_ty: ?ir.Ty) LowerError!ir.Expr {
    const ctor_info = try validateCtor(ctx, ctor_expr.name, ctor_expr.args.len);
    var expected_payload_tys: ?[]const ir.Ty = null;
    if (ctor_info) |info| {
        if (expected_ty) |ty| {
            var bindings = TypeBindings.init(arena.allocator());
            defer bindings.deinit();
            bindTypeParamsFromMatchedAdt(&bindings, info, ty) catch {};
            if (bindings.count() > 0 or info.type_params.len == 0) {
                expected_payload_tys = try typeExprsToTysWithBindings(arena, ctx.record_type_decls, info.payload_types, &bindings);
            }
        }
    }

    var args = std.ArrayList(*const ir.Expr).empty;
    errdefer args.deinit(arena.allocator());
    var wrappers = std.ArrayList(struct {
        name: []const u8,
        value: *const ir.Expr,
    }).empty;
    errdefer wrappers.deinit(arena.allocator());

    for (ctor_expr.args, 0..) |arg, index| {
        const expected_arg_ty: ?ir.Ty = if (expected_payload_tys) |payload_tys| payload_tys[index] else null;
        if (isAtomicTtree(arg)) {
            try args.append(arena.allocator(), try lowerExprPtrExpected(arena, ctx, arg, expected_arg_ty));
        } else {
            const value = try lowerExprPtrExpected(arena, ctx, arg, expected_arg_ty);
            const temp_name = try freshTemp(arena, ctx);
            const var_ptr = try arena.allocator().create(ir.Expr);
            var_ptr.* = .{ .Var = .{
                .name = temp_name,
                .ty = exprTy(value.*),
                .layout = exprLayout(value.*),
            } };
            try wrappers.append(arena.allocator(), .{ .name = temp_name, .value = value });
            try args.append(arena.allocator(), var_ptr);
        }
    }

    const owned_args = try args.toOwnedSlice(arena.allocator());
    const ctor_ty = try ctorTy(arena, ctx, ctor_expr.name, owned_args, expected_ty);
    const ctor_layout = layout.ctor(owned_args.len);
    var current = try arena.allocator().create(ir.Expr);
    current.* = .{ .Ctor = .{
        .name = try arena.allocator().dupe(u8, ctor_expr.name),
        .args = owned_args,
        .ty = ctor_ty,
        .layout = ctor_layout,
        .tag = if (ctor_info) |info| info.tag else builtinCtorTag(ctor_expr.name),
        .type_name = if (ctor_info) |info| try arena.allocator().dupe(u8, info.type_name) else null,
    } };

    var index = wrappers.items.len;
    while (index > 0) {
        index -= 1;
        const wrapper = wrappers.items[index];
        const body = current;
        current = try arena.allocator().create(ir.Expr);
        current.* = .{ .Let = .{
            .name = wrapper.name,
            .value = wrapper.value,
            .body = body,
            .ty = ctor_ty,
            .layout = ctor_layout,
        } };
    }

    return current.*;
}
