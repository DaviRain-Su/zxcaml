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
