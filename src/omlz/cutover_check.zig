//! Legacy runtime API cutover validation shared by `check`/`run`/`idl`/`build`.
//!
//! RESPONSIBILITIES:
//! - Reject legacy runtime `external` declarations in the source text with a
//!   pointer to the SDK-backed replacement.
//! - Reject unshadowed references to legacy runtime helper values in the
//!   parsed module.
const std = @import("std");
const Io = std.Io;
const cmd_common = @import("cmd_common.zig");
const frontend_bridge = @import("../frontend_bridge/ttree.zig");

const CutoverApiDiagnostic = struct {
    legacy: []const u8,
    replacement: []const u8,
    file: []const u8,
    line: u32,
    col: u32,
    external_name: ?[]const u8 = null,
};

pub fn validateCutoverApiUsageOrReport(
    allocator: std.mem.Allocator,
    io: Io,
    module: frontend_bridge.Module,
    input_file: []const u8,
) !bool {
    if (try findLegacyExternalInSource(allocator, io, input_file)) |diagnostic| {
        try reportCutoverApiDiagnostic(allocator, io, diagnostic, true);
        return false;
    }
    if (findLegacyValueDiagnostic(module, input_file)) |diagnostic| {
        try reportCutoverApiDiagnostic(allocator, io, diagnostic, false);
        return false;
    }
    return true;
}

fn reportCutoverApiDiagnostic(
    allocator: std.mem.Allocator,
    io: Io,
    diagnostic: CutoverApiDiagnostic,
    is_external: bool,
) !void {
    const message = if (is_external)
        try std.fmt.allocPrint(
            allocator,
            "{s}:{d}:{d}: error: legacy runtime external `{s}` is no longer supported under the SDK-backed public API; remove that external declaration and use `{s}` instead of `{s}`.\n",
            .{
                diagnostic.file,
                diagnostic.line,
                diagnostic.col,
                diagnostic.external_name orelse diagnostic.legacy,
                diagnostic.replacement,
                diagnostic.legacy,
            },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}:{d}:{d}: error: legacy runtime helper `{s}` is no longer supported under the SDK-backed public API; use `{s}` instead.\n",
            .{
                diagnostic.file,
                diagnostic.line,
                diagnostic.col,
                diagnostic.legacy,
                diagnostic.replacement,
            },
        );
    defer allocator.free(message);
    try cmd_common.writeStderr(io, message);
}

fn legacyValueReplacement(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "invoke")) return "Cpi.invoke";
    if (std.mem.eql(u8, name, "invoke_signed")) return "Cpi.invoke_signed";
    if (std.mem.eql(u8, name, "set_return_data")) return "Cpi.set_return_data";
    if (std.mem.eql(u8, name, "get_return_data")) return "Cpi.get_return_data";
    return null;
}

const LegacyValueShadowState = struct {
    invoke: bool = false,
    invoke_signed: bool = false,
    set_return_data: bool = false,
    get_return_data: bool = false,
};

fn shadowLegacyValue(state: LegacyValueShadowState, name: []const u8) LegacyValueShadowState {
    var next = state;
    if (std.mem.eql(u8, name, "invoke")) next.invoke = true;
    if (std.mem.eql(u8, name, "invoke_signed")) next.invoke_signed = true;
    if (std.mem.eql(u8, name, "set_return_data")) next.set_return_data = true;
    if (std.mem.eql(u8, name, "get_return_data")) next.get_return_data = true;
    return next;
}

fn legacyValueIsShadowed(state: LegacyValueShadowState, name: []const u8) bool {
    if (std.mem.eql(u8, name, "invoke")) return state.invoke;
    if (std.mem.eql(u8, name, "invoke_signed")) return state.invoke_signed;
    if (std.mem.eql(u8, name, "set_return_data")) return state.set_return_data;
    if (std.mem.eql(u8, name, "get_return_data")) return state.get_return_data;
    return false;
}

fn findLegacyExternalInSource(
    allocator: std.mem.Allocator,
    io: Io,
    input_file: []const u8,
) !?CutoverApiDiagnostic {
    const source = std.Io.Dir.cwd().readFileAlloc(io, input_file, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(source);

    const rules = [_]struct { symbol: []const u8, replacement: []const u8 }{
        .{ .symbol = "sol_log_", .replacement = "Syscall.sol_log" },
        .{ .symbol = "sol_log_64_", .replacement = "Syscall.sol_log_64" },
        .{ .symbol = "sol_log_pubkey", .replacement = "Syscall.sol_log_pubkey" },
        .{ .symbol = "sol_sha256", .replacement = "Crypto.sha256" },
        .{ .symbol = "sol_sha256_alloc", .replacement = "Crypto.sha256" },
        .{ .symbol = "sol_keccak256", .replacement = "Crypto.keccak256" },
        .{ .symbol = "sol_keccak256_alloc", .replacement = "Crypto.keccak256" },
        .{ .symbol = "sol_blake3", .replacement = "Crypto.blake3" },
        .{ .symbol = "sol_blake3_alloc", .replacement = "Crypto.blake3" },
        .{ .symbol = "sol_secp256k1_recover_alloc", .replacement = "Crypto.secp256k1_recover" },
        .{ .symbol = "sol_get_clock_sysvar", .replacement = "Syscall.sol_get_clock_sysvar" },
        .{ .symbol = "sol_get_rent_lamports_per_byte_year", .replacement = "Syscall.sol_get_rent_lamports_per_byte_year" },
        .{ .symbol = "sol_log_compute_units_", .replacement = "Syscall.sol_log_compute_units" },
        .{ .symbol = "sol_remaining_compute_units", .replacement = "Syscall.sol_remaining_compute_units" },
        .{ .symbol = "sysvar.readClock", .replacement = "Sysvar.clock_from_account" },
        .{ .symbol = "sysvar.readRent", .replacement = "Sysvar.rent_from_account" },
        .{ .symbol = "sysvar.readInstructionsHeader", .replacement = "Sysvar.instructions_header_from_account" },
        .{ .symbol = "sysvar.readInstructionAt", .replacement = "Sysvar.instruction_at" },
        .{ .symbol = "sysvar.readStakeHistory", .replacement = "Sysvar.stake_history_latest_from_account" },
        .{ .symbol = "sysvar.readEpochSchedule", .replacement = "Sysvar.epoch_schedule_from_account" },
        .{ .symbol = "Cpi.set_return_data", .replacement = "Cpi.set_return_data" },
        .{ .symbol = "Cpi.get_return_data", .replacement = "Cpi.get_return_data" },
        .{ .symbol = "Cpi.get_return_program_id", .replacement = "Cpi.get_return_program_id" },
    };

    for (rules) |rule| {
        const needle = try std.fmt.allocPrint(allocator, "= \"{s}\"", .{rule.symbol});
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, source, needle)) |index| {
            var line: u32 = 1;
            var col: u32 = 1;
            for (source[0..index]) |byte| {
                if (byte == '\n') {
                    line += 1;
                    col = 1;
                } else {
                    col += 1;
                }
            }
            return .{
                .legacy = rule.symbol,
                .replacement = rule.replacement,
                .file = input_file,
                .line = line,
                .col = col,
            };
        }
    }
    return null;
}

fn findLegacyValueDiagnostic(module: frontend_bridge.Module, input_file: []const u8) ?CutoverApiDiagnostic {
    for (module.decls) |decl| {
        switch (decl) {
            .Let => |let_decl| {
                var state = LegacyValueShadowState{};
                state = shadowLegacyValue(state, let_decl.name);
                if (findLegacyValueInExpr(let_decl.body, input_file, state)) |diagnostic| return diagnostic;
            },
            .LetRecGroup => |group| {
                var state = LegacyValueShadowState{};
                for (group.bindings) |binding| state = shadowLegacyValue(state, binding.name);
                for (group.bindings) |binding| {
                    var binding_state = state;
                    for (binding.params) |param| binding_state = shadowLegacyValue(binding_state, param);
                    if (findLegacyValueInExpr(binding.body, input_file, binding_state)) |diagnostic| return diagnostic;
                }
            },
        }
    }
    return null;
}

fn makeValueDiagnostic(input_file: []const u8, loc: frontend_bridge.Loc, legacy: []const u8, replacement: []const u8) CutoverApiDiagnostic {
    return .{
        .legacy = legacy,
        .replacement = replacement,
        .file = if (loc.isUnknown()) input_file else loc.file,
        .line = if (loc.isUnknown()) 1 else loc.line,
        .col = if (loc.isUnknown()) 1 else loc.col,
    };
}

fn findLegacyValueInExpr(
    expr: frontend_bridge.Expr,
    input_file: []const u8,
    shadow_state: LegacyValueShadowState,
) ?CutoverApiDiagnostic {
    switch (expr) {
        .Lambda => |value| {
            var state = shadow_state;
            for (value.params) |param| state = shadowLegacyValue(state, param);
            return findLegacyValueInExpr(value.body.*, input_file, state);
        },
        .Constant => return null,
        .App => |value| {
            if (findLegacyValueInExpr(value.callee.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            for (value.args) |arg| {
                if (findLegacyValueInExpr(arg, input_file, shadow_state)) |diagnostic| return diagnostic;
            }
            return null;
        },
        .Let => |value| {
            const body_state = shadowLegacyValue(shadow_state, value.name);
            if (value.is_rec) {
                if (findLegacyValueInExpr(value.value.*, input_file, body_state)) |diagnostic| return diagnostic;
            } else if (findLegacyValueInExpr(value.value.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            return findLegacyValueInExpr(value.body.*, input_file, body_state);
        },
        .LetRecGroup => |value| {
            var state = shadow_state;
            for (value.bindings) |binding| state = shadowLegacyValue(state, binding.name);
            for (value.bindings) |binding| {
                var binding_state = state;
                for (binding.params) |param| binding_state = shadowLegacyValue(binding_state, param);
                if (findLegacyValueInExpr(binding.body, input_file, binding_state)) |diagnostic| return diagnostic;
            }
            return findLegacyValueInExpr(value.body.*, input_file, state);
        },
        .Assert => |value| return findLegacyValueInExpr(value.condition.*, input_file, shadow_state),
        .If => |value| {
            if (findLegacyValueInExpr(value.cond.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            if (findLegacyValueInExpr(value.then_branch.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            return findLegacyValueInExpr(value.else_branch.*, input_file, shadow_state);
        },
        .Prim => |value| {
            for (value.args) |arg| {
                if (findLegacyValueInExpr(arg, input_file, shadow_state)) |diagnostic| return diagnostic;
            }
            return null;
        },
        .Var => |value| {
            if (!legacyValueIsShadowed(shadow_state, value.name)) {
                if (legacyValueReplacement(value.name)) |replacement| {
                    return makeValueDiagnostic(input_file, value.loc, value.name, replacement);
                }
            }
            return null;
        },
        .Ctor => |value| {
            for (value.args) |arg| {
                if (findLegacyValueInExpr(arg, input_file, shadow_state)) |diagnostic| return diagnostic;
            }
            return null;
        },
        .Match => |value| {
            if (findLegacyValueInExpr(value.scrutinee.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            for (value.arms) |arm| {
                if (arm.guard) |guard| {
                    if (findLegacyValueInExpr(guard.*, input_file, shadow_state)) |diagnostic| return diagnostic;
                }
                if (findLegacyValueInExpr(arm.body.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            }
            return null;
        },
        .Tuple => |value| {
            for (value.items) |item| {
                if (findLegacyValueInExpr(item, input_file, shadow_state)) |diagnostic| return diagnostic;
            }
            return null;
        },
        .TupleProj => |value| return findLegacyValueInExpr(value.tuple_expr.*, input_file, shadow_state),
        .Record => |value| {
            for (value.fields) |field| {
                if (findLegacyValueInExpr(field.value, input_file, shadow_state)) |diagnostic| return diagnostic;
            }
            return null;
        },
        .RecordField => |value| return findLegacyValueInExpr(value.record_expr.*, input_file, shadow_state),
        .RecordUpdate => |value| {
            if (findLegacyValueInExpr(value.base_expr.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            for (value.fields) |field| {
                if (findLegacyValueInExpr(field.value, input_file, shadow_state)) |diagnostic| return diagnostic;
            }
            return null;
        },
        .FieldSet => |value| {
            if (findLegacyValueInExpr(value.record_expr.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            return findLegacyValueInExpr(value.value.*, input_file, shadow_state);
        },
        .ArrayLit => |value| {
            for (value.elems) |elem| {
                if (findLegacyValueInExpr(elem, input_file, shadow_state)) |diagnostic| return diagnostic;
            }
            return null;
        },
        .ArrayGet => |value| {
            if (findLegacyValueInExpr(value.arr.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            return findLegacyValueInExpr(value.idx.*, input_file, shadow_state);
        },
        .ArrayLength => |value| return findLegacyValueInExpr(value.arr.*, input_file, shadow_state),
        .ArraySet => |value| {
            if (findLegacyValueInExpr(value.arr.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            if (findLegacyValueInExpr(value.idx.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            return findLegacyValueInExpr(value.value.*, input_file, shadow_state);
        },
        .ArrayMake => |value| return findLegacyValueInExpr(value.init.*, input_file, shadow_state),
        .RefMake => |value| return findLegacyValueInExpr(value.init.*, input_file, shadow_state),
        .RefGet => |value| return findLegacyValueInExpr(value.target.*, input_file, shadow_state),
        .RefSet => |value| {
            if (findLegacyValueInExpr(value.target.*, input_file, shadow_state)) |diagnostic| return diagnostic;
            return findLegacyValueInExpr(value.value.*, input_file, shadow_state);
        },
    }
}
