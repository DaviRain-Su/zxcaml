// Part of src/backend/zig_codegen.zig; split by concern.
const common = @import("common.zig");
const std = common.std;
const lir = common.lir;
const EmitError = common.EmitError;
const EmitContext = common.EmitContext;
const zigTypeName = common.zigTypeName;
const arrayElementZigTypeName = common.arrayElementZigTypeName;
const emitIndent = common.emitIndent;
const append = common.append;
const appendPrint = common.appendPrint;
const expr_emission = @import("expr_emission.zig");
const emitExpr = expr_emission.emitExpr;

pub fn emitStdlibAppExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!bool {
    if (std.mem.eql(u8, name, "Bytes.of_string")) {
        try emitBytesOfString(out, allocator, app, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "Array.of_list")) {
        try emitArrayOfList(out, allocator, app, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "List.length")) {
        try emitStdlibListLength(out, allocator, app, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "List.rev")) {
        try emitStdlibListRev(out, allocator, app, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "List.append")) {
        try emitStdlibListAppend(out, allocator, app, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "List.hd")) {
        try emitStdlibListHd(out, allocator, app, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "List.tl")) {
        try emitStdlibListTl(out, allocator, app, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "Option.is_none")) {
        try emitStdlibOptionPredicate(out, allocator, app, indent_level, ctx, ".none");
        return true;
    }
    if (std.mem.eql(u8, name, "Option.is_some")) {
        try emitStdlibOptionPredicate(out, allocator, app, indent_level, ctx, ".some");
        return true;
    }
    if (std.mem.eql(u8, name, "Option.value")) {
        try emitStdlibOptionValue(out, allocator, app, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "Option.get")) {
        try emitStdlibOptionGet(out, allocator, app, indent_level, ctx);
        return true;
    }
    if (std.mem.eql(u8, name, "Result.is_ok")) {
        try emitStdlibResultPredicate(out, allocator, app, indent_level, ctx, ".ok");
        return true;
    }
    if (std.mem.eql(u8, name, "Result.is_error")) {
        try emitStdlibResultPredicate(out, allocator, app, indent_level, ctx, ".err");
        return true;
    }
    if (std.mem.eql(u8, name, "Result.ok")) {
        try emitStdlibResultOption(out, allocator, app, indent_level, ctx, ".ok");
        return true;
    }
    if (std.mem.eql(u8, name, "Result.error")) {
        try emitStdlibResultOption(out, allocator, app, indent_level, ctx, ".err");
        return true;
    }
    return false;
}

pub fn emitBytesOfString(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (app.args.len != 1) return error.UnsupportedExpr;
    switch (app.args[0].*) {
        .Constant => |constant| switch (constant) {
            .String => |value| {
                const block_id = ctx.next_block_id;
                ctx.next_block_id += 1;
                try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
                try emitIndent(out, allocator, indent_level + 1);
                try appendPrint(out, allocator, "var omlz_bytes_{d}: []u8 = undefined;\n", .{block_id});
                try emitIndent(out, allocator, indent_level + 1);
                try appendPrint(out, allocator, "arena.allocIntoOrTrap(u8, {d}, &omlz_bytes_{d});\n", .{ value.len, block_id });
                for (value, 0..) |byte, index| {
                    try emitIndent(out, allocator, indent_level + 1);
                    try appendPrint(out, allocator, "omlz_bytes_{d}[{d}] = {d};\n", .{ block_id, index, byte });
                }
                try emitIndent(out, allocator, indent_level + 1);
                try appendPrint(out, allocator, "break :blk{d} omlz_bytes_{d};\n", .{ block_id, block_id });
                try emitIndent(out, allocator, indent_level);
                try append(out, allocator, "}");
                return;
            },
            .Int => return error.UnsupportedExpr,
        },
        else => try emitExpr(out, allocator, app.args[0].*, indent_level, ctx),
    }
}

pub fn emitArrayOfList(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (app.args.len != 1) return error.UnsupportedExpr;
    const elem_ty = arrayElementZigTypeName(allocator, app.ty) catch return error.UnsupportedExpr;
    defer allocator.free(elem_ty);
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;

    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_array_count_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_array_len_{d}: usize = 0;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "while (omlz_array_count_{d}.tag == .cons) {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "omlz_array_len_{d} += 1;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "omlz_array_count_{d} = omlz_array_count_{d}.tail.?.*;\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_array_out_{d}: []{s} = undefined;\n", .{ block_id, elem_ty });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "arena.allocIntoOrTrap({s}, omlz_array_len_{d}, &omlz_array_out_{d});\n", .{ elem_ty, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_array_current_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_array_index_{d}: usize = 0;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "while (omlz_array_current_{d}.tag == .cons) {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "omlz_array_out_{d}[omlz_array_index_{d}] = omlz_array_current_{d}.head;\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "omlz_array_index_{d} += 1;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "omlz_array_current_{d} = omlz_array_current_{d}.tail.?.*;\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_array_out_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStdlibListLength(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (app.args.len != 1) return error.UnsupportedExpr;
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_list_current_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_list_len_{d}: i64 = 0;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "while (omlz_list_current_{d}.tag == .cons) {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "omlz_list_len_{d} +%= 1;\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "omlz_list_current_{d} = omlz_list_current_{d}.tail.?.*;\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_list_len_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStdlibListRev(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (app.args.len != 1) return error.UnsupportedExpr;
    const list_ty = try zigTypeName(allocator, app.ty);
    defer allocator.free(list_ty);
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_list_current_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_list_acc_{d}: {s} = {s}.Nil();\n", .{ block_id, list_ty, list_ty });
    try emitStdlibListConsLoop(out, allocator, block_id, indent_level, "omlz_list_current", "omlz_list_acc", list_ty);
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_list_acc_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStdlibListAppend(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (app.args.len != 2) return error.UnsupportedExpr;
    const list_ty = try zigTypeName(allocator, app.ty);
    defer allocator.free(list_ty);
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_append_left_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_append_right_{d}: {s} = ", .{ block_id, list_ty });
    try emitExpr(out, allocator, app.args[1].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_append_rev_{d}: {s} = {s}.Nil();\n", .{ block_id, list_ty, list_ty });
    try emitStdlibListConsLoop(out, allocator, block_id, indent_level, "omlz_append_left", "omlz_append_rev", list_ty);
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "var omlz_append_rev_current_{d} = omlz_append_rev_{d};\n", .{ block_id, block_id });
    try emitStdlibListConsLoop(out, allocator, block_id, indent_level, "omlz_append_rev_current", "omlz_append_right", list_ty);
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "break :blk{d} omlz_append_right_{d};\n", .{ block_id, block_id });
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStdlibListConsLoop(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    block_id: usize,
    indent_level: usize,
    current_prefix: []const u8,
    acc_prefix: []const u8,
    list_ty: []const u8,
) EmitError!void {
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "while ({s}_{d}.tag == .cons) {{\n", .{ current_prefix, block_id });
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "{s}_{d} = {s}.ConsAlloc(arena, {s}_{d}.head, {s}_{d});\n", .{ acc_prefix, block_id, list_ty, current_prefix, block_id, acc_prefix, block_id });
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "{s}_{d} = {s}_{d}.tail.?.*;\n", .{ current_prefix, block_id, current_prefix, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");
}

pub fn emitStdlibListHd(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (app.args.len != 1) return error.UnsupportedExpr;
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_list_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_list_{d}.tag == .cons) break :blk{d} omlz_list_{d}.head;\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "unreachable;\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStdlibListTl(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (app.args.len != 1) return error.UnsupportedExpr;
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_list_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "if (omlz_list_{d}.tag == .cons) break :blk{d} omlz_list_{d}.tail.?.*;\n", .{ block_id, block_id, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "unreachable;\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStdlibOptionPredicate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
    wanted_tag: []const u8,
) EmitError!void {
    if (app.args.len != 1) return error.UnsupportedExpr;
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    const other_tag = if (std.mem.eql(u8, wanted_tag, ".none")) ".some" else ".none";
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_option_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "switch (omlz_option_{d}) {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    if (std.mem.eql(u8, wanted_tag, ".some")) {
        try appendPrint(out, allocator, "{s} => break :blk{d} prelude.Bool.true,\n", .{ wanted_tag, block_id });
    } else {
        try appendPrint(out, allocator, "{s} => break :blk{d} prelude.Bool.true,\n", .{ wanted_tag, block_id });
    }
    try emitIndent(out, allocator, indent_level + 2);
    if (std.mem.eql(u8, other_tag, ".some")) {
        try appendPrint(out, allocator, "{s} => break :blk{d} prelude.Bool.false,\n", .{ other_tag, block_id });
    } else {
        try appendPrint(out, allocator, "{s} => break :blk{d} prelude.Bool.false,\n", .{ other_tag, block_id });
    }
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStdlibOptionValue(
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
    try appendPrint(out, allocator, "const omlz_option_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "switch (omlz_option_{d}) {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, ".some => |value| break :blk{d} value,\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, ".none => break :blk{d} ", .{block_id});
    try emitExpr(out, allocator, app.args[1].*, indent_level + 2, ctx);
    try append(out, allocator, ",\n");
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStdlibOptionGet(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (app.args.len != 1) return error.UnsupportedExpr;
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_option_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "switch (omlz_option_{d}) {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, ".some => |value| break :blk{d} value,\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try append(out, allocator, ".none => unreachable,\n");
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStdlibResultPredicate(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
    wanted_tag: []const u8,
) EmitError!void {
    if (app.args.len != 1) return error.UnsupportedExpr;
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_result_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "switch (omlz_result_{d}) {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "{s} => break :blk{d} prelude.Bool.true,\n", .{ wanted_tag, block_id });
    try emitIndent(out, allocator, indent_level + 2);
    const other_tag = if (std.mem.eql(u8, wanted_tag, ".ok")) ".err" else ".ok";
    try appendPrint(out, allocator, "{s} => break :blk{d} prelude.Bool.false,\n", .{ other_tag, block_id });
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitStdlibResultOption(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    app: lir.LApp,
    indent_level: usize,
    ctx: *EmitContext,
    wanted_tag: []const u8,
) EmitError!void {
    if (app.args.len != 1) return error.UnsupportedExpr;
    const option_ty = try zigTypeName(allocator, app.ty);
    defer allocator.free(option_ty);
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const omlz_result_{d} = ", .{block_id});
    try emitExpr(out, allocator, app.args[0].*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "switch (omlz_result_{d}) {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 2);
    try appendPrint(out, allocator, "{s} => |value| break :blk{d} {s}.Some(value),\n", .{ wanted_tag, block_id, option_ty });
    try emitIndent(out, allocator, indent_level + 2);
    const other_tag = if (std.mem.eql(u8, wanted_tag, ".ok")) ".err" else ".ok";
    try appendPrint(out, allocator, "{s} => break :blk{d} {s}.None(),\n", .{ other_tag, block_id, option_ty });
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "}\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}
