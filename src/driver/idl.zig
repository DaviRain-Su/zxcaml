//! JSON IDL emitter for the `omlz idl` driver command.
//!
//! RESPONSIBILITIES:
//! - Describe the public Solana instruction surface discovered in Core IR.
//! - Emit deterministic JSON for instruction discriminators, account requirements, arguments, types, and errors.
//! - Emit Anchor 0.30+ compatible IDL JSON for ecosystem tooling.

const std = @import("std");
const ir = @import("../core/ir.zig");
const types = @import("../core/types.zig");

const default_program_id = "11111111111111111111111111111111";
const anchor_spec_version = "0.1.0";
const program_version = "0.1.0";

/// Options that control top-level IDL metadata.
pub const EmitOptions = struct {
    program_name: []const u8,
    program_id: ?[]const u8 = null,
};

/// Emits a deterministic JSON IDL document for a lowered Core IR module.
pub fn emitModule(allocator: std.mem.Allocator, module: ir.Module, options: EmitOptions) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    const program_id = options.program_id orelse findProgramId(module) orelse default_program_id;

    try append(&out, allocator, "{\"address\":");
    try appendJsonString(&out, allocator, program_id);
    try append(&out, allocator, ",\"metadata\":{\"name\":");
    try appendJsonString(&out, allocator, options.program_name);
    try append(&out, allocator, ",\"version\":");
    try appendJsonString(&out, allocator, program_version);
    try append(&out, allocator, ",\"spec\":");
    try appendJsonString(&out, allocator, anchor_spec_version);
    try append(&out, allocator, "},\"instructions\":[");
    try emitInstructions(&out, allocator, module);
    try append(&out, allocator, "],\"accounts\":[");
    try emitAccounts(&out, allocator, module);
    try append(&out, allocator, "],\"types\":[");
    try emitTypes(&out, allocator, module);
    try append(&out, allocator, "],\"events\":[],\"errors\":[");
    try emitErrors(&out, allocator, module);
    try append(&out, allocator, "],\"constants\":[]}");

    return out.toOwnedSlice(allocator);
}

fn emitInstructions(out: *std.ArrayList(u8), allocator: std.mem.Allocator, module: ir.Module) !void {
    var first_instruction = true;
    for (module.decls) |decl| {
        const let_decl = switch (decl) {
            .Let => |value| value,
        };
        if (!std.mem.eql(u8, let_decl.name, "entrypoint")) continue;
        const lambda = switch (let_decl.value.*) {
            .Lambda => |value| value,
            else => continue,
        };

        if (!first_instruction) try append(out, allocator, ",");
        first_instruction = false;

        try append(out, allocator, "{\"name\":");
        try appendJsonString(out, allocator, let_decl.name);
        try append(out, allocator, ",\"discriminator\":");
        try emitDiscriminator(out, allocator, "global:", let_decl.name);
        try append(out, allocator, ",\"accounts\":[");
        try emitInstructionAccounts(out, allocator, lambda);
        try append(out, allocator, "],\"args\":[");
        try emitInstructionArgs(out, allocator, lambda);
        try append(out, allocator, "]}");
    }
}

fn emitInstructionAccounts(out: *std.ArrayList(u8), allocator: std.mem.Allocator, lambda: ir.Lambda) !void {
    var first = true;
    for (lambda.params) |param| {
        if (!isAccountTy(param.ty)) continue;
        if (!first) try append(out, allocator, ",");
        first = false;

        const signer = accountFlagReferenced(lambda.body.*, param.name, "is_signer");
        const writable = accountParamMutated(lambda.body.*, param.name) or
            accountFlagReferenced(lambda.body.*, param.name, "is_writable");

        try append(out, allocator, "{\"name\":");
        try appendJsonString(out, allocator, param.name);
        try append(out, allocator, ",\"writable\":");
        try append(out, allocator, if (writable) "true" else "false");
        try append(out, allocator, ",\"signer\":");
        try append(out, allocator, if (signer) "true" else "false");
        try append(out, allocator, "}");
    }
}

fn emitInstructionArgs(out: *std.ArrayList(u8), allocator: std.mem.Allocator, lambda: ir.Lambda) !void {
    var first = true;
    for (lambda.params) |param| {
        if (isAccountTy(param.ty) or isUnitTy(param.ty)) continue;
        if (!first) try append(out, allocator, ",");
        first = false;

        try append(out, allocator, "{\"name\":");
        try appendJsonString(out, allocator, param.name);
        try append(out, allocator, ",\"type\":");
        try emitAnchorTy(out, allocator, param.ty);
        try append(out, allocator, "}");
    }
}

fn emitDiscriminator(out: *std.ArrayList(u8), allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) !void {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(prefix);
    hasher.update(name);
    hasher.final(&digest);

    try append(out, allocator, "[");
    for (0..8) |index| {
        if (index != 0) try append(out, allocator, ",");
        try appendPrint(out, allocator, "{d}", .{digest[index]});
    }
    try append(out, allocator, "]");
}

fn emitAccounts(out: *std.ArrayList(u8), allocator: std.mem.Allocator, module: ir.Module) !void {
    var first = true;
    for (module.record_type_decls) |type_decl| {
        if (!type_decl.is_account or isBuiltinRecordType(type_decl.name)) continue;
        if (!first) try append(out, allocator, ",");
        first = false;

        try append(out, allocator, "{\"name\":");
        try appendJsonString(out, allocator, type_decl.name);
        try append(out, allocator, ",\"discriminator\":");
        try emitDiscriminator(out, allocator, "account:", type_decl.name);
        try append(out, allocator, "}");
    }
}

fn emitTypes(out: *std.ArrayList(u8), allocator: std.mem.Allocator, module: ir.Module) !void {
    var first = true;
    for (module.type_decls) |type_decl| {
        if (!first) try append(out, allocator, ",");
        first = false;
        try emitVariantType(out, allocator, type_decl);
    }
    for (module.tuple_type_decls) |type_decl| {
        if (!first) try append(out, allocator, ",");
        first = false;
        try emitTupleType(out, allocator, type_decl);
    }
    for (module.record_type_decls) |type_decl| {
        if (isBuiltinRecordType(type_decl.name)) continue;
        if (!first) try append(out, allocator, ",");
        first = false;
        try emitRecordType(out, allocator, type_decl);
    }
}

fn emitVariantType(out: *std.ArrayList(u8), allocator: std.mem.Allocator, type_decl: types.VariantType) !void {
    try append(out, allocator, "{\"name\":");
    try appendJsonString(out, allocator, type_decl.name);
    try append(out, allocator, ",\"type\":{\"kind\":\"enum\",\"variants\":[");
    for (type_decl.variants, 0..) |variant, index| {
        if (index != 0) try append(out, allocator, ",");
        try append(out, allocator, "{\"name\":");
        try appendJsonString(out, allocator, variant.name);
        if (variant.payload_types.len != 0) {
            try append(out, allocator, ",\"fields\":[");
        }
        for (variant.payload_types, 0..) |payload_ty, payload_index| {
            if (payload_index != 0) try append(out, allocator, ",");
            try append(out, allocator, "{\"name\":");
            const field_name = try std.fmt.allocPrint(allocator, "field{d}", .{payload_index});
            defer allocator.free(field_name);
            try appendJsonString(out, allocator, field_name);
            try append(out, allocator, ",\"type\":");
            try emitAnchorTypeExpr(out, allocator, payload_ty);
            try append(out, allocator, "}");
        }
        if (variant.payload_types.len != 0) {
            try append(out, allocator, "]");
        }
        try append(out, allocator, "}");
    }
    try append(out, allocator, "]}}");
}

fn emitTupleType(out: *std.ArrayList(u8), allocator: std.mem.Allocator, type_decl: types.TupleType) !void {
    try append(out, allocator, "{\"name\":");
    try appendJsonString(out, allocator, type_decl.name);
    try append(out, allocator, ",\"type\":{\"kind\":\"struct\",\"fields\":[");
    for (type_decl.items, 0..) |item, index| {
        if (index != 0) try append(out, allocator, ",");
        try append(out, allocator, "{\"name\":");
        const field_name = try std.fmt.allocPrint(allocator, "item{d}", .{index});
        defer allocator.free(field_name);
        try appendJsonString(out, allocator, field_name);
        try append(out, allocator, ",\"type\":");
        try emitAnchorTypeExpr(out, allocator, item);
        try append(out, allocator, "}");
    }
    try append(out, allocator, "]}}");
}

fn emitRecordType(out: *std.ArrayList(u8), allocator: std.mem.Allocator, type_decl: types.RecordType) !void {
    try append(out, allocator, "{\"name\":");
    try appendJsonString(out, allocator, type_decl.name);
    try append(out, allocator, ",\"type\":{\"kind\":\"struct\",\"fields\":[");
    for (type_decl.fields, 0..) |field, index| {
        if (index != 0) try append(out, allocator, ",");

        try append(out, allocator, "{\"name\":");
        try appendJsonString(out, allocator, field.name);
        try append(out, allocator, ",\"type\":");
        try emitAnchorTypeExpr(out, allocator, field.ty);
        try append(out, allocator, "}");
    }
    try append(out, allocator, "]}}");
}

fn emitErrors(out: *std.ArrayList(u8), allocator: std.mem.Allocator, module: ir.Module) !void {
    var first = true;
    for (module.decls) |decl| {
        const let_decl = switch (decl) {
            .Let => |value| value,
        };
        if (!std.mem.startsWith(u8, let_decl.name, "error_")) continue;
        const code = switch (let_decl.value.*) {
            .Constant => |constant| switch (constant.value) {
                .Int => |value| value,
                .String => continue,
            },
            else => continue,
        };
        if (!first) try append(out, allocator, ",");
        first = false;
        try append(out, allocator, "{\"name\":");
        try appendJsonString(out, allocator, let_decl.name);
        try appendPrint(out, allocator, ",\"code\":{d}}}", .{code});
    }
}

fn findProgramId(module: ir.Module) ?[]const u8 {
    for (module.decls) |decl| {
        const let_decl = switch (decl) {
            .Let => |value| value,
        };
        if (!std.mem.eql(u8, let_decl.name, "program_id")) continue;
        return switch (let_decl.value.*) {
            .Constant => |constant| switch (constant.value) {
                .String => |value| value,
                .Int => null,
            },
            else => null,
        };
    }
    return null;
}

fn emitAnchorTy(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ty: ir.Ty) anyerror!void {
    switch (ty) {
        .Int => try append(out, allocator, "\"i64\""),
        .Bool => try append(out, allocator, "\"bool\""),
        .Unit => try append(out, allocator, "\"unit\""),
        .String => try append(out, allocator, "\"bytes\""),
        .Var => |name| try appendJsonString(out, allocator, name),
        .Record => |record| {
            try emitDefinedType(out, allocator, record.name);
        },
        .Adt => |adt| {
            if (std.mem.eql(u8, adt.name, "option") and adt.params.len == 1) {
                try append(out, allocator, "{\"option\":");
                try emitAnchorTy(out, allocator, adt.params[0]);
                try append(out, allocator, "}");
            } else if (std.mem.eql(u8, adt.name, "list") and adt.params.len == 1) {
                try append(out, allocator, "{\"vec\":");
                try emitAnchorTy(out, allocator, adt.params[0]);
                try append(out, allocator, "}");
            } else {
                try emitDefinedType(out, allocator, adt.name);
            }
        },
        .Tuple => |items| {
            try append(out, allocator, "{\"tuple\":[");
            for (items, 0..) |item, index| {
                if (index != 0) try append(out, allocator, ",");
                try emitAnchorTy(out, allocator, item);
            }
            try append(out, allocator, "]}");
        },
        .Arrow => |arrow| {
            try append(out, allocator, "{\"defined\":{\"name\":\"fn\",\"generics\":[");
            for (arrow.params, 0..) |param_ty, index| {
                if (index != 0) try append(out, allocator, ",");
                try emitAnchorTy(out, allocator, param_ty);
            }
            if (arrow.params.len != 0) try append(out, allocator, ",");
            try emitAnchorTy(out, allocator, arrow.ret.*);
            try append(out, allocator, "]}}");
        },
    }
}

fn emitAnchorTypeExpr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, expr: types.TypeExpr) anyerror!void {
    switch (expr) {
        .TypeVar => |name| try appendJsonString(out, allocator, name),
        .TypeRef => |ref| try emitAnchorTypeRef(out, allocator, ref),
        .RecursiveRef => |ref| try emitAnchorTypeRef(out, allocator, ref),
        .Tuple => |items| {
            try append(out, allocator, "{\"tuple\":[");
            for (items, 0..) |item, index| {
                if (index != 0) try append(out, allocator, ",");
                try emitAnchorTypeExpr(out, allocator, item);
            }
            try append(out, allocator, "]}");
        },
    }
}

fn emitAnchorTypeRef(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ref: types.TypeRef) anyerror!void {
    if (std.mem.eql(u8, ref.name, "int")) return append(out, allocator, "\"i64\"");
    if (std.mem.eql(u8, ref.name, "bool")) return append(out, allocator, "\"bool\"");
    if (std.mem.eql(u8, ref.name, "unit")) return append(out, allocator, "\"unit\"");
    if (std.mem.eql(u8, ref.name, "bytes") or std.mem.eql(u8, ref.name, "string")) return append(out, allocator, "\"bytes\"");
    if (std.mem.eql(u8, ref.name, "pubkey") or std.mem.eql(u8, ref.name, "Pubkey.t")) return append(out, allocator, "\"pubkey\"");

    if (std.mem.eql(u8, ref.name, "option") and ref.args.len == 1) {
        try append(out, allocator, "{\"option\":");
        try emitAnchorTypeExpr(out, allocator, ref.args[0]);
        try append(out, allocator, "}");
        return;
    }

    if ((std.mem.eql(u8, ref.name, "list") or std.mem.eql(u8, ref.name, "array")) and ref.args.len == 1) {
        try append(out, allocator, "{\"vec\":");
        try emitAnchorTypeExpr(out, allocator, ref.args[0]);
        try append(out, allocator, "}");
        return;
    }

    try emitDefinedType(out, allocator, ref.name);
}

fn emitDefinedType(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    try append(out, allocator, "{\"defined\":{\"name\":");
    try appendJsonString(out, allocator, name);
    try append(out, allocator, "}}");
}

fn isBuiltinRecordType(name: []const u8) bool {
    return std.mem.eql(u8, name, "account") or
        std.mem.eql(u8, name, "account_meta") or
        std.mem.eql(u8, name, "instruction");
}

fn isAccountTy(ty: ir.Ty) bool {
    const record = switch (ty) {
        .Record => |value| value,
        else => return false,
    };
    return std.mem.eql(u8, record.name, "account") and record.params.len == 0;
}

fn isUnitTy(ty: ir.Ty) bool {
    return switch (ty) {
        .Unit => true,
        else => false,
    };
}

fn accountFlagReferenced(expr: ir.Expr, param_name: []const u8, flag_name: []const u8) bool {
    return switch (expr) {
        .RecordField => |field| (std.mem.eql(u8, field.field_name, flag_name) and exprIsVarNamed(field.record_expr.*, param_name)) or
            accountFlagReferenced(field.record_expr.*, param_name, flag_name),
        .AccountFieldSet => |field_set| accountFlagReferenced(field_set.account_expr.*, param_name, flag_name) or
            accountFlagReferenced(field_set.value.*, param_name, flag_name),
        .Lambda => |lambda| !paramShadows(lambda.params, param_name) and accountFlagReferenced(lambda.body.*, param_name, flag_name),
        .Let => |let_expr| accountFlagReferenced(let_expr.value.*, param_name, flag_name) or
            (!std.mem.eql(u8, let_expr.name, param_name) and accountFlagReferenced(let_expr.body.*, param_name, flag_name)),
        .App => |app| exprSliceFlagReferenced(app.args, param_name, flag_name) or accountFlagReferenced(app.callee.*, param_name, flag_name),
        .If => |if_expr| accountFlagReferenced(if_expr.cond.*, param_name, flag_name) or
            accountFlagReferenced(if_expr.then_branch.*, param_name, flag_name) or
            accountFlagReferenced(if_expr.else_branch.*, param_name, flag_name),
        .Prim => |prim| exprSliceFlagReferenced(prim.args, param_name, flag_name),
        .Ctor => |ctor| exprSliceFlagReferenced(ctor.args, param_name, flag_name),
        .Match => |match_expr| blk: {
            if (accountFlagReferenced(match_expr.scrutinee.*, param_name, flag_name)) break :blk true;
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| {
                    if (accountFlagReferenced(guard.*, param_name, flag_name)) break :blk true;
                }
                if (!patternBindsName(arm.pattern, param_name) and accountFlagReferenced(arm.body.*, param_name, flag_name)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple| exprSliceFlagReferenced(tuple.items, param_name, flag_name),
        .TupleProj => |tuple_proj| accountFlagReferenced(tuple_proj.tuple_expr.*, param_name, flag_name),
        .Record => |record| recordFieldsFlagReferenced(record.fields, param_name, flag_name),
        .RecordUpdate => |record_update| accountFlagReferenced(record_update.base_expr.*, param_name, flag_name) or
            recordFieldsFlagReferenced(record_update.fields, param_name, flag_name),
        .Constant, .Var => false,
    };
}

fn exprSliceFlagReferenced(exprs: []const *const ir.Expr, param_name: []const u8, flag_name: []const u8) bool {
    for (exprs) |expr| {
        if (accountFlagReferenced(expr.*, param_name, flag_name)) return true;
    }
    return false;
}

fn recordFieldsFlagReferenced(fields: []const ir.RecordExprField, param_name: []const u8, flag_name: []const u8) bool {
    for (fields) |field| {
        if (accountFlagReferenced(field.value.*, param_name, flag_name)) return true;
    }
    return false;
}

fn accountParamMutated(expr: ir.Expr, param_name: []const u8) bool {
    return switch (expr) {
        .AccountFieldSet => |field_set| (exprIsVarNamed(field_set.account_expr.*, param_name) and isWritableAccountField(field_set.field_name)) or
            accountParamMutated(field_set.account_expr.*, param_name) or
            accountParamMutated(field_set.value.*, param_name),
        .Lambda => |lambda| !paramShadows(lambda.params, param_name) and accountParamMutated(lambda.body.*, param_name),
        .Let => |let_expr| accountParamMutated(let_expr.value.*, param_name) or
            (!std.mem.eql(u8, let_expr.name, param_name) and accountParamMutated(let_expr.body.*, param_name)),
        .App => |app| exprSliceMutatesAccount(app.args, param_name) or accountParamMutated(app.callee.*, param_name),
        .If => |if_expr| accountParamMutated(if_expr.cond.*, param_name) or
            accountParamMutated(if_expr.then_branch.*, param_name) or
            accountParamMutated(if_expr.else_branch.*, param_name),
        .Prim => |prim| exprSliceMutatesAccount(prim.args, param_name),
        .Ctor => |ctor| exprSliceMutatesAccount(ctor.args, param_name),
        .Match => |match_expr| blk: {
            if (accountParamMutated(match_expr.scrutinee.*, param_name)) break :blk true;
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| {
                    if (accountParamMutated(guard.*, param_name)) break :blk true;
                }
                if (!patternBindsName(arm.pattern, param_name) and accountParamMutated(arm.body.*, param_name)) break :blk true;
            }
            break :blk false;
        },
        .Tuple => |tuple| exprSliceMutatesAccount(tuple.items, param_name),
        .TupleProj => |tuple_proj| accountParamMutated(tuple_proj.tuple_expr.*, param_name),
        .Record => |record| recordFieldsMutateAccount(record.fields, param_name),
        .RecordField => |field| accountParamMutated(field.record_expr.*, param_name),
        .RecordUpdate => |record_update| accountParamMutated(record_update.base_expr.*, param_name) or
            recordFieldsMutateAccount(record_update.fields, param_name),
        .Constant, .Var => false,
    };
}

fn exprSliceMutatesAccount(exprs: []const *const ir.Expr, param_name: []const u8) bool {
    for (exprs) |expr| {
        if (accountParamMutated(expr.*, param_name)) return true;
    }
    return false;
}

fn recordFieldsMutateAccount(fields: []const ir.RecordExprField, param_name: []const u8) bool {
    for (fields) |field| {
        if (accountParamMutated(field.value.*, param_name)) return true;
    }
    return false;
}

fn isWritableAccountField(field_name: []const u8) bool {
    return std.mem.eql(u8, field_name, "lamports") or std.mem.eql(u8, field_name, "data");
}

fn exprIsVarNamed(expr: ir.Expr, name: []const u8) bool {
    return switch (expr) {
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        else => false,
    };
}

fn paramShadows(params: []const ir.Param, name: []const u8) bool {
    for (params) |param| {
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn patternBindsName(pattern: ir.Pattern, name: []const u8) bool {
    return switch (pattern) {
        .Var => |var_pattern| std.mem.eql(u8, var_pattern.name, name),
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
        .Wildcard => false,
    };
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try append(out, allocator, "\"");
    for (value) |byte| {
        switch (byte) {
            '"' => try append(out, allocator, "\\\""),
            '\\' => try append(out, allocator, "\\\\"),
            '\n' => try append(out, allocator, "\\n"),
            '\r' => try append(out, allocator, "\\r"),
            '\t' => try append(out, allocator, "\\t"),
            0...8, 11...12, 14...0x1f => {
                const hex = "0123456789abcdef";
                try append(out, allocator, "\\u00");
                try out.append(allocator, hex[byte >> 4]);
                try out.append(allocator, hex[byte & 0x0f]);
            },
            else => try out.append(allocator, byte),
        }
    }
    try append(out, allocator, "\"");
}

fn append(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try out.appendSlice(allocator, bytes);
}

fn appendPrint(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const bytes = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(bytes);
    try append(out, allocator, bytes);
}

test "IDL emitter keeps modules without entrypoints valid" {
    const json = try emitModule(std.testing.allocator, .{
        .decls = &.{},
        .type_decls = &.{},
        .tuple_type_decls = &.{},
        .record_type_decls = &.{},
    }, .{ .program_name = "empty" });
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"address\":\"11111111111111111111111111111111\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"metadata\":{\"name\":\"empty\",\"version\":\"0.1.0\",\"spec\":\"0.1.0\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"instructions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"accounts\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"types\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"events\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"errors\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"constants\":[]") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
}

test "IDL emitter maps records, variants, options, and Anchor discriminators" {
    const int_ref = types.TypeExpr{ .TypeRef = .{ .name = "int" } };
    const bool_ref = types.TypeExpr{ .TypeRef = .{ .name = "bool" } };
    const option_args = [_]types.TypeExpr{bool_ref};
    const option_ref = types.TypeExpr{ .TypeRef = .{ .name = "option", .args = option_args[0..] } };
    const variant_payload = [_]types.TypeExpr{int_ref};
    const variant_ctors = [_]types.VariantCtor{
        .{ .name = "Ready", .tag = 0 },
        .{ .name = "Frozen", .tag = 1, .payload_types = variant_payload[0..] },
    };
    const record_fields = [_]types.RecordField{
        .{ .name = "balance", .ty = int_ref },
        .{ .name = "enabled", .ty = option_ref },
    };
    const metadata_fields = [_]types.RecordField{
        .{ .name = "authority", .ty = .{ .TypeRef = .{ .name = "bytes" } } },
    };
    const variant_types = [_]types.VariantType{
        .{ .name = "status", .variants = variant_ctors[0..] },
    };
    const record_types = [_]types.RecordType{
        .{ .name = "vault", .fields = record_fields[0..], .is_account = true },
        .{ .name = "metadata", .fields = metadata_fields[0..] },
    };

    const json = try emitModule(std.testing.allocator, .{
        .decls = &.{},
        .type_decls = variant_types[0..],
        .tuple_type_decls = &.{},
        .record_type_decls = record_types[0..],
    }, .{ .program_name = "typed" });
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"accounts\":[{\"name\":\"vault\",\"discriminator\":[222,213,79,124,216,238,238,131]}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"status\",\"type\":{\"kind\":\"enum\",\"variants\":[{\"name\":\"Ready\"},{\"name\":\"Frozen\",\"fields\":[{\"name\":\"field0\",\"type\":\"i64\"}]}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"vault\",\"type\":{\"kind\":\"struct\",\"fields\":[{\"name\":\"balance\",\"type\":\"i64\"},{\"name\":\"enabled\",\"type\":{\"option\":\"bool\"}}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"metadata\",\"type\":{\"kind\":\"struct\",\"fields\":[{\"name\":\"authority\",\"type\":\"bytes\"}]}") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
}
