// Part of src/backend/zig_codegen.zig; split by concern.
const common = @import("common.zig");
const std = common.std;
const lir = common.lir;
const EmitError = common.EmitError;
const EmitContext = common.EmitContext;
const findRecordExprField = common.findRecordExprField;
const collectArrayOfListItems = common.collectArrayOfListItems;
const zigTypeName = common.zigTypeName;
const userTypeName = common.userTypeName;
const emitIndent = common.emitIndent;
const append = common.append;
const appendPrint = common.appendPrint;
const expr_emission = @import("expr_emission.zig");
const emitExpr = expr_emission.emitExpr;

pub fn emitExternalAppExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    external: lir.LExternalDecl,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (std.mem.eql(u8, external.symbol, "sol_log_") and app.args.len == 1) {
        if (try emitSyscallStringCallBlock(out, allocator, app.args[0].*, indent_level, ctx, "syscalls.sol_log_", false, false)) return;
    }
    if (std.mem.eql(u8, external.symbol, "sol_log_pubkey") and app.args.len == 1) {
        if (try emitCryptoHashPubkeyLogBlock(out, allocator, app.args[0].*, indent_level, ctx)) return;
        try append(out, allocator, "syscalls.sol_log_pubkey(@ptrCast((");
        try emitExpr(out, allocator, app.args[0].*, indent_level, ctx);
        try append(out, allocator, ").ptr))");
        return;
    }
    if (std.mem.eql(u8, external.symbol, "sol_sha256_alloc") and app.args.len == 1) {
        if (try emitSyscallStringCallBlock(out, allocator, app.args[0].*, indent_level, ctx, "syscalls.sol_sha256_alloc", true, true)) return;
    }
    if (std.mem.eql(u8, external.symbol, "sol_keccak256_alloc") and app.args.len == 1) {
        if (try emitSyscallStringCallBlock(out, allocator, app.args[0].*, indent_level, ctx, "syscalls.sol_keccak256_alloc", true, true)) return;
    }

    if (externalReturnIsBytes(external)) {
        const block_id = ctx.next_block_id;
        ctx.next_block_id += 1;
        if (externalBytesReturnStorageType(external)) |storage_ty| {
            try registerExternalBytesHoist(allocator, ctx, block_id, storage_ty);
            try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "omlz_external_bytes_{d} = ", .{block_id});
            try emitExternalDirectCall(out, allocator, external, app, indent_level + 1, ctx);
            try append(out, allocator, ";\n");
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "break :blk{d} omlz_external_bytes_{d}[0..];\n", .{ block_id, block_id });
            try emitIndent(out, allocator, indent_level);
            try append(out, allocator, "}");
            return;
        }
        try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "const omlz_external_bytes_{d} = ", .{block_id});
        try emitExternalDirectCall(out, allocator, external, app, indent_level + 1, ctx);
        try append(out, allocator, ";\n");
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "break :blk{d} omlz_external_bytes_{d}[0..];\n", .{ block_id, block_id });
        try emitIndent(out, allocator, indent_level);
        try append(out, allocator, "}");
        return;
    }

    const wrap_int = externalReturnIsInt(external);
    if (wrap_int) try append(out, allocator, "@as(i64, @intCast(");
    try emitExternalDirectCall(out, allocator, external, app, indent_level, ctx);
    if (wrap_int) try append(out, allocator, "))");
}

pub fn registerExternalBytesHoist(
    allocator: std.mem.Allocator,
    ctx: *EmitContext,
    block_id: usize,
    storage_ty: []const u8,
) EmitError!void {
    const hoisted_decls = ctx.hoisted_decls orelse return error.UnsupportedExpr;
    try appendPrint(hoisted_decls, allocator, "    var omlz_external_bytes_{d}: {s} = undefined;\n", .{ block_id, storage_ty });
}

pub fn emitCryptoHashPubkeyLogBlock(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    expr: lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!bool {
    const app = switch (expr) {
        .App => |value| value,
        else => return false,
    };
    if (app.args.len != 1) return false;
    const callee = switch (app.callee.*) {
        .Var => |value| value,
        else => return false,
    };
    const syscall_name = if (std.mem.eql(u8, callee.name, "Crypto.sha256"))
        "syscalls.sol_sha256"
    else if (std.mem.eql(u8, callee.name, "Crypto.keccak256"))
        "syscalls.sol_keccak256"
    else
        return false;

    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_crypto_hash_{d} = {s}(", .{ block_id, syscall_name });
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ");\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "syscalls.sol_log_pubkey(&omlz_crypto_hash_{d});\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d};\n", .{block_id});
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
    return true;
}

pub fn emitExternalDirectCall(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    external: lir.LExternalDecl,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    try emitExternalSymbolRef(out, allocator, external.symbol);
    try append(out, allocator, "(");
    var wrote_arg = false;
    if (externalNeedsArenaArg(external)) {
        try append(out, allocator, "arena");
        wrote_arg = true;
    }

    const params = switch (external.ty) {
        .Closure => |closure| closure.params,
        else => &.{},
    };
    for (app.args, 0..) |arg, index| {
        if (index < params.len and isUnitTy(params[index]) and isUnitExpr(arg.*)) continue;
        if (wrote_arg) try append(out, allocator, ", ");
        try emitExpr(out, allocator, arg.*, indent_level, ctx);
        wrote_arg = true;
    }
    try append(out, allocator, ")");
}

pub fn findExternalDecl(externals: []const lir.LExternalDecl, name: []const u8) ?lir.LExternalDecl {
    for (externals) |external| {
        if (std.mem.eql(u8, external.name, name)) return external;
    }
    return null;
}

pub fn emitExternalSymbolRef(out: *std.ArrayList(u8), allocator: std.mem.Allocator, symbol: []const u8) EmitError!void {
    if (std.mem.indexOfScalar(u8, symbol, '.') != null) {
        try append(out, allocator, symbol);
        return;
    }
    if (isSyscallExternalSymbol(symbol)) {
        try append(out, allocator, "syscalls.");
    }
    try append(out, allocator, symbol);
}

pub fn isSyscallExternalSymbol(symbol: []const u8) bool {
    return std.mem.eql(u8, symbol, "sol_log_") or
        std.mem.eql(u8, symbol, "sol_log_64_") or
        std.mem.eql(u8, symbol, "sol_log_pubkey") or
        std.mem.eql(u8, symbol, "sol_sha256") or
        std.mem.eql(u8, symbol, "sol_sha256_alloc") or
        std.mem.eql(u8, symbol, "sol_keccak256") or
        std.mem.eql(u8, symbol, "sol_keccak256_alloc") or
        std.mem.eql(u8, symbol, "sol_get_clock_sysvar") or
        std.mem.eql(u8, symbol, "sol_get_rent_sysvar") or
        std.mem.eql(u8, symbol, "sol_log_compute_units_") or
        std.mem.eql(u8, symbol, "sol_remaining_compute_units");
}

pub fn externalNeedsArenaArg(external: lir.LExternalDecl) bool {
    return std.mem.eql(u8, external.symbol, "sol_sha256_alloc") or
        std.mem.eql(u8, external.symbol, "sol_keccak256_alloc");
}

pub fn externalReturnIsInt(external: lir.LExternalDecl) bool {
    const closure = switch (external.ty) {
        .Closure => |value| value,
        else => return false,
    };
    return switch (closure.ret.*) {
        .Int => true,
        else => false,
    };
}

pub fn externalReturnIsBytes(external: lir.LExternalDecl) bool {
    const closure = switch (external.ty) {
        .Closure => |value| value,
        else => return false,
    };
    return switch (closure.ret.*) {
        .String => true,
        else => false,
    };
}

pub fn externalBytesReturnStorageType(external: lir.LExternalDecl) ?[]const u8 {
    if (!externalReturnIsBytes(external)) return null;
    if (std.mem.eql(u8, external.symbol, "sol_sha256") or
        std.mem.eql(u8, external.symbol, "sol_keccak256"))
    {
        return "[32]u8";
    }
    return null;
}

pub fn isUnitExpr(expr: lir.LExpr) bool {
    return switch (expr) {
        .Ctor => |ctor| std.mem.eql(u8, ctor.name, "()") and ctor.args.len == 0,
        else => false,
    };
}

pub fn isUnitTy(ty: lir.LTy) bool {
    return switch (ty) {
        .Unit => true,
        else => false,
    };
}

pub fn emitSyscallAppExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!bool {
    if (std.mem.eql(u8, name, "Syscall.sol_log")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        if (try emitSyscallStringCallBlock(out, allocator, app.args[0].*, indent_level, ctx, "syscalls.sol_log_", false, false)) return true;
        try append(out, allocator, "syscalls.sol_log_(");
        try emitExpr(out, allocator, app.args[0].*, indent_level, ctx);
        try append(out, allocator, ")");
        return true;
    }
    if (std.mem.eql(u8, name, "Syscall.sol_log_64")) {
        if (app.args.len != 5) return error.UnsupportedExpr;
        try append(out, allocator, "syscalls.sol_log_64_(");
        for (app.args, 0..) |arg, index| {
            if (index != 0) try append(out, allocator, ", ");
            try emitExpr(out, allocator, arg.*, indent_level, ctx);
        }
        try append(out, allocator, ")");
        return true;
    }
    if (std.mem.eql(u8, name, "Syscall.sol_log_pubkey")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        try append(out, allocator, "syscalls.sol_log_pubkey(@ptrCast((");
        try emitExpr(out, allocator, app.args[0].*, indent_level, ctx);
        try append(out, allocator, ").ptr))");
        return true;
    }
    if (std.mem.eql(u8, name, "Syscall.sol_sha256") or std.mem.eql(u8, name, "Crypto.sha256")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        if (try emitSyscallStringCallBlock(out, allocator, app.args[0].*, indent_level, ctx, "syscalls.sol_sha256_alloc", true, true)) return true;
        try append(out, allocator, "syscalls.sol_sha256_alloc(arena, ");
        try emitExpr(out, allocator, app.args[0].*, indent_level, ctx);
        try append(out, allocator, ")");
        return true;
    }
    if (std.mem.eql(u8, name, "Syscall.sol_keccak256") or std.mem.eql(u8, name, "Crypto.keccak256")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        if (try emitSyscallStringCallBlock(out, allocator, app.args[0].*, indent_level, ctx, "syscalls.sol_keccak256_alloc", true, true)) return true;
        try append(out, allocator, "syscalls.sol_keccak256_alloc(arena, ");
        try emitExpr(out, allocator, app.args[0].*, indent_level, ctx);
        try append(out, allocator, ")");
        return true;
    }
    if (std.mem.eql(u8, name, "Syscall.sol_get_clock_sysvar")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        try emitSyscallClockExpr(out, allocator, app, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "Syscall.sol_remaining_compute_units")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        try append(out, allocator, "@as(i64, @intCast(syscalls.sol_remaining_compute_units()))");
        return true;
    }
    if (std.mem.eql(u8, name, "set_return_data") or std.mem.eql(u8, name, "Cpi.set_return_data") or std.mem.eql(u8, name, "Syscall.sol_set_return_data")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        if (try emitSyscallStringCallBlock(out, allocator, app.args[0].*, indent_level, ctx, "cpi.sol_set_return_data", false, false)) return true;
        try append(out, allocator, "cpi.sol_set_return_data(");
        try emitExpr(out, allocator, app.args[0].*, indent_level, ctx);
        try append(out, allocator, ")");
        return true;
    }
    if (std.mem.eql(u8, name, "get_return_data") or std.mem.eql(u8, name, "Cpi.get_return_data") or std.mem.eql(u8, name, "Syscall.sol_get_return_data")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        try append(out, allocator, "cpi.sol_get_return_data_alloc(arena)");
        return true;
    }
    if (std.mem.eql(u8, name, "invoke")) {
        try emitCpiInvoke(out, allocator, app, indent_level, ctx, false);
        return true;
    }
    if (std.mem.eql(u8, name, "invoke_signed")) {
        try emitCpiInvoke(out, allocator, app, indent_level, ctx, true);
        return true;
    }
    if (std.mem.eql(u8, name, "create_program_address")) {
        try emitCreateProgramAddress(out, allocator, app, indent_level, ctx);
        return true;
    }
    return false;
}

pub fn emitCounterAppExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!bool {
    if (std.mem.eql(u8, name, "read_u8")) {
        if (app.args.len != 2) return error.UnsupportedExpr;
        try emitCounterReadU8(out, allocator, app.args[0].*, app.args[1].*, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "read_u64_le")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        try emitCounterReadU64Le(out, allocator, app.args[0].*, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "write_u64_le")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        try emitCounterWriteU64Le(out, allocator, app.args[0].*, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "set_account_data")) {
        if (app.args.len != 2) return error.UnsupportedExpr;
        try emitCounterSetAccountData(out, allocator, app.args[0].*, app.args[1].*, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "transfer_sol")) {
        if (app.args.len != 4) return error.UnsupportedExpr;
        if (!ctx.is_entrypoint) return error.UnsupportedExpr;
        const block_id = ctx.next_block_id;
        ctx.next_block_id += 1;
        try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "_ = omlz_runtime_accounts;\n");
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "break :blk{d} cpi.zxcaml_transfer_sol_process(arena, omlz_runtime_input, ", .{block_id});
        try emitExpr(out, allocator, app.args[3].*, indent_level, ctx);
        try append(out, allocator, ");\n");
        try emitIndent(out, allocator, indent_level);
        try append(out, allocator, "}");
        return true;
    }
    if (std.mem.eql(u8, name, "vault_deposit") or std.mem.eql(u8, name, "vault_withdraw")) {
        if (app.args.len != 4) return error.UnsupportedExpr;
        if (!ctx.is_entrypoint) return error.UnsupportedExpr;
        try append(out, allocator, "cpi.zxcaml_vault_process(arena, omlz_runtime_input, omlz_runtime_accounts, omlz_runtime_instruction_data)");
        return true;
    }
    if (std.mem.eql(u8, name, "vault_v2_deposit") or std.mem.eql(u8, name, "vault_v2_withdraw")) {
        if (app.args.len != 4) return error.UnsupportedExpr;
        if (!ctx.is_entrypoint) return error.UnsupportedExpr;
        try append(out, allocator, "cpi.zxcaml_vault_v2_process(arena, omlz_runtime_input, omlz_runtime_accounts, omlz_runtime_instruction_data)");
        return true;
    }
    if (std.mem.eql(u8, name, "pda_storage_process")) {
        if (app.args.len != 2) return error.UnsupportedExpr;
        if (!ctx.is_entrypoint) return error.UnsupportedExpr;
        const block_id = ctx.next_block_id;
        ctx.next_block_id += 1;
        try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "const omlz_pda_accounts_witness_{d} = ", .{block_id});
        try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
        try append(out, allocator, ";\n");
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "_ = omlz_pda_accounts_witness_{d};\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "const omlz_pda_instruction_data_witness_{d} = ", .{block_id});
        try emitExpr(out, allocator, app.args[1].*, indent_level + 1, ctx);
        try append(out, allocator, ";\n");
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "_ = omlz_pda_instruction_data_witness_{d};\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "if (omlz_runtime_instruction_data.len < 9) break :blk");
        try appendPrint(out, allocator, "{d} @as(i64, 1);\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "if (omlz_runtime_instruction_data[0] == 0) {\n");
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "if (omlz_runtime_accounts.len < 4) break :blk{d} @as(i64, 1);\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "const omlz_storage_{d} = omlz_runtime_accounts[1];\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "const omlz_user_{d} = omlz_runtime_accounts[2];\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "if (omlz_storage_{d}.data.len < 40) break :blk{d} @as(i64, 1);\n", .{ block_id, block_id });
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "@memcpy(omlz_storage_{d}.data[0..32], omlz_user_{d}.key[0..]);\n", .{ block_id, block_id });
        for (0..8) |index| {
            try emitIndent(out, allocator, indent_level + 2);
            try appendPrint(out, allocator, "omlz_storage_{d}.data[{d}] = omlz_runtime_instruction_data[{d}];\n", .{ block_id, 32 + index, 1 + index });
        }
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "break :blk{d} @as(i64, 0);\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "} else if (omlz_runtime_instruction_data[0] == 1) {\n");
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "if (omlz_runtime_accounts.len < 2) break :blk{d} @as(i64, 1);\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "const omlz_storage_{d} = omlz_runtime_accounts[0];\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "const omlz_user_{d} = omlz_runtime_accounts[1];\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "if (omlz_storage_{d}.data.len < 40) break :blk{d} @as(i64, 1);\n", .{ block_id, block_id });
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "if (!std.mem.eql(u8, omlz_storage_{d}.data[0..32], omlz_user_{d}.key[0..])) break :blk{d} @as(i64, 1);\n", .{ block_id, block_id, block_id });
        for (0..8) |index| {
            try emitIndent(out, allocator, indent_level + 2);
            try appendPrint(out, allocator, "omlz_storage_{d}.data[{d}] = omlz_runtime_instruction_data[{d}];\n", .{ block_id, 32 + index, 1 + index });
        }
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "break :blk{d} @as(i64, 0);\n", .{block_id});
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "}} else break :blk{d} @as(i64, 1);\n", .{block_id});
        try emitIndent(out, allocator, indent_level);
        try append(out, allocator, "}");
        return true;
    }
    return false;
}

pub fn emitCounterReadU8(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes_expr: lir.LExpr,
    offset_expr: lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_counter_bytes_{d} = ", .{block_id});
    try emitExpr(out, allocator, bytes_expr, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_counter_offset_{d} = ", .{block_id});
    try emitExpr(out, allocator, offset_expr, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_counter_offset_{d} < 0) break :blk{d} @as(i64, 0);\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_counter_index_{d}: usize = @intCast(omlz_counter_offset_{d});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_counter_index_{d} >= omlz_counter_bytes_{d}.len) break :blk{d} @as(i64, 0);\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} @as(i64, @intCast(omlz_counter_bytes_{d}[omlz_counter_index_{d}]));\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitCounterReadU64Le(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes_expr: lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_counter_bytes_{d} = ", .{block_id});
    try emitExpr(out, allocator, bytes_expr, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_counter_bytes_{d}.len < 8) break :blk{d} @as(i64, 0);\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_counter_value_{d}: u64 = 0;\n", .{block_id});
    for (0..8) |index| {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "omlz_counter_value_{d} |= @as(u64, omlz_counter_bytes_{d}[{d}]) << {d};\n", .{ block_id, block_id, index, index * 8 });
    }
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} @as(i64, @bitCast(omlz_counter_value_{d}));\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitCounterWriteU64Le(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value_expr: lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_counter_signed_{d}: i64 = ", .{block_id});
    try emitExpr(out, allocator, value_expr, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_counter_value_{d}: u64 = @bitCast(omlz_counter_signed_{d});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_counter_out_{d}: []u8 = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(u8, 8, &omlz_counter_out_{d});\n", .{block_id});
    for (0..8) |index| {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "omlz_counter_out_{d}[{d}] = @intCast((omlz_counter_value_{d} >> {d}) & 0xff);\n", .{ block_id, index, block_id, index * 8 });
    }
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_counter_out_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitCounterSetAccountData(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    account_expr: lir.LExpr,
    data_expr: lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_counter_account_{d} = ", .{block_id});
    try emitExpr(out, allocator, account_expr, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_counter_data_{d} = ", .{block_id});
    try emitExpr(out, allocator, data_expr, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_counter_data_{d}.len > omlz_counter_account_{d}.data.len) unreachable;\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "@memcpy(omlz_counter_account_{d}.data[0..omlz_counter_data_{d}.len], omlz_counter_data_{d});\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d};\n", .{block_id});
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitSplTokenAppExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!bool {
    if (std.mem.eql(u8, name, "SplToken.program_id")) {
        if (app.args.len > 1) return error.UnsupportedExpr;
        try emitSplTokenProgramIdBytes(out, allocator, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "SplToken.transfer_data")) {
        if (app.args.len != 1) return error.UnsupportedExpr;
        try emitSplTokenTransferData(out, allocator, app.args[0].*, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "SplToken.transfer_account_metas")) {
        if (app.args.len != 3) return error.UnsupportedExpr;
        try emitSplTokenTransferAccountMetas(out, allocator, app.args, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "SplToken.transfer_instruction")) {
        if (app.args.len != 4) return error.UnsupportedExpr;
        try emitSplTokenTransferInstruction(out, allocator, app, indent_level, ctx);
        return true;
    }
    return false;
}

pub fn emitSplTokenProgramIdBytes(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_spl_program_id_{d}: []u8 = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(u8, spl_token.pubkey_len, &omlz_spl_program_id_{d});\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_spl_program_id_ptr_{d}: *spl_token.Pubkey = @ptrCast(omlz_spl_program_id_{d}.ptr);\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "spl_token.writeProgramId(omlz_spl_program_id_ptr_{d});\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_spl_program_id_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitSplTokenTransferData(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    amount_expr: lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_spl_amount_{d} = ", .{block_id});
    try emitExpr(out, allocator, amount_expr, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_spl_amount_{d} < 0) break :blk{d} @as([]const u8, &.{{}});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_spl_data_{d}: []u8 = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(u8, spl_token.transfer_instruction_data_len, &omlz_spl_data_{d});\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "_ = spl_token.encodeTransferInto(omlz_spl_data_{d}, @intCast(omlz_spl_amount_{d})) catch break :blk{d} @as([]const u8, &.{{}});\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_spl_data_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitSplTokenTransferAccountMetas(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    args: []const *const lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const account_meta_ty = try userTypeName(allocator, "account_meta");
    defer allocator.free(account_meta_ty);
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});

    const names = [_][]const u8{ "source", "destination", "authority" };
    for (args, names) |arg, name| {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "const omlz_spl_{s}_{d} = ", .{ name, block_id });
        try emitExpr(out, allocator, arg.*, indent_level + 1, ctx);
        try append(out, allocator, ";\n");
    }

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_spl_metas_{d}: []{s} = undefined;\n", .{ block_id, account_meta_ty });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap({s}, 3, &omlz_spl_metas_{d});\n", .{ account_meta_ty, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "omlz_spl_metas_{d}[0] = .{{ .pubkey = omlz_spl_source_{d}, .is_writable = prelude.Bool.true, .is_signer = prelude.Bool.false }};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "omlz_spl_metas_{d}[1] = .{{ .pubkey = omlz_spl_destination_{d}, .is_writable = prelude.Bool.true, .is_signer = prelude.Bool.false }};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "omlz_spl_metas_{d}[2] = .{{ .pubkey = omlz_spl_authority_{d}, .is_writable = prelude.Bool.false, .is_signer = prelude.Bool.true }};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_spl_metas_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitSplTokenTransferInstruction(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const instruction_ty = try zigTypeName(allocator, app.ty);
    defer allocator.free(instruction_ty);
    const account_meta_ty = try userTypeName(allocator, "account_meta");
    defer allocator.free(account_meta_ty);
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});

    const names = [_][]const u8{ "source", "destination", "authority" };
    for (app.args[0..3], names) |arg, name| {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "const omlz_spl_{s}_{d} = ", .{ name, block_id });
        try emitExpr(out, allocator, arg.*, indent_level + 1, ctx);
        try append(out, allocator, ";\n");
    }
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_spl_amount_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[3].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_spl_amount_{d} < 0) break :blk{d} {s}{{ .program_id = &.{{}}, .accounts = &.{{}}, .data = &.{{}} }};\n", .{ block_id, block_id, instruction_ty });

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_spl_program_id_{d}: []u8 = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(u8, spl_token.pubkey_len, &omlz_spl_program_id_{d});\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_spl_program_id_ptr_{d}: *spl_token.Pubkey = @ptrCast(omlz_spl_program_id_{d}.ptr);\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "spl_token.writeProgramId(omlz_spl_program_id_ptr_{d});\n", .{block_id});

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_spl_data_{d}: []u8 = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(u8, spl_token.transfer_instruction_data_len, &omlz_spl_data_{d});\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "_ = spl_token.encodeTransferInto(omlz_spl_data_{d}, @intCast(omlz_spl_amount_{d})) catch break :blk{d} {s}{{ .program_id = &.{{}}, .accounts = &.{{}}, .data = &.{{}} }};\n", .{ block_id, block_id, block_id, instruction_ty });

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_spl_metas_{d}: []{s} = undefined;\n", .{ block_id, account_meta_ty });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap({s}, 3, &omlz_spl_metas_{d});\n", .{ account_meta_ty, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "omlz_spl_metas_{d}[0] = .{{ .pubkey = omlz_spl_source_{d}, .is_writable = prelude.Bool.true, .is_signer = prelude.Bool.false }};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "omlz_spl_metas_{d}[1] = .{{ .pubkey = omlz_spl_destination_{d}, .is_writable = prelude.Bool.true, .is_signer = prelude.Bool.false }};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "omlz_spl_metas_{d}[2] = .{{ .pubkey = omlz_spl_authority_{d}, .is_writable = prelude.Bool.false, .is_signer = prelude.Bool.true }};\n", .{ block_id, block_id });

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} {s}{{ .program_id = omlz_spl_program_id_{d}, .accounts = omlz_spl_metas_{d}, .data = omlz_spl_data_{d} }};\n", .{ block_id, instruction_ty, block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitCpiInvoke(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
    signed: bool,
) EmitError!void {
    if (!ctx.is_entrypoint) return error.UnsupportedExpr;
    if ((!signed and app.args.len != 1) or (signed and app.args.len != 2)) return error.UnsupportedExpr;
    switch (app.args[0].*) {
        .Record => |record| {
            try emitCpiInvokeRecord(out, allocator, record, if (signed) app.args[1].* else null, indent_level, ctx);
            return;
        },
        else => {},
    }
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;

    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_ix_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_program_id_{d}: cpi.Pubkey = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (!spl_token.writeProgramIdFromBytes(&omlz_program_id_{d}, omlz_ix_{d}.program_id)) break :blk{d} @as(i64, 1);\n", .{ block_id, block_id, block_id });

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_cpi_metas_{d}: []cpi.SolAccountMeta = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(cpi.SolAccountMeta, omlz_ix_{d}.accounts.len, &omlz_cpi_metas_{d});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_cpi_meta_pubkeys_{d}: []cpi.Pubkey = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(cpi.Pubkey, omlz_ix_{d}.accounts.len, &omlz_cpi_meta_pubkeys_{d});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "for (omlz_ix_{d}.accounts, 0..) |omlz_meta, omlz_meta_index| {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try append(out, allocator, "if (omlz_meta.pubkey.len != 32) break :blk");
    try appendPrint(out, allocator, "{d} @as(i64, 1);\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "@memcpy(omlz_cpi_meta_pubkeys_{d}[omlz_meta_index][0..], omlz_meta.pubkey[0..32]);\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "omlz_cpi_metas_{d}[omlz_meta_index].pubkey = &omlz_cpi_meta_pubkeys_{d}[omlz_meta_index];\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "omlz_cpi_metas_{d}[omlz_meta_index].is_writable = @intFromBool(prelude.Bool.toNative(omlz_meta.is_writable));\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "omlz_cpi_metas_{d}[omlz_meta_index].is_signer = @intFromBool(prelude.Bool.toNative(omlz_meta.is_signer));\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_c_instruction_{d} = cpi.SolInstruction.fromSlices(&omlz_program_id_{d}, omlz_cpi_metas_{d}, omlz_ix_{d}.data);\n", .{ block_id, block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_views_{d}: []AccountRuntime.AccountView = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "AccountRuntime.parseAccountsFromPtrInto(arena, input, &omlz_views_{d}) catch break :blk{d} @as(i64, 1);\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_infos_{d}: []cpi.SolAccountInfo = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(cpi.SolAccountInfo, omlz_views_{d}.len, &omlz_infos_{d});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "for (omlz_views_{d}, 0..) |omlz_view, omlz_info_index| omlz_infos_{d}[omlz_info_index] = .{{ .key = omlz_view.key, .lamports = omlz_view.lamports, .data_len = omlz_view.data.len, .data = omlz_view.data.ptr, .owner = omlz_view.owner, .rent_epoch = omlz_view.rentEpochValue(), .is_signer = @intFromBool(omlz_view.is_signer), .is_writable = @intFromBool(omlz_view.is_writable), .executable = @intFromBool(omlz_view.executable) }};\n", .{ block_id, block_id });

    if (signed) {
        try emitSignerSeeds(out, allocator, app.args[1].*, block_id, indent_level + 1, ctx);
    } else {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "const omlz_signer_seed_groups_{d}: []const cpi.SolSignerSeedsC = &.{{}};\n", .{block_id});
    }

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} @as(i64, @intCast(cpi.sol_invoke_signed_c(&omlz_c_instruction_{d}, omlz_infos_{d}, omlz_signer_seed_groups_{d}[0..])));\n", .{ block_id, block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitSignerSeeds(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    seeds_expr: lir.LExpr,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (collectArrayOfListItems(allocator, seeds_expr)) |groups| {
        defer allocator.free(groups);
        if (groups.len == 0) {
            try emitIndent(out, allocator, indent_level);
            try appendPrint(out, allocator, "const omlz_signer_seed_groups_{d}: []const cpi.SolSignerSeedsC = &.{{}};\n", .{block_id});
            return;
        }
    } else |_| {}

    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "const omlz_signer_seed_input_{d} = ", .{block_id});
    try emitExpr(out, allocator, seeds_expr, indent_level, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "var omlz_signer_seed_groups_{d}: []cpi.SolSignerSeedsC = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(cpi.SolSignerSeedsC, omlz_signer_seed_input_{d}.len, &omlz_signer_seed_groups_{d});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "for (omlz_signer_seed_input_{d}, 0..) |omlz_seed_group, omlz_seed_group_index| {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_c_seeds_{d}: []cpi.SolSignerSeed = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(cpi.SolSignerSeed, omlz_seed_group.len, &omlz_c_seeds_{d});\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "for (omlz_seed_group, 0..) |omlz_seed, omlz_seed_index| omlz_c_seeds_{d}[omlz_seed_index] = .{{ .addr = omlz_seed.ptr, .len = omlz_seed.len }};\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "omlz_signer_seed_groups_{d}[omlz_seed_group_index] = .{{ .addr = omlz_c_seeds_{d}.ptr, .len = omlz_c_seeds_{d}.len }};\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}\n");
}

pub fn emitCpiInvokeRecord(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ix_record: lir.LRecord,
    signer_seeds_expr: ?lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    _ = signer_seeds_expr;
    _ = indent_level;
    _ = ctx;
    if (recordLooksLikeSplTokenTransfer(ix_record)) {
        try append(out, allocator, "spl_token.zxcaml_transfer_one(arena, omlz_runtime_input)");
        return;
    }
    try append(out, allocator, "cpi.zxcaml_system_transfer_one_lamport(arena, omlz_runtime_input)");
    return;
}

pub fn recordLooksLikeSplTokenTransfer(ix_record: lir.LRecord) bool {
    const data_expr = findRecordExprField(ix_record, "data") orelse return false;
    const app = switch (data_expr.*) {
        .App => |value| value,
        else => return false,
    };
    const callee = switch (app.callee.*) {
        .Var => |value| value,
        else => return false,
    };
    if (!std.mem.eql(u8, callee.name, "Bytes.of_string") or app.args.len != 1) return false;
    const constant = switch (app.args[0].*) {
        .Constant => |value| value,
        else => return false,
    };
    const data = switch (constant) {
        .String => |value| value,
        .Int => return false,
    };
    return data.len == spl_token_transfer_data_len and data[0] == 3;
}

pub const spl_token_transfer_data_len: usize = 9;

pub fn emitCpiInvokeRecordExpanded(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ix_record: lir.LRecord,
    signer_seeds_expr: ?lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const program_id_expr = findRecordExprField(ix_record, "program_id") orelse return error.UnsupportedExpr;
    const accounts_expr = findRecordExprField(ix_record, "accounts") orelse return error.UnsupportedExpr;
    const data_expr = findRecordExprField(ix_record, "data") orelse return error.UnsupportedExpr;
    const account_items = try collectArrayOfListItems(allocator, accounts_expr.*);
    defer allocator.free(account_items);

    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_program_id_slice_{d} = ", .{block_id});
    try emitExpr(out, allocator, program_id_expr.*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_program_id_{d}: cpi.Pubkey = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_program_id_slice_{d}.len != 32) break :blk{d} @as(i64, 1);\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "@memcpy(omlz_program_id_{d}[0..], omlz_program_id_slice_{d}[0..32]);\n", .{ block_id, block_id });

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_cpi_metas_{d}: [{d}]cpi.SolAccountMeta = undefined;\n", .{ block_id, account_items.len });
    for (account_items, 0..) |item, index| {
        const meta_record = switch (item.*) {
            .Record => |record| record,
            else => return error.UnsupportedExpr,
        };
        try emitCpiMetaFromRecord(out, allocator, meta_record, block_id, index, indent_level + 1, ctx);
    }

    try emitBytesSliceBinding(out, allocator, data_expr.*, "omlz_ix_data", block_id, indent_level + 1, ctx);
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_c_instruction_{d}: cpi.SolInstruction = .{{ .program_id = &omlz_program_id_{d}, .accounts = omlz_cpi_metas_{d}[0..].ptr, .account_len = {d}, .data = omlz_ix_data_{d}.ptr, .data_len = omlz_ix_data_{d}.len }};\n", .{ block_id, block_id, block_id, account_items.len, block_id, block_id });

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_views_{d}: []AccountRuntime.AccountView = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "AccountRuntime.parseAccountsFromPtrInto(arena, input, &omlz_views_{d}) catch break :blk{d} @as(i64, 1);\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_infos_{d}: []cpi.SolAccountInfo = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(cpi.SolAccountInfo, omlz_views_{d}.len, &omlz_infos_{d});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "for (omlz_views_{d}, 0..) |omlz_view, omlz_info_index| omlz_infos_{d}[omlz_info_index] = .{{ .key = omlz_view.key, .lamports = omlz_view.lamports, .data_len = omlz_view.data.len, .data = omlz_view.data.ptr, .owner = omlz_view.owner, .rent_epoch = omlz_view.rentEpochValue(), .is_signer = @intFromBool(omlz_view.is_signer), .is_writable = @intFromBool(omlz_view.is_writable), .executable = @intFromBool(omlz_view.executable) }};\n", .{ block_id, block_id });

    if (signer_seeds_expr) |seeds| {
        try emitSignerSeedsDirect(out, allocator, seeds, block_id, indent_level + 1, ctx);
    } else {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "const omlz_signer_seed_groups_{d}: []const cpi.SolSignerSeedsC = &.{{}};\n", .{block_id});
    }

    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} @as(i64, @intCast(cpi.sol_invoke_signed_c(&omlz_c_instruction_{d}, omlz_infos_{d}, omlz_signer_seed_groups_{d}[0..])));\n", .{ block_id, block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitCpiMetaFromRecord(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    meta_record: lir.LRecord,
    block_id: usize,
    index: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const pubkey_expr = findRecordExprField(meta_record, "pubkey") orelse return error.UnsupportedExpr;
    const writable_expr = findRecordExprField(meta_record, "is_writable") orelse return error.UnsupportedExpr;
    const signer_expr = findRecordExprField(meta_record, "is_signer") orelse return error.UnsupportedExpr;
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "const omlz_meta_pubkey_slice_{d}_{d} = ", .{ block_id, index });
    try emitExpr(out, allocator, pubkey_expr.*, indent_level, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "var omlz_meta_pubkey_{d}_{d}: cpi.Pubkey = undefined;\n", .{ block_id, index });
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "if (omlz_meta_pubkey_slice_{d}_{d}.len != 32) break :blk{d} @as(i64, 1);\n", .{ block_id, index, block_id });
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "@memcpy(omlz_meta_pubkey_{d}_{d}[0..], omlz_meta_pubkey_slice_{d}_{d}[0..32]);\n", .{ block_id, index, block_id, index });
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "omlz_cpi_metas_{d}[{d}].pubkey = &omlz_meta_pubkey_{d}_{d};\n", .{ block_id, index, block_id, index });
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "omlz_cpi_metas_{d}[{d}].is_writable = @intFromBool(prelude.Bool.toNative(", .{ block_id, index });
    try emitExpr(out, allocator, writable_expr.*, indent_level, ctx);
    try append(out, allocator, "));\n");
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "omlz_cpi_metas_{d}[{d}].is_signer = @intFromBool(prelude.Bool.toNative(", .{ block_id, index });
    try emitExpr(out, allocator, signer_expr.*, indent_level, ctx);
    try append(out, allocator, "));\n");
}

pub fn emitBytesSliceBinding(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    expr: lir.LExpr,
    prefix: []const u8,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const literal: ?[]const u8 = switch (expr) {
        .App => |app| blk: {
            const callee = switch (app.callee.*) {
                .Var => |value| value,
                else => break :blk null,
            };
            if (!std.mem.eql(u8, callee.name, "Bytes.of_string") or app.args.len != 1) break :blk null;
            break :blk switch (app.args[0].*) {
                .Constant => |constant| switch (constant) {
                    .String => |value| value,
                    .Int => null,
                },
                else => null,
            };
        },
        .Constant => |constant| switch (constant) {
            .String => |value| value,
            .Int => null,
        },
        else => null,
    };
    if (literal) |value| {
        try emitIndent(out, allocator, indent_level);
        try appendPrint(out, allocator, "var {s}_{d}: []u8 = undefined;\n", .{ prefix, block_id });
        try emitIndent(out, allocator, indent_level);
        try appendPrint(out, allocator, "arena.allocIntoOrTrap(u8, {d}, &{s}_{d});\n", .{ value.len, prefix, block_id });
        for (value, 0..) |byte, index| {
            try emitIndent(out, allocator, indent_level);
            try appendPrint(out, allocator, "{s}_{d}[{d}] = {d};\n", .{ prefix, block_id, index, byte });
        }
        return;
    }
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "const {s}_{d} = ", .{ prefix, block_id });
    try emitExpr(out, allocator, expr, indent_level, ctx);
    try append(out, allocator, ";\n");
}

pub fn emitSignerSeedsDirect(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    expr: lir.LExpr,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const groups = try collectArrayOfListItems(allocator, expr);
    defer allocator.free(groups);
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "var omlz_signer_seed_groups_{d}: [{d}]cpi.SolSignerSeedsC = undefined;\n", .{ block_id, groups.len });
    for (groups, 0..) |group_expr, group_index| {
        const seeds = try collectArrayOfListItems(allocator, group_expr.*);
        defer allocator.free(seeds);
        try emitIndent(out, allocator, indent_level);
        try appendPrint(out, allocator, "var omlz_c_seeds_{d}_{d}: [{d}]cpi.SolSignerSeed = undefined;\n", .{ block_id, group_index, seeds.len });
        for (seeds, 0..) |seed_expr, seed_index| {
            const seed_prefix = try std.fmt.allocPrint(allocator, "omlz_seed_{d}_{d}_{d}", .{ block_id, group_index, seed_index });
            defer allocator.free(seed_prefix);
            try emitBytesSliceBinding(out, allocator, seed_expr.*, seed_prefix, block_id, indent_level, ctx);
            try emitIndent(out, allocator, indent_level);
            try appendPrint(out, allocator, "omlz_c_seeds_{d}_{d}[{d}] = .{{ .addr = {s}_{d}.ptr, .len = {s}_{d}.len }};\n", .{ block_id, group_index, seed_index, seed_prefix, block_id, seed_prefix, block_id });
        }
        try emitIndent(out, allocator, indent_level);
        try appendPrint(out, allocator, "omlz_signer_seed_groups_{d}[{d}] = .{{ .addr = omlz_c_seeds_{d}_{d}[0..].ptr, .len = {d} }};\n", .{ block_id, group_index, block_id, group_index, seeds.len });
    }
}

pub fn emitCreateProgramAddress(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (app.args.len != 2) return error.UnsupportedExpr;
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_seed_group_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_program_id_slice_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[1].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_program_id_{d}: cpi.Pubkey = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_program_id_slice_{d}.len != 32) break :blk{d} @as([]const u8, &.{{}});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "@memcpy(omlz_program_id_{d}[0..], omlz_program_id_slice_{d}[0..32]);\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_c_seeds_{d}: []cpi.SolSignerSeed = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(cpi.SolSignerSeed, omlz_seed_group_{d}.len, &omlz_c_seeds_{d});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "for (omlz_seed_group_{d}, 0..) |omlz_seed, omlz_seed_index| omlz_c_seeds_{d}[omlz_seed_index] = cpi.SolSignerSeed.fromSlice(omlz_seed);\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_out_{d}: []cpi.Pubkey = undefined;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap(cpi.Pubkey, 1, &omlz_out_{d});\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_status_{d} = cpi.sol_create_program_address(omlz_c_seeds_{d}, &omlz_program_id_{d}, &omlz_out_{d}[0]);\n", .{ block_id, block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_status_{d} != 0) break :blk{d} @as([]const u8, &.{{}});\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_out_{d}[0][0..];\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitSyscallStringCallBlock(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    expr: lir.LExpr,
    indent_level: usize,
    ctx: *EmitContext,
    call_name: []const u8,
    pass_arena: bool,
    returns_value: bool,
) EmitError!bool {
    switch (expr) {
        .Constant => |constant| switch (constant) {
            .String => |value| {
                const block_id = ctx.next_block_id;
                ctx.next_block_id += 1;
                try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
                try emitIndent(out, allocator, indent_level + 1);
                try appendPrint(out, allocator, "var omlz_syscall_bytes_{d}: [{d}]u8 = undefined;\n", .{ block_id, value.len });
                for (value, 0..) |byte, index| {
                    try emitIndent(out, allocator, indent_level + 1);
                    try appendPrint(out, allocator, "omlz_syscall_bytes_{d}[{d}] = {d};\n", .{ block_id, index, byte });
                }
                try emitIndent(out, allocator, indent_level + 1);
                if (returns_value) {
                    try appendPrint(out, allocator, "break :blk{d} {s}(", .{ block_id, call_name });
                } else {
                    try appendPrint(out, allocator, "{s}(", .{call_name});
                }
                if (pass_arena) try append(out, allocator, "arena, ");
                try appendPrint(out, allocator, "omlz_syscall_bytes_{d}[0..]);\n", .{block_id});
                if (!returns_value) {
                    try emitIndent(out, allocator, indent_level + 1);
                    try appendPrint(out, allocator, "break :blk{d};\n", .{block_id});
                }
                try emitIndent(out, allocator, indent_level);
                try append(out, allocator, "}");
                return true;
            },
            else => {},
        },
        else => {},
    }

    return false;
}

pub fn emitSyscallClockExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const clock_ty = try zigTypeName(allocator, app.ty);
    defer allocator.free(clock_ty);
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_clock_{d} = syscalls.sol_get_clock_sysvar();\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} {s}{{ .slot = @intCast(omlz_clock_{d}.slot), .epoch_start_timestamp = @intCast(omlz_clock_{d}.epoch_start_timestamp), .epoch = @intCast(omlz_clock_{d}.epoch), .leader_schedule_epoch = @intCast(omlz_clock_{d}.leader_schedule_epoch), .unix_timestamp = @intCast(omlz_clock_{d}.unix_timestamp) }};\n", .{ block_id, clock_ty, block_id, block_id, block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}
