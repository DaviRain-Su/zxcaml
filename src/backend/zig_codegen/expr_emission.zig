// Part of src/backend/zig_codegen.zig; split by concern.
const common = @import("common.zig");
const std = common.std;
const lir = common.lir;
const EmitError = common.EmitError;
const EmitContext = common.EmitContext;
const LetBindingStorage = common.LetBindingStorage;
const LetBindingSnapshot = common.LetBindingSnapshot;
const emitVariableValue = common.emitVariableValue;
const pushLetBinding = common.pushLetBinding;
const restoreLetBinding = common.restoreLetBinding;
const freeEmittedFunctionName = common.freeEmittedFunctionName;
const exprUsesName = common.exprUsesName;
const isNilCtor = common.isNilCtor;
const zigTypeName = common.zigTypeName;
const findUserVariant = common.findUserVariant;
const findUserTypeDecl = common.findUserTypeDecl;
const findRecordTypeDecl = common.findRecordTypeDecl;
const isAccountTy = common.isAccountTy;
const findRecordUpdateField = common.findRecordUpdateField;
const findClosureCodeId = common.findClosureCodeId;
const closureFuncMatchesTy = common.closureFuncMatchesTy;
const zigInstantiatedTypeRefName = common.zigInstantiatedTypeRefName;
const zigUserAdtTypeName = common.zigUserAdtTypeName;
const isRecursivePayload = common.isRecursivePayload;
const userVariantName = common.userVariantName;
const appendSanitized = common.appendSanitized;
const primOpToken = common.primOpToken;
const ctorVariantName = common.ctorVariantName;
const emitIdentifier = common.emitIdentifier;
const emitIndent = common.emitIndent;
const append = common.append;
const appendPrint = common.appendPrint;
const decl_emission = @import("decl_emission.zig");
const emittedFunctionName = decl_emission.emittedFunctionName;
const emittedClosureFunctionName = decl_emission.emittedClosureFunctionName;
const runtime_imports = @import("runtime_imports.zig");
const emitExternalAppExpr = runtime_imports.emitExternalAppExpr;
const findExternalDecl = runtime_imports.findExternalDecl;
const emitSyscallAppExpr = runtime_imports.emitSyscallAppExpr;
const emitCounterAppExpr = runtime_imports.emitCounterAppExpr;
const emitSplTokenAppExpr = runtime_imports.emitSplTokenAppExpr;
const stdlib_emission = @import("stdlib_emission.zig");
const emitStdlibAppExpr = stdlib_emission.emitStdlibAppExpr;
const match_emission = @import("match_emission.zig");
const emitMatchExpr = match_emission.emitMatchExpr;

pub fn emitExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    expr: lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    switch (expr) {
        .Constant => |constant| switch (constant) {
            .Int => |value| {
                // Emit integer constants as @as(i64, value) instead of bare
                // literals.  Bare integer literals are comptime_int in Zig;
                // when used inside a labeled block that contains runtime
                // control flow (e.g. if-then-else), the compiler rejects
                // them with "value with comptime-only type depends on
                // runtime control flow".  Wrapping in @as(i64, ...) gives
                // a concrete runtime type that works in all contexts.
                try appendPrint(out, allocator, "@as(i64, {d})", .{value});
            },
            .String => |value| try appendPrint(out, allocator, "\"{f}\"", .{std.zig.fmtString(value)}),
        },
        .Var => |var_ref| try emitVariableValue(out, allocator, var_ref.name, ctx),
        .App => |app| try emitAppExpr(out, allocator, app, indent_level, ctx),
        .Let => |let_expr| try emitLetExpr(out, allocator, let_expr, indent_level, ctx),
        .Assert => |assert_expr| try emitAssertExpr(out, allocator, assert_expr, indent_level, ctx),
        .If => |if_expr| try emitIfExpr(out, allocator, if_expr, indent_level, ctx),
        .Prim => |prim| try emitPrimExpr(out, allocator, prim, indent_level, ctx),
        .Ctor => |ctor_expr| try emitCtorExpr(out, allocator, ctor_expr, indent_level, ctx),
        .Match => |match_expr| try emitMatchExpr(out, allocator, match_expr, indent_level, ctx),
        .Closure => |closure| try emitClosureExpr(out, allocator, closure, indent_level, ctx),
        .Tuple => |tuple_expr| try emitTupleExpr(out, allocator, tuple_expr, indent_level, ctx),
        .TupleProj => |tuple_proj| try emitTupleProjExpr(out, allocator, tuple_proj, indent_level, ctx),
        .Record => |record_expr| try emitRecordExpr(out, allocator, record_expr, indent_level, ctx),
        .RecordField => |record_field| try emitRecordFieldExpr(out, allocator, record_field, indent_level, ctx),
        .RecordUpdate => |record_update| try emitRecordUpdateExpr(out, allocator, record_update, indent_level, ctx),
        .AccountFieldSet => |field_set| try emitAccountFieldSetExpr(out, allocator, field_set, indent_level, ctx),
    }
}

pub fn emitTupleExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    tuple_expr: lir.LTuple,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    _ = tuple_expr.ty;
    try append(out, allocator, ".{ ");
    for (tuple_expr.items, 0..) |item, index| {
        if (index != 0) try append(out, allocator, ", ");
        try appendPrint(out, allocator, ".@\"{d}\" = ", .{index});
        try emitExpr(out, allocator, item.*, indent_level, ctx);
    }
    try append(out, allocator, " }");
}

pub fn emitTupleProjExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    tuple_proj: lir.LTupleProj,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    try append(out, allocator, "(");
    try emitExpr(out, allocator, tuple_proj.tuple_expr.*, indent_level, ctx);
    try appendPrint(out, allocator, ").@\"{d}\"", .{tuple_proj.index});
}

pub fn emitRecordExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    record_expr: lir.LRecord,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (isAccountTy(record_expr.ty)) return error.UnsupportedExpr;
    const ty_name = try zigTypeName(allocator, record_expr.ty);
    defer allocator.free(ty_name);
    try appendPrint(out, allocator, "{s}{{ ", .{ty_name});
    for (record_expr.fields, 0..) |field, index| {
        if (index != 0) try append(out, allocator, ", ");
        try append(out, allocator, ".");
        try emitIdentifier(out, allocator, field.name);
        try append(out, allocator, " = ");
        try emitExpr(out, allocator, field.value.*, indent_level, ctx);
    }
    try append(out, allocator, " }");
}

pub fn emitRecordFieldExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    record_field: lir.LRecordField,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (record_field.record_ty) |record_ty| {
        if (isAccountTy(record_ty)) {
            try emitAccountFieldReadExpr(out, allocator, record_field, indent_level, ctx);
            return;
        }
    }
    try append(out, allocator, "(");
    try emitExpr(out, allocator, record_field.record_expr.*, indent_level, ctx);
    try append(out, allocator, ").");
    try emitIdentifier(out, allocator, record_field.field_name);
}

pub fn emitAccountFieldReadExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    record_field: lir.LRecordField,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (std.mem.eql(u8, record_field.field_name, "lamports")) {
        try append(out, allocator, "@as(i64, @intCast((");
        try emitExpr(out, allocator, record_field.record_expr.*, indent_level, ctx);
        try append(out, allocator, ").lamportsValue()))");
        return;
    }
    if (std.mem.eql(u8, record_field.field_name, "data")) {
        try append(out, allocator, "(");
        try emitExpr(out, allocator, record_field.record_expr.*, indent_level, ctx);
        try append(out, allocator, ").data");
        return;
    }
    if (std.mem.eql(u8, record_field.field_name, "key")) {
        try append(out, allocator, "(");
        try emitExpr(out, allocator, record_field.record_expr.*, indent_level, ctx);
        try append(out, allocator, ").key[0..]");
        return;
    }
    if (std.mem.eql(u8, record_field.field_name, "owner")) {
        try append(out, allocator, "(");
        try emitExpr(out, allocator, record_field.record_expr.*, indent_level, ctx);
        try append(out, allocator, ").owner[0..]");
        return;
    }
    if (std.mem.eql(u8, record_field.field_name, "is_signer") or
        std.mem.eql(u8, record_field.field_name, "is_writable") or
        std.mem.eql(u8, record_field.field_name, "executable"))
    {
        try append(out, allocator, "prelude.Bool.fromNative((");
        try emitExpr(out, allocator, record_field.record_expr.*, indent_level, ctx);
        try append(out, allocator, ").");
        try emitIdentifier(out, allocator, record_field.field_name);
        try append(out, allocator, ")");
        return;
    }
    return error.UnsupportedExpr;
}

pub fn emitAccountFieldSetExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    field_set: lir.LAccountFieldSet,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_account_{d} = ", .{block_id});
    try emitExpr(out, allocator, field_set.account_expr.*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    if (std.mem.eql(u8, field_set.field_name, "lamports")) {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "omlz_account_{d}.lamports.* = @intCast(", .{block_id});
        try emitExpr(out, allocator, field_set.value.*, indent_level + 1, ctx);
        try append(out, allocator, ");\n");
    } else if (std.mem.eql(u8, field_set.field_name, "data")) {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "const omlz_account_data_{d} = ", .{block_id});
        try emitExpr(out, allocator, field_set.value.*, indent_level + 1, ctx);
        try append(out, allocator, ";\n");
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "if (omlz_account_data_{d}.len > omlz_account_{d}.data.len) unreachable;\n", .{ block_id, block_id });
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "@memcpy(omlz_account_{d}.data[0..omlz_account_data_{d}.len], omlz_account_data_{d});\n", .{ block_id, block_id, block_id });
    } else if (std.mem.eql(u8, field_set.field_name, "key") or std.mem.eql(u8, field_set.field_name, "owner")) {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "@compileError(\"ZXCAML: account field '{s}' is read-only\");\n", .{field_set.field_name});
    } else {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "@compileError(\"ZXCAML: account field '{s}' is not writable\");\n", .{field_set.field_name});
    }
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d};\n", .{block_id});
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitRecordUpdateExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    record_update: lir.LRecordUpdate,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const record_ty = switch (record_update.ty) {
        .Record => |value| value,
        else => return error.UnsupportedExpr,
    };
    const record_decl = findRecordTypeDecl(ctx.record_type_decls, record_ty.name) orelse return error.UnsupportedExpr;
    const ty_name = try zigTypeName(allocator, record_update.ty);
    defer allocator.free(ty_name);
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_record_base_{d} = ", .{block_id});
    try emitExpr(out, allocator, record_update.base_expr.*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} {s}{{ ", .{ block_id, ty_name });
    for (record_decl.fields, 0..) |field, index| {
        if (index != 0) try append(out, allocator, ", ");
        try append(out, allocator, ".");
        try emitIdentifier(out, allocator, field.name);
        try append(out, allocator, " = ");
        if (findRecordUpdateField(record_update.fields, field.name)) |updated| {
            try emitExpr(out, allocator, updated.value.*, indent_level + 1, ctx);
        } else {
            try appendPrint(out, allocator, "omlz_record_base_{d}.", .{block_id});
            try emitIdentifier(out, allocator, field.name);
        }
    }
    try append(out, allocator, " };\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitAppExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (app.is_tail_call) {
        if (try emitTailCallContinueExpr(out, allocator, app, indent_level, ctx)) return;
    }
    switch (app.callee.*) {
        .Var => |callee| if (try emitCounterAppExpr(out, allocator, callee.name, app, indent_level, ctx)) return,
        else => {},
    }
    if (app.kind == .Closure) {
        const callee = switch (app.callee.*) {
            .Var => |var_ref| var_ref,
            else => return error.UnsupportedExpr,
        };
        const closure_ty = switch (app.callee_ty) {
            .Closure => |value| value,
            else => return error.UnsupportedExpr,
        };
        try append(out, allocator, "blk");
        const block_id = ctx.next_block_id;
        ctx.next_block_id += 1;
        try appendPrint(out, allocator, "{d}: {{\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "switch (");
        try emitVariableValue(out, allocator, callee.name, ctx);
        try append(out, allocator, ".code) {\n");
        var emitted_case = false;
        for (ctx.functions, 0..) |func, index| {
            if (func.calling_convention != .Closure) continue;
            if (!closureFuncMatchesTy(func, closure_ty)) continue;
            emitted_case = true;
            try emitIndent(out, allocator, indent_level + 2);
            try appendPrint(out, allocator, "{d} => break :blk{d} ", .{ index + 1, block_id });
            const function_name = try emittedClosureFunctionName(allocator, func.name);
            defer allocator.free(function_name);
            try appendPrint(out, allocator, "{s}(arena, ", .{function_name});
            try emitVariableValue(out, allocator, callee.name, ctx);
            for (app.args) |arg| {
                try append(out, allocator, ", ");
                try emitExpr(out, allocator, arg.*, indent_level + 2, ctx);
            }
            try append(out, allocator, "),\n");
        }
        if (!emitted_case) return error.UnsupportedExpr;
        try emitIndent(out, allocator, indent_level + 2);
        try append(out, allocator, "else => unreachable,\n");
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "}\n");
        try emitIndent(out, allocator, indent_level);
        try append(out, allocator, "}");
        return;
    }

    switch (app.callee.*) {
        .Var => |callee| {
            if (findExternalDecl(ctx.externals, callee.name)) |external| {
                try emitExternalAppExpr(out, allocator, external, app, indent_level, ctx);
                return;
            }
            if (try emitSyscallAppExpr(out, allocator, callee.name, app, indent_level, ctx)) return;
            if (try emitSplTokenAppExpr(out, allocator, callee.name, app, indent_level, ctx)) return;
            if (try emitCounterAppExpr(out, allocator, callee.name, app, indent_level, ctx)) return;
            if (try emitStdlibAppExpr(out, allocator, callee.name, app, indent_level, ctx)) return;
            const function_name = try emittedFunctionName(allocator, callee.name);
            defer freeEmittedFunctionName(allocator, callee.name, function_name);
            try append(out, allocator, function_name);
        },
        else => return error.UnsupportedExpr,
    }
    try append(out, allocator, "(arena");
    for (app.args) |arg| {
        try append(out, allocator, ", ");
        try emitExpr(out, allocator, arg.*, indent_level, ctx);
    }
    try append(out, allocator, ")");
}

pub fn emitTailCallContinueExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!bool {
    const function_name = ctx.tco_function_name orelse return false;
    const callee = switch (app.callee.*) {
        .Var => |value| value,
        else => return false,
    };
    if (!std.mem.eql(u8, callee.name, function_name)) return false;
    if (app.kind != .Direct) return false;
    if (app.args.len != ctx.tco_params.len) return error.UnsupportedExpr;

    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    const ty_name = try zigTypeName(allocator, app.ty);
    defer allocator.free(ty_name);
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (@intFromPtr(arena) == 0) break :blk{d} @as({s}, undefined);\n", .{ block_id, ty_name });
    for (app.args, 0..) |arg, index| {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "const omlz_tco_arg_{d}_{d} = ", .{ block_id, index });
        try emitExpr(out, allocator, arg.*, indent_level + 1, ctx);
        try append(out, allocator, ";\n");
    }
    for (ctx.tco_params, 0..) |param, index| {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "{s} = omlz_tco_arg_{d}_{d};\n", .{ param.local_name, block_id, index });
    }
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "continue;\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
    return true;
}

pub fn emitIfExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    if_expr: lir.LIf,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "if (prelude.Bool.toNative(");
    try emitExpr(out, allocator, if_expr.cond.*, indent_level + 1, ctx);
    try append(out, allocator, ")) {\n");
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "break :blk{d} ", .{block_id});
    try emitExpr(out, allocator, if_expr.then_branch.*, indent_level + 2, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "} else {\n");
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "break :blk{d} ", .{block_id});
    try emitExpr(out, allocator, if_expr.else_branch.*, indent_level + 2, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitAssertExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    assert_expr: lir.LAssert,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "if (!prelude.Bool.toNative(");
    try emitExpr(out, allocator, assert_expr.condition.*, indent_level + 1, ctx);
    try append(out, allocator, ")) runtime_panic.assertFailure();\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d};\n", .{block_id});
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitPrimExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prim: lir.LPrim,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    switch (prim.op) {
        .StringLength => {
            if (prim.args.len != 1) return error.UnsupportedExpr;
            try append(out, allocator, "@as(i64, @intCast((");
            try emitExpr(out, allocator, prim.args[0].*, indent_level, ctx);
            try append(out, allocator, ").len))");
        },
        .StringGet => {
            if (prim.args.len != 2) return error.UnsupportedExpr;
            try append(out, allocator, "@as(i64, @intCast((");
            try emitExpr(out, allocator, prim.args[0].*, indent_level, ctx);
            try append(out, allocator, ")[@as(usize, @intCast(");
            try emitExpr(out, allocator, prim.args[1].*, indent_level, ctx);
            try append(out, allocator, "))]))");
        },
        .StringSub => try emitStringSubExpr(out, allocator, prim, indent_level, ctx),
        .StringConcat => try emitStringConcatExpr(out, allocator, prim, indent_level, ctx),
        .CharCode, .CharChr => {
            if (prim.args.len != 1) return error.UnsupportedExpr;
            try emitExpr(out, allocator, prim.args[0].*, indent_level, ctx);
        },
        .Div => {
            if (prim.args.len != 2) return error.UnsupportedExpr;
            try append(out, allocator, "prelude.intDiv(");
            try emitExpr(out, allocator, prim.args[0].*, indent_level, ctx);
            try append(out, allocator, ", ");
            try emitExpr(out, allocator, prim.args[1].*, indent_level, ctx);
            try append(out, allocator, ")");
        },
        .Mod => {
            if (prim.args.len != 2) return error.UnsupportedExpr;
            try append(out, allocator, "prelude.intMod(");
            try emitExpr(out, allocator, prim.args[0].*, indent_level, ctx);
            try append(out, allocator, ", ");
            try emitExpr(out, allocator, prim.args[1].*, indent_level, ctx);
            try append(out, allocator, ")");
        },
        .Eq, .Ne, .Lt, .Le, .Gt, .Ge => {
            if (prim.args.len != 2) return error.UnsupportedExpr;
            try append(out, allocator, "prelude.Bool.fromNative((");
            try emitExpr(out, allocator, prim.args[0].*, indent_level, ctx);
            try appendPrint(out, allocator, " {s} ", .{primOpToken(prim.op)});
            try emitExpr(out, allocator, prim.args[1].*, indent_level, ctx);
            try append(out, allocator, "))");
        },
        .Add, .Sub, .Mul => {
            if (prim.args.len != 2) return error.UnsupportedExpr;
            try append(out, allocator, "(");
            try emitExpr(out, allocator, prim.args[0].*, indent_level, ctx);
            try appendPrint(out, allocator, " {s} ", .{primOpToken(prim.op)});
            try emitExpr(out, allocator, prim.args[1].*, indent_level, ctx);
            try append(out, allocator, ")");
        },
    }
}

pub fn emitStringSubExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prim: lir.LPrim,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (prim.args.len != 3) return error.UnsupportedExpr;
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_string_value_{d} = ", .{block_id});
    try emitExpr(out, allocator, prim.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_string_start_{d}: usize = @intCast(", .{block_id});
    try emitExpr(out, allocator, prim.args[1].*, indent_level + 1, ctx);
    try append(out, allocator, ");\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_string_len_{d}: usize = @intCast(", .{block_id});
    try emitExpr(out, allocator, prim.args[2].*, indent_level + 1, ctx);
    try append(out, allocator, ");\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_string_value_{d}[omlz_string_start_{d}..][0..omlz_string_len_{d}];\n", .{ block_id, block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStringConcatExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prim: lir.LPrim,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (prim.args.len != 2) return error.UnsupportedExpr;
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_string_left_{d} = ", .{block_id});
    try emitExpr(out, allocator, prim.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_string_right_{d} = ", .{block_id});
    try emitExpr(out, allocator, prim.args[1].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_string_out_{d}: []u8 = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(u8, omlz_string_left_{d}.len + omlz_string_right_{d}.len, &omlz_string_out_{d});\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "@memcpy(omlz_string_out_{d}[0..omlz_string_left_{d}.len], omlz_string_left_{d});\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "@memcpy(omlz_string_out_{d}[omlz_string_left_{d}.len..], omlz_string_right_{d});\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_string_out_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitCtorExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ctor_expr: lir.LCtor,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (std.mem.eql(u8, ctor_expr.name, "true") or std.mem.eql(u8, ctor_expr.name, "false")) {
        try appendPrint(out, allocator, "prelude.Bool.fromNative({s})", .{ctor_expr.name});
        return;
    }
    const ty_name = if (ctor_expr.type_name) |type_name|
        try zigUserAdtTypeName(allocator, ctor_expr.ty, type_name)
    else
        try zigTypeName(allocator, ctor_expr.ty);
    defer allocator.free(ty_name);
    const variant = if (ctor_expr.type_name != null)
        try userVariantName(allocator, ctor_expr.name)
    else
        try allocator.dupe(u8, try ctorVariantName(ctor_expr.name));
    defer allocator.free(variant);

    if (ctor_expr.type_name != null) {
        if (ctor_expr.args.len == 0) {
            try appendPrint(out, allocator, "{s}{{ .tag = .{s} }}", .{ ty_name, variant });
            return;
        }
        const type_name = ctor_expr.type_name.?;
        const type_decl = findUserTypeDecl(ctx.type_decls, type_name) orelse return error.UnsupportedExpr;
        const variant_info = findUserVariant(ctx.type_decls, type_name, ctor_expr.name) orelse return error.UnsupportedExpr;
        if (variant_info.payload_types.len != ctor_expr.args.len) return error.UnsupportedExpr;

        var needs_block = ctor_expr.args.len > 1;
        for (variant_info.payload_types) |payload_ty| {
            if (isRecursivePayload(payload_ty)) needs_block = true;
        }

        if (!needs_block) {
            try appendPrint(out, allocator, "{s}{{ .tag = .{s}, .payload = .{{ .{s} = ", .{ ty_name, variant, variant });
            try emitExpr(out, allocator, ctor_expr.args[0].*, indent_level, ctx);
            try append(out, allocator, " } }");
            return;
        }

        const block_id = ctx.next_block_id;
        ctx.next_block_id += 1;
        try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
        for (ctor_expr.args, variant_info.payload_types, 0..) |arg, payload_ty, index| {
            if (!isRecursivePayload(payload_ty)) continue;
            const ref = switch (payload_ty) {
                .RecursiveRef => |value| value,
                else => unreachable,
            };
            const child_ty_name = try zigInstantiatedTypeRefName(allocator, ref, type_decl.params, ctor_expr.ty);
            defer allocator.free(child_ty_name);
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "const omlz_recursive_payload_{d}_{d} = arena.allocOneOrTrap({s});\n", .{ block_id, index, child_ty_name });
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "omlz_recursive_payload_{d}_{d}.* = ", .{ block_id, index });
            try emitExpr(out, allocator, arg.*, indent_level + 1, ctx);
            try append(out, allocator, ";\n");
        }
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "break :blk{d} {s}{{ .tag = .{s}, .payload = .{{ .{s} = ", .{ block_id, ty_name, variant, variant });
        if (ctor_expr.args.len == 1) {
            if (isRecursivePayload(variant_info.payload_types[0])) {
                try appendPrint(out, allocator, "omlz_recursive_payload_{d}_0", .{block_id});
            } else {
                try emitExpr(out, allocator, ctor_expr.args[0].*, indent_level + 1, ctx);
            }
        } else {
            try append(out, allocator, ".{ ");
            for (ctor_expr.args, variant_info.payload_types, 0..) |arg, payload_ty, index| {
                if (index != 0) try append(out, allocator, ", ");
                try appendPrint(out, allocator, "._{d} = ", .{index});
                if (isRecursivePayload(payload_ty)) {
                    try appendPrint(out, allocator, "omlz_recursive_payload_{d}_{d}", .{ block_id, index });
                } else {
                    try emitExpr(out, allocator, arg.*, indent_level + 1, ctx);
                }
            }
            try append(out, allocator, " }");
        }
        try append(out, allocator, " } };\n");
        try emitIndent(out, allocator, indent_level);
        try append(out, allocator, "}");
        return;
    }

    if (ctor_expr.args.len == 0) {
        if (std.mem.eql(u8, ctor_expr.name, "[]")) {
            try appendPrint(out, allocator, "{s}.Nil()", .{ty_name});
            return;
        }
        try appendPrint(out, allocator, "{s}.{s}", .{ ty_name, variant });
        return;
    }

    if (std.mem.eql(u8, ctor_expr.name, "::")) {
        try emitConsCtorExpr(out, allocator, ctor_expr, ty_name, indent_level, ctx);
        return;
    }

    if (ctor_expr.args.len != 1) return error.UnsupportedExpr;

    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_ctor_payload_{d} = {s}{{ .{s} = ", .{ block_id, ty_name, variant });
    try emitExpr(out, allocator, ctor_expr.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, " };\n");

    switch (ctor_expr.layout.region) {
        .Arena => {
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "const omlz_ctor_box_{d} = arena.allocOneOrTrap({s});\n", .{ block_id, ty_name });
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "omlz_ctor_box_{d}.* = omlz_ctor_payload_{d};\n", .{ block_id, block_id });
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "break :blk{d} omlz_ctor_box_{d}.*;\n", .{ block_id, block_id });
        },
        .Static, .Stack => {
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "break :blk{d} omlz_ctor_payload_{d};\n", .{ block_id, block_id });
        },
    }

    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitClosureExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    closure: lir.LClosure,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    const code_id = findClosureCodeId(ctx.functions, closure.name) orelse return error.UnsupportedExpr;

    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    if (closure.captures.len > 0) {
        const captures_type_name = try closureCaptureStructName(allocator, closure.name);
        defer allocator.free(captures_type_name);

        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "const omlz_closure_captures_{d} = arena.allocOneOrTrap({s});\n", .{ block_id, captures_type_name });
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "omlz_closure_captures_{d}.* = .{{ ", .{block_id});
        for (closure.captures, 0..) |capture, index| {
            if (index != 0) try append(out, allocator, ", ");
            try append(out, allocator, ".");
            try emitIdentifier(out, allocator, capture.name);
            try append(out, allocator, " = ");
            try emitVariableValue(out, allocator, capture.name, ctx);
        }
        try append(out, allocator, " };\n");
    }
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_closure_slot_{d} = arena.allocOneOrTrap(prelude.Closure);\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    if (closure.captures.len > 0) {
        try appendPrint(out, allocator, "omlz_closure_slot_{d}.* = prelude.Closure.init({d}, omlz_closure_captures_{d});\n", .{ block_id, code_id, block_id });
    } else {
        try appendPrint(out, allocator, "omlz_closure_slot_{d}.* = prelude.Closure.init({d}, null);\n", .{ block_id, code_id });
    }
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "omlz_closure_slot_{d}.self = omlz_closure_slot_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_closure_slot_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn closureCaptureStructName(allocator: std.mem.Allocator, source_name: []const u8) EmitError![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try append(&out, allocator, "omlz_closure_captures_");
    try appendSanitized(&out, allocator, source_name);
    return out.toOwnedSlice(allocator);
}

pub fn emitConsCtorExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ctor_expr: lir.LCtor,
    ty_name: []const u8,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (ctor_expr.args.len != 2) return error.UnsupportedExpr;

    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_list_head_{d} = ", .{block_id});
    try emitExpr(out, allocator, ctor_expr.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_list_tail_{d} = ", .{block_id});
    if (isNilCtor(ctor_expr.args[1].*)) {
        try appendPrint(out, allocator, "{s}.Nil()", .{ty_name});
    } else {
        try emitExpr(out, allocator, ctor_expr.args[1].*, indent_level + 1, ctx);
    }
    try append(out, allocator, ";\n");

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_list_tail_box_{d} = {s}.Box(arena, omlz_list_tail_{d});\n", .{ block_id, ty_name, block_id });

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_ctor_payload_{d} = {s}.ConsFromTailPtr(omlz_list_head_{d}, omlz_list_tail_box_{d});\n", .{ block_id, ty_name, block_id, block_id });

    switch (ctor_expr.layout.region) {
        .Arena => {
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "const omlz_ctor_box_{d} = arena.allocOneOrTrap({s});\n", .{ block_id, ty_name });
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "omlz_ctor_box_{d}.* = omlz_ctor_payload_{d};\n", .{ block_id, block_id });
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "break :blk{d} omlz_ctor_box_{d}.*;\n", .{ block_id, block_id });
        },
        .Static, .Stack => {
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "break :blk{d} omlz_ctor_payload_{d};\n", .{ block_id, block_id });
        },
    }

    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitLetExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    let_expr: lir.LLet,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;

    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    const is_discard = std.mem.eql(u8, let_expr.name, "_");
    var binding_snapshot: ?LetBindingSnapshot = null;
    if (is_discard) {
        try append(out, allocator, "_ = ");
        try emitExpr(out, allocator, let_expr.value.*, indent_level + 1, ctx);
        try append(out, allocator, ";\n");
    } else {
        const storage: LetBindingStorage = switch (let_expr.layout.region) {
            .Arena => .ArenaPointer,
            .Static, .Stack => .Direct,
        };
        const ty_name = try zigLetStorageTypeName(allocator, let_expr);
        defer allocator.free(ty_name);
        switch (let_expr.layout.region) {
            .Arena => {
                try append(out, allocator, "const ");
                try emitIdentifier(out, allocator, let_expr.name);
                try appendPrint(out, allocator, " = arena.allocOneOrTrap({s});\n", .{ty_name});
                try emitIndent(out, allocator, indent_level + 1);
                try emitIdentifier(out, allocator, let_expr.name);
                try append(out, allocator, ".* = ");
                try emitExpr(out, allocator, let_expr.value.*, indent_level + 1, ctx);
                try append(out, allocator, ";\n");
            },
            .Stack => {
                try append(out, allocator, "var ");
                try emitIdentifier(out, allocator, let_expr.name);
                try appendPrint(out, allocator, ": {s} = ", .{ty_name});
                try emitExpr(out, allocator, let_expr.value.*, indent_level + 1, ctx);
                try append(out, allocator, ";\n");
                try emitIndent(out, allocator, indent_level + 1);
                try append(out, allocator, "_ = &");
                try emitIdentifier(out, allocator, let_expr.name);
                try append(out, allocator, ";\n");
            },
            .Static => {
                try append(out, allocator, "const ");
                try emitIdentifier(out, allocator, let_expr.name);
                try append(out, allocator, " = ");
                try emitExpr(out, allocator, let_expr.value.*, indent_level + 1, ctx);
                try append(out, allocator, ";\n");
            },
        }
        binding_snapshot = try pushLetBinding(ctx, let_expr.name, storage);
    }
    defer if (binding_snapshot) |snapshot| restoreLetBinding(ctx, snapshot);
    if (!is_discard and let_expr.layout.region == .Static and !exprUsesName(let_expr.body.*, let_expr.name)) {
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "_ = ");
        try emitIdentifier(out, allocator, let_expr.name);
        try append(out, allocator, ";\n");
    }
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} ", .{block_id});
    try emitExpr(out, allocator, let_expr.body.*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn zigLetStorageTypeName(allocator: std.mem.Allocator, let_expr: lir.LLet) EmitError![]const u8 {
    return switch (let_expr.value.*) {
        .Ctor => |ctor_expr| if (ctor_expr.type_name) |type_name|
            try zigUserAdtTypeName(allocator, ctor_expr.ty, type_name)
        else
            try zigTypeName(allocator, let_expr.ty),
        else => try zigTypeName(allocator, let_expr.ty),
    };
}
