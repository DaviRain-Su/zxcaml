//! Core IR source-location plumbing regression tests.

const std = @import("std");

const core_anf = @import("../../src/core/anf.zig");
const core_const_fold = @import("../../src/core/const_fold.zig");
const core_dce = @import("../../src/core/dce.zig");
const core_inline = @import("../../src/core/inline.zig");
const ir = @import("../../src/core/ir.zig");
const ttree = @import("../../src/frontend_bridge/ttree.zig");

const options = @import("core_loc_options");

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

fn exprLoc(expr: ir.Expr) ?ir.Loc {
    return switch (expr) {
        .Lambda => |value| value.loc,
        .Constant => |value| value.loc,
        .App => |value| value.loc,
        .Let => |value| value.loc,
        .LetGroup => |value| value.loc,
        .Assert => |value| value.loc,
        .If => |value| value.loc,
        .Prim => |value| value.loc,
        .Var => |value| value.loc,
        .Ctor => |value| value.loc,
        .Match => |value| value.loc,
        .Tuple => |value| value.loc,
        .TupleProj => |value| value.loc,
        .Record => |value| value.loc,
        .RecordField => |value| value.loc,
        .RecordUpdate => |value| value.loc,
        .AccountFieldSet => |value| value.loc,
        .ArrayLit => |value| value.loc,
        .ArrayGet => |value| value.loc,
        .ArrayLength => |value| value.loc,
        .ArraySet => |value| value.loc,
        .ArrayMake => |value| value.loc,
        .RefMake => |value| value.loc,
        .RefGet => |value| value.loc,
        .RefSet => |value| value.loc,
    };
}

fn optimizedHackathonCore(allocator: std.mem.Allocator, io: std.Io) !struct {
    frontend_arena: std.heap.ArenaAllocator,
    core_arena: std.heap.ArenaAllocator,
    module: ir.Module,
} {
    const argv = [_][]const u8{
        options.zxc_frontend_bin,
        "--emit=sexp",
        "examples/hackathon_greet.ml",
    };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (exitCode(result.term) != 0) {
        std.debug.print("zxc-frontend failed while emitting hackathon_greet sexp:\n{s}\n", .{result.stderr});
        return error.FrontendFailed;
    }

    var frontend_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer frontend_arena.deinit();
    const typed = try ttree.parseModule(&frontend_arena, result.stdout);

    var core_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer core_arena.deinit();
    const lowered = try core_anf.lowerModule(&core_arena, typed);
    const folded = try core_const_fold.foldModule(&core_arena, lowered);
    const eliminated = try core_dce.eliminateModule(&core_arena, folded);
    const inlined = try core_inline.inlineModule(&core_arena, eliminated);
    const optimized = try core_const_fold.foldModule(&core_arena, inlined);

    return .{
        .frontend_arena = frontend_arena,
        .core_arena = core_arena,
        .module = optimized,
    };
}

test "core loc: optimized hackathon_greet top-level Expr keeps frontend loc" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var result = try optimizedHackathonCore(allocator, io);
    defer result.core_arena.deinit();
    defer result.frontend_arena.deinit();

    var saw_entrypoint = false;
    for (result.module.decls) |decl| {
        const let_decl = switch (decl) {
            .Let => |value| value,
            .LetGroup => continue,
        };
        if (!std.mem.eql(u8, let_decl.name, "entrypoint")) continue;
        saw_entrypoint = true;
        const loc = exprLoc(let_decl.value.*) orelse return error.MissingCoreLoc;
        try std.testing.expect(!loc.isUnknown());
        try std.testing.expectEqualStrings("examples/hackathon_greet.ml", loc.file);
        try std.testing.expect(loc.line > 0);
        try std.testing.expect(loc.end_line >= loc.line);
    }
    try std.testing.expect(saw_entrypoint);
}

// CR-7 audit baseline (2026-06-10): the frontend emits `(located ...)`
// only for top-level let bindings, so decl-level locs are the granularity
// every consumer (diagnostics, source maps) can rely on today. This test
// pins that floor for every value declaration across a corpus sample;
// widening loc emission to inner expressions is tracked as a frontend
// wire-format slice in mission-internal/code-review-backlog.md.
test "core loc: every top-level value decl keeps a known loc across corpus sample" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const sample_files = [_][]const u8{
        "examples/hackathon_greet.ml",
        "examples/factorial.ml",
        "examples/tree_adt.ml",
        "examples/counter.ml",
    };

    for (sample_files) |input_file| {
        const argv = [_][]const u8{
            options.zxc_frontend_bin,
            "--emit=sexp",
            input_file,
        };
        const result = try std.process.run(allocator, io, .{ .argv = &argv });
        defer allocator.free(result.stderr);
        defer allocator.free(result.stdout);

        if (exitCode(result.term) != 0) {
            std.debug.print("zxc-frontend failed for {s}:\n{s}\n", .{ input_file, result.stderr });
            return error.FrontendFailed;
        }

        var frontend_arena = std.heap.ArenaAllocator.init(allocator);
        defer frontend_arena.deinit();
        const typed = try ttree.parseModule(&frontend_arena, result.stdout);

        var core_arena = std.heap.ArenaAllocator.init(allocator);
        defer core_arena.deinit();
        const lowered = try core_anf.lowerModule(&core_arena, typed);

        var decl_count: usize = 0;
        for (lowered.decls) |decl| {
            switch (decl) {
                .Let => |let_decl| {
                    decl_count += 1;
                    const loc = exprLoc(let_decl.value.*) orelse {
                        std.debug.print("missing loc on decl `{s}` in {s}\n", .{ let_decl.name, input_file });
                        return error.MissingCoreLoc;
                    };
                    if (loc.isUnknown()) {
                        std.debug.print("unknown loc on decl `{s}` in {s}\n", .{ let_decl.name, input_file });
                        return error.UnknownCoreLoc;
                    }
                    try std.testing.expectEqualStrings(input_file, loc.file);
                    try std.testing.expect(loc.line > 0);
                    try std.testing.expect(loc.end_line >= loc.line);
                },
                .LetGroup => |group| for (group.bindings) |binding| {
                    decl_count += 1;
                    const loc = exprLoc(binding.value.*) orelse {
                        std.debug.print("missing loc on group binding `{s}` in {s}\n", .{ binding.name, input_file });
                        return error.MissingCoreLoc;
                    };
                    if (loc.isUnknown()) {
                        std.debug.print("unknown loc on group binding `{s}` in {s}\n", .{ binding.name, input_file });
                        return error.UnknownCoreLoc;
                    }
                    try std.testing.expectEqualStrings(input_file, loc.file);
                },
            }
        }
        try std.testing.expect(decl_count > 0);
    }
}

fn countKnownExprLocs(expr: ir.Expr, total: *usize, known: *usize) void {
    total.* += 1;
    if (exprLoc(expr)) |loc| {
        if (!loc.isUnknown()) known.* += 1;
    }
    switch (expr) {
        .Lambda => |value| countKnownExprLocs(value.body.*, total, known),
        .Constant, .Var => {},
        .App => |value| {
            countKnownExprLocs(value.callee.*, total, known);
            for (value.args) |arg| countKnownExprLocs(arg.*, total, known);
        },
        .Let => |value| {
            countKnownExprLocs(value.value.*, total, known);
            countKnownExprLocs(value.body.*, total, known);
        },
        .LetGroup => |value| {
            for (value.bindings) |binding| countKnownExprLocs(binding.value.*, total, known);
            countKnownExprLocs(value.body.*, total, known);
        },
        .Assert => |value| countKnownExprLocs(value.condition.*, total, known),
        .If => |value| {
            countKnownExprLocs(value.cond.*, total, known);
            countKnownExprLocs(value.then_branch.*, total, known);
            countKnownExprLocs(value.else_branch.*, total, known);
        },
        .Prim => |value| for (value.args) |arg| countKnownExprLocs(arg.*, total, known),
        .Ctor => |value| for (value.args) |arg| countKnownExprLocs(arg.*, total, known),
        .Match => |value| {
            countKnownExprLocs(value.scrutinee.*, total, known);
            for (value.arms) |arm| {
                if (arm.guard) |guard| countKnownExprLocs(guard.*, total, known);
                countKnownExprLocs(arm.body.*, total, known);
            }
        },
        .Tuple => |value| for (value.items) |item| countKnownExprLocs(item.*, total, known),
        .TupleProj => |value| countKnownExprLocs(value.tuple_expr.*, total, known),
        .Record => |value| for (value.fields) |field| countKnownExprLocs(field.value.*, total, known),
        .RecordField => |value| countKnownExprLocs(value.record_expr.*, total, known),
        .RecordUpdate => |value| {
            countKnownExprLocs(value.base_expr.*, total, known);
            for (value.fields) |field| countKnownExprLocs(field.value.*, total, known);
        },
        .AccountFieldSet => |value| {
            countKnownExprLocs(value.account_expr.*, total, known);
            countKnownExprLocs(value.value.*, total, known);
        },
        .ArrayLit => |value| for (value.elems) |elem| countKnownExprLocs(elem.*, total, known),
        .ArrayGet => |value| {
            countKnownExprLocs(value.arr.*, total, known);
            countKnownExprLocs(value.idx.*, total, known);
        },
        .ArrayLength => |value| countKnownExprLocs(value.arr.*, total, known),
        .ArraySet => |value| {
            countKnownExprLocs(value.arr.*, total, known);
            countKnownExprLocs(value.idx.*, total, known);
            countKnownExprLocs(value.value.*, total, known);
        },
        .ArrayMake => |value| countKnownExprLocs(value.init.*, total, known),
        .RefMake => |value| countKnownExprLocs(value.init.*, total, known),
        .RefGet => |value| countKnownExprLocs(value.target.*, total, known),
        .RefSet => |value| {
            countKnownExprLocs(value.target.*, total, known);
            countKnownExprLocs(value.value.*, total, known);
        },
    }
}

// Wire 1.6: the frontend now wraps inner expressions in (located ...), so
// ANF lowering can stamp expression-level locs, not just decl-level ones.
// Require a majority of pre-optimization Core IR nodes to carry a known loc.
test "core loc: wire 1.6 stamps inner expression locs in lowered Core IR" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{
        options.zxc_frontend_bin,
        "--emit=sexp",
        "examples/hackathon_greet.ml",
    };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    try std.testing.expectEqual(@as(u8, 0), exitCode(result.term));

    var frontend_arena = std.heap.ArenaAllocator.init(allocator);
    defer frontend_arena.deinit();
    const typed = try ttree.parseModule(&frontend_arena, result.stdout);

    var core_arena = std.heap.ArenaAllocator.init(allocator);
    defer core_arena.deinit();
    const lowered = try core_anf.lowerModule(&core_arena, typed);

    var total: usize = 0;
    var known: usize = 0;
    for (lowered.decls) |decl| {
        switch (decl) {
            .Let => |let_decl| countKnownExprLocs(let_decl.value.*, &total, &known),
            .LetGroup => |group| for (group.bindings) |binding|
                countKnownExprLocs(binding.value.*, &total, &known),
        }
    }

    try std.testing.expect(total > 10);
    if (known * 2 < total) {
        std.debug.print("inner loc coverage too low: {d}/{d}\n", .{ known, total });
        return error.InnerLocCoverageTooLow;
    }
}

fn runOmlz(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !struct { stdout: []u8, stderr: []u8, exit_code: u8 } {
    const result = try std.process.run(allocator, io, .{ .argv = args });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exitCode(result.term),
    };
}

test "core loc: default hackathon_greet core-ir output stays loc-free and deterministic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const argv = [_][]const u8{
        options.omlz_bin,
        "check",
        "--emit=core-ir",
        "examples/hackathon_greet.ml",
    };

    const first = try runOmlz(allocator, io, &argv);
    defer allocator.free(first.stdout);
    defer allocator.free(first.stderr);
    const second = try runOmlz(allocator, io, &argv);
    defer allocator.free(second.stdout);
    defer allocator.free(second.stderr);

    if (first.exit_code != 0) {
        std.debug.print("omlz core-ir failed:\n{s}\n", .{first.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), first.exit_code);
    try std.testing.expectEqual(@as(u8, 0), second.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, first.stdout, "(loc ") == null);
    try std.testing.expectEqualStrings(first.stdout, second.stdout);
}
