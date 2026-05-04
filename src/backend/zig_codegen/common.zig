// Shared types, predicates, naming, and low-level append helpers for Zig codegen.

pub const std = @import("std");
pub const lir = @import("../../lower/lir.zig");
pub const match_compiler = @import("../match.zig");

pub const EmitError = std.mem.Allocator.Error || error{
    NegativeIntegerResultUnsupported,
    UnsupportedCallingConvention,
    UnsupportedExpr,
    InvalidPatternMatrix,
};

pub const EmitContext = struct {
    next_block_id: usize = 0,
    is_entrypoint: bool = false,
    functions: []const lir.LFunc = &.{},
    type_decls: []const lir.LVariantType = &.{},
    record_type_decls: []const lir.LRecordType = &.{},
    externals: []const lir.LExternalDecl = &.{},
    hoisted_decls: ?*std.ArrayList(u8) = null,
    let_bindings: ?*std.StringHashMap(LetBindingStorage) = null,
    tco_function_name: ?[]const u8 = null,
    tco_params: []const TailCallParam = &.{},
};

pub const TailCallParam = struct {
    source_name: []const u8,
    local_name: []const u8,
};

pub const LetBindingStorage = enum {
    Direct,
    ArenaPointer,
};

pub const LetBindingSnapshot = struct {
    name: []const u8,
    previous: ?LetBindingStorage,
};

pub fn emitVariableValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, ctx: *EmitContext) EmitError!void {
    if (ctx.let_bindings) |bindings| {
        if (bindings.get(name)) |storage| {
            try emitIdentifier(out, allocator, name);
            if (storage == .ArenaPointer) try append(out, allocator, ".*");
            return;
        }
    }
    for (ctx.tco_params) |param| {
        if (std.mem.eql(u8, param.source_name, name)) {
            try append(out, allocator, param.local_name);
            return;
        }
    }
    try emitIdentifier(out, allocator, name);
}

pub fn pushLetBinding(ctx: *EmitContext, name: []const u8, storage: LetBindingStorage) EmitError!LetBindingSnapshot {
    const bindings = ctx.let_bindings orelse return .{ .name = name, .previous = null };
    const previous = bindings.get(name);
    try bindings.put(name, storage);
    return .{ .name = name, .previous = previous };
}

pub fn restoreLetBinding(ctx: *EmitContext, snapshot: LetBindingSnapshot) void {
    const bindings = ctx.let_bindings orelse return;
    if (snapshot.previous) |previous| {
        bindings.getPtr(snapshot.name).?.* = previous;
    } else {
        _ = bindings.remove(snapshot.name);
    }
}

pub fn freeEmittedFunctionName(allocator: std.mem.Allocator, source_name: []const u8, emitted: []const u8) void {
    if (!std.mem.eql(u8, source_name, "entrypoint")) allocator.free(emitted);
}

pub fn exprUsesName(expr: lir.LExpr, name: []const u8) bool {
    return switch (expr) {
        .Constant => false,
        .Var => |var_ref| std.mem.eql(u8, var_ref.name, name),
        .App => |app| blk: {
            if (exprUsesName(app.callee.*, name)) break :blk true;
            for (app.args) |arg| {
                if (exprUsesName(arg.*, name)) break :blk true;
            }
            break :blk false;
        },
        .Let => |let_expr| exprUsesName(let_expr.value.*, name) or
            (!std.mem.eql(u8, let_expr.name, name) and exprUsesName(let_expr.body.*, name)),
        .Assert => |assert_expr| exprUsesName(assert_expr.condition.*, name),
        .If => |if_expr| exprUsesName(if_expr.cond.*, name) or exprUsesName(if_expr.then_branch.*, name) or exprUsesName(if_expr.else_branch.*, name),
        .Prim => |prim| blk: {
            for (prim.args) |arg| {
                if (exprUsesName(arg.*, name)) break :blk true;
            }
            break :blk false;
        },
        .Ctor => |ctor_expr| {
            for (ctor_expr.args) |arg| {
                if (exprUsesName(arg.*, name)) return true;
            }
            return false;
        },
        .Tuple => |tuple_expr| {
            for (tuple_expr.items) |item| {
                if (exprUsesName(item.*, name)) return true;
            }
            return false;
        },
        .TupleProj => |tuple_proj| exprUsesName(tuple_proj.tuple_expr.*, name),
        .Record => |record_expr| {
            for (record_expr.fields) |field| {
                if (exprUsesName(field.value.*, name)) return true;
            }
            return false;
        },
        .RecordField => |record_field| exprUsesName(record_field.record_expr.*, name),
        .RecordUpdate => |record_update| {
            if (exprUsesName(record_update.base_expr.*, name)) return true;
            for (record_update.fields) |field| {
                if (exprUsesName(field.value.*, name)) return true;
            }
            return false;
        },
        .AccountFieldSet => |field_set| exprUsesName(field_set.account_expr.*, name) or exprUsesName(field_set.value.*, name),
        .Match => |match_expr| {
            if (exprUsesName(match_expr.scrutinee.*, name)) return true;
            for (match_expr.arms) |arm| {
                if (!patternBindsName(arm.pattern, name)) {
                    if (arm.guard) |guard_expr| {
                        if (exprUsesName(guard_expr.*, name)) return true;
                    }
                    if (exprUsesName(arm.body.*, name)) return true;
                }
            }
            return false;
        },
        .Closure => |closure| {
            for (closure.captures) |capture| {
                if (std.mem.eql(u8, capture.name, name)) return true;
            }
            return false;
        },
    };
}

pub fn exprUsesCpiInvoke(expr: lir.LExpr) bool {
    return switch (expr) {
        .App => |app| blk: {
            switch (app.callee.*) {
                .Var => |callee| {
                    if (std.mem.eql(u8, callee.name, "invoke") or
                        std.mem.eql(u8, callee.name, "invoke_signed") or
                        std.mem.eql(u8, callee.name, "transfer_sol") or
                        std.mem.eql(u8, callee.name, "vault_deposit") or
                        std.mem.eql(u8, callee.name, "vault_withdraw") or
                        std.mem.eql(u8, callee.name, "vault_v2_deposit") or
                        std.mem.eql(u8, callee.name, "vault_v2_withdraw")) break :blk true;
                },
                else => {},
            }
            if (exprUsesCpiInvoke(app.callee.*)) break :blk true;
            for (app.args) |arg| {
                if (exprUsesCpiInvoke(arg.*)) break :blk true;
            }
            break :blk false;
        },
        .Let => |let_expr| exprUsesCpiInvoke(let_expr.value.*) or exprUsesCpiInvoke(let_expr.body.*),
        .Assert => |assert_expr| exprUsesCpiInvoke(assert_expr.condition.*),
        .If => |if_expr| exprUsesCpiInvoke(if_expr.cond.*) or exprUsesCpiInvoke(if_expr.then_branch.*) or exprUsesCpiInvoke(if_expr.else_branch.*),
        .Prim => |prim| blk: {
            for (prim.args) |arg| if (exprUsesCpiInvoke(arg.*)) break :blk true;
            break :blk false;
        },
        .Ctor => |ctor_expr| blk: {
            for (ctor_expr.args) |arg| if (exprUsesCpiInvoke(arg.*)) break :blk true;
            break :blk false;
        },
        .Tuple => |tuple_expr| blk: {
            for (tuple_expr.items) |item| if (exprUsesCpiInvoke(item.*)) break :blk true;
            break :blk false;
        },
        .TupleProj => |tuple_proj| exprUsesCpiInvoke(tuple_proj.tuple_expr.*),
        .Record => |record_expr| blk: {
            for (record_expr.fields) |field| if (exprUsesCpiInvoke(field.value.*)) break :blk true;
            break :blk false;
        },
        .RecordField => |field| exprUsesCpiInvoke(field.record_expr.*),
        .RecordUpdate => |record_update| blk: {
            if (exprUsesCpiInvoke(record_update.base_expr.*)) break :blk true;
            for (record_update.fields) |field| if (exprUsesCpiInvoke(field.value.*)) break :blk true;
            break :blk false;
        },
        .AccountFieldSet => |field_set| exprUsesCpiInvoke(field_set.account_expr.*) or exprUsesCpiInvoke(field_set.value.*),
        .Match => |match_expr| blk: {
            if (exprUsesCpiInvoke(match_expr.scrutinee.*)) break :blk true;
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| if (exprUsesCpiInvoke(guard.*)) break :blk true;
                if (exprUsesCpiInvoke(arm.body.*)) break :blk true;
            }
            break :blk false;
        },
        .Closure => false,
        .Constant, .Var => false,
    };
}

pub fn patternBindsName(pattern: lir.LPattern, name: []const u8) bool {
    return switch (pattern) {
        .Wildcard, .Constant => false,
        .Var => |var_name| std.mem.eql(u8, var_name, name),
        .Alias => |alias| std.mem.eql(u8, alias.name, name) or patternBindsName(alias.pattern.*, name),
        .Ctor => |ctor_pattern| {
            for (ctor_pattern.args) |arg| {
                if (patternBindsName(arg, name)) return true;
            }
            return false;
        },
        .Tuple => |items| {
            for (items) |item| {
                if (patternBindsName(item, name)) return true;
            }
            return false;
        },
        .Record => |fields| {
            for (fields) |field| {
                if (patternBindsName(field.pattern, name)) return true;
            }
            return false;
        },
    };
}

pub fn armUsesName(body: lir.LExpr, guard: ?*const lir.LExpr, name: []const u8) bool {
    if (guard) |guard_expr| {
        if (exprUsesName(guard_expr.*, name)) return true;
    }
    return exprUsesName(body, name);
}

pub fn patternsNeedSource(patterns: []const lir.LPattern, body: lir.LExpr, guard: ?*const lir.LExpr) bool {
    for (patterns) |pattern| {
        if (patternNeedsSource(pattern, body, guard)) return true;
    }
    return false;
}

pub fn patternNeedsSource(pattern: lir.LPattern, body: lir.LExpr, guard: ?*const lir.LExpr) bool {
    return switch (pattern) {
        .Wildcard => false,
        .Var => |name| !std.mem.eql(u8, name, "_") and armUsesName(body, guard, name),
        .Constant => true,
        .Alias => |alias| patternNeedsSource(alias.pattern.*, body, guard) or armUsesName(body, guard, alias.name),
        .Ctor, .Tuple, .Record => true,
    };
}

pub fn patternIsIrrefutable(pattern: lir.LPattern) bool {
    return switch (pattern) {
        .Wildcard, .Var => true,
        .Alias => |alias| patternIsIrrefutable(alias.pattern.*),
        .Tuple => |items| blk: {
            for (items) |item| {
                if (!patternIsIrrefutable(item)) break :blk false;
            }
            break :blk true;
        },
        .Record => |fields| blk: {
            for (fields) |field| {
                if (!patternIsIrrefutable(field.pattern)) break :blk false;
            }
            break :blk true;
        },
        .Constant, .Ctor => false,
    };
}

pub fn matchHasCtorArm(match_expr: lir.LMatch) bool {
    for (match_expr.arms) |arm| {
        switch (arm.pattern) {
            .Ctor => return true,
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {},
        }
    }
    return false;
}

pub fn matchHasUserCtorArm(match_expr: lir.LMatch) bool {
    for (match_expr.arms) |arm| {
        switch (arm.pattern) {
            .Ctor => |ctor| if (ctor.type_name != null) return true,
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {},
        }
    }
    return false;
}

pub fn matchHasBuiltinListCtorArm(match_expr: lir.LMatch) bool {
    for (match_expr.arms) |arm| {
        switch (arm.pattern) {
            .Ctor => |ctor| {
                if (std.mem.eql(u8, ctor.name, "[]") or std.mem.eql(u8, ctor.name, "::")) return true;
            },
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {},
        }
    }
    return false;
}

pub fn emittedVariantName(allocator: std.mem.Allocator, ctor_pattern: lir.LCtorPattern) EmitError![]const u8 {
    return if (ctor_pattern.type_name != null)
        try userVariantName(allocator, ctor_pattern.name)
    else
        try allocator.dupe(u8, try ctorVariantName(ctor_pattern.name));
}

pub fn sameConstructor(a: lir.LCtorPattern, b: lir.LCtorPattern) bool {
    const same_type = if (a.type_name == null and b.type_name == null)
        true
    else if (a.type_name != null and b.type_name != null)
        std.mem.eql(u8, a.type_name.?, b.type_name.?)
    else
        false;
    return same_type and std.mem.eql(u8, a.name, b.name);
}

pub fn matchHasDefaultRows(match_expr: lir.LMatch) bool {
    for (match_expr.arms) |arm| {
        switch (arm.pattern) {
            .Wildcard, .Var => return true,
            .Alias => |alias| if (patternIsIrrefutable(alias.pattern.*)) return true,
            .Ctor, .Constant, .Tuple, .Record => {},
        }
    }
    return false;
}

pub fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

pub fn isNilCtor(expr: lir.LExpr) bool {
    const ctor = switch (expr) {
        .Ctor => |value| value,
        else => return false,
    };
    return std.mem.eql(u8, ctor.name, "[]") and ctor.args.len == 0;
}

pub fn findRecordExprField(record: lir.LRecord, name: []const u8) ?*const lir.LExpr {
    for (record.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

pub fn collectArrayOfListItems(allocator: std.mem.Allocator, expr: lir.LExpr) EmitError![]const *const lir.LExpr {
    const app = switch (expr) {
        .App => |value| value,
        else => return error.UnsupportedExpr,
    };
    const callee = switch (app.callee.*) {
        .Var => |value| value,
        else => return error.UnsupportedExpr,
    };
    if (!std.mem.eql(u8, callee.name, "Array.of_list") or app.args.len != 1) return error.UnsupportedExpr;
    var items = std.ArrayList(*const lir.LExpr).empty;
    errdefer items.deinit(allocator);
    try collectLoweredListItems(allocator, app.args[0].*, &items);
    return items.toOwnedSlice(allocator);
}

pub fn collectLoweredListItems(allocator: std.mem.Allocator, expr: lir.LExpr, items: *std.ArrayList(*const lir.LExpr)) EmitError!void {
    const ctor = switch (expr) {
        .Ctor => |value| value,
        else => return error.UnsupportedExpr,
    };
    if (std.mem.eql(u8, ctor.name, "[]")) {
        if (ctor.args.len != 0) return error.UnsupportedExpr;
        return;
    }
    if (!std.mem.eql(u8, ctor.name, "::") or ctor.args.len != 2) return error.UnsupportedExpr;
    try items.append(allocator, ctor.args[0]);
    try collectLoweredListItems(allocator, ctor.args[1].*, items);
}

pub fn zigTypeName(allocator: std.mem.Allocator, ty: lir.LTy) EmitError![]const u8 {
    return switch (ty) {
        .Int => allocator.dupe(u8, "i64"),
        .Bool => allocator.dupe(u8, "prelude.Bool"),
        .Unit => allocator.dupe(u8, "void"),
        .String => allocator.dupe(u8, "[]const u8"),
        .Var => return error.UnsupportedExpr,
        .Closure => allocator.dupe(u8, "*const prelude.Closure"),
        .Record => |record| blk: {
            if (isAccountRecordTy(record)) break :blk try allocator.dupe(u8, "AccountRuntime.AccountView");
            break :blk try zigUserRecordNameFromRecord(allocator, record);
        },
        .Tuple => |items| blk: {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            try append(&out, allocator, "struct { ");
            for (items, 0..) |item, index| {
                if (index != 0) try append(&out, allocator, ", ");
                const item_ty = try zigTypeName(allocator, item);
                defer allocator.free(item_ty);
                try appendPrint(&out, allocator, "@\"{d}\": {s}", .{ index, item_ty });
            }
            try append(&out, allocator, " }");
            break :blk try out.toOwnedSlice(allocator);
        },
        .Adt => |adt| blk: {
            if (std.mem.eql(u8, adt.name, "option")) {
                if (adt.params.len != 1) return error.UnsupportedExpr;
                const inner = try zigTypeName(allocator, adt.params[0]);
                defer allocator.free(inner);
                break :blk try std.fmt.allocPrint(allocator, "prelude.Option({s})", .{inner});
            }
            if (std.mem.eql(u8, adt.name, "result")) {
                if (adt.params.len != 2) return error.UnsupportedExpr;
                const ok_ty = try zigTypeName(allocator, adt.params[0]);
                defer allocator.free(ok_ty);
                const err_ty = try zigTypeName(allocator, adt.params[1]);
                defer allocator.free(err_ty);
                break :blk try std.fmt.allocPrint(allocator, "prelude.Result({s}, {s})", .{ ok_ty, err_ty });
            }
            if (std.mem.eql(u8, adt.name, "list")) {
                if (adt.params.len != 1) return error.UnsupportedExpr;
                const inner = try zigTypeName(allocator, adt.params[0]);
                defer allocator.free(inner);
                break :blk try std.fmt.allocPrint(allocator, "prelude.List({s})", .{inner});
            }
            if (std.mem.eql(u8, adt.name, "array")) {
                if (adt.params.len != 1) return error.UnsupportedExpr;
                const inner = try zigTypeName(allocator, adt.params[0]);
                defer allocator.free(inner);
                break :blk try std.fmt.allocPrint(allocator, "[]const {s}", .{inner});
            }
            break :blk try zigUserAdtNameFromAdt(allocator, adt);
        },
    };
}

pub fn zigTypeExprName(allocator: std.mem.Allocator, ty: lir.LTypeExpr, type_params: []const []const u8) EmitError![]const u8 {
    return switch (ty) {
        .TypeVar => |name| blk: {
            if (!containsString(type_params, name)) return error.UnsupportedExpr;
            break :blk try typeParamName(allocator, name);
        },
        .TypeRef => |ref| try zigTypeRefName(allocator, ref, type_params),
        .RecursiveRef => |ref| try zigRecursiveTypeRefName(allocator, ref, type_params),
        .Tuple => |items| blk: {
            if (items.len == 0) break :blk try allocator.dupe(u8, "void");
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            try append(&out, allocator, "struct { ");
            for (items, 0..) |item, index| {
                if (index != 0) try append(&out, allocator, ", ");
                const item_ty = try zigTypeExprName(allocator, item, type_params);
                defer allocator.free(item_ty);
                try appendPrint(&out, allocator, "_{d}: {s}", .{ index, item_ty });
            }
            try append(&out, allocator, " }");
            break :blk try out.toOwnedSlice(allocator);
        },
    };
}

pub fn zigRecursiveTypeRefName(allocator: std.mem.Allocator, ref: lir.LTypeRef, type_params: []const []const u8) EmitError![]const u8 {
    const type_name = try zigTypeRefName(allocator, ref, type_params);
    defer allocator.free(type_name);
    return std.fmt.allocPrint(allocator, "*const {s}", .{type_name});
}

pub fn zigTypeRefName(allocator: std.mem.Allocator, ref: lir.LTypeRef, type_params: []const []const u8) EmitError![]const u8 {
    if (std.mem.eql(u8, ref.name, "int")) return allocator.dupe(u8, "i64");
    if (std.mem.eql(u8, ref.name, "bool")) return allocator.dupe(u8, "prelude.Bool");
    if (std.mem.eql(u8, ref.name, "unit")) return allocator.dupe(u8, "void");
    if (std.mem.eql(u8, ref.name, "string")) return allocator.dupe(u8, "[]const u8");
    if (std.mem.eql(u8, ref.name, "bytes")) return allocator.dupe(u8, "[]const u8");
    if (std.mem.eql(u8, ref.name, "account")) return allocator.dupe(u8, "AccountRuntime.AccountView");
    if (std.mem.eql(u8, ref.name, "array")) {
        if (ref.args.len != 1) return error.UnsupportedExpr;
        const inner = try zigTypeExprName(allocator, ref.args[0], type_params);
        defer allocator.free(inner);
        return std.fmt.allocPrint(allocator, "[]const {s}", .{inner});
    }
    const base = try userTypeName(allocator, ref.name);
    if (ref.args.len == 0) return base;
    defer allocator.free(base);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try append(&out, allocator, base);
    try append(&out, allocator, "(");
    for (ref.args, 0..) |arg, index| {
        if (index != 0) try append(&out, allocator, ", ");
        const arg_name = try zigTypeExprName(allocator, arg, type_params);
        defer allocator.free(arg_name);
        try append(&out, allocator, arg_name);
    }
    try append(&out, allocator, ")");
    return out.toOwnedSlice(allocator);
}

pub fn arrayElementZigTypeName(allocator: std.mem.Allocator, ty: lir.LTy) EmitError![]const u8 {
    const adt = switch (ty) {
        .Adt => |value| value,
        else => return error.UnsupportedExpr,
    };
    if (!std.mem.eql(u8, adt.name, "array") or adt.params.len != 1) return error.UnsupportedExpr;
    return zigTypeName(allocator, adt.params[0]);
}

pub fn payloadTypeName(allocator: std.mem.Allocator, variant: lir.LVariantCtor, type_params: []const []const u8) EmitError![]const u8 {
    if (variant.payload_types.len == 0) return allocator.dupe(u8, "void");
    if (variant.payload_types.len == 1) return zigTypeExprName(allocator, variant.payload_types[0], type_params);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try append(&out, allocator, "struct { ");
    for (variant.payload_types, 0..) |payload_ty, index| {
        if (index != 0) try append(&out, allocator, ", ");
        const ty_name = try zigTypeExprName(allocator, payload_ty, type_params);
        defer allocator.free(ty_name);
        try appendPrint(&out, allocator, "_{d}: {s}", .{ index, ty_name });
    }
    try append(&out, allocator, " }");
    return out.toOwnedSlice(allocator);
}

pub fn findUserVariant(type_decls: []const lir.LVariantType, type_name: []const u8, ctor_name: []const u8) ?lir.LVariantCtor {
    for (type_decls) |type_decl| {
        if (!std.mem.eql(u8, type_decl.name, type_name)) continue;
        for (type_decl.variants) |variant| {
            if (std.mem.eql(u8, variant.name, ctor_name)) return variant;
        }
    }
    return null;
}

pub fn findUserTypeDecl(type_decls: []const lir.LVariantType, type_name: []const u8) ?lir.LVariantType {
    for (type_decls) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, type_name)) return type_decl;
    }
    return null;
}

pub fn findRecordTypeDecl(type_decls: []const lir.LRecordType, type_name: []const u8) ?lir.LRecordType {
    for (type_decls) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, type_name)) return type_decl;
    }
    return null;
}

pub fn hasAccountRecordType(type_decls: []const lir.LRecordType) bool {
    return findRecordTypeDecl(type_decls, "account") != null;
}

pub fn isAccountTy(ty: lir.LTy) bool {
    const record = switch (ty) {
        .Record => |value| value,
        else => return false,
    };
    return isAccountRecordTy(record);
}

pub fn isAccountRecordTy(record: lir.LRecordTy) bool {
    return std.mem.eql(u8, record.name, "account") and record.params.len == 0;
}

pub fn paramsNeedEntrypointAccounts(params: []const lir.LParam) bool {
    for (params) |param| {
        if (paramNeedsEntrypointAccounts(param)) return true;
    }
    return false;
}

pub fn paramsNeedEntrypointAccountList(params: []const lir.LParam) bool {
    for (params) |param| {
        if (paramNeedsEntrypointAccounts(param) and isAccountListTy(param.ty)) return true;
    }
    return false;
}

pub fn paramNeedsEntrypointAccounts(param: lir.LParam) bool {
    return std.mem.eql(u8, param.name, "accounts") or isAccountTy(param.ty) or isAccountListTy(param.ty);
}

pub fn paramNeedsEntrypointInstructionData(param: lir.LParam) bool {
    return std.mem.eql(u8, param.name, "input") or
        std.mem.eql(u8, param.name, "instruction_data") or
        (std.mem.eql(u8, param.name, "data") and isBytesTy(param.ty));
}

pub fn isBytesTy(ty: lir.LTy) bool {
    return switch (ty) {
        .String => true,
        .Adt => |adt| blk: {
            if (!std.mem.eql(u8, adt.name, "array") or adt.params.len != 1) break :blk false;
            break :blk switch (adt.params[0]) {
                .Int => true,
                else => false,
            };
        },
        else => false,
    };
}

pub fn isAccountListTy(ty: lir.LTy) bool {
    const adt = switch (ty) {
        .Adt => |value| value,
        else => return false,
    };
    if (!std.mem.eql(u8, adt.name, "list") or adt.params.len != 1) return false;
    const item = switch (adt.params[0]) {
        .Record => |value| value,
        else => return false,
    };
    return std.mem.eql(u8, item.name, "account") and item.params.len == 0;
}

pub fn findRecordUpdateField(fields: []const lir.LRecordExprField, field_name: []const u8) ?lir.LRecordExprField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) return field;
    }
    return null;
}

pub fn findClosureCodeId(functions: []const lir.LFunc, name: []const u8) ?usize {
    for (functions, 0..) |func, index| {
        if (func.calling_convention == .Closure and std.mem.eql(u8, func.name, name)) return index + 1;
    }
    return null;
}

pub fn closureFuncMatchesTy(func: lir.LFunc, closure_ty: lir.LClosureTy) bool {
    if (func.params.len != closure_ty.params.len) return false;
    for (func.params, closure_ty.params) |param, expected| {
        if (!tyEql(param.ty, expected)) return false;
    }
    return tyEql(func.return_ty, closure_ty.ret.*);
}

pub fn tyEql(a: lir.LTy, b: lir.LTy) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .Int, .Bool, .Unit, .String => true,
        .Var => |name| std.mem.eql(u8, name, b.Var),
        .Adt => |adt| blk: {
            const other = b.Adt;
            if (!std.mem.eql(u8, adt.name, other.name) or adt.params.len != other.params.len) break :blk false;
            for (adt.params, other.params) |left, right| {
                if (!tyEql(left, right)) break :blk false;
            }
            break :blk true;
        },
        .Tuple => |items| blk: {
            const other = b.Tuple;
            if (items.len != other.len) break :blk false;
            for (items, other) |left, right| {
                if (!tyEql(left, right)) break :blk false;
            }
            break :blk true;
        },
        .Record => |record| blk: {
            const other = b.Record;
            if (!std.mem.eql(u8, record.name, other.name) or record.params.len != other.params.len) break :blk false;
            for (record.params, other.params) |left, right| {
                if (!tyEql(left, right)) break :blk false;
            }
            break :blk true;
        },
        .Closure => |closure| blk: {
            const other = b.Closure;
            if (closure.params.len != other.params.len) break :blk false;
            for (closure.params, other.params) |left, right| {
                if (!tyEql(left, right)) break :blk false;
            }
            break :blk tyEql(closure.ret.*, other.ret.*);
        },
    };
}

pub fn zigInstantiatedTypeRefName(
    allocator: std.mem.Allocator,
    ref: lir.LTypeRef,
    type_params: []const []const u8,
    concrete_ty: lir.LTy,
) EmitError![]const u8 {
    if (std.mem.eql(u8, ref.name, "int")) return allocator.dupe(u8, "i64");
    if (std.mem.eql(u8, ref.name, "bool")) return allocator.dupe(u8, "prelude.Bool");
    if (std.mem.eql(u8, ref.name, "unit")) return allocator.dupe(u8, "void");
    if (std.mem.eql(u8, ref.name, "string")) return allocator.dupe(u8, "[]const u8");

    const base = try userTypeName(allocator, ref.name);
    if (ref.args.len == 0) return base;
    defer allocator.free(base);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try append(&out, allocator, base);
    try append(&out, allocator, "(");
    for (ref.args, 0..) |arg, index| {
        if (index != 0) try append(&out, allocator, ", ");
        const arg_name = try zigInstantiatedTypeExprName(allocator, arg, type_params, concrete_ty);
        defer allocator.free(arg_name);
        try append(&out, allocator, arg_name);
    }
    try append(&out, allocator, ")");
    return out.toOwnedSlice(allocator);
}

pub fn zigInstantiatedTypeExprName(
    allocator: std.mem.Allocator,
    ty: lir.LTypeExpr,
    type_params: []const []const u8,
    concrete_ty: lir.LTy,
) EmitError![]const u8 {
    return switch (ty) {
        .TypeVar => |name| try concreteTypeParamName(allocator, name, type_params, concrete_ty),
        .TypeRef => |ref| try zigInstantiatedTypeRefName(allocator, ref, type_params, concrete_ty),
        .RecursiveRef => |ref| blk: {
            const type_name = try zigInstantiatedTypeRefName(allocator, ref, type_params, concrete_ty);
            defer allocator.free(type_name);
            break :blk try std.fmt.allocPrint(allocator, "*const {s}", .{type_name});
        },
        .Tuple => |items| blk: {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            try append(&out, allocator, "struct { ");
            for (items, 0..) |item, index| {
                if (index != 0) try append(&out, allocator, ", ");
                const item_name = try zigInstantiatedTypeExprName(allocator, item, type_params, concrete_ty);
                defer allocator.free(item_name);
                try appendPrint(&out, allocator, "_{d}: {s}", .{ index, item_name });
            }
            try append(&out, allocator, " }");
            break :blk try out.toOwnedSlice(allocator);
        },
    };
}

pub fn concreteTypeParamName(
    allocator: std.mem.Allocator,
    name: []const u8,
    type_params: []const []const u8,
    concrete_ty: lir.LTy,
) EmitError![]const u8 {
    const adt = switch (concrete_ty) {
        .Adt => |value| value,
        else => return error.UnsupportedExpr,
    };
    for (type_params, 0..) |param_name, index| {
        if (!std.mem.eql(u8, param_name, name)) continue;
        if (index >= adt.params.len) return error.UnsupportedExpr;
        return zigTypeName(allocator, adt.params[index]);
    }
    return error.UnsupportedExpr;
}

pub fn zigUserAdtTypeName(allocator: std.mem.Allocator, ty: lir.LTy, fallback_name: []const u8) EmitError![]const u8 {
    return switch (ty) {
        .Adt => |adt| try zigUserAdtNameFromAdt(allocator, adt),
        else => try userTypeName(allocator, fallback_name),
    };
}

pub fn zigUserAdtNameFromAdt(allocator: std.mem.Allocator, adt: lir.LAdt) EmitError![]const u8 {
    const base = try userTypeName(allocator, adt.name);
    if (adt.params.len == 0) return base;
    defer allocator.free(base);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try append(&out, allocator, base);
    try append(&out, allocator, "(");
    for (adt.params, 0..) |param, index| {
        if (index != 0) try append(&out, allocator, ", ");
        const param_name = try zigTypeName(allocator, param);
        defer allocator.free(param_name);
        try append(&out, allocator, param_name);
    }
    try append(&out, allocator, ")");
    return out.toOwnedSlice(allocator);
}

pub fn zigUserRecordNameFromRecord(allocator: std.mem.Allocator, record: lir.LRecordTy) EmitError![]const u8 {
    const base = try userTypeName(allocator, record.name);
    if (record.params.len == 0) return base;
    defer allocator.free(base);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try append(&out, allocator, base);
    try append(&out, allocator, "(");
    for (record.params, 0..) |param, index| {
        if (index != 0) try append(&out, allocator, ", ");
        const param_name = try zigTypeName(allocator, param);
        defer allocator.free(param_name);
        try append(&out, allocator, param_name);
    }
    try append(&out, allocator, ")");
    return out.toOwnedSlice(allocator);
}

pub fn isRecursivePayload(ty: lir.LTypeExpr) bool {
    return switch (ty) {
        .RecursiveRef => true,
        else => false,
    };
}

pub fn userTypeName(allocator: std.mem.Allocator, source_name: []const u8) EmitError![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try append(&out, allocator, "omlz_type_");
    try appendSanitized(&out, allocator, source_name);
    return out.toOwnedSlice(allocator);
}

pub fn userVariantName(allocator: std.mem.Allocator, source_name: []const u8) EmitError![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendSanitized(&out, allocator, source_name);
    return out.toOwnedSlice(allocator);
}

pub fn typeParamName(allocator: std.mem.Allocator, source_name: []const u8) EmitError![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try append(&out, allocator, "omlz_tparam_");
    try appendSanitized(&out, allocator, source_name);
    return out.toOwnedSlice(allocator);
}

pub fn appendSanitized(out: *std.ArrayList(u8), allocator: std.mem.Allocator, source_name: []const u8) EmitError!void {
    if (source_name.len == 0) {
        try append(out, allocator, "_");
        return;
    }
    if (!std.ascii.isAlphabetic(source_name[0]) and source_name[0] != '_') {
        try out.append(allocator, '_');
    }
    for (source_name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '_');
        }
    }
}

pub fn primOpToken(op: lir.LPrimOp) []const u8 {
    return switch (op) {
        .Add => "+%",
        .Sub => "-%",
        .Mul => "*%",
        .Eq => "==",
        .Ne => "!=",
        .Lt => "<",
        .Le => "<=",
        .Gt => ">",
        .Ge => ">=",
        .Div, .Mod, .StringLength, .StringGet, .StringSub, .StringConcat, .CharCode, .CharChr => unreachable,
    };
}

pub fn ctorVariantName(name: []const u8) EmitError![]const u8 {
    if (std.mem.eql(u8, name, "None")) return "none";
    if (std.mem.eql(u8, name, "Some")) return "some";
    if (std.mem.eql(u8, name, "Ok")) return "ok";
    if (std.mem.eql(u8, name, "Error")) return "err";
    if (std.mem.eql(u8, name, "[]")) return "nil";
    if (std.mem.eql(u8, name, "::")) return "cons";
    return error.UnsupportedExpr;
}

pub fn emitIdentifier(out: *std.ArrayList(u8), allocator: std.mem.Allocator, source_name: []const u8) EmitError!void {
    if (source_name.len == 0) {
        try append(out, allocator, "omlz_empty");
        return;
    }

    if (std.ascii.isAlphabetic(source_name[0]) or source_name[0] == '_') {
        for (source_name) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                try out.append(allocator, ch);
            } else {
                try out.append(allocator, '_');
            }
        }
    } else {
        try append(out, allocator, "omlz_");
        for (source_name) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                try out.append(allocator, ch);
            } else {
                try out.append(allocator, '_');
            }
        }
    }
}

pub fn emitIndent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, indent_level: usize) EmitError!void {
    var index: usize = 0;
    while (index < indent_level) : (index += 1) {
        try append(out, allocator, "    ");
    }
}

pub fn emitConstArrayAddressWorkaround(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    local_name: []const u8,
    module_const_name: []const u8,
) EmitError!void {
    // Zig 0.16 BPF quirk: module-scope const arrays can be lowered to low
    // verifier-rejected addresses; every future array address-of site must go
    // through this local stack copy pattern before taking `&`.
    try append(out, allocator, "    var ");
    try append(out, allocator, local_name);
    try append(out, allocator, "_stack_copy = ");
    try append(out, allocator, module_const_name);
    try append(out, allocator, ";\n");
    try append(out, allocator, "    const ");
    try append(out, allocator, local_name);
    try append(out, allocator, " = &");
    try append(out, allocator, local_name);
    try append(out, allocator, "_stack_copy;\n");
}

pub fn append(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try out.appendSlice(allocator, bytes);
}

pub fn appendPrint(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const bytes = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(bytes);
    try append(out, allocator, bytes);
}
