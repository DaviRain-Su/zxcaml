// Part of src/backend/zig_codegen.zig; split by concern.
const common = @import("common.zig");
const std = common.std;
const lir = common.lir;
const EmitError = common.EmitError;
const EmitContext = common.EmitContext;
const TailCallParam = common.TailCallParam;
const LetBindingStorage = common.LetBindingStorage;
const freeEmittedFunctionName = common.freeEmittedFunctionName;
const exprUsesName = common.exprUsesName;
const exprUsesCpiInvoke = common.exprUsesCpiInvoke;
const zigTypeName = common.zigTypeName;
const zigTypeExprName = common.zigTypeExprName;
const payloadTypeName = common.payloadTypeName;
const isAccountTy = common.isAccountTy;
const paramsNeedEntrypointAccountList = common.paramsNeedEntrypointAccountList;
const paramNeedsEntrypointAccounts = common.paramNeedsEntrypointAccounts;
const paramNeedsEntrypointInstructionData = common.paramNeedsEntrypointInstructionData;
const userTypeName = common.userTypeName;
const userVariantName = common.userVariantName;
const typeParamName = common.typeParamName;
const emitIdentifier = common.emitIdentifier;
const append = common.append;
const appendPrint = common.appendPrint;
const expr_emission = @import("expr_emission.zig");
const emitExpr = expr_emission.emitExpr;
const closureCaptureStructName = expr_emission.closureCaptureStructName;

pub fn emitVariantType(out: *std.ArrayList(u8), allocator: std.mem.Allocator, type_decl: lir.LVariantType) EmitError!void {
    const type_name = try userTypeName(allocator, type_decl.name);
    defer allocator.free(type_name);

    if (type_decl.params.len == 0) {
        try appendPrint(out, allocator, "const {s} = struct {{\n", .{type_name});
    } else {
        try appendPrint(out, allocator, "fn {s}(", .{type_name});
        for (type_decl.params, 0..) |param, index| {
            if (index != 0) try append(out, allocator, ", ");
            const param_name = try typeParamName(allocator, param);
            defer allocator.free(param_name);
            try appendPrint(out, allocator, "comptime {s}: type", .{param_name});
        }
        try append(out, allocator, ") type {\n    return struct {\n");
    }
    try append(out, allocator, "    const Self = @This();\n");
    try append(out, allocator, "    const Tag = enum(u32) { ");
    for (type_decl.variants, 0..) |variant, index| {
        if (index != 0) try append(out, allocator, ", ");
        const variant_name = try userVariantName(allocator, variant.name);
        defer allocator.free(variant_name);
        try appendPrint(out, allocator, "{s} = {d}", .{ variant_name, variant.tag });
    }
    try append(out, allocator, " };\n");

    try append(out, allocator, "    const Payload = union { ");
    var payload_count: usize = 0;
    for (type_decl.variants) |variant| {
        if (variant.payload_types.len == 0) continue;
        if (payload_count != 0) try append(out, allocator, ", ");
        const variant_name = try userVariantName(allocator, variant.name);
        defer allocator.free(variant_name);
        const payload_ty = try payloadTypeName(allocator, variant, type_decl.params);
        defer allocator.free(payload_ty);
        try appendPrint(out, allocator, "{s}: {s}", .{ variant_name, payload_ty });
        payload_count += 1;
    }
    if (payload_count == 0) try append(out, allocator, "_none: void");
    try append(out, allocator, " };\n");
    try append(out, allocator, "    tag: Tag,\n");
    try append(out, allocator, "    payload: Payload = undefined,\n\n");

    for (type_decl.variants) |variant| {
        try emitVariantConstructorHelper(out, allocator, variant, type_decl.params);
    }
    if (type_decl.params.len == 0) {
        try append(out, allocator, "};\n");
    } else {
        try append(out, allocator, "    };\n}\n");
    }
}

pub fn emitRecordType(out: *std.ArrayList(u8), allocator: std.mem.Allocator, type_decl: lir.LRecordType) EmitError!void {
    if (std.mem.eql(u8, type_decl.name, "account") and type_decl.params.len == 0) return;
    const type_name = try userTypeName(allocator, type_decl.name);
    defer allocator.free(type_name);
    if (type_decl.params.len == 0) {
        try appendPrint(out, allocator, "const {s} = struct {{\n", .{type_name});
    } else {
        try appendPrint(out, allocator, "fn {s}(", .{type_name});
        for (type_decl.params, 0..) |param, index| {
            if (index != 0) try append(out, allocator, ", ");
            const param_name = try typeParamName(allocator, param);
            defer allocator.free(param_name);
            try appendPrint(out, allocator, "comptime {s}: type", .{param_name});
        }
        try append(out, allocator, ") type {\n    return struct {\n");
    }
    for (type_decl.fields) |field| {
        try append(out, allocator, "    ");
        try emitIdentifier(out, allocator, field.name);
        try append(out, allocator, ": ");
        const ty_name = try zigTypeExprName(allocator, field.ty, type_decl.params);
        defer allocator.free(ty_name);
        try appendPrint(out, allocator, "{s},\n", .{ty_name});
    }
    if (type_decl.params.len == 0) {
        try append(out, allocator, "};\n");
    } else {
        try append(out, allocator, "    };\n}\n");
    }
}

pub fn emitClosureCaptureStructs(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    functions: []const lir.LFunc,
) EmitError!void {
    for (functions) |func| {
        if (func.calling_convention != .Closure or func.captures.len == 0) continue;
        const type_name = try closureCaptureStructName(allocator, func.name);
        defer allocator.free(type_name);
        try appendPrint(out, allocator, "const {s} = struct {{\n", .{type_name});
        for (func.captures) |capture| {
            try append(out, allocator, "    ");
            try emitIdentifier(out, allocator, capture.name);
            try append(out, allocator, ": ");
            const capture_ty = try zigTypeName(allocator, capture.ty);
            defer allocator.free(capture_ty);
            try appendPrint(out, allocator, "{s},\n", .{capture_ty});
        }
        try append(out, allocator, "};\n\n");
    }
}

pub fn emitVariantConstructorHelper(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    variant: lir.LVariantCtor,
    type_params: []const []const u8,
) EmitError!void {
    const variant_name = try userVariantName(allocator, variant.name);
    defer allocator.free(variant_name);

    try appendPrint(out, allocator, "    pub fn {s}(", .{variant_name});
    if (variant.payload_types.len == 1) {
        const payload_ty = try zigTypeExprName(allocator, variant.payload_types[0], type_params);
        defer allocator.free(payload_ty);
        try appendPrint(out, allocator, "value: {s}", .{payload_ty});
    } else if (variant.payload_types.len > 1) {
        const payload_ty = try payloadTypeName(allocator, variant, type_params);
        defer allocator.free(payload_ty);
        try appendPrint(out, allocator, "value: {s}", .{payload_ty});
    }
    try append(out, allocator, ") Self {\n");
    try appendPrint(out, allocator, "        return .{{ .tag = .{s}", .{variant_name});
    if (variant.payload_types.len > 0) {
        try appendPrint(out, allocator, ", .payload = .{{ .{s} = value }}", .{variant_name});
    }
    try append(out, allocator, " };\n");
    try append(out, allocator, "    }\n");
}

pub fn emitFunction(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    func: lir.LFunc,
    functions: []const lir.LFunc,
    type_decls: []const lir.LVariantType,
    record_type_decls: []const lir.LRecordType,
    externals: []const lir.LExternalDecl,
) EmitError!void {
    try append(out, allocator, "// source span: unavailable (M0 frontend bridge does not emit spans yet)\n");
    const is_entrypoint = std.mem.eql(u8, func.name, "entrypoint");
    try append(out, allocator, if (is_entrypoint) "pub inline fn " else "fn ");
    const function_name = switch (func.calling_convention) {
        .ArenaThreaded => try emittedFunctionName(allocator, func.name),
        .Closure => try emittedClosureFunctionName(allocator, func.name),
    };
    defer freeEmittedFunctionName(allocator, func.name, function_name);
    try append(out, allocator, function_name);
    try append(out, allocator, "(arena: *Arena");
    if (is_entrypoint) {
        try append(out, allocator, ", omlz_runtime_input: [*]u8, omlz_runtime_accounts: []AccountRuntime.AccountView, omlz_runtime_instruction_data: []const u8) u64 {\n");
    } else {
        if (func.calling_convention == .Closure) {
            try append(out, allocator, ", closure: *const prelude.Closure");
        }
        for (func.params) |param| {
            try append(out, allocator, ", ");
            try emitIdentifier(out, allocator, param.name);
            try append(out, allocator, ": ");
            const ty_name = try zigTypeName(allocator, param.ty);
            defer allocator.free(ty_name);
            try append(out, allocator, ty_name);
        }
        const return_ty = try zigTypeName(allocator, func.return_ty);
        defer allocator.free(return_ty);
        try appendPrint(out, allocator, ") {s} {{\n", .{return_ty});
    }
    var body_out = std.ArrayList(u8).empty;
    defer body_out.deinit(allocator);
    var hoisted_decls = std.ArrayList(u8).empty;
    defer hoisted_decls.deinit(allocator);
    var let_bindings = std.StringHashMap(LetBindingStorage).init(allocator);
    defer let_bindings.deinit();
    const uses_tco = functionHasSelfTailCall(func);
    const tco_params = if (uses_tco) try tailCallParams(allocator, func.params) else &.{};
    defer {
        if (uses_tco) {
            for (tco_params) |param| allocator.free(param.local_name);
            allocator.free(tco_params);
        }
    }
    var ctx: EmitContext = .{ .is_entrypoint = is_entrypoint, .functions = functions, .type_decls = type_decls, .record_type_decls = record_type_decls, .externals = externals };
    ctx.hoisted_decls = &hoisted_decls;
    ctx.let_bindings = &let_bindings;
    if (uses_tco) {
        ctx.tco_function_name = func.name;
        ctx.tco_params = tco_params;
    }
    try emitExpr(&body_out, allocator, func.body, 1, &ctx);
    const entrypoint_needs_account_list = is_entrypoint and paramsNeedEntrypointAccountList(func.params);
    const function_uses_arena = sourceUsesArena(body_out.items) or sourceUsesArena(hoisted_decls.items);
    if (!function_uses_arena and !entrypoint_needs_account_list) {
        try append(out, allocator, "    _ = arena;\n");
    }
    if (is_entrypoint) {
        const bindings = try emitEntrypointRuntimeBindings(out, allocator, func.params, func.body);
        const uses_runtime_cpi = exprUsesCpiInvoke(func.body);
        if (!uses_runtime_cpi) try append(out, allocator, "    _ = omlz_runtime_input;\n");
        if (!bindings.accounts_used and !uses_runtime_cpi) try append(out, allocator, "    _ = omlz_runtime_accounts;\n");
        if (!bindings.instruction_data_used) try append(out, allocator, "    _ = omlz_runtime_instruction_data;\n");
    }
    if (func.calling_convention == .Closure) {
        try emitClosureCaptureBindings(out, allocator, func.name, func.captures);
    }
    try append(out, allocator, hoisted_decls.items);
    if (uses_tco) {
        try emitTailCallParamLocals(out, allocator, func.params, tco_params);
        try append(out, allocator, "    while (true) {\n");
        try append(out, allocator, if (is_entrypoint) "        return @intCast(" else "        return ");
        try append(out, allocator, body_out.items);
        try append(out, allocator, if (is_entrypoint) ");\n" else ";\n");
        try append(out, allocator, "    }\n");
        try append(out, allocator, "    unreachable;\n");
    } else {
        try append(out, allocator, if (is_entrypoint) "    return @intCast(" else "    return ");
        try append(out, allocator, body_out.items);
        try append(out, allocator, if (is_entrypoint) ");\n" else ";\n");
    }
    try append(out, allocator, "}\n");
}

pub fn sourceUsesArena(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "arena.") != null or
        std.mem.indexOf(u8, source, "arena,") != null or
        std.mem.indexOf(u8, source, "arena)") != null or
        std.mem.indexOf(u8, source, "arena;") != null;
}

pub fn functionHasSelfTailCall(func: lir.LFunc) bool {
    return exprHasSelfTailCall(func.body, func.name);
}

pub fn exprHasSelfTailCall(expr: lir.LExpr, function_name: []const u8) bool {
    return switch (expr) {
        .App => |app| blk: {
            if (app.is_tail_call) {
                switch (app.callee.*) {
                    .Var => |callee| if (std.mem.eql(u8, callee.name, function_name)) break :blk true,
                    else => {},
                }
            }
            if (exprHasSelfTailCall(app.callee.*, function_name)) break :blk true;
            for (app.args) |arg| {
                if (exprHasSelfTailCall(arg.*, function_name)) break :blk true;
            }
            break :blk false;
        },
        .Let => |let_expr| exprHasSelfTailCall(let_expr.value.*, function_name) or exprHasSelfTailCall(let_expr.body.*, function_name),
        .Assert => |assert_expr| exprHasSelfTailCall(assert_expr.condition.*, function_name),
        .If => |if_expr| exprHasSelfTailCall(if_expr.cond.*, function_name) or
            exprHasSelfTailCall(if_expr.then_branch.*, function_name) or
            exprHasSelfTailCall(if_expr.else_branch.*, function_name),
        .Prim => |prim| blk: {
            for (prim.args) |arg| {
                if (exprHasSelfTailCall(arg.*, function_name)) break :blk true;
            }
            break :blk false;
        },
        .Ctor => |ctor| blk: {
            for (ctor.args) |arg| {
                if (exprHasSelfTailCall(arg.*, function_name)) break :blk true;
            }
            break :blk false;
        },
        .Match => |match_expr| blk: {
            if (exprHasSelfTailCall(match_expr.scrutinee.*, function_name)) break :blk true;
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| {
                    if (exprHasSelfTailCall(guard.*, function_name)) break :blk true;
                }
                if (exprHasSelfTailCall(arm.body.*, function_name)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple_expr| blk: {
            for (tuple_expr.items) |item| {
                if (exprHasSelfTailCall(item.*, function_name)) break :blk true;
            }
            break :blk false;
        },
        .TupleProj => |tuple_proj| exprHasSelfTailCall(tuple_proj.tuple_expr.*, function_name),
        .Record => |record_expr| blk: {
            for (record_expr.fields) |field| {
                if (exprHasSelfTailCall(field.value.*, function_name)) break :blk true;
            }
            break :blk false;
        },
        .RecordField => |record_field| exprHasSelfTailCall(record_field.record_expr.*, function_name),
        .RecordUpdate => |record_update| blk: {
            if (exprHasSelfTailCall(record_update.base_expr.*, function_name)) break :blk true;
            for (record_update.fields) |field| {
                if (exprHasSelfTailCall(field.value.*, function_name)) break :blk true;
            }
            break :blk false;
        },
        .AccountFieldSet => |field_set| exprHasSelfTailCall(field_set.account_expr.*, function_name) or
            exprHasSelfTailCall(field_set.value.*, function_name),
        .Constant, .Var, .Closure => false,
    };
}

pub fn tailCallParams(allocator: std.mem.Allocator, params: []const lir.LParam) EmitError![]const TailCallParam {
    const aliases = try allocator.alloc(TailCallParam, params.len);
    for (params, 0..) |param, index| {
        aliases[index] = .{
            .source_name = param.name,
            .local_name = try tailCallParamLocalName(allocator, param.name),
        };
    }
    return aliases;
}

pub fn tailCallParamLocalName(allocator: std.mem.Allocator, source_name: []const u8) EmitError![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try append(&out, allocator, "omlz_tco_");
    for (source_name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '_');
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn emitTailCallParamLocals(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    params: []const lir.LParam,
    aliases: []const TailCallParam,
) EmitError!void {
    for (params, aliases) |param, alias| {
        const ty_name = try zigTypeName(allocator, param.ty);
        defer allocator.free(ty_name);
        try appendPrint(out, allocator, "    var {s}: {s} = ", .{ alias.local_name, ty_name });
        try emitIdentifier(out, allocator, param.name);
        try append(out, allocator, ";\n");
    }
}

pub fn emitBuiltinAccountRecordType(out: *std.ArrayList(u8), allocator: std.mem.Allocator) EmitError!void {
    try append(out, allocator,
        \\const omlz_type_account = struct {
        \\    key: []const u8,
        \\    lamports: i64,
        \\    data: []const u8,
        \\    owner: []const u8,
        \\    is_signer: prelude.Bool,
        \\    is_writable: prelude.Bool,
        \\    executable: prelude.Bool,
        \\};
        \\
    );
}

pub fn emitAccountViewHelper(out: *std.ArrayList(u8), allocator: std.mem.Allocator) EmitError!void {
    try append(out, allocator,
        \\fn omlz_log_account_view(view: AccountRuntime.AccountView) void {
        \\    const hex = "0123456789abcdef";
        \\    var key_hex: [64]u8 = undefined;
        \\    for (view.key.*, 0..) |byte, index| {
        \\        key_hex[index * 2] = hex[byte >> 4];
        \\        key_hex[index * 2 + 1] = hex[byte & 0x0f];
        \\    }
        \\    syscalls.sol_log_(key_hex[0..]);
        \\    syscalls.sol_log_64_(@intCast(view.lamportsValue()), 0, 0, 0, 0);
        \\}
        \\
    );
}

pub const EntrypointRuntimeBindings = struct {
    accounts_used: bool = false,
    instruction_data_used: bool = false,
};

pub fn emitEntrypointRuntimeBindings(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    params: []const lir.LParam,
    body: lir.LExpr,
) EmitError!EntrypointRuntimeBindings {
    var bindings: EntrypointRuntimeBindings = .{};
    var account_index: usize = 0;
    for (params) |param| {
        if (paramNeedsEntrypointInstructionData(param)) {
            bindings.instruction_data_used = true;
            try append(out, allocator, "    const ");
            try emitIdentifier(out, allocator, param.name);
            try append(out, allocator, " = omlz_runtime_instruction_data;\n");
            if (!exprUsesName(body, param.name)) {
                try append(out, allocator, "    _ = ");
                try emitIdentifier(out, allocator, param.name);
                try append(out, allocator, ";\n");
            }
            continue;
        }
        if (!paramNeedsEntrypointAccounts(param)) continue;
        bindings.accounts_used = true;
        if (isAccountTy(param.ty)) {
            try append(out, allocator, "    const ");
            try emitIdentifier(out, allocator, param.name);
            try appendPrint(out, allocator, " = if (omlz_runtime_accounts.len > {d}) omlz_runtime_accounts[{d}] else return 1;\n", .{ account_index, account_index });
            if (!exprUsesName(body, param.name)) {
                try append(out, allocator, "    _ = ");
                try emitIdentifier(out, allocator, param.name);
                try append(out, allocator, ";\n");
            }
            account_index += 1;
        } else {
            try append(out, allocator, "    for (omlz_runtime_accounts) |omlz_entry_account| omlz_log_account_view(omlz_entry_account);\n");
            try append(out, allocator, "    const ");
            try emitIdentifier(out, allocator, param.name);
            try append(out, allocator, " = @as(i64, 0);\n");
            if (!exprUsesName(body, param.name)) {
                try append(out, allocator, "    _ = ");
                try emitIdentifier(out, allocator, param.name);
                try append(out, allocator, ";\n");
            }
        }
    }
    return bindings;
}

pub fn emittedFunctionName(allocator: std.mem.Allocator, source_name: []const u8) EmitError![]const u8 {
    if (std.mem.eql(u8, source_name, "entrypoint")) {
        return "omlz_user_entrypoint";
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try append(&out, allocator, "omlz_user_");
    for (source_name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '_');
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn emittedClosureFunctionName(allocator: std.mem.Allocator, source_name: []const u8) EmitError![]const u8 {
    const base = try emittedFunctionName(allocator, source_name);
    defer freeEmittedFunctionName(allocator, source_name, base);
    return std.fmt.allocPrint(allocator, "{s}__closure", .{base});
}

pub fn emitClosureCaptureBindings(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    func_name: []const u8,
    captures: []const lir.LParam,
) EmitError!void {
    if (captures.len == 0) try append(out, allocator, "    _ = closure;\n");
    if (captures.len == 0) return;

    const type_name = try closureCaptureStructName(allocator, func_name);
    defer allocator.free(type_name);
    try appendPrint(out, allocator, "    const omlz_captures: *const {s} = @ptrCast(@alignCast(closure.captures.?));\n", .{type_name});
    for (captures) |capture| {
        try append(out, allocator, "    const ");
        try emitIdentifier(out, allocator, capture.name);
        try append(out, allocator, " = omlz_captures.");
        try emitIdentifier(out, allocator, capture.name);
        try append(out, allocator, ";\n");
    }
}
