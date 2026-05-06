//! `omlz test` subcommand implementation.
//!
//! RESPONSIBILITIES:
//! - Discover `let%test_unit` thunks lowered by the frontend into
//!   `__otest_registry__`.
//! - Run those thunks through the in-process tree-walk interpreter.
//! - Report cargo-test-style output or JSON Lines for LSP/tooling consumers.

const std = @import("std");
const Io = std.Io;

const pipeline = @import("../driver/pipeline.zig");
const diag = @import("../util/diag.zig");
const render = @import("../util/render.zig");
const interp = @import("../backend/interp.zig");
const core_anf = @import("../core/anf.zig");
const core_const_fold = @import("../core/const_fold.zig");
const core_dce = @import("../core/dce.zig");
const core_inline = @import("../core/inline.zig");
const ir = @import("../core/ir.zig");
const layout = @import("../core/layout.zig");

pub const TestError = error{
    UnsupportedArgs,
    FileNotFound,
    FrontendFailed,
} || std.mem.Allocator.Error || std.process.GetEnvVarOwnedError || std.fs.File.OpenError;

const Format = enum {
    cargo,
    json,
};

const CaseKind = enum {
    unit,
    prop,
};

const Args = struct {
    filter: ?[]const u8 = null,
    no_color: bool = false,
    format: Format = .cargo,
    num_cases: usize = 100,
    seed: i64 = 0,
    files: []const []const u8 = &.{},
};

const TestCase = struct {
    file: []const u8,
    name: []const u8,
    thunk_name: []const u8,
    kind: CaseKind = .unit,
    loc: ir.Loc,
};

const FileDiscovery = struct {
    path: []const u8,
    had_tests: bool,
    cases: []const TestCase,
};

const TestStatus = enum {
    ok,
    failed,
};

const TestResult = struct {
    case: TestCase,
    status: TestStatus,
    message: []const u8 = "",
    elapsed_ms: i64,
    num_cases: usize = 1,
    executed_cases: usize = 1,
    seed: i64 = 0,
    counterexample: ?[]const u8 = null,
    shrunk_steps: usize = 0,
};

const Summary = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    elapsed_ms: i64 = 0,
};

pub fn writeHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz test [OPTIONS] [FILE...]
        \\
        \\Runs let%test_unit bindings through the in-process interpreter.
        \\With no FILE arguments, scans examples/tests/*.ml.
        \\
        \\Options:
        \\  --filter SUBSTR        Run only tests whose name contains SUBSTR.
        \\  --format=cargo|json    Select output format (default: cargo).
        \\  --num-cases N          Number of generated samples per property test (default: 100).
        \\  --seed N               Seed property-test generation deterministically (default: current time).
        \\  --no-color             Disable ANSI colors in cargo output.
        \\
    );
}

pub fn run(init: std.process.Init, argv0: []const u8, raw_args: []const []const u8) !void {
    const args = parseArgs(init.gpa, init.io, raw_args) catch {
        try writeStderr(init.io, "error: unsupported test option; run `omlz test --help` for usage.\n");
        std.process.exit(2);
    };

    const files = if (args.files.len == 0)
        try defaultTestFiles(init.gpa, init.io)
    else
        args.files;

    for (files) |file| {
        std.Io.Dir.cwd().access(init.io, file, .{}) catch {
            try writeStderr(init.io, "error: test file not found: ");
            try writeStderr(init.io, file);
            try writeStderr(init.io, "\n");
            std.process.exit(2);
        };
    }

    var discoveries = std.ArrayList(FileDiscovery).empty;
    for (files) |file| {
        const discovery = discoverFile(init, argv0, file, args) catch |err| {
            if (err == error.FrontendFailed) std.process.exit(2);
            try writeStderr(init.io, "error: failed to prepare test file: ");
            try writeStderr(init.io, file);
            try writeStderr(init.io, ": ");
            try writeStderr(init.io, @errorName(err));
            try writeStderr(init.io, "\n");
            std.process.exit(2);
        };
        try discoveries.append(init.gpa, discovery);
    }

    var summary: Summary = .{};
    for (discoveries.items) |discovery| summary.total += discovery.cases.len;

    var output = std.ArrayList(u8).empty;
    defer output.deinit(init.gpa);

    const use_color = args.format == .cargo and try shouldUseColor(init, args);
    if (args.format == .cargo) {
        try appendCargoHeader(&output, init.gpa, summary.total);
    }

    for (discoveries.items) |discovery| {
        if (!discovery.had_tests and args.format == .cargo) {
            const line = try std.fmt.allocPrint(init.gpa, "test {s} ... 0 tests, 0 passed\n", .{discovery.path});
            defer init.gpa.free(line);
            try output.appendSlice(init.gpa, line);
            continue;
        }

        const file_summary = runFile(init, argv0, discovery, args, &output, use_color) catch |err| {
            if (err == error.FrontendFailed) std.process.exit(2);
            try writeStderr(init.io, "error: failed to run test file: ");
            try writeStderr(init.io, discovery.path);
            try writeStderr(init.io, ": ");
            try writeStderr(init.io, @errorName(err));
            try writeStderr(init.io, "\n");
            std.process.exit(2);
        };
        summary.passed += file_summary.passed;
        summary.failed += file_summary.failed;
    }

    summary.elapsed_ms = 0;
    if (args.format == .cargo) {
        try appendCargoSummary(&output, init.gpa, summary, use_color);
    } else {
        try appendJsonSummary(&output, init.gpa, summary);
    }

    try writeStdout(init.io, output.items);
    std.process.exit(if (summary.failed == 0) 0 else 1);
}

fn parseArgs(allocator: std.mem.Allocator, io: Io, raw_args: []const []const u8) !Args {
    var files = std.ArrayList([]const u8).empty;
    var args: Args = .{ .seed = defaultSeed() };

    var index: usize = 2;
    while (index < raw_args.len) : (index += 1) {
        const arg = raw_args[index];
        if (std.mem.eql(u8, arg, "--filter")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            args.filter = raw_args[index];
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            args.filter = arg["--filter=".len..];
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            args.no_color = true;
        } else if (std.mem.eql(u8, arg, "--num-cases")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            args.num_cases = try parsePositiveUsize(raw_args[index]);
        } else if (std.mem.startsWith(u8, arg, "--num-cases=")) {
            args.num_cases = try parsePositiveUsize(arg["--num-cases=".len..]);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            args.seed = try std.fmt.parseInt(i64, raw_args[index], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            args.seed = try std.fmt.parseInt(i64, arg["--seed=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            const value = arg["--format=".len..];
            if (std.mem.eql(u8, value, "cargo")) {
                args.format = .cargo;
            } else if (std.mem.eql(u8, value, "json")) {
                args.format = .json;
            } else {
                return error.UnsupportedArgs;
            }
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            const value = raw_args[index];
            if (std.mem.eql(u8, value, "cargo")) {
                args.format = .cargo;
            } else if (std.mem.eql(u8, value, "json")) {
                args.format = .json;
            } else {
                return error.UnsupportedArgs;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedArgs;
        } else {
            try files.append(allocator, arg);
        }
    }

    _ = io;
    args.files = try files.toOwnedSlice(allocator);
    return args;
}

fn parsePositiveUsize(text: []const u8) !usize {
    const value = try std.fmt.parseInt(usize, text, 10);
    if (value == 0) return error.UnsupportedArgs;
    return value;
}

fn defaultSeed() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 1;
    const sec: i64 = @intCast(ts.sec);
    const nsec: i64 = @intCast(ts.nsec);
    return sec ^ nsec;
}

fn defaultTestFiles(allocator: std.mem.Allocator, io: Io) ![]const []const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, "examples/tests", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var files = std.ArrayList([]const u8).empty;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ml")) continue;
        try files.append(allocator, try std.fmt.allocPrint(allocator, "examples/tests/{s}", .{entry.name}));
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return files.toOwnedSlice(allocator);
}

fn discoverFile(init: std.process.Init, argv0: []const u8, file: []const u8, args: Args) !FileDiscovery {
    var frontend = pipeline.runFrontendFromArgv0WithOptions(
        init.gpa,
        init.io,
        init.minimal.environ,
        argv0,
        file,
        try frontendOptions(init, args),
    ) catch return error.FrontendFailed;
    defer frontend.deinit();

    const parsed = switch (frontend) {
        .success => |parsed| parsed,
        .failed => return error.FrontendFailed,
    };

    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();
    const core_module = core_anf.lowerModule(&core_arena, parsed.module) catch return error.FrontendFailed;

    var cases = std.ArrayList(TestCase).empty;
    const had_tests = try appendRegistryCases(init.gpa, &cases, file, core_module, args.filter);
    return .{
        .path = try init.gpa.dupe(u8, file),
        .had_tests = had_tests,
        .cases = try cases.toOwnedSlice(init.gpa),
    };
}

fn runFile(
    init: std.process.Init,
    argv0: []const u8,
    discovery: FileDiscovery,
    args: Args,
    output: *std.ArrayList(u8),
    use_color: bool,
) !Summary {
    if (discovery.cases.len == 0) return .{};

    var frontend = pipeline.runFrontendFromArgv0WithOptions(
        init.gpa,
        init.io,
        init.minimal.environ,
        argv0,
        discovery.path,
        try frontendOptions(init, args),
    ) catch return error.FrontendFailed;
    defer frontend.deinit();

    const parsed = switch (frontend) {
        .success => |parsed| parsed,
        .failed => return error.FrontendFailed,
    };

    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();
    const core_module = try core_anf.lowerModule(&core_arena, parsed.module);
    const optimized_module = try optimizeModule(&core_arena, parsed.module);

    var summary: Summary = .{};
    for (discovery.cases) |case| {
        const result = switch (case.kind) {
            .unit => try runOneCase(&core_arena, optimized_module, case),
            .prop => try runOnePropCase(init.gpa, &core_arena, core_module, case, args),
        };
        summary.total += 1;
        switch (result.status) {
            .ok => summary.passed += 1,
            .failed => summary.failed += 1,
        }
        if (args.format == .cargo) {
            try appendCargoResult(output, init.gpa, result, use_color);
        } else {
            try appendJsonResult(output, init.gpa, result);
        }
    }
    return summary;
}

fn optimizeModule(core_arena: *std.heap.ArenaAllocator, module: @import("../frontend_bridge/ttree.zig").Module) !ir.Module {
    const core_module = try core_anf.lowerModule(core_arena, module);
    const folded_core_module = try core_const_fold.foldModule(core_arena, core_module);
    const dce_core_module = try core_dce.eliminateModule(core_arena, folded_core_module);
    const inlined_core_module = try core_inline.inlineModule(core_arena, dce_core_module);
    return core_const_fold.foldModule(core_arena, inlined_core_module);
}

fn appendRegistryCases(
    allocator: std.mem.Allocator,
    cases: *std.ArrayList(TestCase),
    file: []const u8,
    module: ir.Module,
    filter: ?[]const u8,
) !bool {
    const registry = findTopLevelLet(module, "__otest_registry__") orelse return false;
    var all_cases = std.ArrayList(TestCase).empty;
    var env = std.StringHashMap(*const ir.Expr).init(allocator);
    defer env.deinit();
    try collectRegistryExpr(allocator, &all_cases, &env, file, module, registry.value.*);
    for (all_cases.items) |case| {
        if (filter) |needle| {
            if (std.mem.indexOf(u8, case.name, needle) == null) continue;
        }
        try cases.append(allocator, case);
    }
    return all_cases.items.len != 0;
}

fn collectRegistryExpr(
    allocator: std.mem.Allocator,
    cases: *std.ArrayList(TestCase),
    env: *std.StringHashMap(*const ir.Expr),
    file: []const u8,
    module: ir.Module,
    expr: ir.Expr,
) !void {
    switch (expr) {
        .Let => |let_expr| {
            try env.put(let_expr.name, let_expr.value);
            try collectRegistryExpr(allocator, cases, env, file, module, let_expr.body.*);
            return;
        },
        .Var => |var_ref| {
            if (env.get(var_ref.name)) |resolved| {
                try collectRegistryExpr(allocator, cases, env, file, module, resolved.*);
            }
            return;
        },
        else => {},
    }

    const ctor = switch (expr) {
        .Ctor => |ctor| ctor,
        else => return,
    };
    if (std.mem.eql(u8, ctor.name, "[]")) return;
    if (!std.mem.eql(u8, ctor.name, "::") or ctor.args.len != 2) return;

    try collectRegistryPair(allocator, cases, env, file, module, ctor.args[0].*);
    try collectRegistryExpr(allocator, cases, env, file, module, ctor.args[1].*);
}

fn collectRegistryPair(
    allocator: std.mem.Allocator,
    cases: *std.ArrayList(TestCase),
    env: *std.StringHashMap(*const ir.Expr),
    file: []const u8,
    module: ir.Module,
    expr: ir.Expr,
) !void {
    const resolved_expr = resolveRegistryExpr(env, expr);
    const tuple = switch (resolved_expr) {
        .Tuple => |tuple| tuple,
        else => return,
    };
    if (tuple.items.len != 2 and tuple.items.len != 3) return;
    const name_expr = resolveRegistryExpr(env, tuple.items[0].*);
    const name = switch (name_expr) {
        .Constant => |constant| switch (constant.value) {
            .String => |value| value,
            else => return,
        },
        else => return,
    };
    var kind: CaseKind = .unit;
    const thunk_index: usize = if (tuple.items.len == 3) blk: {
        const kind_expr = resolveRegistryExpr(env, tuple.items[1].*);
        const kind_text = switch (kind_expr) {
            .Constant => |constant| switch (constant.value) {
                .String => |value| value,
                else => return,
            },
            else => return,
        };
        if (std.mem.eql(u8, kind_text, "prop")) {
            kind = .prop;
        } else if (std.mem.eql(u8, kind_text, "unit")) {
            kind = .unit;
        } else {
            return;
        }
        break :blk 2;
    } else 1;
    const thunk_expr = resolveRegistryExpr(env, tuple.items[thunk_index].*);
    const thunk_name = switch (thunk_expr) {
        .Var => |var_ref| var_ref.name,
        else => return,
    };

    const loc = findThunkLoc(module, thunk_name) orelse ir.Loc.unknown;
    try cases.append(allocator, .{
        .file = try allocator.dupe(u8, file),
        .name = try allocator.dupe(u8, name),
        .thunk_name = try allocator.dupe(u8, thunk_name),
        .kind = kind,
        .loc = .{
            .file = try allocator.dupe(u8, if (loc.isUnknown()) file else loc.file),
            .line = loc.line,
            .col = loc.col,
            .end_line = loc.end_line,
            .end_col = loc.end_col,
        },
    });
}

fn resolveRegistryExpr(env: *std.StringHashMap(*const ir.Expr), expr: ir.Expr) ir.Expr {
    return switch (expr) {
        .Var => |var_ref| if (env.get(var_ref.name)) |resolved| resolved.* else expr,
        else => expr,
    };
}

fn findTopLevelLet(module: ir.Module, name: []const u8) ?ir.Let {
    for (module.decls) |decl| switch (decl) {
        .Let => |let_decl| if (std.mem.eql(u8, let_decl.name, name)) return let_decl,
        .LetGroup => {},
    };
    return null;
}

fn findThunkLoc(module: ir.Module, thunk_name: []const u8) ?ir.Loc {
    const thunk = findTopLevelLet(module, thunk_name) orelse return null;
    return firstExprLoc(thunk.value.*);
}

fn firstExprLoc(expr: ir.Expr) ?ir.Loc {
    if (ir.exprLoc(expr)) |loc| {
        if (!loc.isUnknown()) return loc;
    }
    return switch (expr) {
        .Lambda => |lambda| firstExprLoc(lambda.body.*),
        .Assert => |assert_expr| firstExprLoc(assert_expr.condition.*),
        .Let => |let_expr| firstExprLoc(let_expr.value.*) orelse firstExprLoc(let_expr.body.*),
        .App => |app| firstExprLoc(app.callee.*),
        .If => |if_expr| firstExprLoc(if_expr.cond.*) orelse firstExprLoc(if_expr.then_branch.*) orelse firstExprLoc(if_expr.else_branch.*),
        .Prim => |prim| if (prim.args.len == 0) null else firstExprLoc(prim.args[0].*),
        .Ctor => |ctor| if (ctor.args.len == 0) null else firstExprLoc(ctor.args[0].*),
        .Tuple => |tuple| if (tuple.items.len == 0) null else firstExprLoc(tuple.items[0].*),
        .Match => |match_expr| firstExprLoc(match_expr.scrutinee.*),
        else => null,
    };
}

fn runOneCase(core_arena: *std.heap.ArenaAllocator, module: ir.Module, case: TestCase) !TestResult {
    const entry_module = try moduleWithEntrypoint(core_arena, module, case.thunk_name, case.loc);
    var interpreter: interp.Interpreter = .{};
    _ = interpreter.backend().evalModule(entry_module) catch |err| {
        return .{
            .case = case,
            .status = .failed,
            .message = interp.panicMarker(err) orelse interp.errorMessage(err),
            .elapsed_ms = 0,
        };
    };
    return .{
        .case = case,
        .status = .ok,
        .elapsed_ms = 0,
    };
}

const PropParts = struct {
    generator: *const ir.Expr,
    body: ir.Lambda,
    sample_ty: ir.Ty,
};

fn runOnePropCase(
    allocator: std.mem.Allocator,
    core_arena: *std.heap.ArenaAllocator,
    module: ir.Module,
    case: TestCase,
    args: Args,
) !TestResult {
    const parts = findPropParts(module, case.thunk_name) orelse {
        return .{
            .case = case,
            .status = .failed,
            .message = "property thunk did not contain generator/body metadata",
            .elapsed_ms = 0,
            .num_cases = args.num_cases,
            .executed_cases = 0,
            .seed = args.seed,
        };
    };

    var seed = args.seed;
    var case_index: usize = 0;
    while (case_index < args.num_cases) : (case_index += 1) {
        const entry_module = try moduleWithPropEntrypoint(core_arena, module, parts, seed, case.loc);
        var interpreter: interp.Interpreter = .{};
        const next_seed_u64 = interpreter.backend().evalModule(entry_module) catch |err| {
            const shrink = try shrinkCounterexample(allocator, core_arena, module, parts, seed, case.loc);
            defer allocator.free(shrink.counterexample);
            return .{
                .case = case,
                .status = .failed,
                .message = interp.panicMarker(err) orelse interp.errorMessage(err),
                .elapsed_ms = 0,
                .num_cases = args.num_cases,
                .executed_cases = case_index + 1,
                .seed = args.seed,
                .counterexample = try allocator.dupe(u8, shrink.counterexample),
                .shrunk_steps = shrink.steps,
            };
        };
        seed = @intCast(next_seed_u64);
    }

    return .{
        .case = case,
        .status = .ok,
        .elapsed_ms = 0,
        .num_cases = args.num_cases,
        .executed_cases = args.num_cases,
        .seed = args.seed,
    };
}

fn findPropParts(module: ir.Module, thunk_name: []const u8) ?PropParts {
    const thunk = findTopLevelLet(module, thunk_name) orelse return null;
    const lambda = switch (thunk.value.*) {
        .Lambda => |value| value,
        else => return null,
    };
    const generator_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return null,
    };
    const body_let = switch (generator_let.body.*) {
        .Let => |value| value,
        else => return null,
    };
    if (!std.mem.startsWith(u8, generator_let.name, "__otest_generator_")) return null;
    if (!std.mem.startsWith(u8, body_let.name, "__otest_body_")) return null;
    const body_lambda = switch (body_let.value.*) {
        .Lambda => |value| value,
        else => return null,
    };
    if (body_lambda.params.len != 1) return null;
    return .{
        .generator = generator_let.value,
        .body = body_lambda,
        .sample_ty = body_lambda.params[0].ty,
    };
}

const ShrinkResult = struct {
    counterexample: []const u8,
    steps: usize,
    owned: bool = true,
};

fn shrinkCounterexample(
    allocator: std.mem.Allocator,
    core_arena: *std.heap.ArenaAllocator,
    module: ir.Module,
    parts: PropParts,
    initial: i64,
    loc: ir.Loc,
) !ShrinkResult {
    const sample_is_int = switch (parts.sample_ty) {
        .Int => true,
        else => false,
    };
    if (!sample_is_int) {
        const rendered = try std.fmt.allocPrint(allocator, "seed {d}", .{initial});
        return .{ .counterexample = rendered, .steps = 0 };
    }

    var current = initial;
    var steps: usize = 0;
    while (steps < 100) {
        const candidates = try shrinkIntCandidates(allocator, current);
        defer allocator.free(candidates);
        var advanced = false;
        for (candidates) |candidate| {
            if (try propBodyFails(core_arena, module, parts, candidate, loc)) {
                current = candidate;
                steps += 1;
                advanced = true;
                break;
            }
        }
        if (!advanced) break;
    }
    const rendered = try std.fmt.allocPrint(allocator, "{d}", .{current});
    return .{ .counterexample = rendered, .steps = steps };
}

fn shrinkIntCandidates(allocator: std.mem.Allocator, value: i64) ![]const i64 {
    var candidates = std.ArrayList(i64).empty;
    if (value == 0) return candidates.toOwnedSlice(allocator);
    try appendUniqueInt(&candidates, allocator, 0);
    const sign: i64 = if (value < 0) -1 else 1;
    var delta = @divTrunc(if (value < 0) -value else value, 2);
    while (delta != 0) : (delta = @divTrunc(delta, 2)) {
        try appendUniqueInt(&candidates, allocator, value - (sign * delta));
    }
    return candidates.toOwnedSlice(allocator);
}

fn appendUniqueInt(list: *std.ArrayList(i64), allocator: std.mem.Allocator, value: i64) !void {
    for (list.items) |existing| {
        if (existing == value) return;
    }
    try list.append(allocator, value);
}

fn propBodyFails(
    core_arena: *std.heap.ArenaAllocator,
    module: ir.Module,
    parts: PropParts,
    sample: i64,
    loc: ir.Loc,
) !bool {
    const entry_module = try moduleWithPropBodyEntrypoint(core_arena, module, parts, sample, loc);
    var interpreter: interp.Interpreter = .{};
    _ = interpreter.backend().evalModule(entry_module) catch return true;
    return false;
}

fn moduleWithPropEntrypoint(core_arena: *std.heap.ArenaAllocator, module: ir.Module, parts: PropParts, seed: i64, loc: ir.Loc) !ir.Module {
    const allocator = core_arena.allocator();
    const decls = try allocator.alloc(ir.Decl, module.decls.len + 1);
    @memcpy(decls[0..module.decls.len], module.decls);

    const pair_ty = generatorReturnTy(parts.generator.*) orelse ir.Ty{ .Tuple = &.{ .Int, .Int } };
    const pair_var = try varExpr(allocator, "__otest_sample_pair__", pair_ty, layout.structPack(), loc);
    const sample_proj = try allocator.create(ir.Expr);
    sample_proj.* = .{ .TupleProj = .{
        .tuple_expr = pair_var,
        .index = 0,
        .ty = parts.sample_ty,
        .layout = layoutForTy(parts.sample_ty),
        .loc = loc,
    } };

    const pair_var_for_seed = try varExpr(allocator, "__otest_sample_pair__", pair_ty, layout.structPack(), loc);
    const next_seed = try allocator.create(ir.Expr);
    next_seed.* = .{ .TupleProj = .{
        .tuple_expr = pair_var_for_seed,
        .index = 1,
        .ty = .Int,
        .layout = layout.intConstant(),
        .loc = loc,
    } };

    const body_call = try bodyCallExpr(allocator, parts, sample_proj, loc);
    const after_body = try propContinuationAfterBody(allocator, parts.body, body_call, next_seed, loc);

    const generator_call = try generatorCallExpr(allocator, parts.generator, seed, loc);
    const body = try allocator.create(ir.Expr);
    body.* = .{ .Let = .{
        .name = "__otest_sample_pair__",
        .value = generator_call,
        .body = after_body,
        .ty = .Int,
        .layout = layout.intConstant(),
        .loc = loc,
    } };

    decls[module.decls.len] = try entryDecl(allocator, body, loc);
    return moduleWithDecls(module, decls);
}

fn moduleWithPropBodyEntrypoint(core_arena: *std.heap.ArenaAllocator, module: ir.Module, parts: PropParts, sample: i64, loc: ir.Loc) !ir.Module {
    const allocator = core_arena.allocator();
    const decls = try allocator.alloc(ir.Decl, module.decls.len + 1);
    @memcpy(decls[0..module.decls.len], module.decls);

    const sample_expr = try intExpr(allocator, sample, loc);
    const body_call = try bodyCallExpr(allocator, parts, sample_expr, loc);
    const zero = try intExpr(allocator, 0, loc);
    const body = try propContinuationAfterBody(allocator, parts.body, body_call, zero, loc);

    decls[module.decls.len] = try entryDecl(allocator, body, loc);
    return moduleWithDecls(module, decls);
}

fn generatorCallExpr(allocator: std.mem.Allocator, generator: *const ir.Expr, seed: i64, loc: ir.Loc) !*const ir.Expr {
    const args = try allocator.alloc(*const ir.Expr, 1);
    args[0] = try intExpr(allocator, seed, loc);
    const call = try allocator.create(ir.Expr);
    call.* = .{ .App = .{
        .callee = generator,
        .args = args,
        .ty = generatorReturnTy(generator.*) orelse ir.Ty{ .Tuple = &.{ .Int, .Int } },
        .layout = layout.structPack(),
        .loc = loc,
    } };
    return call;
}

fn bodyCallExpr(allocator: std.mem.Allocator, parts: PropParts, sample: *const ir.Expr, loc: ir.Loc) !*const ir.Expr {
    const body_value = try allocator.create(ir.Expr);
    body_value.* = .{ .Lambda = parts.body };
    const args = try allocator.alloc(*const ir.Expr, 1);
    args[0] = sample;
    const call = try allocator.create(ir.Expr);
    call.* = .{ .App = .{
        .callee = body_value,
        .args = args,
        .ty = lambdaReturnTy(parts.body) orelse .Unit,
        .layout = layoutForTy(lambdaReturnTy(parts.body) orelse .Unit),
        .loc = loc,
    } };
    return call;
}

fn propContinuationAfterBody(
    allocator: std.mem.Allocator,
    body_lambda: ir.Lambda,
    body_call: *const ir.Expr,
    success_expr: *const ir.Expr,
    loc: ir.Loc,
) !*const ir.Expr {
    const ret_ty = lambdaReturnTy(body_lambda) orelse .Unit;
    const ret_is_bool = switch (ret_ty) {
        .Bool => true,
        else => false,
    };
    if (ret_is_bool) {
        const assert_expr = try allocator.create(ir.Expr);
        assert_expr.* = .{ .Assert = .{
            .condition = body_call,
            .ty = .Unit,
            .layout = layout.unitValue(),
            .loc = loc,
        } };
        const outer = try allocator.create(ir.Expr);
        outer.* = .{ .Let = .{
            .name = "__otest_asserted__",
            .value = assert_expr,
            .body = success_expr,
            .ty = .Int,
            .layout = layout.intConstant(),
            .loc = loc,
        } };
        return outer;
    }

    const outer = try allocator.create(ir.Expr);
    outer.* = .{ .Let = .{
        .name = "__otest_prop_ignored__",
        .value = body_call,
        .body = success_expr,
        .ty = .Int,
        .layout = layout.intConstant(),
        .loc = loc,
    } };
    return outer;
}

fn entryDecl(allocator: std.mem.Allocator, body: *const ir.Expr, loc: ir.Loc) !ir.Decl {
    const int_ty = try allocator.create(ir.Ty);
    int_ty.* = .Int;
    const lambda_ty: ir.Ty = .{ .Arrow = .{ .params = &.{}, .ret = int_ty } };
    const entry_expr = try allocator.create(ir.Expr);
    entry_expr.* = .{ .Lambda = .{
        .params = &.{},
        .body = body,
        .ty = lambda_ty,
        .layout = layout.topLevelLambda(),
        .loc = loc,
    } };
    return .{ .Let = .{
        .name = "entrypoint",
        .value = entry_expr,
        .ty = lambda_ty,
        .layout = layout.topLevelLambda(),
    } };
}

fn moduleWithDecls(module: ir.Module, decls: []const ir.Decl) ir.Module {
    return .{
        .decls = decls,
        .type_decls = module.type_decls,
        .tuple_type_decls = module.tuple_type_decls,
        .record_type_decls = module.record_type_decls,
        .externals = module.externals,
    };
}

fn intExpr(allocator: std.mem.Allocator, value: i64, loc: ir.Loc) !*const ir.Expr {
    const expr = try allocator.create(ir.Expr);
    expr.* = .{ .Constant = .{
        .value = .{ .Int = value },
        .ty = .Int,
        .layout = layout.intConstant(),
        .loc = loc,
    } };
    return expr;
}

fn varExpr(allocator: std.mem.Allocator, name: []const u8, ty: ir.Ty, expr_layout: layout.Layout, loc: ir.Loc) !*const ir.Expr {
    const expr = try allocator.create(ir.Expr);
    expr.* = .{ .Var = .{
        .name = name,
        .ty = ty,
        .layout = expr_layout,
        .loc = loc,
    } };
    return expr;
}

fn lambdaReturnTy(lambda: ir.Lambda) ?ir.Ty {
    return switch (lambda.ty) {
        .Arrow => |arrow| arrow.ret.*,
        else => null,
    };
}

fn generatorReturnTy(expr: ir.Expr) ?ir.Ty {
    return switch (expr) {
        .App => |app| switch (app.ty) {
            .Arrow => |arrow| arrow.ret.*,
            else => null,
        },
        .Var => |var_ref| switch (var_ref.ty) {
            .Arrow => |arrow| arrow.ret.*,
            else => null,
        },
        .Lambda => |lambda| lambdaReturnTy(lambda),
        else => null,
    };
}

fn layoutForTy(ty: ir.Ty) layout.Layout {
    return switch (ty) {
        .Int, .Bool => layout.intConstant(),
        .Unit => layout.unitValue(),
        .String => layout.defaultFor(.StringLiteral),
        .Adt, .Tuple, .Record, .Var, .Arrow => layout.structPack(),
    };
}

fn moduleWithEntrypoint(core_arena: *std.heap.ArenaAllocator, module: ir.Module, thunk_name: []const u8, loc: ir.Loc) !ir.Module {
    const allocator = core_arena.allocator();
    const decls = try allocator.alloc(ir.Decl, module.decls.len + 1);
    @memcpy(decls[0..module.decls.len], module.decls);

    const int_ty = try allocator.create(ir.Ty);
    int_ty.* = .Int;
    const unit_ty = try allocator.create(ir.Ty);
    unit_ty.* = .Unit;

    const unit_arg = try allocator.create(ir.Expr);
    unit_arg.* = .{ .Ctor = .{
        .name = "()",
        .args = &.{},
        .ty = .Unit,
        .layout = layout.unitValue(),
        .loc = loc,
    } };
    const args = try allocator.alloc(*const ir.Expr, 1);
    args[0] = unit_arg;

    const thunk = findTopLevelLet(module, thunk_name);
    const callee = try allocator.create(ir.Expr);
    callee.* = .{ .Var = .{
        .name = thunk_name,
        .ty = if (thunk) |decl| decl.ty else .{ .Arrow = .{ .params = &.{.Unit}, .ret = unit_ty } },
        .layout = if (thunk) |decl| decl.layout else layout.topLevelLambda(),
        .loc = loc,
    } };

    const call = try allocator.create(ir.Expr);
    call.* = .{ .App = .{
        .callee = callee,
        .args = args,
        .ty = .Unit,
        .layout = layout.unitValue(),
        .loc = loc,
    } };

    const zero = try allocator.create(ir.Expr);
    zero.* = .{ .Constant = .{
        .value = .{ .Int = 0 },
        .ty = .Int,
        .layout = layout.intConstant(),
        .loc = loc,
    } };

    const body = try allocator.create(ir.Expr);
    body.* = .{ .Let = .{
        .name = "__otest_ignored__",
        .value = call,
        .body = zero,
        .ty = .Int,
        .layout = layout.intConstant(),
        .loc = loc,
    } };

    const lambda_ty: ir.Ty = .{ .Arrow = .{ .params = &.{}, .ret = int_ty } };
    const entry_expr = try allocator.create(ir.Expr);
    entry_expr.* = .{ .Lambda = .{
        .params = &.{},
        .body = body,
        .ty = lambda_ty,
        .layout = layout.topLevelLambda(),
        .loc = loc,
    } };

    decls[module.decls.len] = .{ .Let = .{
        .name = "entrypoint",
        .value = entry_expr,
        .ty = lambda_ty,
        .layout = layout.topLevelLambda(),
    } };

    return .{
        .decls = decls,
        .type_decls = module.type_decls,
        .tuple_type_decls = module.tuple_type_decls,
        .record_type_decls = module.record_type_decls,
        .externals = module.externals,
    };
}

fn appendCargoHeader(output: *std.ArrayList(u8), allocator: std.mem.Allocator, total: usize) !void {
    const line = try std.fmt.allocPrint(allocator, "running {d} tests\n", .{total});
    defer allocator.free(line);
    try output.appendSlice(allocator, line);
}

fn appendCargoResult(output: *std.ArrayList(u8), allocator: std.mem.Allocator, result: TestResult, use_color: bool) !void {
    const status = switch (result.status) {
        .ok => if (use_color) "\x1b[32mok\x1b[0m" else "ok",
        .failed => if (use_color) "\x1b[31mFAILED\x1b[0m" else "FAILED",
    };
    const line = if (result.case.kind == .prop)
        try std.fmt.allocPrint(
            allocator,
            "test {s}::prop_{s} ... {s} ({d} cases)\n",
            .{ result.case.file, result.case.name, status, result.num_cases },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "test {s}::{s} ... {s}\n",
            .{ result.case.file, result.case.name, status },
        );
    defer allocator.free(line);
    try output.appendSlice(allocator, line);
    if (result.status == .failed) {
        const failure_line = if (result.case.kind == .prop)
            try std.fmt.allocPrint(
                allocator,
                "  {s}:{d}:{d}: {s}; FAILED after {d} tests; shrunk to: {s} (in {d} shrink steps)\n",
                .{
                    result.case.loc.file,
                    result.case.loc.line,
                    result.case.loc.col,
                    result.message,
                    result.executed_cases,
                    result.counterexample orelse "unknown",
                    result.shrunk_steps,
                },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "  {s}:{d}:{d}: {s}\n",
                .{ result.case.loc.file, result.case.loc.line, result.case.loc.col, result.message },
            );
        defer allocator.free(failure_line);
        try output.appendSlice(allocator, failure_line);
    }
}

fn appendCargoSummary(output: *std.ArrayList(u8), allocator: std.mem.Allocator, summary: Summary, use_color: bool) !void {
    const status = if (summary.failed == 0)
        if (use_color) "\x1b[32mok\x1b[0m" else "ok"
    else if (use_color) "\x1b[31mFAILED\x1b[0m" else "FAILED";
    const line = try std.fmt.allocPrint(
        allocator,
        "test result: {s}. {d} passed; {d} failed; finished in {d}ms\n",
        .{ status, summary.passed, summary.failed, summary.elapsed_ms },
    );
    defer allocator.free(line);
    try output.appendSlice(allocator, line);
}

fn appendJsonResult(output: *std.ArrayList(u8), allocator: std.mem.Allocator, result: TestResult) !void {
    try output.appendSlice(allocator, "{\"type\":\"test\",\"file\":");
    try appendJsonString(output, allocator, result.case.file);
    try output.appendSlice(allocator, ",\"name\":");
    try appendJsonString(output, allocator, result.case.name);
    try output.appendSlice(allocator, ",\"kind\":\"");
    try output.appendSlice(allocator, if (result.case.kind == .prop) "prop" else "unit");
    try output.appendSlice(allocator, "\",\"status\":\"");
    try output.appendSlice(allocator, if (result.status == .ok) "ok" else "failed");
    try output.appendSlice(allocator, "\",\"elapsed_ms\":");
    try appendInt(output, allocator, result.elapsed_ms);
    if (result.case.kind == .prop) {
        try output.appendSlice(allocator, ",\"num_cases\":");
        try appendInt(output, allocator, result.num_cases);
        try output.appendSlice(allocator, ",\"seed\":");
        try appendInt(output, allocator, result.seed);
    }
    if (result.status == .failed) {
        try output.appendSlice(allocator, ",\"message\":");
        try appendJsonString(output, allocator, result.message);
        try output.appendSlice(allocator, ",\"line\":");
        try appendInt(output, allocator, result.case.loc.line);
        try output.appendSlice(allocator, ",\"col\":");
        try appendInt(output, allocator, result.case.loc.col);
        if (result.case.kind == .prop) {
            try output.appendSlice(allocator, ",\"shrunk_steps\":");
            try appendInt(output, allocator, result.shrunk_steps);
            try output.appendSlice(allocator, ",\"counterexample\":");
            try appendJsonString(output, allocator, result.counterexample orelse "unknown");
        }
    }
    try output.appendSlice(allocator, "}\n");
}

fn appendJsonSummary(output: *std.ArrayList(u8), allocator: std.mem.Allocator, summary: Summary) !void {
    try output.appendSlice(allocator, "{\"type\":\"summary\",\"status\":\"");
    try output.appendSlice(allocator, if (summary.failed == 0) "ok" else "failed");
    try output.appendSlice(allocator, "\",\"total\":");
    try appendInt(output, allocator, summary.total);
    try output.appendSlice(allocator, ",\"passed\":");
    try appendInt(output, allocator, summary.passed);
    try output.appendSlice(allocator, ",\"failed\":");
    try appendInt(output, allocator, summary.failed);
    try output.appendSlice(allocator, ",\"elapsed_ms\":");
    try appendInt(output, allocator, summary.elapsed_ms);
    try output.appendSlice(allocator, "}\n");
}

fn appendJsonString(line: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try line.append(allocator, '"');
    for (text) |byte| {
        switch (byte) {
            '"' => try line.appendSlice(allocator, "\\\""),
            '\\' => try line.appendSlice(allocator, "\\\\"),
            '\n' => try line.appendSlice(allocator, "\\n"),
            '\r' => try line.appendSlice(allocator, "\\r"),
            '\t' => try line.appendSlice(allocator, "\\t"),
            else => {
                if (byte < 0x20) {
                    var buffer: [8]u8 = undefined;
                    const escaped = try std.fmt.bufPrint(&buffer, "\\u00{x:0>2}", .{byte});
                    try line.appendSlice(allocator, escaped);
                } else {
                    try line.append(allocator, byte);
                }
            },
        }
    }
    try line.append(allocator, '"');
}

fn appendInt(line: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) !void {
    var buffer: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try line.appendSlice(allocator, rendered);
}

fn shouldUseColor(init: std.process.Init, args: Args) !bool {
    if (args.no_color) return false;
    if (try hasNoColorEnv(init.gpa, init.minimal.environ)) return false;
    return std.Io.File.stdout().isTty(init.io) catch false;
}

fn frontendOptions(init: std.process.Init, args: Args) !pipeline.FrontendOptions {
    return .{
        .diagnostics = .{
            .error_format = diag.ErrorFormat.human,
            .color = if (args.no_color) render.Color.never else render.Color.auto,
            .stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false,
            .no_color_env = try hasNoColorEnv(init.gpa, init.minimal.environ),
        },
        .wire_version = null,
    };
}

fn hasNoColorEnv(allocator: std.mem.Allocator, environ: std.process.Environ) !bool {
    const value = std.process.Environ.getAlloc(environ, allocator, "NO_COLOR") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        else => |e| return e,
    };
    allocator.free(value);
    return true;
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

fn writeStderr(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}
