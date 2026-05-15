//! Static compute-unit and stack-depth report for Core IR modules.
//!
//! RESPONSIBILITIES:
//! - Walk the post-optimization, post-region-inference Core IR and produce a
//!   deterministic, opt-in textual report consumed by
//!   `omlz check --report=<kinds>`.
//! - Estimate compute-unit (CU) usage conservatively per the rules documented
//!   in `docs/06-bpf-target.md` ("Static profiling reports").
//! - Estimate max per-function stack frame size from Core IR layout
//!   annotations carried by region inference.
//! - Never instrument or execute BPF; the report is a static estimate that
//!   may differ from runtime behavior.

const std = @import("std");
const ir = @import("ir.zig");
const layout = @import("layout.zig");

/// Report sections requested by the CLI.
pub const Kinds = struct {
    cu: bool = false,
    stack: bool = false,

    pub fn any(self: Kinds) bool {
        return self.cu or self.stack;
    }
};

/// Errors produced when parsing the `--report=<csv>` value.
pub const ParseKindsError = error{UnknownReportKind};

/// Parses the comma-separated kinds value from `--report=<value>`.
///
/// Accepts the literal `all` plus any combination of `cu` / `stack` separated
/// by commas. Leading/trailing whitespace is ignored. Unknown kinds return
/// `error.UnknownReportKind` so the CLI can map the failure to a stable code.
pub fn parseKinds(value: []const u8) ParseKindsError!Kinds {
    var kinds: Kinds = .{};
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "all")) {
            kinds.cu = true;
            kinds.stack = true;
        } else if (std.mem.eql(u8, trimmed, "cu")) {
            kinds.cu = true;
        } else if (std.mem.eql(u8, trimmed, "stack")) {
            kinds.stack = true;
        } else {
            return error.UnknownReportKind;
        }
    }
    if (!kinds.any()) return error.UnknownReportKind;
    return kinds;
}

/// Render error union: allocation failures plus internal analysis stalls.
pub const ReportError = std.mem.Allocator.Error;

/// Loop bound multiplier cap; beyond this we treat the loop as unbounded
/// for cost-estimation purposes.
const max_static_loop_bound: u32 = 256;

/// Estimated CU per non-syscall function call.
const cu_per_call: u32 = 5;

/// Estimated CU per Prim/arith/compare op.
const cu_per_prim: u32 = 1;

/// Estimated CU per control-flow branch decision.
const cu_per_branch: u32 = 1;

/// Default syscall cost when not in the small table.
const default_syscall_cu: u32 = 100;

/// Syscall cost-table entry.
const SyscallCost = struct {
    name: []const u8,
    base: u32,
    per_byte: u32,
};

/// Small static syscall cost table (alphabetized for stability).
const syscall_table = [_]SyscallCost{
    .{ .name = "sol_blake3", .base = 85, .per_byte = 10 },
    .{ .name = "sol_invoke_signed_c", .base = 1000, .per_byte = 0 },
    .{ .name = "sol_keccak256", .base = 85, .per_byte = 10 },
    .{ .name = "sol_log_", .base = 100, .per_byte = 0 },
    .{ .name = "sol_log_64", .base = 100, .per_byte = 0 },
    .{ .name = "sol_secp256k1_recover", .base = 25000, .per_byte = 0 },
    .{ .name = "sol_sha256", .base = 85, .per_byte = 10 },
};

fn lookupSyscallCost(symbol: []const u8) ?SyscallCost {
    for (syscall_table) |entry| {
        if (std.mem.eql(u8, entry.name, symbol)) return entry;
    }
    return null;
}

/// Per-syscall accumulated counter.
const SyscallTally = struct {
    name: []const u8,
    calls: u32 = 0,
    total_cu: u64 = 0,
};

/// Stack-frame estimate per function.
const StackEntry = struct {
    name: []const u8,
    bytes: u64,
};

/// Classification of a desugared loop function discovered by the analyzer.
const LoopKind = enum { For, While };

/// Reason a loop was flagged as risky (or `None` if the multiplier applied).
const LoopRisk = enum { None, Unbounded, UnknownDynamic };

/// One desugared `__zxc_loop_<id>` function the analyzer touched.
const LoopInfo = struct {
    name: []const u8,
    enclosing: []const u8,
    kind: LoopKind,
    risk: LoopRisk = .None,
    iterations: ?u64 = null,
    body_cost_cu: u64 = 0,
    dynamic_reason: []const u8 = "",
};

/// One pass result; produced before rendering.
const Analysis = struct {
    allocator: std.mem.Allocator,
    module: ir.Module,
    externals: std.StringHashMap([]const u8), // function name -> zig symbol
    top_level: std.StringHashMap(*const ir.Let),

    // CU section state.
    prim_count: u64 = 0,
    call_count: u64 = 0,
    branch_count: u64 = 0,
    syscall_cu_total: u64 = 0,
    extra_loop_cu: u64 = 0,
    syscall_tallies: std.StringHashMap(SyscallTally),
    has_unbounded_loop: bool = false,
    has_unknown_dynamic: bool = false,

    // Map of locally-bound integer literals discovered while walking
    // expressions, keyed by binding name. Used to resolve `__zxc_loop_lo_<n>`
    // / `__zxc_loop_bound_<n>` from the surrounding ADR-015 desugar shape.
    int_literal_bindings: std.StringHashMap(i64),

    // Set of loop ids (the `<n>` suffix) whose `__zxc_loop_bound_<n>` binding
    // we have observed. Presence indicates a `for` desugar; absence indicates
    // a `while` desugar.
    loop_bound_ids: std.StringHashMap(void),

    // Discovered desugared loops, in the order they were encountered.
    loops: std.ArrayList(LoopInfo),

    // Name of the enclosing top-level declaration we are currently visiting.
    // Used so loop-risk messages can name the host function.
    current_function: []const u8 = "(toplevel)",

    // Names of loop helpers whose back-edge tail call should be skipped
    // because we already folded their cost into the multiplier.
    skip_loop_back_edge: std.StringHashMap(void),

    // Stack section state.
    stack_entries: std.ArrayList(StackEntry),

    // Per-function visit caches.
    visiting: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator, module: ir.Module) Analysis {
        return .{
            .allocator = allocator,
            .module = module,
            .externals = std.StringHashMap([]const u8).init(allocator),
            .top_level = std.StringHashMap(*const ir.Let).init(allocator),
            .syscall_tallies = std.StringHashMap(SyscallTally).init(allocator),
            .int_literal_bindings = std.StringHashMap(i64).init(allocator),
            .loop_bound_ids = std.StringHashMap(void).init(allocator),
            .loops = std.ArrayList(LoopInfo).empty,
            .skip_loop_back_edge = std.StringHashMap(void).init(allocator),
            .stack_entries = std.ArrayList(StackEntry).empty,
            .visiting = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *Analysis) void {
        self.externals.deinit();
        self.top_level.deinit();
        self.syscall_tallies.deinit();
        self.int_literal_bindings.deinit();
        self.loop_bound_ids.deinit();
        self.loops.deinit(self.allocator);
        self.skip_loop_back_edge.deinit();
        self.stack_entries.deinit(self.allocator);
        self.visiting.deinit();
    }

    fn buildIndex(self: *Analysis) ReportError!void {
        for (self.module.externals) |external| {
            try self.externals.put(external.name, external.symbol);
        }
        for (self.module.decls) |*decl| {
            switch (decl.*) {
                .Let => |*let_decl| try self.top_level.put(let_decl.name, let_decl),
                .LetGroup => |group| {
                    // LetGroup top-level entries are anonymous mutually-recursive
                    // groups; expose each binding so callers resolve transitively.
                    for (group.bindings) |binding| {
                        // We can't form a *const ir.Let safely from a binding,
                        // so register only externals and named top-level lets.
                        _ = binding;
                    }
                },
            }
        }
    }

    fn recordSyscall(self: *Analysis, symbol: []const u8, byte_estimate: u32) ReportError!void {
        const entry = try self.syscall_tallies.getOrPut(symbol);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .name = symbol };
        }
        entry.value_ptr.calls += 1;
        const cost = lookupSyscallCost(symbol);
        const base = if (cost) |c| c.base else default_syscall_cu;
        const per_byte = if (cost) |c| c.per_byte else 0;
        const this_cost = @as(u64, base) + @as(u64, per_byte) * @as(u64, byte_estimate);
        entry.value_ptr.total_cu += this_cost;
        self.syscall_cu_total += this_cost;
    }
};

/// Returns the iteration count for a `for to`/`downto` loop given the
/// resolved literal bounds. `lo` and `hi` are inclusive in the desugar.
fn forLoopIterations(op_cmp: PrimCmp, lo: i64, hi: i64) ?u64 {
    return switch (op_cmp) {
        .Gt => if (hi >= lo) blk: {
            const diff = @as(u64, @intCast(hi - lo));
            break :blk diff + 1;
        } else null,
        .Lt => if (lo >= hi) blk: {
            const diff = @as(u64, @intCast(lo - hi));
            break :blk diff + 1;
        } else null,
        else => null,
    };
}

const PrimCmp = enum { Gt, Lt, Other };

fn classifyLoopCmp(body: ir.Expr) PrimCmp {
    return switch (body) {
        .If => |if_expr| switch (if_expr.cond.*) {
            .Prim => |prim| switch (prim.op) {
                .Gt => .Gt,
                .Lt => .Lt,
                else => .Other,
            },
            else => .Other,
        },
        else => .Other,
    };
}

/// Cost of walking an expression as if it were the body of a loop helper.
/// Mirrors `visitExpr` but accumulates into a fresh CU counter and does NOT
/// follow the back-edge tail call. Returns the total CU contribution.
fn measureLoopBodyCu(self: *Analysis, loop_name: []const u8, expr: ir.Expr) ReportError!u64 {
    // Snapshot global counters and syscalls before walking the body so we
    // can compute the body's exclusive contribution.
    const prim_before = self.prim_count;
    const branch_before = self.branch_count;
    const call_before = self.call_count;
    const syscall_total_before = self.syscall_cu_total;

    // Suppress back-edge accounting while we walk the body.
    try self.skip_loop_back_edge.put(loop_name, {});
    defer _ = self.skip_loop_back_edge.remove(loop_name);

    try visitExpr(self, expr);

    const prim_delta = self.prim_count - prim_before;
    const branch_delta = self.branch_count - branch_before;
    const call_delta = self.call_count - call_before;
    const syscall_delta = self.syscall_cu_total - syscall_total_before;

    return prim_delta * cu_per_prim +
        branch_delta * cu_per_branch +
        call_delta * cu_per_call +
        syscall_delta;
}

/// Processes a `let rec __zxc_loop_<n> = lambda in <body-or-call>` binding.
/// Adds the loop's multiplied CU contribution (when bounded) and records the
/// loop in `self.loops` for later risk reporting.
fn handleLoopBinding(
    self: *Analysis,
    loop_name: []const u8,
    lambda: ir.Lambda,
    in_body: ir.Expr,
) ReportError!void {
    // Walk the lambda body once for the "one iteration already counted"
    // accounting (the existing pass counts it as a single recursive call).
    // Then walk it again in isolation to measure its CU and apply the
    // multiplier for the remaining iterations.
    const body_cost = try measureLoopBodyCu(self, loop_name, lambda.body.*);

    const id_suffix = loop_name["__zxc_loop_".len..];
    const kind: LoopKind = if (self.loop_bound_ids.contains(id_suffix)) .For else .While;

    var info: LoopInfo = .{
        .name = loop_name,
        .enclosing = self.current_function,
        .kind = kind,
        .body_cost_cu = body_cost,
    };

    switch (kind) {
        .For => {
            // Try to resolve `__zxc_loop_lo_<n>` and `__zxc_loop_bound_<n>`.
            const lo_key = try std.fmt.allocPrint(self.allocator, "__zxc_loop_lo_{s}", .{id_suffix});
            defer self.allocator.free(lo_key);
            const hi_key = try std.fmt.allocPrint(self.allocator, "__zxc_loop_bound_{s}", .{id_suffix});
            defer self.allocator.free(hi_key);

            const cmp = classifyLoopCmp(lambda.body.*);
            const lo_opt = self.int_literal_bindings.get(lo_key);
            const hi_opt = self.int_literal_bindings.get(hi_key);

            if (lo_opt == null or hi_opt == null or cmp == .Other) {
                info.risk = .UnknownDynamic;
                info.dynamic_reason = if (cmp == .Other) "non-canonical" else "non-literal bound";
                self.has_unknown_dynamic = true;
            } else {
                const lo_val = lo_opt.?;
                const hi_val = hi_opt.?;
                if (forLoopIterations(cmp, lo_val, hi_val)) |iters| {
                    if (iters > max_static_loop_bound) {
                        info.risk = .Unbounded;
                        info.iterations = iters;
                        self.has_unbounded_loop = true;
                    } else if (iters >= 1) {
                        info.iterations = iters;
                        // The lambda body already accounts for one iteration;
                        // add the remaining `iters - 1` iterations' cost.
                        self.extra_loop_cu += body_cost * (iters - 1);
                    } else {
                        info.iterations = 0;
                        // Zero-iteration loop: the lambda body cost was added
                        // once but the `cond` will short-circuit; conservative
                        // bound keeps that single accounting.
                    }
                } else {
                    info.risk = .UnknownDynamic;
                    info.dynamic_reason = "non-canonical";
                    self.has_unknown_dynamic = true;
                }
            }
        },
        .While => {
            info.risk = .UnknownDynamic;
            info.dynamic_reason = "while";
            self.has_unknown_dynamic = true;
        },
    }

    try self.loops.append(self.allocator, info);

    // Visit the body of the surrounding `let` (which contains the initial
    // App `__zxc_loop_<n> ...`). We do NOT charge the initial call against
    // the standard counters: the loop's iterations already cover it.
    try self.skip_loop_back_edge.put(loop_name, {});
    defer _ = self.skip_loop_back_edge.remove(loop_name);
    try visitExpr(self, in_body);
}

/// Walks every reachable expression in `expr`, accumulating CU costs and
/// counting branches/prims.
fn visitExpr(self: *Analysis, expr: ir.Expr) ReportError!void {
    switch (expr) {
        .Constant, .Var => {},
        .Lambda => |lambda| try visitExpr(self, lambda.body.*),
        .App => |app| {
            try visitExpr(self, app.callee.*);
            for (app.args) |arg| try visitExpr(self, arg.*);

            // Identify callee.
            const callee_name: ?[]const u8 = switch (app.callee.*) {
                .Var => |v| v.name,
                else => null,
            };
            if (callee_name) |name| {
                if (self.externals.get(name)) |symbol| {
                    if (std.mem.startsWith(u8, symbol, "sol_")) {
                        const byte_estimate = inferSyscallByteEstimate(app);
                        try self.recordSyscall(symbol, byte_estimate);
                        return;
                    }
                }
                if (std.mem.startsWith(u8, name, "__zxc_loop_")) {
                    if (self.skip_loop_back_edge.contains(name)) {
                        // The enclosing loop's body cost (including this
                        // tail call) has already been folded into the
                        // multiplier; skip the standard accounting.
                        return;
                    }
                    self.call_count += 1;
                    return;
                }
            }
            self.call_count += 1;
        },
        .Let => |let_expr| {
            // Track integer-literal lets so the loop-bound lookup can
            // resolve `__zxc_loop_lo_<n>` / `__zxc_loop_bound_<n>` later.
            switch (let_expr.value.*) {
                .Constant => |c| switch (c.value) {
                    .Int => |n| try self.int_literal_bindings.put(let_expr.name, n),
                    else => {},
                },
                else => {},
            }

            // Track `__zxc_loop_bound_<n>` bindings (regardless of whether
            // their value is a literal) so we can distinguish `for` from
            // `while` desugars later.
            if (std.mem.startsWith(u8, let_expr.name, "__zxc_loop_bound_")) {
                const suffix = let_expr.name["__zxc_loop_bound_".len..];
                try self.loop_bound_ids.put(suffix, {});
            }

            // Detect a desugared loop binding: `let rec __zxc_loop_<n> = lambda in ...`.
            if (std.mem.startsWith(u8, let_expr.name, "__zxc_loop_") and
                !std.mem.startsWith(u8, let_expr.name, "__zxc_loop_lo_") and
                !std.mem.startsWith(u8, let_expr.name, "__zxc_loop_bound_"))
            {
                switch (let_expr.value.*) {
                    .Lambda => |lambda| {
                        try handleLoopBinding(self, let_expr.name, lambda, let_expr.body.*);
                        return;
                    },
                    else => {},
                }
            }

            try visitExpr(self, let_expr.value.*);
            try visitExpr(self, let_expr.body.*);
        },
        .LetGroup => |group| {
            for (group.bindings) |binding| try visitExpr(self, binding.value.*);
            try visitExpr(self, group.body.*);
        },
        .Assert => |assert_expr| {
            // Assert is one comparison + one branch.
            self.prim_count += 1;
            self.branch_count += 1;
            try visitExpr(self, assert_expr.condition.*);
        },
        .If => |if_expr| {
            self.branch_count += 1;
            try visitExpr(self, if_expr.cond.*);
            try visitExpr(self, if_expr.then_branch.*);
            try visitExpr(self, if_expr.else_branch.*);
        },
        .Prim => |prim| {
            self.prim_count += 1;
            for (prim.args) |arg| try visitExpr(self, arg.*);
        },
        .Ctor => |ctor| {
            for (ctor.args) |arg| try visitExpr(self, arg.*);
        },
        .Match => |match_expr| {
            try visitExpr(self, match_expr.scrutinee.*);
            // Each arm decision costs one branch; conservative bound.
            self.branch_count += match_expr.arms.len;
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| try visitExpr(self, guard.*);
                try visitExpr(self, arm.body.*);
            }
        },
        .Tuple => |tuple_expr| {
            for (tuple_expr.items) |item| try visitExpr(self, item.*);
        },
        .TupleProj => |proj| try visitExpr(self, proj.tuple_expr.*),
        .Record => |record_expr| {
            for (record_expr.fields) |field| try visitExpr(self, field.value.*);
        },
        .RecordField => |field| try visitExpr(self, field.record_expr.*),
        .RecordUpdate => |update| {
            try visitExpr(self, update.base_expr.*);
            for (update.fields) |field| try visitExpr(self, field.value.*);
        },
        .AccountFieldSet => |field_set| {
            try visitExpr(self, field_set.account_expr.*);
            try visitExpr(self, field_set.value.*);
        },
        .ArrayLit => |array_lit| {
            // ADR-015 R9.1: account ~1 CU per element initializer to model
            // the eager arena fill emitted by codegen, plus one prim for
            // the allocation itself.
            self.prim_count += 1;
            for (array_lit.elems) |elem| {
                self.prim_count += 1;
                try visitExpr(self, elem.*);
            }
        },
        .ArrayGet => |array_get| {
            // Two CU per get: one for the bounds check, one for the load.
            self.prim_count += 2;
            self.branch_count += 1;
            try visitExpr(self, array_get.arr.*);
            try visitExpr(self, array_get.idx.*);
        },
        .ArrayLength => |array_length| {
            // One CU for the slice length probe.
            self.prim_count += 1;
            try visitExpr(self, array_length.arr.*);
        },
        .ArraySet => |array_set| {
            // ADR-015 R9.2: two CU per set (the store + bounds check).
            self.prim_count += 2;
            self.branch_count += 1;
            try visitExpr(self, array_set.arr.*);
            try visitExpr(self, array_set.idx.*);
            try visitExpr(self, array_set.value.*);
        },
        .ArrayMake => |array_make| {
            // ADR-015 R9.2: one CU per element initializer for the eager
            // arena fill, plus one for the allocation itself.
            self.prim_count += 1 + array_make.size;
            try visitExpr(self, array_make.init.*);
        },
        .RefMake => |ref_make| {
            // ADR-015 option C / R10: one CU for the 1-slot arena allocation
            // plus one for the initial store.
            self.prim_count += 2;
            try visitExpr(self, ref_make.init.*);
        },
        .RefGet => |ref_get| {
            // One CU for the pointer load.
            self.prim_count += 1;
            try visitExpr(self, ref_get.target.*);
        },
        .RefSet => |ref_set| {
            // One CU for the pointer store.
            self.prim_count += 1;
            try visitExpr(self, ref_set.target.*);
            try visitExpr(self, ref_set.value.*);
        },
    }
}

/// Approximates the byte argument of a Solana syscall when it is a string
/// literal. Returns 0 otherwise (we can't tell statically).
fn inferSyscallByteEstimate(app: ir.App) u32 {
    for (app.args) |arg| {
        switch (arg.*) {
            .Constant => |c| switch (c.value) {
                .String => |s| return std.math.cast(u32, s.len) orelse std.math.maxInt(u32),
                else => {},
            },
            else => {},
        }
    }
    return 0;
}

/// Approximates a Core IR type size in bytes for stack-depth estimation.
fn tySize(ty: ir.Ty) u64 {
    return switch (ty) {
        .Int => 8,
        .Bool => 1,
        .Unit => 0,
        .String => 16, // pointer + length
        .Var => 8, // unknown; treat as pointer
        .Arrow => 8, // function pointer / closure pointer
        .Adt => 16, // discriminator + boxed payload pointer (conservative)
        .Tuple => |items| blk: {
            var sum: u64 = 0;
            for (items) |item| sum += tySize(item);
            break :blk sum;
        },
        .Record => 16, // boxed record pointer (conservative)
        // R9.1 read-only int arrays are lowered as Zig slices: ptr + len.
        .Array => 16,
        // ADR-015 option C / R10 ref cells are a single arena pointer.
        .Ref => 8,
    };
}

/// Per-function stack-frame walk: counts params and named lets whose region
/// is `Stack` (post region inference). Closure captures stored in arena are
/// not counted here.
fn measureStack(self: *Analysis, function_name: []const u8, body: ir.Expr, params: []const ir.Param) ReportError!void {
    var bytes: u64 = 0;
    for (params) |param| {
        bytes += tySize(param.ty);
    }
    bytes += accumulateStackLets(body);
    try self.stack_entries.append(self.allocator, .{ .name = function_name, .bytes = bytes });
}

fn accumulateStackLets(expr: ir.Expr) u64 {
    return switch (expr) {
        .Let => |let_expr| blk: {
            var sum: u64 = 0;
            if (let_expr.layout.region == .Stack) {
                sum += tySize(let_expr.ty);
            }
            sum += accumulateStackLets(let_expr.value.*);
            sum += accumulateStackLets(let_expr.body.*);
            break :blk sum;
        },
        .LetGroup => |group| blk: {
            var sum: u64 = 0;
            for (group.bindings) |binding| {
                if (binding.layout.region == .Stack) sum += tySize(binding.ty);
                sum += accumulateStackLets(binding.value.*);
            }
            sum += accumulateStackLets(group.body.*);
            break :blk sum;
        },
        .Lambda => |lambda| accumulateStackLets(lambda.body.*),
        .App => |app| blk: {
            var sum = accumulateStackLets(app.callee.*);
            for (app.args) |arg| sum += accumulateStackLets(arg.*);
            break :blk sum;
        },
        .Assert => |assert_expr| accumulateStackLets(assert_expr.condition.*),
        .If => |if_expr| accumulateStackLets(if_expr.cond.*) + accumulateStackLets(if_expr.then_branch.*) + accumulateStackLets(if_expr.else_branch.*),
        .Prim => |prim| blk: {
            var sum: u64 = 0;
            for (prim.args) |arg| sum += accumulateStackLets(arg.*);
            break :blk sum;
        },
        .Ctor => |ctor| blk: {
            var sum: u64 = 0;
            for (ctor.args) |arg| sum += accumulateStackLets(arg.*);
            break :blk sum;
        },
        .Match => |match_expr| blk: {
            var sum = accumulateStackLets(match_expr.scrutinee.*);
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| sum += accumulateStackLets(guard.*);
                sum += accumulateStackLets(arm.body.*);
            }
            break :blk sum;
        },
        .Tuple => |tuple_expr| blk: {
            var sum: u64 = 0;
            for (tuple_expr.items) |item| sum += accumulateStackLets(item.*);
            break :blk sum;
        },
        .TupleProj => |proj| accumulateStackLets(proj.tuple_expr.*),
        .Record => |record_expr| blk: {
            var sum: u64 = 0;
            for (record_expr.fields) |field| sum += accumulateStackLets(field.value.*);
            break :blk sum;
        },
        .RecordField => |field| accumulateStackLets(field.record_expr.*),
        .RecordUpdate => |update| blk: {
            var sum = accumulateStackLets(update.base_expr.*);
            for (update.fields) |field| sum += accumulateStackLets(field.value.*);
            break :blk sum;
        },
        .AccountFieldSet => |field_set| accumulateStackLets(field_set.account_expr.*) + accumulateStackLets(field_set.value.*),
        .ArrayLit => |array_lit| blk: {
            var sum: u64 = 0;
            for (array_lit.elems) |elem| sum += accumulateStackLets(elem.*);
            break :blk sum;
        },
        .ArrayGet => |array_get| accumulateStackLets(array_get.arr.*) + accumulateStackLets(array_get.idx.*),
        .ArrayLength => |array_length| accumulateStackLets(array_length.arr.*),
        .ArraySet => |array_set| accumulateStackLets(array_set.arr.*) + accumulateStackLets(array_set.idx.*) + accumulateStackLets(array_set.value.*),
        .ArrayMake => |array_make| accumulateStackLets(array_make.init.*),
        .RefMake => |ref_make| accumulateStackLets(ref_make.init.*),
        .RefGet => |ref_get| accumulateStackLets(ref_get.target.*),
        .RefSet => |ref_set| accumulateStackLets(ref_set.target.*) + accumulateStackLets(ref_set.value.*),
        .Constant, .Var => 0,
    };
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessThanSyscall(_: void, a: SyscallTally, b: SyscallTally) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn lessThanStack(_: void, a: StackEntry, b: StackEntry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Walks the top-level declarations and feeds CU/stack visitors.
fn runAnalysis(self: *Analysis) ReportError!void {
    try self.buildIndex();

    for (self.module.decls) |decl| {
        switch (decl) {
            .Let => |let_decl| {
                self.current_function = let_decl.name;
                switch (let_decl.value.*) {
                    .Lambda => |lambda| {
                        try measureStack(self, let_decl.name, lambda.body.*, lambda.params);
                        try visitExpr(self, lambda.body.*);
                    },
                    else => {
                        try measureStack(self, let_decl.name, let_decl.value.*, &.{});
                        try visitExpr(self, let_decl.value.*);
                    },
                }
            },
            .LetGroup => |group| {
                for (group.bindings) |binding| {
                    self.current_function = binding.name;
                    switch (binding.value.*) {
                        .Lambda => |lambda| {
                            try measureStack(self, binding.name, lambda.body.*, lambda.params);
                            try visitExpr(self, lambda.body.*);
                        },
                        else => {
                            try measureStack(self, binding.name, binding.value.*, &.{});
                            try visitExpr(self, binding.value.*);
                        },
                    }
                }
            },
        }
    }
}

/// Produces the rendered report text for the requested kinds.
///
/// Output is deterministic and uses LF line endings. The caller owns the
/// returned bytes.
pub fn run(allocator: std.mem.Allocator, module: ir.Module, kinds: Kinds) ReportError![]u8 {
    var analysis = Analysis.init(allocator, module);
    defer analysis.deinit();

    try runAnalysis(&analysis);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (kinds.cu) try renderCu(&out, allocator, &analysis);
    if (kinds.cu and kinds.stack) try appendStr(&out, allocator, "\n");
    if (kinds.stack) try renderStack(&out, allocator, &analysis);

    return out.toOwnedSlice(allocator);
}

fn appendStr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) ReportError!void {
    try out.appendSlice(allocator, s);
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ReportError!void {
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(rendered);
    try out.appendSlice(allocator, rendered);
}

fn renderCu(out: *std.ArrayList(u8), allocator: std.mem.Allocator, self: *Analysis) ReportError!void {
    try appendStr(out, allocator, "== Compute units (static estimate) ==\n");

    // Sort syscalls alphabetically before computing/printing.
    var syscall_list = std.ArrayList(SyscallTally).empty;
    defer syscall_list.deinit(allocator);
    var it = self.syscall_tallies.iterator();
    while (it.next()) |entry| {
        try syscall_list.append(allocator, entry.value_ptr.*);
    }
    std.mem.sort(SyscallTally, syscall_list.items, {}, lessThanSyscall);

    var total: u64 = 0;
    total += self.prim_count * cu_per_prim;
    total += self.branch_count * cu_per_branch;
    total += self.call_count * cu_per_call;
    for (syscall_list.items) |s| total += s.total_cu;
    total += self.extra_loop_cu;

    try appendFmt(out, allocator, "estimated cu budget: {d}\n", .{total});
    try appendStr(out, allocator, "breakdown:\n");
    try appendStr(out, allocator, "  - syscalls:\n");
    if (syscall_list.items.len == 0) {
        try appendStr(out, allocator, "      (none)\n");
    } else {
        for (syscall_list.items) |s| {
            try appendFmt(out, allocator, "      {s}: {d} call{s} \u{2248} {d} cu\n", .{
                s.name,
                s.calls,
                if (s.calls == 1) "" else "s",
                s.total_cu,
            });
        }
    }
    try appendFmt(out, allocator, "  - arithmetic ops: {d}  (\u{2248} {d} cu, free in BPF but counted for completeness)\n", .{ self.prim_count, self.prim_count * cu_per_prim });
    try appendFmt(out, allocator, "  - control flow: {d}\n", .{self.branch_count});
    try appendFmt(out, allocator, "  - function calls: {d} non-syscall\n", .{self.call_count});
    // Risks subsection (only when something to report).
    if (self.has_unbounded_loop or self.has_unknown_dynamic) {
        // Sort loops by name for deterministic output. Only risky loops
        // appear in the rendered list.
        const sorted = try allocator.alloc(LoopInfo, self.loops.items.len);
        defer allocator.free(sorted);
        @memcpy(sorted, self.loops.items);
        std.mem.sort(LoopInfo, sorted, {}, lessThanLoop);

        try appendStr(out, allocator, "risks:\n");
        for (sorted) |info| {
            switch (info.risk) {
                .None => {},
                .Unbounded => {
                    try appendFmt(
                        out,
                        allocator,
                        "  - has unbounded loop (bound > {d}): {s} in {s}\n",
                        .{ max_static_loop_bound, info.name, info.enclosing },
                    );
                },
                .UnknownDynamic => {
                    const tag = switch (info.kind) {
                        .For => "for",
                        .While => "while",
                    };
                    try appendFmt(
                        out,
                        allocator,
                        "  - has unknown dynamic loop: {s} ({s}) in {s}\n",
                        .{ info.name, tag, info.enclosing },
                    );
                },
            }
        }
    }

    try appendStr(out, allocator, "notes:\n");
    try appendStr(out, allocator, "  - This is a STATIC estimate based on the post-optimization Core IR. Real BPF compute units are determined at runtime by the SVM and may differ.\n");
    if (self.has_unbounded_loop) {
        try appendStr(out, allocator, "  - WARN: at least one loop has an unbounded back-edge; loop body cost is not multiplied.\n");
    }
    if (self.has_unknown_dynamic) {
        try appendStr(out, allocator, "  - WARN: at least one recursive call is dynamic and not statically bounded.\n");
    }
    try appendStr(out, allocator, "  - See https://docs.solana.com/developing/programming-model/runtime for the canonical cost table.\n");
}

fn lessThanLoop(_: void, a: LoopInfo, b: LoopInfo) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn renderStack(out: *std.ArrayList(u8), allocator: std.mem.Allocator, self: *Analysis) ReportError!void {
    try appendStr(out, allocator, "== Max function stack depth (static estimate) ==\n");

    // Find deepest first, then sort alphabetically for deterministic listing.
    if (self.stack_entries.items.len == 0) {
        try appendStr(out, allocator, "deepest function: (none) \u{2248} 0 bytes\n");
        try appendStr(out, allocator, "all functions:\n");
        try appendStr(out, allocator, "  (none)\n");
    } else {
        var deepest = self.stack_entries.items[0];
        for (self.stack_entries.items) |entry| {
            if (entry.bytes > deepest.bytes or (entry.bytes == deepest.bytes and std.mem.order(u8, entry.name, deepest.name) == .lt)) {
                deepest = entry;
            }
        }
        try appendFmt(out, allocator, "deepest function: {s} \u{2248} {d} bytes\n", .{ deepest.name, deepest.bytes });
        try appendStr(out, allocator, "all functions:\n");

        const sorted = try allocator.alloc(StackEntry, self.stack_entries.items.len);
        defer allocator.free(sorted);
        @memcpy(sorted, self.stack_entries.items);
        std.mem.sort(StackEntry, sorted, {}, lessThanStack);

        for (sorted) |entry| {
            try appendFmt(out, allocator, "  {s}: {d} bytes\n", .{ entry.name, entry.bytes });
            if (entry.bytes > 1024) {
                try appendFmt(out, allocator, "    WARN: large stack frame ({d} bytes > 1024)\n", .{entry.bytes});
            }
        }
    }
    try appendStr(out, allocator, "notes:\n");
    try appendStr(out, allocator, "  - BPF stack frame limit is 4096 bytes per call (SBPFv2 spec, subject to validator).\n");
    try appendStr(out, allocator, "  - This counts named locals + params at their Lowered IR layout; closure captures stored in arena are NOT counted here.\n");
    try appendStr(out, allocator, "  - Closures captured into the heap are not stack-relevant; this estimate covers true stack frames only.\n");
}

// -------------------- tests --------------------

const layout_mod = @import("layout.zig");

fn exprPtr(arena_allocator: std.mem.Allocator, expr: ir.Expr) !*const ir.Expr {
    const ptr = try arena_allocator.create(ir.Expr);
    ptr.* = expr;
    return ptr;
}

fn intExpr(arena_allocator: std.mem.Allocator, value: i64) !*const ir.Expr {
    return exprPtr(arena_allocator, .{ .Constant = .{
        .value = .{ .Int = value },
        .ty = .Int,
        .layout = layout_mod.intConstant(),
    } });
}

fn topLambda(arena_allocator: std.mem.Allocator, body: *const ir.Expr) !*const ir.Expr {
    const params = try arena_allocator.alloc(ir.Param, 1);
    params[0] = .{ .name = "_input", .ty = .Int };
    const ret_ty = try arena_allocator.create(ir.Ty);
    ret_ty.* = .Int;
    const param_tys = try arena_allocator.alloc(ir.Ty, 1);
    param_tys[0] = .Int;
    return exprPtr(arena_allocator, .{ .Lambda = .{
        .params = params,
        .body = body,
        .ty = .{ .Arrow = .{ .params = param_tys, .ret = ret_ty } },
        .layout = layout_mod.topLevelLambda(),
    } });
}

fn moduleWithDecls(arena_allocator: std.mem.Allocator, decls: []const ir.Decl) !ir.Module {
    const owned = try arena_allocator.alloc(ir.Decl, decls.len);
    @memcpy(owned, decls);
    return .{ .decls = owned };
}

test "parseKinds accepts cu, stack, all, csv" {
    try std.testing.expect((try parseKinds("cu")).cu);
    try std.testing.expect(!(try parseKinds("cu")).stack);
    try std.testing.expect((try parseKinds("stack")).stack);
    const both = try parseKinds("cu,stack");
    try std.testing.expect(both.cu and both.stack);
    const all = try parseKinds("all");
    try std.testing.expect(all.cu and all.stack);
    try std.testing.expectError(error.UnknownReportKind, parseKinds("bogus"));
    try std.testing.expectError(error.UnknownReportKind, parseKinds(""));
}

test "static_report emits minimal report for empty module" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    const module = try moduleWithDecls(arena_allocator, &.{});

    const rendered = try run(std.testing.allocator, module, .{ .cu = true, .stack = true });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "== Compute units") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "== Max function stack depth") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "(none)") != null);
}

test "static_report counts a syscall in the breakdown" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    const externals = try arena_allocator.alloc(ir.ExternalDecl, 1);
    const ext_ret_ty = try arena_allocator.create(ir.Ty);
    ext_ret_ty.* = .Unit;
    const ext_params = try arena_allocator.alloc(ir.Ty, 1);
    ext_params[0] = .String;
    externals[0] = .{
        .name = "log_message",
        .ty = .{ .Arrow = .{ .params = ext_params, .ret = ext_ret_ty } },
        .symbol = "sol_log_",
    };

    // body = log_message "hi"
    const log_callee = try exprPtr(arena_allocator, .{ .Var = .{
        .name = "log_message",
        .ty = .{ .Arrow = .{ .params = ext_params, .ret = ext_ret_ty } },
        .layout = layout_mod.topLevelLambda(),
    } });
    const str_arg = try exprPtr(arena_allocator, .{ .Constant = .{
        .value = .{ .String = "hi" },
        .ty = .String,
        .layout = layout_mod.defaultFor(.StringLiteral),
    } });
    const args = try arena_allocator.alloc(*const ir.Expr, 1);
    args[0] = str_arg;
    const body = try exprPtr(arena_allocator, .{ .App = .{
        .callee = log_callee,
        .args = args,
        .ty = .Unit,
        .layout = layout_mod.unitValue(),
    } });

    const decls = try arena_allocator.alloc(ir.Decl, 1);
    decls[0] = .{ .Let = .{
        .name = "entrypoint",
        .value = try topLambda(arena_allocator, body),
        .ty = .Int,
        .layout = layout_mod.topLevelLambda(),
    } };

    const module = ir.Module{
        .decls = decls,
        .externals = externals,
    };

    const rendered = try run(std.testing.allocator, module, .{ .cu = true });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "sol_log_") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "1 call") != null);
}

/// Helper: build a `Var` expression pointer.
fn varExpr(arena_allocator: std.mem.Allocator, name: []const u8, ty: ir.Ty) !*const ir.Expr {
    return exprPtr(arena_allocator, .{ .Var = .{
        .name = name,
        .ty = ty,
        .layout = layout_mod.intConstant(),
    } });
}

/// Helper: build a `Prim` expression pointer with two pre-built args.
fn primBin(arena_allocator: std.mem.Allocator, op: ir.PrimOp, lhs: *const ir.Expr, rhs: *const ir.Expr, result_ty: ir.Ty) !*const ir.Expr {
    const args = try arena_allocator.alloc(*const ir.Expr, 2);
    args[0] = lhs;
    args[1] = rhs;
    return exprPtr(arena_allocator, .{ .Prim = .{
        .op = op,
        .args = args,
        .ty = result_ty,
        .layout = layout_mod.intConstant(),
    } });
}

/// Helper: build a `__zxc_loop_<id>` lambda + the outer `let lo`/`let bound`/
/// `let-rec loop`/`App loop lo` desugar shape for a `for to` or `for downto`
/// loop. `lo_value` and `hi_value` are expression pointers (typically int
/// literals).
fn buildForLoopExpr(
    arena_allocator: std.mem.Allocator,
    id: []const u8, // e.g. "0"
    cmp_op: ir.PrimOp, // .Gt or .Lt
    step_op: ir.PrimOp, // .Add or .Sub
    lo_value: *const ir.Expr,
    hi_value: *const ir.Expr,
) !*const ir.Expr {
    const lo_name = try std.fmt.allocPrint(arena_allocator, "__zxc_loop_lo_{s}", .{id});
    const bound_name = try std.fmt.allocPrint(arena_allocator, "__zxc_loop_bound_{s}", .{id});
    const loop_name = try std.fmt.allocPrint(arena_allocator, "__zxc_loop_{s}", .{id});

    // loop body = if (i op_cmp bound) then 0 else self_call(i step_op 1)
    const i_var = try varExpr(arena_allocator, "i", .Int);
    const bound_var = try varExpr(arena_allocator, bound_name, .Int);
    const one_lit = try intExpr(arena_allocator, 1);
    const cond = try primBin(arena_allocator, cmp_op, i_var, bound_var, .Bool);

    const i_var2 = try varExpr(arena_allocator, "i", .Int);
    const step_expr = try primBin(arena_allocator, step_op, i_var2, one_lit, .Int);

    const loop_callee = try varExpr(arena_allocator, loop_name, .Int);
    const call_args = try arena_allocator.alloc(*const ir.Expr, 1);
    call_args[0] = step_expr;
    const recursive_call = try exprPtr(arena_allocator, .{ .App = .{
        .callee = loop_callee,
        .args = call_args,
        .ty = .Int,
        .layout = layout_mod.intConstant(),
        .is_tail_call = true,
    } });

    const zero_lit = try intExpr(arena_allocator, 0);
    const if_expr = try exprPtr(arena_allocator, .{ .If = .{
        .cond = cond,
        .then_branch = zero_lit,
        .else_branch = recursive_call,
        .ty = .Int,
        .layout = layout_mod.intConstant(),
    } });

    const params = try arena_allocator.alloc(ir.Param, 1);
    params[0] = .{ .name = "i", .ty = .Int };
    const param_tys = try arena_allocator.alloc(ir.Ty, 1);
    param_tys[0] = .Int;
    const ret_ty = try arena_allocator.create(ir.Ty);
    ret_ty.* = .Int;
    const lambda = try exprPtr(arena_allocator, .{ .Lambda = .{
        .params = params,
        .body = if_expr,
        .ty = .{ .Arrow = .{ .params = param_tys, .ret = ret_ty } },
        .layout = layout_mod.topLevelLambda(),
    } });

    // call site: App loop_name lo_name
    const loop_callee_outer = try varExpr(arena_allocator, loop_name, .Int);
    const lo_var = try varExpr(arena_allocator, lo_name, .Int);
    const outer_args = try arena_allocator.alloc(*const ir.Expr, 1);
    outer_args[0] = lo_var;
    const outer_app = try exprPtr(arena_allocator, .{ .App = .{
        .callee = loop_callee_outer,
        .args = outer_args,
        .ty = .Int,
        .layout = layout_mod.intConstant(),
    } });

    // let __zxc_loop_<n> = lambda in outer_app
    const let_loop = try exprPtr(arena_allocator, .{ .Let = .{
        .name = loop_name,
        .value = lambda,
        .body = outer_app,
        .ty = .Int,
        .layout = layout_mod.intConstant(),
        .is_rec = true,
    } });

    // let bound_name = hi in (let_loop)
    const let_bound = try exprPtr(arena_allocator, .{ .Let = .{
        .name = bound_name,
        .value = hi_value,
        .body = let_loop,
        .ty = .Int,
        .layout = layout_mod.intConstant(),
    } });

    // let lo_name = lo in (let_bound)
    const let_lo = try exprPtr(arena_allocator, .{ .Let = .{
        .name = lo_name,
        .value = lo_value,
        .body = let_bound,
        .ty = .Int,
        .layout = layout_mod.intConstant(),
    } });

    return let_lo;
}

/// Build a `while` desugar shape: `let rec __zxc_loop_<id> = lambda in
/// App loop_name 0` where `lambda` body is `if cond then self_call(counter+1)
/// else (counter + 0)`. `cond` is provided.
fn buildWhileLoopExpr(
    arena_allocator: std.mem.Allocator,
    id: []const u8,
    cond_value: *const ir.Expr,
) !*const ir.Expr {
    const loop_name = try std.fmt.allocPrint(arena_allocator, "__zxc_loop_{s}", .{id});
    const counter_name = try std.fmt.allocPrint(arena_allocator, "zxc_loop_counter_{s}", .{id});

    const counter_var = try varExpr(arena_allocator, counter_name, .Int);
    const one_lit = try intExpr(arena_allocator, 1);
    const step = try primBin(arena_allocator, .Add, counter_var, one_lit, .Int);

    const loop_callee = try varExpr(arena_allocator, loop_name, .Int);
    const call_args = try arena_allocator.alloc(*const ir.Expr, 1);
    call_args[0] = step;
    const recursive_call = try exprPtr(arena_allocator, .{ .App = .{
        .callee = loop_callee,
        .args = call_args,
        .ty = .Int,
        .layout = layout_mod.intConstant(),
        .is_tail_call = true,
    } });

    const counter_var2 = try varExpr(arena_allocator, counter_name, .Int);
    const zero_lit = try intExpr(arena_allocator, 0);
    const else_expr = try primBin(arena_allocator, .Add, counter_var2, zero_lit, .Int);

    const if_expr = try exprPtr(arena_allocator, .{ .If = .{
        .cond = cond_value,
        .then_branch = recursive_call,
        .else_branch = else_expr,
        .ty = .Int,
        .layout = layout_mod.intConstant(),
    } });

    const params = try arena_allocator.alloc(ir.Param, 1);
    params[0] = .{ .name = counter_name, .ty = .Int };
    const param_tys = try arena_allocator.alloc(ir.Ty, 1);
    param_tys[0] = .Int;
    const ret_ty = try arena_allocator.create(ir.Ty);
    ret_ty.* = .Int;
    const lambda = try exprPtr(arena_allocator, .{ .Lambda = .{
        .params = params,
        .body = if_expr,
        .ty = .{ .Arrow = .{ .params = param_tys, .ret = ret_ty } },
        .layout = layout_mod.topLevelLambda(),
    } });

    const loop_callee_outer = try varExpr(arena_allocator, loop_name, .Int);
    const zero_arg = try intExpr(arena_allocator, 0);
    const outer_args = try arena_allocator.alloc(*const ir.Expr, 1);
    outer_args[0] = zero_arg;
    const outer_app = try exprPtr(arena_allocator, .{ .App = .{
        .callee = loop_callee_outer,
        .args = outer_args,
        .ty = .Int,
        .layout = layout_mod.intConstant(),
    } });

    const let_loop = try exprPtr(arena_allocator, .{ .Let = .{
        .name = loop_name,
        .value = lambda,
        .body = outer_app,
        .ty = .Int,
        .layout = layout_mod.intConstant(),
        .is_rec = true,
    } });

    return let_loop;
}

fn moduleWithEntrypointBody(
    arena_allocator: std.mem.Allocator,
    body: *const ir.Expr,
) !ir.Module {
    const decls = try arena_allocator.alloc(ir.Decl, 1);
    decls[0] = .{ .Let = .{
        .name = "entrypoint",
        .value = try topLambda(arena_allocator, body),
        .ty = .Int,
        .layout = layout_mod.topLevelLambda(),
    } };
    return ir.Module{ .decls = decls };
}

test "static_report loop multiplier: bounded `for to`" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    const lo = try intExpr(arena_allocator, 1);
    const hi = try intExpr(arena_allocator, 5);
    const loop_expr = try buildForLoopExpr(arena_allocator, "0", .Gt, .Add, lo, hi);

    const module = try moduleWithEntrypointBody(arena_allocator, loop_expr);

    const rendered = try run(std.testing.allocator, module, .{ .cu = true });
    defer std.testing.allocator.free(rendered);

    // Body cost = 1 branch + 2 prims (cmp `>` + step `+`) = 3.
    // 5 iterations → 15 CU total.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "estimated cu budget: 15") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "risks:") == null);
}

test "static_report loop multiplier: bounded `for downto`" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    const lo = try intExpr(arena_allocator, 3);
    const hi = try intExpr(arena_allocator, 0);
    const loop_expr = try buildForLoopExpr(arena_allocator, "0", .Lt, .Sub, lo, hi);

    const module = try moduleWithEntrypointBody(arena_allocator, loop_expr);

    const rendered = try run(std.testing.allocator, module, .{ .cu = true });
    defer std.testing.allocator.free(rendered);

    // 4 iterations × 3 CU body = 12 CU.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "estimated cu budget: 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "risks:") == null);
}

test "static_report loop multiplier: bound > 256 flags unbounded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    const lo = try intExpr(arena_allocator, 0);
    const hi = try intExpr(arena_allocator, 1000);
    const loop_expr = try buildForLoopExpr(arena_allocator, "7", .Gt, .Add, lo, hi);

    const module = try moduleWithEntrypointBody(arena_allocator, loop_expr);

    const rendered = try run(std.testing.allocator, module, .{ .cu = true });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "has unbounded loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "__zxc_loop_7") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "in entrypoint") != null);
}

test "static_report loop multiplier: non-literal bound flags dynamic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    // Use a free variable reference (not a literal) for the `hi` bound.
    const lo = try intExpr(arena_allocator, 0);
    const hi = try varExpr(arena_allocator, "n", .Int);
    const loop_expr = try buildForLoopExpr(arena_allocator, "3", .Gt, .Add, lo, hi);

    const module = try moduleWithEntrypointBody(arena_allocator, loop_expr);

    const rendered = try run(std.testing.allocator, module, .{ .cu = true });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "has unknown dynamic loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "__zxc_loop_3") != null);
}

test "static_report loop multiplier: while flagged as unknown dynamic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    // `while false do () done`-style: cond is a Var that the analyzer can't
    // reason about statically.
    const cond = try varExpr(arena_allocator, "some_bool", .Bool);
    const loop_expr = try buildWhileLoopExpr(arena_allocator, "0", cond);

    const module = try moduleWithEntrypointBody(arena_allocator, loop_expr);

    const rendered = try run(std.testing.allocator, module, .{ .cu = true });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "has unknown dynamic loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "(while)") != null);
}

test "static_report stack section lists entrypoint with params" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    const body = try intExpr(arena_allocator, 0);
    const decls = try arena_allocator.alloc(ir.Decl, 1);
    decls[0] = .{ .Let = .{
        .name = "entrypoint",
        .value = try topLambda(arena_allocator, body),
        .ty = .Int,
        .layout = layout_mod.topLevelLambda(),
    } };

    const module = ir.Module{ .decls = decls };

    const rendered = try run(std.testing.allocator, module, .{ .stack = true });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "entrypoint:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "deepest function: entrypoint") != null);
}
