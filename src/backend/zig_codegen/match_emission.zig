// Part of src/backend/zig_codegen.zig; split by concern.
const common = @import("common.zig");
const std = common.std;
const lir = common.lir;
const match_compiler = common.match_compiler;
const EmitError = common.EmitError;
const EmitContext = common.EmitContext;
const armUsesName = common.armUsesName;
const patternsNeedSource = common.patternsNeedSource;
const patternNeedsSource = common.patternNeedsSource;
const patternIsIrrefutable = common.patternIsIrrefutable;
const matchHasCtorArm = common.matchHasCtorArm;
const matchHasUserCtorArm = common.matchHasUserCtorArm;
const matchHasBuiltinListCtorArm = common.matchHasBuiltinListCtorArm;
const emittedVariantName = common.emittedVariantName;
const sameConstructor = common.sameConstructor;
const matchHasDefaultRows = common.matchHasDefaultRows;
const containsString = common.containsString;
const findUserVariant = common.findUserVariant;
const findUserTypeDecl = common.findUserTypeDecl;
const isRecursivePayload = common.isRecursivePayload;
const userVariantName = common.userVariantName;
const ctorVariantName = common.ctorVariantName;
const emitIdentifier = common.emitIdentifier;
const emitIndent = common.emitIndent;
const append = common.append;
const appendPrint = common.appendPrint;
const expr_emission = @import("expr_emission.zig");
const emitExpr = expr_emission.emitExpr;

pub fn emitMatchExpr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    match_expr: lir.LMatch,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const block_id = ctx.next_block_id;
    ctx.next_block_id += 1;
    const scrutinee_name = try std.fmt.allocPrint(allocator, "omlz_match_scrutinee_{d}", .{block_id});
    defer allocator.free(scrutinee_name);

    try appendPrint(out, allocator, "blk{d}: {{\n", .{block_id});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, "const {s} = ", .{scrutinee_name});
    try emitExpr(out, allocator, match_expr.scrutinee.*, indent_level + 1, ctx);
    try append(out, allocator, ";\n");

    if (!matchHasCtorArm(match_expr)) {
        try emitNonCtorMatch(out, allocator, match_expr, scrutinee_name, block_id, indent_level, ctx);
        try emitIndent(out, allocator, indent_level);
        try append(out, allocator, "}");
        return;
    }

    try emitDecisionMatchArms(out, allocator, match_expr, scrutinee_name, block_id, indent_level + 1, ctx);
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}");
}

pub fn emitDecisionMatchArms(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    match_expr: lir.LMatch,
    scrutinee_name: []const u8,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    var decision_arena = std.heap.ArenaAllocator.init(allocator);
    defer decision_arena.deinit();
    const decision_allocator = decision_arena.allocator();
    const matrix = try buildDecisionMatrix(decision_allocator, match_expr);
    const actions = try buildDecisionActions(decision_allocator, match_expr.arms.len);
    const tree = try match_compiler.compileMatrix(decision_allocator, matrix, actions);

    switch (tree.*) {
        .Switch => {},
        .Leaf, .Fail => {
            try emitSequentialMatchRows(out, allocator, match_expr, scrutinee_name, block_id, indent_level, ctx);
            return;
        },
    }
    if (matchHasBuiltinListCtorArm(match_expr)) {
        try emitSequentialMatchRows(out, allocator, match_expr, scrutinee_name, block_id, indent_level, ctx);
        return;
    }

    const user_ctor_match = matchHasUserCtorArm(match_expr);
    var emitted = std.ArrayList([]const u8).empty;
    defer {
        for (emitted.items) |name| allocator.free(name);
        emitted.deinit(allocator);
    }

    try emitIndent(out, allocator, indent_level);
    if (user_ctor_match) {
        try appendPrint(out, allocator, "switch ({s}.tag) {{\n", .{scrutinee_name});
    } else {
        try appendPrint(out, allocator, "switch ({s}) {{\n", .{scrutinee_name});
    }

    const switch_node = tree.Switch;
    for (switch_node.cases) |case| {
        const ctor_pattern = findTopLevelCtorPattern(match_expr, case.constructor) orelse continue;
        const variant = try emittedVariantName(allocator, ctor_pattern);
        defer allocator.free(variant);
        if (containsString(emitted.items, variant)) continue;
        try emitted.append(allocator, try allocator.dupe(u8, variant));
        try emitDecisionCase(out, allocator, match_expr, ctor_pattern, variant, scrutinee_name, block_id, indent_level + 1, ctx);
    }

    if (matchHasDefaultRows(match_expr) or hasMissingConstructors(allocator, ctx.type_decls, match_expr, emitted.items)) {
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "else => {\n");
        if (matchHasDefaultRows(match_expr)) {
            try emitDefaultRows(out, allocator, match_expr, scrutinee_name, block_id, indent_level + 2, ctx);
        }
        if (!matchHasUnguardedCatchAll(match_expr)) {
            try emitNonExhaustivePanic(out, allocator, ctx.type_decls, match_expr, emitted.items, indent_level + 2);
        }
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "},\n");
    }

    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}\n");
}

pub fn buildDecisionMatrix(allocator: std.mem.Allocator, match_expr: lir.LMatch) EmitError![]const []const lir.LPattern {
    const matrix = try allocator.alloc([]const lir.LPattern, match_expr.arms.len);
    for (match_expr.arms, 0..) |arm, index| {
        const row = try allocator.alloc(lir.LPattern, 1);
        row[0] = arm.pattern;
        matrix[index] = row;
    }
    return matrix;
}

pub fn buildDecisionActions(allocator: std.mem.Allocator, arm_count: usize) EmitError![]const usize {
    const actions = try allocator.alloc(usize, arm_count);
    for (actions, 0..) |*action, index| action.* = index;
    return actions;
}

pub fn findTopLevelCtorPattern(match_expr: lir.LMatch, constructor: []const u8) ?lir.LCtorPattern {
    for (match_expr.arms) |arm| {
        switch (arm.pattern) {
            .Ctor => |ctor| if (std.mem.eql(u8, ctor.name, constructor)) return ctor,
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {},
        }
    }
    return null;
}

pub fn emitDecisionCase(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    match_expr: lir.LMatch,
    selected_ctor: lir.LCtorPattern,
    variant: []const u8,
    scrutinee_name: []const u8,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, ".{s}", .{variant});

    const payload_name: ?[]const u8 = if (selected_ctor.type_name == null and selected_ctor.args.len > 0)
        try std.fmt.allocPrint(allocator, "omlz_match_payload_{d}", .{ctx.next_block_id})
    else
        null;
    defer if (payload_name) |name| allocator.free(name);
    if (payload_name != null) ctx.next_block_id += 1;

    if (payload_name) |name| {
        try appendPrint(out, allocator, " => |{s}| {{\n", .{name});
        if (!caseNeedsBuiltinPayload(match_expr, selected_ctor)) {
            try emitIndent(out, allocator, indent_level + 1);
            try appendPrint(out, allocator, "_ = {s};\n", .{name});
        }
    } else {
        try append(out, allocator, " => {\n");
    }

    var case_covered = false;
    for (match_expr.arms) |arm| {
        if (case_covered) break;
        switch (arm.pattern) {
            .Ctor => |ctor_pattern| {
                if (!sameConstructor(ctor_pattern, selected_ctor)) continue;
                try emitSpecializedCtorRow(out, allocator, ctor_pattern, arm.body.*, arm.guard, scrutinee_name, payload_name, block_id, indent_level + 1, ctx);
                if (arm.guard == null and ctorPayloadsIrrefutable(ctor_pattern.args)) case_covered = true;
            },
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {
                const patterns = [_]lir.LPattern{arm.pattern};
                const sources = [_][]const u8{scrutinee_name};
                try emitPatternSequence(out, allocator, patterns[0..], sources[0..], arm.body.*, arm.guard, block_id, indent_level + 1, ctx);
                if (arm.guard == null and patternIsIrrefutable(arm.pattern)) case_covered = true;
            },
        }
    }

    const exhaustively_covered = case_covered or try caseExhaustivelyCovered(allocator, ctx.type_decls, match_expr, selected_ctor);
    if (!exhaustively_covered) {
        try emitNonExhaustivePanic(out, allocator, ctx.type_decls, match_expr, &.{}, indent_level + 1);
    } else if (!case_covered) {
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "unreachable;\n");
    }
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "},\n");
}

pub fn emitSpecializedCtorRow(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ctor_pattern: lir.LCtorPattern,
    body: lir.LExpr,
    guard: ?*const lir.LExpr,
    scrutinee_name: []const u8,
    builtin_payload_name: ?[]const u8,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (ctor_pattern.type_name != null) {
        const type_name = ctor_pattern.type_name.?;
        const variant_info = findUserVariant(ctx.type_decls, type_name, ctor_pattern.name) orelse return error.UnsupportedExpr;
        if (variant_info.payload_types.len != ctor_pattern.args.len) return error.UnsupportedExpr;
        const variant = try userVariantName(allocator, ctor_pattern.name);
        defer allocator.free(variant);

        var payload_sources = std.ArrayList([]const u8).empty;
        defer {
            for (payload_sources.items) |payload_source| allocator.free(payload_source);
            payload_sources.deinit(allocator);
        }
        for (ctor_pattern.args, variant_info.payload_types, 0..) |_, payload_ty, index| {
            const payload_name = try std.fmt.allocPrint(allocator, "omlz_match_payload_{d}", .{ctx.next_block_id});
            ctx.next_block_id += 1;
            try emitIndent(out, allocator, indent_level);
            try appendPrint(out, allocator, "const {s} = ", .{payload_name});
            if (ctor_pattern.args.len == 1) {
                try appendPrint(out, allocator, "{s}.payload.{s}", .{ scrutinee_name, variant });
            } else {
                try appendPrint(out, allocator, "{s}.payload.{s}._{d}", .{ scrutinee_name, variant, index });
            }
            if (isRecursivePayload(payload_ty)) try append(out, allocator, ".*");
            try append(out, allocator, ";\n");
            if (!patternNeedsSource(ctor_pattern.args[index], body, guard)) {
                try emitIndent(out, allocator, indent_level);
                try appendPrint(out, allocator, "_ = {s};\n", .{payload_name});
            }
            try payload_sources.append(allocator, payload_name);
        }
        try emitPatternSequence(out, allocator, ctor_pattern.args, payload_sources.items, body, guard, block_id, indent_level, ctx);
        return;
    }

    if (ctor_pattern.args.len == 0) {
        try emitGuardedMatchBreak(out, allocator, body, guard, block_id, indent_level, ctx);
        return;
    }
    const payload_name = builtin_payload_name orelse return error.UnsupportedExpr;
    var payload_sources = std.ArrayList([]const u8).empty;
    defer {
        for (payload_sources.items) |payload_source| {
            if (!std.mem.eql(u8, payload_source, payload_name)) allocator.free(payload_source);
        }
        payload_sources.deinit(allocator);
    }
    if (std.mem.eql(u8, ctor_pattern.name, "::")) {
        if (ctor_pattern.args.len != 2) return error.UnsupportedExpr;
        try payload_sources.append(allocator, try std.fmt.allocPrint(allocator, "{s}.head", .{payload_name}));
        try payload_sources.append(allocator, try std.fmt.allocPrint(allocator, "{s}.tail.*", .{payload_name}));
    } else {
        if (ctor_pattern.args.len != 1) return error.UnsupportedExpr;
        try payload_sources.append(allocator, payload_name);
    }
    try emitPatternSequence(out, allocator, ctor_pattern.args, payload_sources.items, body, guard, block_id, indent_level, ctx);
}

pub fn emitDefaultRows(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    match_expr: lir.LMatch,
    scrutinee_name: []const u8,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    for (match_expr.arms) |arm| {
        switch (arm.pattern) {
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {
                const patterns = [_]lir.LPattern{arm.pattern};
                const sources = [_][]const u8{scrutinee_name};
                try emitPatternSequence(out, allocator, patterns[0..], sources[0..], arm.body.*, arm.guard, block_id, indent_level, ctx);
            },
            .Ctor => {},
        }
    }
}

pub fn emitPatternSequence(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    patterns: []const lir.LPattern,
    sources: []const []const u8,
    body: lir.LExpr,
    guard: ?*const lir.LExpr,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (patterns.len != sources.len) return error.UnsupportedExpr;
    if (patterns.len == 0) {
        try emitGuardedMatchBreak(out, allocator, body, guard, block_id, indent_level, ctx);
        return;
    }

    const pattern = patterns[0];
    const source = sources[0];
    switch (pattern) {
        .Wildcard => {
            try emitIndent(out, allocator, indent_level);
            try append(out, allocator, "{\n");
            try emitPatternSequence(out, allocator, patterns[1..], sources[1..], body, guard, block_id, indent_level + 1, ctx);
            try emitIndent(out, allocator, indent_level);
            try append(out, allocator, "}\n");
        },
        .Var => |name| {
            const should_bind = !std.mem.eql(u8, name, "_") and armUsesName(body, guard, name);
            try emitIndent(out, allocator, indent_level);
            try append(out, allocator, "{\n");
            if (should_bind) {
                try emitIndent(out, allocator, indent_level + 1);
                try append(out, allocator, "const ");
                try emitIdentifier(out, allocator, name);
                try appendPrint(out, allocator, " = {s};\n", .{source});
            }
            try emitPatternSequence(out, allocator, patterns[1..], sources[1..], body, guard, block_id, indent_level + 1, ctx);
            try emitIndent(out, allocator, indent_level);
            try append(out, allocator, "}\n");
        },
        .Constant => |constant| {
            try emitIndent(out, allocator, indent_level);
            try append(out, allocator, "if (");
            try emitConstantPatternCondition(out, allocator, constant, source);
            try append(out, allocator, ") {\n");
            try emitPatternSequence(out, allocator, patterns[1..], sources[1..], body, guard, block_id, indent_level + 1, ctx);
            try emitIndent(out, allocator, indent_level);
            try append(out, allocator, "}\n");
        },
        .Alias => |alias| {
            const alias_bind = lir.LPattern{ .Var = alias.name };
            const alias_patterns = [_]lir.LPattern{ alias.pattern.*, alias_bind };
            const alias_sources = [_][]const u8{ source, source };
            try emitCombinedPatternSequence(out, allocator, alias_patterns[0..], alias_sources[0..], patterns[1..], sources[1..], body, guard, block_id, indent_level, ctx);
        },
        .Ctor => |ctor_pattern| try emitCtorPatternSequence(out, allocator, ctor_pattern, source, patterns[1..], sources[1..], body, guard, block_id, indent_level, ctx),
        .Tuple => |items| {
            var item_sources = std.ArrayList([]const u8).empty;
            defer {
                for (item_sources.items) |item_source| allocator.free(item_source);
                item_sources.deinit(allocator);
            }
            for (items, 0..) |_, index| {
                try item_sources.append(allocator, try std.fmt.allocPrint(allocator, "{s}.@\"{d}\"", .{ source, index }));
            }
            try emitCombinedPatternSequence(out, allocator, items, item_sources.items, patterns[1..], sources[1..], body, guard, block_id, indent_level, ctx);
        },
        .Record => |fields| {
            var field_sources = std.ArrayList([]const u8).empty;
            var field_patterns = std.ArrayList(lir.LPattern).empty;
            defer {
                for (field_sources.items) |field_source| allocator.free(field_source);
                field_sources.deinit(allocator);
                field_patterns.deinit(allocator);
            }
            for (fields) |field| {
                const field_source = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ source, field.name });
                try field_sources.append(allocator, field_source);
                try field_patterns.append(allocator, field.pattern);
            }
            try emitCombinedPatternSequence(out, allocator, field_patterns.items, field_sources.items, patterns[1..], sources[1..], body, guard, block_id, indent_level, ctx);
        },
    }
}

pub fn emitConstantPatternCondition(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    constant: lir.LPatternConstant,
    source: []const u8,
) EmitError!void {
    switch (constant) {
        .Int => |value| try appendPrint(out, allocator, "{s} == @as(i64, {d})", .{ source, value }),
        .Char => |value| try appendPrint(out, allocator, "{s} == @as(i64, {d})", .{ source, value }),
        .String => |value| try appendPrint(out, allocator, "std.mem.eql(u8, {s}, \"{f}\")", .{ source, std.zig.fmtString(value) }),
    }
}

pub fn emitCtorPatternSequence(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ctor_pattern: lir.LCtorPattern,
    source: []const u8,
    rest_patterns: []const lir.LPattern,
    rest_sources: []const []const u8,
    body: lir.LExpr,
    guard: ?*const lir.LExpr,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (ctor_pattern.type_name != null) {
        try emitUserCtorPatternSequence(out, allocator, ctor_pattern, source, rest_patterns, rest_sources, body, guard, block_id, indent_level, ctx);
        return;
    }

    const variant = try ctorVariantName(ctor_pattern.name);
    if (std.mem.eql(u8, ctor_pattern.name, "[]")) {
        try emitIndent(out, allocator, indent_level);
        try appendPrint(out, allocator, "if ({s}.tag == .nil) {{\n", .{source});
        try emitPatternSequence(out, allocator, rest_patterns, rest_sources, body, guard, block_id, indent_level + 1, ctx);
        try emitIndent(out, allocator, indent_level);
        try append(out, allocator, "}\n");
        return;
    }
    if (std.mem.eql(u8, ctor_pattern.name, "::")) {
        if (ctor_pattern.args.len != 2) return error.UnsupportedExpr;
        var payload_sources = std.ArrayList([]const u8).empty;
        defer {
            for (payload_sources.items) |payload_source| allocator.free(payload_source);
            payload_sources.deinit(allocator);
        }
        try payload_sources.append(allocator, try std.fmt.allocPrint(allocator, "{s}.head", .{source}));
        try payload_sources.append(allocator, try std.fmt.allocPrint(allocator, "{s}.tail.?.*", .{source}));
        try emitIndent(out, allocator, indent_level);
        try appendPrint(out, allocator, "if ({s}.tag == .cons) {{\n", .{source});
        try emitCombinedPatternSequence(out, allocator, ctor_pattern.args, payload_sources.items, rest_patterns, rest_sources, body, guard, block_id, indent_level + 1, ctx);
        try emitIndent(out, allocator, indent_level);
        try append(out, allocator, "}\n");
        return;
    }
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "switch ({s}) {{\n", .{source});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, ".{s}", .{variant});

    if (ctor_pattern.args.len == 0) {
        try append(out, allocator, " => {\n");
        try emitPatternSequence(out, allocator, rest_patterns, rest_sources, body, guard, block_id, indent_level + 2, ctx);
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "},\n");
    } else {
        const payload_name = try std.fmt.allocPrint(allocator, "omlz_match_payload_{d}", .{ctx.next_block_id});
        defer allocator.free(payload_name);
        ctx.next_block_id += 1;
        try appendPrint(out, allocator, " => |{s}| {{\n", .{payload_name});
        if (!patternsNeedSource(ctor_pattern.args, body, guard)) {
            try emitIndent(out, allocator, indent_level + 2);
            try appendPrint(out, allocator, "_ = {s};\n", .{payload_name});
        }

        var payload_sources = std.ArrayList([]const u8).empty;
        defer {
            for (payload_sources.items) |payload_source| {
                if (!std.mem.eql(u8, payload_source, payload_name)) allocator.free(payload_source);
            }
            payload_sources.deinit(allocator);
        }
        if (std.mem.eql(u8, ctor_pattern.name, "::")) {
            if (ctor_pattern.args.len != 2) return error.UnsupportedExpr;
            try payload_sources.append(allocator, try std.fmt.allocPrint(allocator, "{s}.head", .{payload_name}));
            try payload_sources.append(allocator, try std.fmt.allocPrint(allocator, "{s}.tail.*", .{payload_name}));
        } else {
            if (ctor_pattern.args.len != 1) return error.UnsupportedExpr;
            try payload_sources.append(allocator, payload_name);
        }
        try emitCombinedPatternSequence(out, allocator, ctor_pattern.args, payload_sources.items, rest_patterns, rest_sources, body, guard, block_id, indent_level + 2, ctx);
        try emitIndent(out, allocator, indent_level + 1);
        try append(out, allocator, "},\n");
    }
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "else => {},\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}\n");
}

pub fn emitUserCtorPatternSequence(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ctor_pattern: lir.LCtorPattern,
    source: []const u8,
    rest_patterns: []const lir.LPattern,
    rest_sources: []const []const u8,
    body: lir.LExpr,
    guard: ?*const lir.LExpr,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    const type_name = ctor_pattern.type_name.?;
    const variant_info = findUserVariant(ctx.type_decls, type_name, ctor_pattern.name) orelse return error.UnsupportedExpr;
    if (variant_info.payload_types.len != ctor_pattern.args.len) return error.UnsupportedExpr;
    const variant = try userVariantName(allocator, ctor_pattern.name);
    defer allocator.free(variant);

    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "switch ({s}.tag) {{\n", .{source});
    try emitIndent(out, allocator, indent_level + 1);
    try appendPrint(out, allocator, ".{s} => {{\n", .{variant});

    var payload_sources = std.ArrayList([]const u8).empty;
    defer {
        for (payload_sources.items) |payload_source| allocator.free(payload_source);
        payload_sources.deinit(allocator);
    }
    for (ctor_pattern.args, variant_info.payload_types, 0..) |_, payload_ty, index| {
        const payload_name = try std.fmt.allocPrint(allocator, "omlz_match_payload_{d}", .{ctx.next_block_id});
        ctx.next_block_id += 1;
        try emitIndent(out, allocator, indent_level + 2);
        try appendPrint(out, allocator, "const {s} = ", .{payload_name});
        if (ctor_pattern.args.len == 1) {
            try appendPrint(out, allocator, "{s}.payload.{s}", .{ source, variant });
        } else {
            try appendPrint(out, allocator, "{s}.payload.{s}._{d}", .{ source, variant, index });
        }
        if (isRecursivePayload(payload_ty)) try append(out, allocator, ".*");
        try append(out, allocator, ";\n");
        if (!patternNeedsSource(ctor_pattern.args[index], body, guard)) {
            try emitIndent(out, allocator, indent_level + 2);
            try appendPrint(out, allocator, "_ = {s};\n", .{payload_name});
        }
        try payload_sources.append(allocator, payload_name);
    }

    try emitCombinedPatternSequence(out, allocator, ctor_pattern.args, payload_sources.items, rest_patterns, rest_sources, body, guard, block_id, indent_level + 2, ctx);
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "},\n");
    try emitIndent(out, allocator, indent_level + 1);
    try append(out, allocator, "else => {},\n");
    try emitIndent(out, allocator, indent_level);
    try append(out, allocator, "}\n");
}

pub fn emitCombinedPatternSequence(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix_patterns: []const lir.LPattern,
    prefix_sources: []const []const u8,
    rest_patterns: []const lir.LPattern,
    rest_sources: []const []const u8,
    body: lir.LExpr,
    guard: ?*const lir.LExpr,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (prefix_patterns.len != prefix_sources.len or rest_patterns.len != rest_sources.len) return error.UnsupportedExpr;
    const total = prefix_patterns.len + rest_patterns.len;
    const combined_patterns = try allocator.alloc(lir.LPattern, total);
    defer allocator.free(combined_patterns);
    const combined_sources = try allocator.alloc([]const u8, total);
    defer allocator.free(combined_sources);
    for (prefix_patterns, 0..) |pattern, index| {
        combined_patterns[index] = pattern;
        combined_sources[index] = prefix_sources[index];
    }
    for (rest_patterns, 0..) |pattern, index| {
        combined_patterns[prefix_patterns.len + index] = pattern;
        combined_sources[prefix_patterns.len + index] = rest_sources[index];
    }
    try emitPatternSequence(out, allocator, combined_patterns, combined_sources, body, guard, block_id, indent_level, ctx);
}

pub fn emitGuardedMatchBreak(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: lir.LExpr,
    guard: ?*const lir.LExpr,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (guard) |guard_expr| {
        try emitIndent(out, allocator, indent_level);
        try append(out, allocator, "if (prelude.Bool.toNative(");
        try emitExpr(out, allocator, guard_expr.*, indent_level, ctx);
        try append(out, allocator, ")) {\n");
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "break :blk{d} ", .{block_id});
        try emitExpr(out, allocator, body, indent_level + 1, ctx);
        try append(out, allocator, ";\n");
        try emitIndent(out, allocator, indent_level);
        try append(out, allocator, "}\n");
        return;
    }
    try emitIndent(out, allocator, indent_level);
    try appendPrint(out, allocator, "break :blk{d} ", .{block_id});
    try emitExpr(out, allocator, body, indent_level, ctx);
    try append(out, allocator, ";\n");
}

pub fn emitNonCtorMatch(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    match_expr: lir.LMatch,
    scrutinee_name: []const u8,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    try emitSequentialMatchRows(out, allocator, match_expr, scrutinee_name, block_id, indent_level, ctx);
}

pub fn emitSequentialMatchRows(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    match_expr: lir.LMatch,
    scrutinee_name: []const u8,
    block_id: usize,
    indent_level: usize,
    ctx: *EmitContext,
) EmitError!void {
    if (match_expr.arms.len == 0) return error.UnsupportedExpr;

    if (!matchRowsNeedScrutinee(match_expr)) {
        try emitIndent(out, allocator, indent_level + 1);
        try appendPrint(out, allocator, "_ = {s};\n", .{scrutinee_name});
    }

    for (match_expr.arms) |arm| {
        const patterns = [_]lir.LPattern{arm.pattern};
        const sources = [_][]const u8{scrutinee_name};
        try emitPatternSequence(out, allocator, patterns[0..], sources[0..], arm.body.*, arm.guard, block_id, indent_level + 1, ctx);
    }

    if (!matchHasUnguardedCatchAll(match_expr)) {
        if (!matchHasCtorArm(match_expr)) {
            try emitNonExhaustivePanic(out, allocator, ctx.type_decls, match_expr, &.{}, indent_level + 1);
        } else {
            try emitIndent(out, allocator, indent_level + 1);
            try append(out, allocator, "unreachable;\n");
        }
    }
}

pub fn matchRowsNeedScrutinee(match_expr: lir.LMatch) bool {
    for (match_expr.arms) |arm| {
        if (patternNeedsSource(arm.pattern, arm.body.*, arm.guard)) return true;
    }
    return false;
}

pub fn hasMissingConstructors(allocator: std.mem.Allocator, type_decls: []const lir.LVariantType, match_expr: lir.LMatch, emitted_variants: []const []const u8) bool {
    if (matchHasUnguardedCatchAll(match_expr)) return false;
    const missing = missingConstructorsMessage(allocator, type_decls, match_expr, emitted_variants) catch return false;
    defer allocator.free(missing);
    return missing.len != 0;
}

pub fn emitNonExhaustivePanic(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    type_decls: []const lir.LVariantType,
    match_expr: lir.LMatch,
    emitted_variants: []const []const u8,
    indent_level: usize,
) EmitError!void {
    const missing = try missingConstructorsMessage(allocator, type_decls, match_expr, emitted_variants);
    defer allocator.free(missing);
    try emitIndent(out, allocator, indent_level);
    if (missing.len == 0) {
        try append(out, allocator, "@compileError(\"ZXCAML: non-exhaustive match: guard failure or missing nested constructor\");\n");
    } else {
        try appendPrint(out, allocator, "@compileError(\"ZXCAML: non-exhaustive match: missing constructors: {f}\");\n", .{std.zig.fmtString(missing)});
    }
}

pub fn missingConstructorsMessage(allocator: std.mem.Allocator, type_decls: []const lir.LVariantType, match_expr: lir.LMatch, emitted_variants: []const []const u8) EmitError![]const u8 {
    _ = emitted_variants;
    var missing = std.ArrayList(u8).empty;
    errdefer missing.deinit(allocator);

    if (userMatchTypeName(match_expr)) |type_name| {
        for (type_decls) |type_decl| {
            if (!std.mem.eql(u8, type_decl.name, type_name)) continue;
            for (type_decl.variants) |variant| {
                if (try constructorExhaustivelyCoveredByName(allocator, type_decls, match_expr, type_name, variant.name)) continue;
                if (missing.items.len != 0) try append(&missing, allocator, ", ");
                try append(&missing, allocator, variant.name);
            }
            return missing.toOwnedSlice(allocator);
        }
        return missing.toOwnedSlice(allocator);
    }

    const family = builtinMatchFamily(match_expr) orelse return missing.toOwnedSlice(allocator);
    for (family.constructors) |ctor_name| {
        if (try constructorExhaustivelyCoveredByName(allocator, type_decls, match_expr, null, ctor_name)) continue;
        if (missing.items.len != 0) try append(&missing, allocator, ", ");
        try append(&missing, allocator, ctor_name);
    }
    return missing.toOwnedSlice(allocator);
}

pub const BuiltinFamily = struct {
    constructors: []const []const u8,
};

pub fn builtinMatchFamily(match_expr: lir.LMatch) ?BuiltinFamily {
    for (match_expr.arms) |arm| {
        switch (arm.pattern) {
            .Ctor => |ctor| if (builtinFamilyForCtor(ctor.name)) |family| return family,
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {},
        }
    }
    return null;
}

pub fn builtinFamilyForCtor(ctor_name: []const u8) ?BuiltinFamily {
    if (std.mem.eql(u8, ctor_name, "Some") or std.mem.eql(u8, ctor_name, "None")) {
        return .{ .constructors = &.{ "Some", "None" } };
    }
    if (std.mem.eql(u8, ctor_name, "Ok") or std.mem.eql(u8, ctor_name, "Error")) {
        return .{ .constructors = &.{ "Ok", "Error" } };
    }
    if (std.mem.eql(u8, ctor_name, "::") or std.mem.eql(u8, ctor_name, "[]")) {
        return .{ .constructors = &.{ "::", "[]" } };
    }
    return null;
}

pub fn matchHasUnguardedCatchAll(match_expr: lir.LMatch) bool {
    for (match_expr.arms) |arm| {
        if (arm.guard != null) continue;
        switch (arm.pattern) {
            .Wildcard, .Var => return true,
            .Alias => |alias| if (patternIsIrrefutable(alias.pattern.*)) return true,
            .Ctor, .Constant, .Tuple, .Record => {},
        }
    }
    return false;
}

pub fn constructorUnconditionallyCovered(match_expr: lir.LMatch, type_name: ?[]const u8, constructor: []const u8) bool {
    for (match_expr.arms) |arm| {
        if (arm.guard != null) continue;
        switch (arm.pattern) {
            .Wildcard, .Var => return true,
            .Alias => |alias| if (patternIsIrrefutable(alias.pattern.*)) return true,
            .Ctor => |ctor| {
                const same_type = if (type_name == null and ctor.type_name == null)
                    true
                else if (type_name != null and ctor.type_name != null)
                    std.mem.eql(u8, type_name.?, ctor.type_name.?)
                else
                    false;
                if (same_type and std.mem.eql(u8, ctor.name, constructor) and ctorPayloadsIrrefutable(ctor.args)) return true;
            },
            .Constant, .Tuple, .Record => {},
        }
    }
    return false;
}

pub fn constructorExhaustivelyCoveredByName(
    allocator: std.mem.Allocator,
    type_decls: []const lir.LVariantType,
    match_expr: lir.LMatch,
    type_name: ?[]const u8,
    constructor: []const u8,
) EmitError!bool {
    if (constructorUnconditionallyCovered(match_expr, type_name, constructor)) return true;

    var payload_patterns = std.ArrayList(lir.LPattern).empty;
    defer payload_patterns.deinit(allocator);

    for (match_expr.arms) |arm| {
        if (arm.guard != null) continue;
        switch (arm.pattern) {
            .Ctor => |ctor| {
                if (!sameConstructorName(ctor, type_name, constructor)) continue;
                if (ctor.args.len != 1) continue;
                try payload_patterns.append(allocator, ctor.args[0]);
            },
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {},
        }
    }

    if (payload_patterns.items.len == 0) return false;
    return patternsCoverFamily(allocator, type_decls, payload_patterns.items);
}

pub fn caseUnconditionallyCovered(match_expr: lir.LMatch, selected_ctor: lir.LCtorPattern) bool {
    for (match_expr.arms) |arm| {
        if (arm.guard != null) continue;
        switch (arm.pattern) {
            .Wildcard, .Var => return true,
            .Alias => |alias| if (patternIsIrrefutable(alias.pattern.*)) return true,
            .Ctor => |ctor| if (sameConstructor(ctor, selected_ctor) and ctorPayloadsIrrefutable(ctor.args)) return true,
            .Constant, .Tuple, .Record => {},
        }
    }
    return false;
}

pub fn caseExhaustivelyCovered(
    allocator: std.mem.Allocator,
    type_decls: []const lir.LVariantType,
    match_expr: lir.LMatch,
    selected_ctor: lir.LCtorPattern,
) EmitError!bool {
    if (caseUnconditionallyCovered(match_expr, selected_ctor)) return true;

    var payload_patterns = std.ArrayList(lir.LPattern).empty;
    defer payload_patterns.deinit(allocator);

    for (match_expr.arms) |arm| {
        if (arm.guard != null) continue;
        switch (arm.pattern) {
            .Ctor => |ctor| {
                if (!sameConstructor(ctor, selected_ctor)) continue;
                if (ctor.args.len != 1) continue;
                try payload_patterns.append(allocator, ctor.args[0]);
            },
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {},
        }
    }

    if (payload_patterns.items.len == 0) return false;
    return patternsCoverFamily(allocator, type_decls, payload_patterns.items);
}

pub fn patternsCoverFamily(
    allocator: std.mem.Allocator,
    type_decls: []const lir.LVariantType,
    patterns: []const lir.LPattern,
) EmitError!bool {
    for (patterns) |pattern| {
        switch (pattern) {
            .Wildcard, .Var => return true,
            .Alias => |alias| if (patternIsIrrefutable(alias.pattern.*)) return true,
            .Ctor, .Constant, .Tuple, .Record => {},
        }
    }

    const first_ctor = firstCtorPattern(patterns) orelse return false;
    if (first_ctor.type_name) |type_name| {
        const type_decl = findUserTypeDecl(type_decls, type_name) orelse return false;
        for (type_decl.variants) |variant| {
            if (!try constructorCoveredByPatterns(allocator, type_decls, patterns, type_name, variant.name)) return false;
        }
        return true;
    }

    const family = builtinFamilyForCtor(first_ctor.name) orelse return false;
    for (family.constructors) |ctor_name| {
        if (!try constructorCoveredByPatterns(allocator, type_decls, patterns, null, ctor_name)) return false;
    }
    return true;
}

pub fn constructorCoveredByPatterns(
    allocator: std.mem.Allocator,
    type_decls: []const lir.LVariantType,
    patterns: []const lir.LPattern,
    type_name: ?[]const u8,
    constructor: []const u8,
) EmitError!bool {
    var nested_patterns = std.ArrayList(lir.LPattern).empty;
    defer nested_patterns.deinit(allocator);

    for (patterns) |pattern| {
        switch (pattern) {
            .Wildcard, .Var => return true,
            .Alias => |alias| if (patternIsIrrefutable(alias.pattern.*)) return true,
            .Ctor => |ctor| {
                if (!sameConstructorName(ctor, type_name, constructor)) continue;
                if (ctor.args.len == 0) return true;
                if (ctorPayloadsIrrefutable(ctor.args)) return true;
                if (ctor.args.len == 1) try nested_patterns.append(allocator, ctor.args[0]);
            },
            .Constant, .Tuple, .Record => {},
        }
    }

    if (nested_patterns.items.len == 0) return false;
    return patternsCoverFamily(allocator, type_decls, nested_patterns.items);
}

pub fn firstCtorPattern(patterns: []const lir.LPattern) ?lir.LCtorPattern {
    for (patterns) |pattern| {
        switch (pattern) {
            .Ctor => |ctor| return ctor,
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {},
        }
    }
    return null;
}

pub fn sameConstructorName(ctor: lir.LCtorPattern, type_name: ?[]const u8, constructor: []const u8) bool {
    const same_type = if (type_name == null and ctor.type_name == null)
        true
    else if (type_name != null and ctor.type_name != null)
        std.mem.eql(u8, type_name.?, ctor.type_name.?)
    else
        false;
    return same_type and std.mem.eql(u8, ctor.name, constructor);
}

pub fn caseNeedsBuiltinPayload(match_expr: lir.LMatch, selected_ctor: lir.LCtorPattern) bool {
    if (selected_ctor.type_name != null or selected_ctor.args.len == 0) return false;
    for (match_expr.arms) |arm| {
        switch (arm.pattern) {
            .Ctor => |ctor| {
                if (sameConstructor(ctor, selected_ctor) and patternsNeedSource(ctor.args, arm.body.*, arm.guard)) return true;
            },
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {},
        }
    }
    return false;
}

pub fn ctorPayloadsIrrefutable(patterns: []const lir.LPattern) bool {
    for (patterns) |pattern| {
        if (!patternIsIrrefutable(pattern)) return false;
    }
    return true;
}

pub fn userMatchTypeName(match_expr: lir.LMatch) ?[]const u8 {
    for (match_expr.arms) |arm| {
        switch (arm.pattern) {
            .Ctor => |ctor| if (ctor.type_name) |type_name| return type_name,
            .Wildcard, .Var, .Constant, .Tuple, .Record, .Alias => {},
        }
    }
    return null;
}
