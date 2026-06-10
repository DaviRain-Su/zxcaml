//! Tree-walk interpreter for Core IR modules.
//!
//! RESPONSIBILITIES:
//! - Execute Core IR directly, without passing through Lowered IR.
//! - Provide the semantic oracle used by `omlz run` and future determinism tests.
//! - Return clear stub errors for Core IR nodes not yet implemented in M0.

const std = @import("std");
const api = @import("api.zig");
const ir = @import("../core/ir.zig");
const layout = @import("../core/layout.zig");

const division_by_zero_marker = "ZXCAML_PANIC:division_by_zero";
const assert_failure_marker = "ZXCAML_PANIC:assert_failure";
const array_oob_marker = "ZXCAML_PANIC:array_oob";

/// Stateless M0 interpreter backend.
pub const Interpreter = struct {
    const vtable: api.VTable = .{
        .evalModule = evalBackend,
        .emitModule = api.unsupportedEmitModule,
    };

    /// Returns this interpreter behind the backend extension-point trait.
    pub fn backend(self: *Interpreter) api.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

/// Errors produced by M0 interpreter stubs.
pub const EvalError = error{
    EntrypointNotFound,
    UnsupportedDecl,
    UnsupportedExpr,
    UnsupportedTopLevelValue,
    UnboundVariable,
    MatchFailure,
    ArityMismatch,
    DivisionByZero,
    AssertFailure,
    OutOfMemory,
    /// ADR-015 R9.1 read-only array out-of-bounds index. Maps to the
    /// `array_oob` panic marker on `error.ArrayOutOfBounds`.
    ArrayOutOfBounds,
};

const Value = union(enum) {
    Int: i64,
    Bool: bool,
    String: []const u8,
    Ctor: CtorValue,
    List: *const ListValue,
    Tuple: []const Value,
    Record: RecordValue,
    Lambda: ir.Lambda,
    Closure: *const ClosureValue,
    /// ADR-015 R9.1+R9.2 mutable array. R9.2 promotes the backing
    /// storage to a writable slice so `Array.set` / `a.(i) <- v` can
    /// mutate elements in place. Elements are boxed `Value`s so arrays
    /// of non-int payloads (e.g. `bytes array` PDA signer seeds built
    /// via `Array.of_list`) evaluate too; an OOB access returns the
    /// `array_oob` panic marker via `error.ArrayOutOfBounds`.
    Array: []Value,
    /// ADR-015 option C / R10 mutable ref cell. The cell is allocated on
    /// the per-evaluation arena and stores any supported element value
    /// (`int`, `bool`, `option int`, `option bool`).
    Ref: *RefCell,
};

const RefCell = struct {
    value: Value,
};

const CtorValue = struct {
    name: []const u8,
    args: []const Value,
};

const RecordValue = struct {
    fields: []const RecordValueField,
};

const RecordValueField = struct {
    name: []const u8,
    value: Value,
};

const ListValue = union(enum) {
    nil,
    cons: Cons,
};

const Cons = struct {
    head: Value,
    tail: *const ListValue,
};

const ClosureValue = struct {
    lambda: ir.Lambda,
    captures: []const CapturedValue,
    self_name: ?[]const u8 = null,
};

const CapturedValue = struct {
    name: []const u8,
    value: Value,
};

/// Evaluates a Core IR module by invoking its top-level `entrypoint` lambda.
pub fn evalModule(module: ir.Module) EvalError!u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = std.StringHashMap(Value).init(arena.allocator());
    defer env.deinit();

    var entrypoint: ?ir.Let = null;
    for (module.decls) |decl| {
        switch (decl) {
            .Let => |let_decl| {
                if (std.mem.eql(u8, let_decl.name, "entrypoint")) {
                    entrypoint = let_decl;
                    continue;
                }
                switch (let_decl.value.*) {
                    .Lambda => |lambda| {
                        const closure = try makeClosure(arena.allocator(), lambda, &env, if (let_decl.is_rec) let_decl.name else null);
                        try env.put(let_decl.name, .{ .Closure = closure });
                        continue;
                    },
                    else => {},
                }
                try env.put(let_decl.name, try evalTopLevelValue(arena.allocator(), let_decl.value.*, &env));
            },
            .LetGroup => |group| {
                for (group.bindings) |binding| {
                    const lambda = switch (binding.value.*) {
                        .Lambda => |lambda| lambda,
                        else => return error.UnsupportedTopLevelValue,
                    };
                    const closure = try makeClosure(arena.allocator(), lambda, &env, binding.name);
                    try env.put(binding.name, .{ .Closure = closure });
                }
            },
        }
    }

    const entry = entrypoint orelse return error.EntrypointNotFound;
    const lambda = switch (entry.value.*) {
        .Lambda => |value| value,
        else => return error.UnsupportedTopLevelValue,
    };
    return valueToU64(try evalExpr(arena.allocator(), lambda.body.*, &env));
}

/// Returns the user-facing diagnostic for an interpreter error.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EntrypointNotFound => "interpreter does not yet implement module without entrypoint",
        error.UnsupportedDecl => "interpreter does not yet implement declaration node",
        error.UnsupportedExpr => "interpreter does not yet implement expression node",
        error.UnsupportedTopLevelValue => "interpreter entrypoint must be a function",
        error.UnboundVariable => "interpreter found an unbound variable",
        error.MatchFailure => "interpreter pattern match was non-exhaustive",
        error.ArityMismatch => "interpreter function application arity mismatch",
        error.DivisionByZero => division_by_zero_marker,
        error.AssertFailure => assert_failure_marker,
        error.ArrayOutOfBounds => array_oob_marker,
        error.NotImplemented => "interpreter does not yet implement source emission",
        else => "interpreter failed",
    };
}

/// Returns a stable panic marker for errors that model user-program panics.
pub fn panicMarker(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.DivisionByZero => division_by_zero_marker,
        error.AssertFailure => assert_failure_marker,
        error.ArrayOutOfBounds => array_oob_marker,
        else => null,
    };
}

fn evalBackend(_: *anyopaque, module: ir.Module) anyerror!u64 {
    return evalModule(module);
}

fn evalTopLevelValue(allocator: std.mem.Allocator, expr: ir.Expr, env: *std.StringHashMap(Value)) EvalError!Value {
    return switch (expr) {
        .Constant, .Let, .LetGroup, .Assert, .Var, .Ctor, .Match, .Tuple, .TupleProj, .Record, .RecordField, .RecordUpdate, .AccountFieldSet, .ArrayLit, .ArrayGet, .ArrayLength, .ArraySet, .ArrayMake, .RefMake, .RefGet, .RefSet => evalExpr(allocator, expr, env),
        .App, .If, .Prim => evalExpr(allocator, expr, env),
        .Lambda => |lambda| .{ .Closure = try makeClosure(allocator, lambda, env, null) },
    };
}

fn evalExpr(allocator: std.mem.Allocator, expr: ir.Expr, env: *std.StringHashMap(Value)) EvalError!Value {
    return switch (expr) {
        .Constant => |constant| switch (constant.value) {
            .Int => |value| .{ .Int = value },
            .String => |value| .{ .String = value },
        },
        .Let => |let_expr| evalLet(allocator, let_expr, env),
        .LetGroup => |group| evalLetGroup(allocator, group, env),
        .Assert => |assert_expr| evalAssert(allocator, assert_expr, env),
        .Var => |var_ref| env.get(var_ref.name) orelse error.UnboundVariable,
        .App => |app| evalApp(allocator, app, env),
        .If => |if_expr| evalIf(allocator, if_expr, env),
        .Prim => |prim| evalPrim(allocator, prim, env),
        .Ctor => |ctor_expr| evalCtor(allocator, ctor_expr, env),
        .Match => |match_expr| evalMatch(allocator, match_expr, env),
        .Tuple => |tuple_expr| evalTuple(allocator, tuple_expr, env),
        .TupleProj => |tuple_proj| evalTupleProj(allocator, tuple_proj, env),
        .Record => |record_expr| evalRecord(allocator, record_expr, env),
        .RecordField => |record_field| evalRecordField(allocator, record_field, env),
        .RecordUpdate => |record_update| evalRecordUpdate(allocator, record_update, env),
        .AccountFieldSet => |field_set| evalAccountFieldSet(allocator, field_set, env),
        .Lambda => |lambda| .{ .Closure = try makeClosure(allocator, lambda, env, null) },
        .ArrayLit => |array_lit| evalArrayLit(allocator, array_lit, env),
        .ArrayGet => |array_get| evalArrayGet(allocator, array_get, env),
        .ArrayLength => |array_length| evalArrayLength(allocator, array_length, env),
        .ArraySet => |array_set| evalArraySet(allocator, array_set, env),
        .ArrayMake => |array_make| evalArrayMake(allocator, array_make, env),
        .RefMake => |ref_make| evalRefMake(allocator, ref_make, env),
        .RefGet => |ref_get| evalRefGet(allocator, ref_get, env),
        .RefSet => |ref_set| evalRefSet(allocator, ref_set, env),
    };
}

/// ADR-015 option C / R10 evaluate a `ref` allocation: alloc a cell on
/// the per-eval arena and store the initializer value.
fn evalRefMake(allocator: std.mem.Allocator, ref_make: ir.RefMake, env: *std.StringHashMap(Value)) EvalError!Value {
    const init_value = try evalExpr(allocator, ref_make.init.*, env);
    const cell = try allocator.create(RefCell);
    cell.* = .{ .value = init_value };
    return .{ .Ref = cell };
}

/// ADR-015 option C / R10 evaluate `!r`.
fn evalRefGet(allocator: std.mem.Allocator, ref_get: ir.RefGet, env: *std.StringHashMap(Value)) EvalError!Value {
    const target = try evalExpr(allocator, ref_get.target.*, env);
    return switch (target) {
        .Ref => |cell| cell.value,
        else => error.UnsupportedExpr,
    };
}

/// ADR-015 option C / R10 evaluate `r := v`; yields unit (encoded as Int 0).
fn evalRefSet(allocator: std.mem.Allocator, ref_set: ir.RefSet, env: *std.StringHashMap(Value)) EvalError!Value {
    const target = try evalExpr(allocator, ref_set.target.*, env);
    const value = try evalExpr(allocator, ref_set.value.*, env);
    switch (target) {
        .Ref => |cell| cell.value = value,
        else => return error.UnsupportedExpr,
    }
    return .{ .Int = 0 };
}

/// ADR-015 R9.1 interpreter evaluation of an array literal.
fn evalArrayLit(allocator: std.mem.Allocator, array_lit: ir.ArrayLit, env: *std.StringHashMap(Value)) EvalError!Value {
    const elems = try allocator.alloc(Value, array_lit.elems.len);
    for (array_lit.elems, 0..) |elem, index| {
        elems[index] = try evalExpr(allocator, elem.*, env);
    }
    return .{ .Array = elems };
}

/// ADR-015 R9.1 interpreter evaluation of `arr.(idx)`.
fn evalArrayGet(allocator: std.mem.Allocator, array_get: ir.ArrayGet, env: *std.StringHashMap(Value)) EvalError!Value {
    const arr_val = try evalExpr(allocator, array_get.arr.*, env);
    const elems = switch (arr_val) {
        .Array => |value| value,
        else => return error.UnsupportedExpr,
    };
    const idx = try intValue(try evalExpr(allocator, array_get.idx.*, env));
    if (idx < 0 or @as(usize, @intCast(idx)) >= elems.len) return error.ArrayOutOfBounds;
    return elems[@as(usize, @intCast(idx))];
}

/// ADR-015 R9.1 interpreter evaluation of `Array.length arr`.
fn evalArrayLength(allocator: std.mem.Allocator, array_length: ir.ArrayLength, env: *std.StringHashMap(Value)) EvalError!Value {
    const arr_val = try evalExpr(allocator, array_length.arr.*, env);
    const elems = switch (arr_val) {
        .Array => |value| value,
        else => return error.UnsupportedExpr,
    };
    return .{ .Int = @as(i64, @intCast(elems.len)) };
}

/// ADR-015 R9.2 interpreter evaluation of `a.(i) <- v` / `Array.set a i v`.
/// Mutates the backing storage of `Value.Array` in place; OOB indices map
/// to the `array_oob` panic marker via `error.ArrayOutOfBounds`. Returns
/// the unit constructor.
fn evalArraySet(allocator: std.mem.Allocator, array_set: ir.ArraySet, env: *std.StringHashMap(Value)) EvalError!Value {
    const arr_val = try evalExpr(allocator, array_set.arr.*, env);
    const elems = switch (arr_val) {
        .Array => |value| value,
        else => return error.UnsupportedExpr,
    };
    const idx = try intValue(try evalExpr(allocator, array_set.idx.*, env));
    if (idx < 0 or @as(usize, @intCast(idx)) >= elems.len) return error.ArrayOutOfBounds;
    const value = try evalExpr(allocator, array_set.value.*, env);
    elems[@as(usize, @intCast(idx))] = value;
    return .{ .Ctor = .{ .name = "()", .args = &.{} } };
}

/// ADR-015 R9.2 interpreter evaluation of `Array.make N init` (literal N).
/// Allocates a writable `[]Value` of length `size` filled with `init`.
fn evalArrayMake(allocator: std.mem.Allocator, array_make: ir.ArrayMake, env: *std.StringHashMap(Value)) EvalError!Value {
    const init_val = try evalExpr(allocator, array_make.init.*, env);
    const elems = try allocator.alloc(Value, @as(usize, array_make.size));
    for (elems) |*slot| slot.* = init_val;
    return .{ .Array = elems };
}

fn evalApp(allocator: std.mem.Allocator, app: ir.App, env: *std.StringHashMap(Value)) EvalError!Value {
    if (app.callee.* == .Var) {
        const callee = app.callee.Var;
        if (try evalStdlibApp(allocator, callee.name, app.args, env)) |value| return value;
    }
    const callee = try evalExpr(allocator, app.callee.*, env);
    const closure = switch (callee) {
        .Closure => |value| value,
        .Lambda => |value| try makeClosure(allocator, value, env, null),
        else => return error.UnsupportedExpr,
    };
    const lambda = closure.lambda;
    if (lambda.params.len != app.args.len) return error.ArityMismatch;

    var inserted = std.ArrayList(EnvBinding).empty;
    defer inserted.deinit(allocator);
    for (closure.captures) |capture| {
        const previous = env.get(capture.name);
        try env.put(capture.name, capture.value);
        try inserted.append(allocator, .{ .name = capture.name, .previous = previous });
    }
    if (closure.self_name) |self_name| {
        const previous = env.get(self_name);
        try env.put(self_name, .{ .Closure = closure });
        try inserted.append(allocator, .{ .name = self_name, .previous = previous });
    }
    for (lambda.params, app.args) |param, arg| {
        const value = try evalExpr(allocator, arg.*, env);
        const previous = env.get(param.name);
        try env.put(param.name, value);
        try inserted.append(allocator, .{ .name = param.name, .previous = previous });
    }
    defer restoreEnv(env, inserted.items);
    return evalExpr(allocator, lambda.body.*, env);
}

fn evalStdlibApp(
    allocator: std.mem.Allocator,
    name: []const u8,
    args: []const *const ir.Expr,
    env: *std.StringHashMap(Value),
) EvalError!?Value {
    if (std.mem.eql(u8, name, "String.length")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Int = @intCast((try stringValue(try evalExpr(allocator, args[0].*, env))).len) };
    }
    if (std.mem.eql(u8, name, "String.get")) {
        if (args.len != 2) return error.ArityMismatch;
        const value = try stringValue(try evalExpr(allocator, args[0].*, env));
        const index: usize = @intCast(try intValue(try evalExpr(allocator, args[1].*, env)));
        return .{ .Int = @intCast(value[index]) };
    }
    if (std.mem.eql(u8, name, "Bytes.get")) {
        if (args.len != 2) return error.ArityMismatch;
        const value = try stringValue(try evalExpr(allocator, args[0].*, env));
        const index: usize = @intCast(try intValue(try evalExpr(allocator, args[1].*, env)));
        return .{ .Int = @intCast(value[index]) };
    }
    if (std.mem.eql(u8, name, "String.sub")) {
        if (args.len != 3) return error.ArityMismatch;
        const value = try stringValue(try evalExpr(allocator, args[0].*, env));
        const start: usize = @intCast(try intValue(try evalExpr(allocator, args[1].*, env)));
        const len: usize = @intCast(try intValue(try evalExpr(allocator, args[2].*, env)));
        return .{ .String = value[start..][0..len] };
    }
    if (std.mem.eql(u8, name, "Bytes.of_string")) {
        if (args.len != 1) return error.ArityMismatch;
        return try evalExpr(allocator, args[0].*, env);
    }
    if (std.mem.eql(u8, name, "Bytes.length")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Int = @intCast((try stringValue(try evalExpr(allocator, args[0].*, env))).len) };
    }
    if (std.mem.eql(u8, name, "Bytes.sub")) {
        if (args.len != 3) return error.ArityMismatch;
        const value = try stringValue(try evalExpr(allocator, args[0].*, env));
        const start: usize = @intCast(try intValue(try evalExpr(allocator, args[1].*, env)));
        const len: usize = @intCast(try intValue(try evalExpr(allocator, args[2].*, env)));
        return .{ .String = value[start..][0..len] };
    }
    if (std.mem.eql(u8, name, "^")) {
        if (args.len != 2) return error.ArityMismatch;
        const left = try stringValue(try evalExpr(allocator, args[0].*, env));
        const right = try stringValue(try evalExpr(allocator, args[1].*, env));
        const out = try allocator.alloc(u8, left.len + right.len);
        @memcpy(out[0..left.len], left);
        @memcpy(out[left.len..], right);
        return .{ .String = out };
    }
    if (std.mem.eql(u8, name, "Char.code") or std.mem.eql(u8, name, "Char.chr")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Int = try intValue(try evalExpr(allocator, args[0].*, env)) };
    }

    if (std.mem.eql(u8, name, "List.length")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Int = try listLength(try evalListArg(allocator, args[0].*, env)) };
    }
    if (std.mem.eql(u8, name, "List.rev")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .List = try listRev(allocator, try evalListArg(allocator, args[0].*, env)) };
    }
    if (std.mem.eql(u8, name, "List.append")) {
        if (args.len != 2) return error.ArityMismatch;
        return .{ .List = try listAppend(allocator, try evalListArg(allocator, args[0].*, env), try evalListArg(allocator, args[1].*, env)) };
    }
    if (std.mem.eql(u8, name, "List.hd")) {
        if (args.len != 1) return error.ArityMismatch;
        const list = try evalListArg(allocator, args[0].*, env);
        return switch (list.*) {
            .cons => |cell| cell.head,
            .nil => error.MatchFailure,
        };
    }
    if (std.mem.eql(u8, name, "List.tl")) {
        if (args.len != 1) return error.ArityMismatch;
        const list = try evalListArg(allocator, args[0].*, env);
        return switch (list.*) {
            .cons => |cell| .{ .List = cell.tail },
            .nil => error.MatchFailure,
        };
    }
    if (std.mem.eql(u8, name, "Array.of_list")) {
        if (args.len != 1) return error.ArityMismatch;
        const list = try evalListArg(allocator, args[0].*, env);
        const length: usize = @intCast(try listLength(list));
        const elems = try allocator.alloc(Value, length);
        var current = list;
        var index: usize = 0;
        while (current.* == .cons) : (index += 1) {
            elems[index] = current.cons.head;
            current = current.cons.tail;
        }
        return .{ .Array = elems };
    }

    if (std.mem.eql(u8, name, "create_program_address") or std.mem.eql(u8, name, "Pda.create_program_address")) {
        // Deterministic off-chain stub mirroring `stdlib/core.ml`: evaluate
        // both arguments, ignore the seeds, and return the program id
        // unchanged. The real sha256-based derivation only runs on BPF.
        if (args.len != 2) return error.ArityMismatch;
        _ = try evalExpr(allocator, args[0].*, env);
        return try evalExpr(allocator, args[1].*, env);
    }
    if (std.mem.eql(u8, name, "try_find_program_address") or std.mem.eql(u8, name, "Pda.try_find_program_address")) {
        // Deterministic off-chain stub mirroring `stdlib/core.ml`: evaluate
        // both arguments, ignore the seeds, and return
        // `Some (program_id, 0)`. The real bump search only runs on BPF.
        if (args.len != 2) return error.ArityMismatch;
        _ = try evalExpr(allocator, args[0].*, env);
        const program_id = try evalExpr(allocator, args[1].*, env);
        const tuple_items = try allocator.alloc(Value, 2);
        tuple_items[0] = program_id;
        tuple_items[1] = .{ .Int = 0 };
        const some_args = try allocator.alloc(Value, 1);
        some_args[0] = .{ .Tuple = tuple_items };
        return .{ .Ctor = .{ .name = "Some", .args = some_args } };
    }

    if (std.mem.eql(u8, name, "Option.is_none")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Bool = ctorIs(try evalExpr(allocator, args[0].*, env), "None") };
    }
    if (std.mem.eql(u8, name, "Option.is_some")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Bool = ctorIs(try evalExpr(allocator, args[0].*, env), "Some") };
    }
    if (std.mem.eql(u8, name, "Option.value")) {
        if (args.len != 2) return error.ArityMismatch;
        const value = try evalExpr(allocator, args[0].*, env);
        return switch (value) {
            .Ctor => |ctor| if (std.mem.eql(u8, ctor.name, "Some") and ctor.args.len == 1)
                ctor.args[0]
            else if (std.mem.eql(u8, ctor.name, "None") and ctor.args.len == 0)
                try evalExpr(allocator, args[1].*, env)
            else
                error.UnsupportedExpr,
            else => error.UnsupportedExpr,
        };
    }
    if (std.mem.eql(u8, name, "Option.get")) {
        if (args.len != 1) return error.ArityMismatch;
        return try optionGet(try evalExpr(allocator, args[0].*, env));
    }

    if (std.mem.eql(u8, name, "Result.is_ok")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Bool = ctorIs(try evalExpr(allocator, args[0].*, env), "Ok") };
    }
    if (std.mem.eql(u8, name, "Result.is_error")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Bool = ctorIs(try evalExpr(allocator, args[0].*, env), "Error") };
    }
    if (std.mem.eql(u8, name, "Result.ok")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Ctor = try resultToOption(allocator, try evalExpr(allocator, args[0].*, env), "Ok") };
    }
    if (std.mem.eql(u8, name, "Result.error")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Ctor = try resultToOption(allocator, try evalExpr(allocator, args[0].*, env), "Error") };
    }

    if (std.mem.eql(u8, name, "Bytes.equal")) {
        if (args.len != 2) return error.ArityMismatch;
        const a = try stringValue(try evalExpr(allocator, args[0].*, env));
        const b = try stringValue(try evalExpr(allocator, args[1].*, env));
        return boolCtor(std.mem.eql(u8, a, b));
    }
    if (std.mem.eql(u8, name, "Bytes.compare")) {
        if (args.len != 2) return error.ArityMismatch;
        const a = try stringValue(try evalExpr(allocator, args[0].*, env));
        const b = try stringValue(try evalExpr(allocator, args[1].*, env));
        return .{ .Int = switch (std.mem.order(u8, a, b)) {
            .lt => @as(i64, -1),
            .eq => @as(i64, 0),
            .gt => @as(i64, 1),
        } };
    }
    if (std.mem.eql(u8, name, "not")) {
        if (args.len != 1) return error.ArityMismatch;
        const v = try boolValue(try evalExpr(allocator, args[0].*, env));
        return boolCtor(!v);
    }

    if (try evalAccountApp(allocator, name, args, env)) |value| return value;
    if (try evalFixedAmountApp(allocator, name, args, env)) |value| return value;

    if (std.mem.eql(u8, name, "Format.int_to_string")) {
        if (args.len != 1) return error.ArityMismatch;
        const n = try intValue(try evalExpr(allocator, args[0].*, env));
        const out = try std.fmt.allocPrint(allocator, "{d}", .{n});
        return .{ .String = out };
    }
    if (std.mem.eql(u8, name, "Format.hex_of_int")) {
        if (args.len != 2) return error.ArityMismatch;
        const width = try intValue(try evalExpr(allocator, args[0].*, env));
        const n = try intValue(try evalExpr(allocator, args[1].*, env));
        const u: u64 = @bitCast(n);
        var tmp: [32]u8 = undefined;
        const hex = std.fmt.bufPrint(&tmp, "{x}", .{u}) catch unreachable;
        const width_usize: usize = if (width < 0) 0 else @intCast(width);
        if (width_usize <= hex.len) {
            const out = try allocator.alloc(u8, hex.len);
            @memcpy(out, hex);
            return .{ .String = out };
        }
        const pad = width_usize - hex.len;
        const out = try allocator.alloc(u8, width_usize);
        @memset(out[0..pad], '0');
        @memcpy(out[pad..], hex);
        return .{ .String = out };
    }

    return null;
}

fn evalListArg(allocator: std.mem.Allocator, expr: ir.Expr, env: *std.StringHashMap(Value)) EvalError!*const ListValue {
    return switch (try evalExpr(allocator, expr, env)) {
        .List => |list| list,
        else => error.UnsupportedExpr,
    };
}

fn listLength(list: *const ListValue) EvalError!i64 {
    var len: i64 = 0;
    var current = list;
    while (true) {
        switch (current.*) {
            .nil => return len,
            .cons => |cell| {
                len += 1;
                current = cell.tail;
            },
        }
    }
}

fn listRev(allocator: std.mem.Allocator, list: *const ListValue) EvalError!*const ListValue {
    var current = list;
    var acc = try allocator.create(ListValue);
    acc.* = .nil;
    while (true) {
        switch (current.*) {
            .nil => return acc,
            .cons => |cell| {
                const next = try allocator.create(ListValue);
                next.* = .{ .cons = .{ .head = cell.head, .tail = acc } };
                acc = next;
                current = cell.tail;
            },
        }
    }
}

fn listAppend(allocator: std.mem.Allocator, left: *const ListValue, right: *const ListValue) EvalError!*const ListValue {
    var current = try listRev(allocator, left);
    var acc = right;
    while (true) {
        switch (current.*) {
            .nil => return acc,
            .cons => |cell| {
                const next = try allocator.create(ListValue);
                next.* = .{ .cons = .{ .head = cell.head, .tail = acc } };
                acc = next;
                current = cell.tail;
            },
        }
    }
}

fn ctorIs(value: Value, name: []const u8) bool {
    return switch (value) {
        .Ctor => |ctor| std.mem.eql(u8, ctor.name, name),
        else => false,
    };
}

fn optionGet(value: Value) EvalError!Value {
    return switch (value) {
        .Ctor => |ctor| if (std.mem.eql(u8, ctor.name, "Some") and ctor.args.len == 1)
            ctor.args[0]
        else
            error.MatchFailure,
        else => error.UnsupportedExpr,
    };
}

fn resultToOption(allocator: std.mem.Allocator, value: Value, wanted: []const u8) EvalError!CtorValue {
    const ctor = switch (value) {
        .Ctor => |result_ctor| result_ctor,
        else => return error.UnsupportedExpr,
    };
    if (std.mem.eql(u8, ctor.name, wanted)) {
        if (ctor.args.len != 1) return error.ArityMismatch;
        const args = try allocator.alloc(Value, 1);
        args[0] = ctor.args[0];
        return .{ .name = "Some", .args = args };
    }
    if (ctor.args.len != 1) return error.ArityMismatch;
    return .{ .name = "None", .args = &.{} };
}

fn makeClosure(
    allocator: std.mem.Allocator,
    lambda: ir.Lambda,
    env: *std.StringHashMap(Value),
    self_name: ?[]const u8,
) EvalError!*const ClosureValue {
    var captures = std.ArrayList(CapturedValue).empty;
    errdefer captures.deinit(allocator);

    var iterator = env.iterator();
    while (iterator.next()) |entry| {
        if (self_name) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) continue;
        }
        try captures.append(allocator, .{
            .name = entry.key_ptr.*,
            .value = entry.value_ptr.*,
        });
    }

    const closure = try allocator.create(ClosureValue);
    closure.* = .{
        .lambda = lambda,
        .captures = try captures.toOwnedSlice(allocator),
        .self_name = self_name,
    };
    return closure;
}

fn evalIf(allocator: std.mem.Allocator, if_expr: ir.IfExpr, env: *std.StringHashMap(Value)) EvalError!Value {
    const cond = try evalExpr(allocator, if_expr.cond.*, env);
    return if (try boolValue(cond))
        evalExpr(allocator, if_expr.then_branch.*, env)
    else
        evalExpr(allocator, if_expr.else_branch.*, env);
}

fn evalAssert(allocator: std.mem.Allocator, assert_expr: ir.AssertExpr, env: *std.StringHashMap(Value)) EvalError!Value {
    const cond = try evalExpr(allocator, assert_expr.condition.*, env);
    if (!try boolValue(cond)) return error.AssertFailure;
    return .{ .Ctor = .{ .name = "()", .args = &.{} } };
}

fn evalAccountApp(
    allocator: std.mem.Allocator,
    name: []const u8,
    args: []const *const ir.Expr,
    env: *std.StringHashMap(Value),
) EvalError!?Value {
    if (std.mem.eql(u8, name, "Account.key") or std.mem.eql(u8, name, "Account.owner") or std.mem.eql(u8, name, "Account.data")) {
        if (args.len != 1) return error.ArityMismatch;
        const record = try accountRecord(try evalExpr(allocator, args[0].*, env));
        const field_name = if (std.mem.eql(u8, name, "Account.key")) "key" else if (std.mem.eql(u8, name, "Account.owner")) "owner" else "data";
        return findRecordValue(record, field_name) orelse error.UnsupportedExpr;
    }
    if (std.mem.eql(u8, name, "Account.lamports")) {
        if (args.len != 1) return error.ArityMismatch;
        const record = try accountRecord(try evalExpr(allocator, args[0].*, env));
        return findRecordValue(record, "lamports") orelse error.UnsupportedExpr;
    }
    if (std.mem.eql(u8, name, "Account.data_len")) {
        if (args.len != 1) return error.ArityMismatch;
        const record = try accountRecord(try evalExpr(allocator, args[0].*, env));
        const data = try stringValue(findRecordValue(record, "data") orelse return error.UnsupportedExpr);
        return .{ .Int = @intCast(data.len) };
    }
    if (std.mem.eql(u8, name, "Account.is_signer") or std.mem.eql(u8, name, "Account.is_writable") or std.mem.eql(u8, name, "Account.is_executable")) {
        if (args.len != 1) return error.ArityMismatch;
        const record = try accountRecord(try evalExpr(allocator, args[0].*, env));
        const field_name = if (std.mem.eql(u8, name, "Account.is_signer")) "is_signer" else if (std.mem.eql(u8, name, "Account.is_writable")) "is_writable" else "executable";
        return findRecordValue(record, field_name) orelse error.UnsupportedExpr;
    }
    if (std.mem.eql(u8, name, "Account.has_key") or std.mem.eql(u8, name, "Account.is_owned_by")) {
        if (args.len != 2) return error.ArityMismatch;
        const record = try accountRecord(try evalExpr(allocator, args[0].*, env));
        const field_name = if (std.mem.eql(u8, name, "Account.has_key")) "key" else "owner";
        const actual = try stringValue(findRecordValue(record, field_name) orelse return error.UnsupportedExpr);
        const expected = try stringValue(try evalExpr(allocator, args[1].*, env));
        return boolCtor(std.mem.eql(u8, actual, expected));
    }
    return null;
}

fn evalFixedAmountApp(
    allocator: std.mem.Allocator,
    name: []const u8,
    args: []const *const ir.Expr,
    env: *std.StringHashMap(Value),
) EvalError!?Value {
    const scale: i64 = 1000000;
    const half_scale: i64 = scale / 2;

    if (std.mem.eql(u8, name, "Fixed.of_scaled") or std.mem.eql(u8, name, "Fixed.to_scaled")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Int = try intValue(try evalExpr(allocator, args[0].*, env)) };
    }
    if (std.mem.eql(u8, name, "Fixed.of_int")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Int = wrappingMul(try intValue(try evalExpr(allocator, args[0].*, env)), scale) };
    }
    if (std.mem.eql(u8, name, "Fixed.to_int_trunc")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Int = try truncatingDiv(try intValue(try evalExpr(allocator, args[0].*, env)), scale) };
    }
    if (std.mem.eql(u8, name, "Fixed.to_int_floor")) {
        if (args.len != 1) return error.ArityMismatch;
        const value = try intValue(try evalExpr(allocator, args[0].*, env));
        const quotient = try truncatingDiv(value, scale);
        const remainder = try truncatingMod(value, scale);
        return .{ .Int = if (value < 0 and remainder != 0) quotient - 1 else quotient };
    }
    if (std.mem.eql(u8, name, "Fixed.to_int_ceil")) {
        if (args.len != 1) return error.ArityMismatch;
        const value = try intValue(try evalExpr(allocator, args[0].*, env));
        const quotient = try truncatingDiv(value, scale);
        const remainder = try truncatingMod(value, scale);
        return .{ .Int = if (value > 0 and remainder != 0) quotient + 1 else quotient };
    }
    if (std.mem.eql(u8, name, "Fixed.to_int_round")) {
        if (args.len != 1) return error.ArityMismatch;
        const value = try intValue(try evalExpr(allocator, args[0].*, env));
        const adjusted = if (value >= 0) wrappingAdd(value, half_scale) else wrappingSub(value, half_scale);
        return .{ .Int = try truncatingDiv(adjusted, scale) };
    }
    if (std.mem.eql(u8, name, "Fixed.neg")) {
        if (args.len != 1) return error.ArityMismatch;
        return .{ .Int = wrappingSub(0, try intValue(try evalExpr(allocator, args[0].*, env))) };
    }
    if (std.mem.eql(u8, name, "Fixed.bps")) {
        if (args.len != 1) return error.ArityMismatch;
        const value = try intValue(try evalExpr(allocator, args[0].*, env));
        return .{ .Int = try truncatingDiv(wrappingMul(value, scale), 10000) };
    }

    if (args.len == 2) {
        const matches_binary_fixed =
            std.mem.eql(u8, name, "Fixed.add") or
            std.mem.eql(u8, name, "Fixed.sub") or
            std.mem.eql(u8, name, "Fixed.mul") or
            std.mem.eql(u8, name, "Fixed.div") or
            std.mem.eql(u8, name, "Fixed.mul_int") or
            std.mem.eql(u8, name, "Fixed.div_int") or
            std.mem.eql(u8, name, "Fixed.ratio") or
            std.mem.eql(u8, name, "Fixed.apply") or
            std.mem.eql(u8, name, "Fixed.compare") or
            std.mem.eql(u8, name, "Fixed.equal") or
            std.mem.eql(u8, name, "Fixed.min") or
            std.mem.eql(u8, name, "Fixed.max") or
            std.mem.eql(u8, name, "Amount.apply_rate") or
            std.mem.eql(u8, name, "Amount.fee_bps") or
            std.mem.eql(u8, name, "Amount.discount_bps") or
            std.mem.eql(u8, name, "Amount.premium_bps");
        if (!matches_binary_fixed) return null;

        const left = try intValue(try evalExpr(allocator, args[0].*, env));
        const right = try intValue(try evalExpr(allocator, args[1].*, env));
        if (std.mem.eql(u8, name, "Fixed.add")) return .{ .Int = wrappingAdd(left, right) };
        if (std.mem.eql(u8, name, "Fixed.sub")) return .{ .Int = wrappingSub(left, right) };
        if (std.mem.eql(u8, name, "Fixed.mul")) return .{ .Int = try truncatingDiv(wrappingMul(left, right), scale) };
        if (std.mem.eql(u8, name, "Fixed.div")) return .{ .Int = try truncatingDiv(wrappingMul(left, scale), right) };
        if (std.mem.eql(u8, name, "Fixed.mul_int")) return .{ .Int = wrappingMul(left, right) };
        if (std.mem.eql(u8, name, "Fixed.div_int")) return .{ .Int = try truncatingDiv(left, right) };
        if (std.mem.eql(u8, name, "Fixed.ratio")) return .{ .Int = try truncatingDiv(wrappingMul(left, scale), right) };
        if (std.mem.eql(u8, name, "Fixed.apply") or std.mem.eql(u8, name, "Amount.apply_rate")) return .{ .Int = try truncatingDiv(wrappingMul(left, right), scale) };
        if (std.mem.eql(u8, name, "Fixed.compare")) return .{ .Int = if (left < right) -1 else if (left > right) 1 else 0 };
        if (std.mem.eql(u8, name, "Fixed.equal")) return boolCtor(left == right);
        if (std.mem.eql(u8, name, "Fixed.min")) return .{ .Int = if (left <= right) left else right };
        if (std.mem.eql(u8, name, "Fixed.max")) return .{ .Int = if (left >= right) left else right };
        if (std.mem.eql(u8, name, "Amount.fee_bps")) return .{ .Int = try truncatingDiv(wrappingMul(left, right), 10000) };
        if (std.mem.eql(u8, name, "Amount.discount_bps")) return .{ .Int = wrappingSub(left, try truncatingDiv(wrappingMul(left, right), 10000)) };
        if (std.mem.eql(u8, name, "Amount.premium_bps")) return .{ .Int = wrappingAdd(left, try truncatingDiv(wrappingMul(left, right), 10000)) };
    }

    return null;
}

fn evalPrim(allocator: std.mem.Allocator, prim: ir.Prim, env: *std.StringHashMap(Value)) EvalError!Value {
    return switch (prim.op) {
        .StringLength => {
            if (prim.args.len != 1) return error.ArityMismatch;
            return .{ .Int = @intCast((try stringValue(try evalExpr(allocator, prim.args[0].*, env))).len) };
        },
        .StringGet => {
            if (prim.args.len != 2) return error.ArityMismatch;
            const value = try stringValue(try evalExpr(allocator, prim.args[0].*, env));
            const index: usize = @intCast(try intValue(try evalExpr(allocator, prim.args[1].*, env)));
            return .{ .Int = @intCast(value[index]) };
        },
        .StringSub => {
            if (prim.args.len != 3) return error.ArityMismatch;
            const value = try stringValue(try evalExpr(allocator, prim.args[0].*, env));
            const start: usize = @intCast(try intValue(try evalExpr(allocator, prim.args[1].*, env)));
            const len: usize = @intCast(try intValue(try evalExpr(allocator, prim.args[2].*, env)));
            return .{ .String = value[start..][0..len] };
        },
        .StringConcat => {
            if (prim.args.len != 2) return error.ArityMismatch;
            const left = try stringValue(try evalExpr(allocator, prim.args[0].*, env));
            const right = try stringValue(try evalExpr(allocator, prim.args[1].*, env));
            const out = try allocator.alloc(u8, left.len + right.len);
            @memcpy(out[0..left.len], left);
            @memcpy(out[left.len..], right);
            return .{ .String = out };
        },
        .CharCode, .CharChr => {
            if (prim.args.len != 1) return error.ArityMismatch;
            return .{ .Int = try intValue(try evalExpr(allocator, prim.args[0].*, env)) };
        },
        .BitNot => {
            if (prim.args.len != 1) return error.ArityMismatch;
            const v = try intValue(try evalExpr(allocator, prim.args[0].*, env));
            return .{ .Int = ~v };
        },
        .BytesCreate => {
            if (prim.args.len != 1) return error.ArityMismatch;
            const size: usize = @intCast(try intValue(try evalExpr(allocator, prim.args[0].*, env)));
            const buf = try allocator.alloc(u8, size);
            @memset(buf, 0);
            return .{ .String = buf };
        },
        .BytesSet => {
            if (prim.args.len != 3) return error.ArityMismatch;
            const data = try stringValue(try evalExpr(allocator, prim.args[0].*, env));
            const index: usize = @intCast(try intValue(try evalExpr(allocator, prim.args[1].*, env)));
            const value: u8 = @intCast(try intValue(try evalExpr(allocator, prim.args[2].*, env)));
            if (index < data.len) {
                // Bytes values may be mutable buffers from Bytes.create;
                // constCast is safe because we own the allocation.
                const mutable: []u8 = @constCast(data.ptr)[0..data.len];
                mutable[index] = value;
            }
            return .{ .Ctor = .{ .name = "()", .args = &.{} } };
        },
        .BytesBlit => {
            if (prim.args.len != 5) return error.ArityMismatch;
            const src = try stringValue(try evalExpr(allocator, prim.args[0].*, env));
            const src_off: usize = @intCast(try intValue(try evalExpr(allocator, prim.args[1].*, env)));
            const dst = try stringValue(try evalExpr(allocator, prim.args[2].*, env));
            const dst_off: usize = @intCast(try intValue(try evalExpr(allocator, prim.args[3].*, env)));
            const len: usize = @intCast(try intValue(try evalExpr(allocator, prim.args[4].*, env)));
            const dst_mut: []u8 = @constCast(dst.ptr)[0..dst.len];
            const src_mut: []const u8 = src;
            if (src_off + len <= src.len and dst_off + len <= dst.len) {
                @memcpy(dst_mut[dst_off .. dst_off + len], src_mut[src_off .. src_off + len]);
            }
            return .{ .Ctor = .{ .name = "()", .args = &.{} } };
        },
        .BytesFill => {
            if (prim.args.len != 4) return error.ArityMismatch;
            const dst = try stringValue(try evalExpr(allocator, prim.args[0].*, env));
            const off: usize = @intCast(try intValue(try evalExpr(allocator, prim.args[1].*, env)));
            const len: usize = @intCast(try intValue(try evalExpr(allocator, prim.args[2].*, env)));
            const value: u8 = @intCast(try intValue(try evalExpr(allocator, prim.args[3].*, env)));
            const dst_mut: []u8 = @constCast(dst.ptr)[0..dst.len];
            if (off + len <= dst.len) {
                @memset(dst_mut[off .. off + len], value);
            }
            return .{ .Ctor = .{ .name = "()", .args = &.{} } };
        },
        .Eq, .Ne => {
            if (prim.args.len != 2) return error.ArityMismatch;
            const lhs = try evalExpr(allocator, prim.args[0].*, env);
            const rhs = try evalExpr(allocator, prim.args[1].*, env);
            const equal = try valuesEqual(lhs, rhs);
            return boolCtor(if (prim.op == .Eq) equal else !equal);
        },
        else => {
            if (prim.args.len != 2) return error.ArityMismatch;
            const lhs_value = try evalExpr(allocator, prim.args[0].*, env);
            const rhs_value = try evalExpr(allocator, prim.args[1].*, env);
            const lhs = try intValue(lhs_value);
            const rhs = try intValue(rhs_value);
            return switch (prim.op) {
                .Add => .{ .Int = wrappingAdd(lhs, rhs) },
                .Sub => .{ .Int = wrappingSub(lhs, rhs) },
                .Mul => .{ .Int = wrappingMul(lhs, rhs) },
                .Div => .{ .Int = try truncatingDiv(lhs, rhs) },
                .Mod => .{ .Int = try truncatingMod(lhs, rhs) },
                .BitAnd => .{ .Int = lhs & rhs },
                .BitOr => .{ .Int = lhs | rhs },
                .BitXor => .{ .Int = lhs ^ rhs },
                .ShiftLeft => .{ .Int = wrappingShl(lhs, rhs) },
                .ShiftRight => .{ .Int = wrappingShr(lhs, rhs) },
                .Lt => boolCtor(lhs < rhs),
                .Le => boolCtor(lhs <= rhs),
                .Gt => boolCtor(lhs > rhs),
                .Ge => boolCtor(lhs >= rhs),
                .Eq, .Ne => unreachable,
                .StringLength, .StringGet, .StringSub, .StringConcat, .CharCode, .CharChr, .BitNot, .BytesCreate, .BytesSet, .BytesBlit, .BytesFill => unreachable,
            };
        },
    };
}

fn valuesEqual(lhs: Value, rhs: Value) EvalError!bool {
    // Equality that mirrors the OCaml semantics across the small subset the
    // interpreter currently handles: integers, booleans (native or `true`/
    // `false` constructors), strings, and constructor values that compare
    // structurally. Any unsupported shape surfaces the same UnsupportedExpr
    // error used elsewhere in the evaluator.
    switch (lhs) {
        .Int => |l| return switch (rhs) {
            .Int => |r| l == r,
            else => error.UnsupportedExpr,
        },
        .String => |l| return switch (rhs) {
            .String => |r| std.mem.eql(u8, l, r),
            else => error.UnsupportedExpr,
        },
        .Bool, .Ctor => {
            // Treat bools and "true"/"false" constructors as a single domain.
            const lhs_is_bool = (lhs == .Bool) or (lhs == .Ctor and (std.mem.eql(u8, lhs.Ctor.name, "true") or std.mem.eql(u8, lhs.Ctor.name, "false")));
            const rhs_is_bool = (rhs == .Bool) or (rhs == .Ctor and (std.mem.eql(u8, rhs.Ctor.name, "true") or std.mem.eql(u8, rhs.Ctor.name, "false")));
            if (lhs_is_bool and rhs_is_bool) {
                return (try boolValue(lhs)) == (try boolValue(rhs));
            }
            if (lhs == .Ctor and rhs == .Ctor) {
                if (!std.mem.eql(u8, lhs.Ctor.name, rhs.Ctor.name)) return false;
                if (lhs.Ctor.args.len != rhs.Ctor.args.len) return false;
                for (lhs.Ctor.args, rhs.Ctor.args) |la, ra| {
                    if (!try valuesEqual(la, ra)) return false;
                }
                return true;
            }
            return error.UnsupportedExpr;
        },
        else => return error.UnsupportedExpr,
    }
}

fn boolCtor(value: bool) Value {
    return .{ .Ctor = .{ .name = if (value) "true" else "false", .args = &.{} } };
}

fn boolValue(value: Value) EvalError!bool {
    return switch (value) {
        .Bool => |native| native,
        .Ctor => |ctor| {
            if (ctor.args.len == 0 and std.mem.eql(u8, ctor.name, "true")) return true;
            if (ctor.args.len == 0 and std.mem.eql(u8, ctor.name, "false")) return false;
            return error.UnsupportedExpr;
        },
        else => error.UnsupportedExpr,
    };
}

fn wrappingAdd(lhs: i64, rhs: i64) i64 {
    const result = @addWithOverflow(lhs, rhs);
    return result[0];
}

fn wrappingSub(lhs: i64, rhs: i64) i64 {
    const result = @subWithOverflow(lhs, rhs);
    return result[0];
}

fn wrappingMul(lhs: i64, rhs: i64) i64 {
    const result = @mulWithOverflow(lhs, rhs);
    return result[0];
}

fn truncatingDiv(lhs: i64, rhs: i64) EvalError!i64 {
    if (rhs == 0) return error.DivisionByZero;
    if (lhs == std.math.minInt(i64) and rhs == -1) return std.math.minInt(i64);
    return @divTrunc(lhs, rhs);
}

fn truncatingMod(lhs: i64, rhs: i64) EvalError!i64 {
    if (rhs == 0) return error.DivisionByZero;
    if (lhs == std.math.minInt(i64) and rhs == -1) return 0;
    return @rem(lhs, rhs);
}

fn wrappingShl(lhs: i64, rhs: i64) i64 {
    if (rhs < 0 or rhs >= 64) return 0;
    return lhs << @intCast(rhs);
}

fn wrappingShr(lhs: i64, rhs: i64) i64 {
    if (rhs < 0 or rhs >= 64) return 0;
    return @bitCast(@as(u64, @bitCast(lhs)) >> @intCast(rhs));
}

fn intValue(value: Value) EvalError!i64 {
    return switch (value) {
        .Int => |int| int,
        else => error.UnsupportedExpr,
    };
}

fn stringValue(value: Value) EvalError![]const u8 {
    return switch (value) {
        .String => |string| string,
        else => error.UnsupportedExpr,
    };
}

fn evalMatch(allocator: std.mem.Allocator, match_expr: ir.Match, env: *std.StringHashMap(Value)) EvalError!Value {
    const scrutinee = try evalExpr(allocator, match_expr.scrutinee.*, env);
    for (match_expr.arms) |arm| {
        var inserted = std.ArrayList(EnvBinding).empty;
        defer inserted.deinit(allocator);

        if (try patternMatches(allocator, arm.pattern, scrutinee, env, &inserted)) {
            defer restoreEnv(env, inserted.items);
            if (arm.guard) |guard_expr| {
                const guard_value = try evalExpr(allocator, guard_expr.*, env);
                if (!try boolValue(guard_value)) continue;
            }
            return evalExpr(allocator, arm.body.*, env);
        }
        restoreEnv(env, inserted.items);
    }
    return error.MatchFailure;
}

fn evalCtor(allocator: std.mem.Allocator, ctor_expr: ir.Ctor, env: *std.StringHashMap(Value)) EvalError!Value {
    if (std.mem.eql(u8, ctor_expr.name, "[]")) {
        if (ctor_expr.args.len != 0) return error.ArityMismatch;
        const list = try allocator.create(ListValue);
        list.* = .nil;
        return .{ .List = list };
    }
    if (std.mem.eql(u8, ctor_expr.name, "::")) {
        if (ctor_expr.args.len != 2) return error.ArityMismatch;
        const head = try evalExpr(allocator, ctor_expr.args[0].*, env);
        const tail = switch (try evalExpr(allocator, ctor_expr.args[1].*, env)) {
            .List => |list| list,
            else => return error.UnsupportedExpr,
        };
        const list = try allocator.create(ListValue);
        list.* = .{ .cons = .{ .head = head, .tail = tail } };
        return .{ .List = list };
    }

    const args = try allocator.alloc(Value, ctor_expr.args.len);
    for (ctor_expr.args, 0..) |arg, index| {
        args[index] = try evalExpr(allocator, arg.*, env);
    }
    return .{ .Ctor = .{
        .name = ctor_expr.name,
        .args = args,
    } };
}

fn evalTuple(allocator: std.mem.Allocator, tuple_expr: ir.Tuple, env: *std.StringHashMap(Value)) EvalError!Value {
    const items = try allocator.alloc(Value, tuple_expr.items.len);
    for (tuple_expr.items, 0..) |item, index| {
        items[index] = try evalExpr(allocator, item.*, env);
    }
    return .{ .Tuple = items };
}

fn evalTupleProj(allocator: std.mem.Allocator, tuple_proj: ir.TupleProj, env: *std.StringHashMap(Value)) EvalError!Value {
    const tuple = switch (try evalExpr(allocator, tuple_proj.tuple_expr.*, env)) {
        .Tuple => |items| items,
        else => return error.UnsupportedExpr,
    };
    if (tuple_proj.index >= tuple.len) return error.UnsupportedExpr;
    return tuple[tuple_proj.index];
}

fn evalRecord(allocator: std.mem.Allocator, record_expr: ir.Record, env: *std.StringHashMap(Value)) EvalError!Value {
    const fields = try allocator.alloc(RecordValueField, record_expr.fields.len);
    for (record_expr.fields, 0..) |field, index| {
        fields[index] = .{
            .name = field.name,
            .value = try evalExpr(allocator, field.value.*, env),
        };
    }
    return .{ .Record = .{ .fields = fields } };
}

fn evalRecordField(allocator: std.mem.Allocator, record_field: ir.RecordField, env: *std.StringHashMap(Value)) EvalError!Value {
    const record = switch (try evalExpr(allocator, record_field.record_expr.*, env)) {
        .Record => |value| value,
        else => return error.UnsupportedExpr,
    };
    return findRecordValue(record, record_field.field_name) orelse error.UnsupportedExpr;
}

fn evalRecordUpdate(allocator: std.mem.Allocator, record_update: ir.RecordUpdate, env: *std.StringHashMap(Value)) EvalError!Value {
    const base = switch (try evalExpr(allocator, record_update.base_expr.*, env)) {
        .Record => |value| value,
        else => return error.UnsupportedExpr,
    };
    const fields = try allocator.alloc(RecordValueField, base.fields.len);
    for (base.fields, 0..) |base_field, index| {
        var value = base_field.value;
        for (record_update.fields) |update_field| {
            if (std.mem.eql(u8, update_field.name, base_field.name)) {
                value = try evalExpr(allocator, update_field.value.*, env);
                break;
            }
        }
        fields[index] = .{ .name = base_field.name, .value = value };
    }
    return .{ .Record = .{ .fields = fields } };
}

fn evalAccountFieldSet(allocator: std.mem.Allocator, field_set: ir.AccountFieldSet, env: *std.StringHashMap(Value)) EvalError!Value {
    _ = try evalExpr(allocator, field_set.account_expr.*, env);
    _ = try evalExpr(allocator, field_set.value.*, env);
    return .{ .Ctor = .{ .name = "()", .args = &.{} } };
}

fn accountRecord(value: Value) EvalError!RecordValue {
    return switch (value) {
        .Record => |record| record,
        else => error.UnsupportedExpr,
    };
}

fn findRecordValue(record: RecordValue, field_name: []const u8) ?Value {
    for (record.fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) return field.value;
    }
    return null;
}

fn evalLetGroup(allocator: std.mem.Allocator, group: ir.LetGroupExpr, env: *std.StringHashMap(Value)) EvalError!Value {
    var inserted = std.ArrayList(EnvBinding).empty;
    defer inserted.deinit(allocator);

    for (group.bindings) |binding| {
        const value = switch (binding.value.*) {
            .Lambda => |lambda| Value{ .Closure = try makeClosure(allocator, lambda, env, binding.name) },
            else => try evalExpr(allocator, binding.value.*, env),
        };
        const previous = env.get(binding.name);
        try env.put(binding.name, value);
        try inserted.append(allocator, .{ .name = binding.name, .previous = previous });
    }
    defer restoreEnv(env, inserted.items);
    return evalExpr(allocator, group.body.*, env);
}

fn evalLet(allocator: std.mem.Allocator, let_expr: ir.LetExpr, env: *std.StringHashMap(Value)) EvalError!Value {
    const value = switch (let_expr.value.*) {
        .Lambda => |lambda| Value{ .Closure = try makeClosure(allocator, lambda, env, if (let_expr.is_rec) let_expr.name else null) },
        else => try evalExpr(allocator, let_expr.value.*, env),
    };
    const previous = env.get(let_expr.name);
    switch (exprLayout(let_expr.value.*).region) {
        .Stack, .Static, .Arena => try env.put(let_expr.name, value),
    }
    defer {
        if (previous) |binding| {
            env.getPtr(let_expr.name).?.* = binding;
        } else {
            _ = env.remove(let_expr.name);
        }
    }
    return evalExpr(allocator, let_expr.body.*, env);
}

fn exprLayout(expr: ir.Expr) layout.Layout {
    return switch (expr) {
        .Lambda => |lambda| lambda.layout,
        .Constant => |constant| constant.layout,
        .App => |app| app.layout,
        .Let => |let_expr| let_expr.layout,
        .LetGroup => |group| group.layout,
        .Assert => |assert_expr| assert_expr.layout,
        .If => |if_expr| if_expr.layout,
        .Prim => |prim| prim.layout,
        .Var => |var_ref| var_ref.layout,
        .Ctor => |ctor_expr| ctor_expr.layout,
        .Match => |match_expr| match_expr.layout,
        .Tuple => |tuple_expr| tuple_expr.layout,
        .TupleProj => |tuple_proj| tuple_proj.layout,
        .Record => |record_expr| record_expr.layout,
        .RecordField => |record_field| record_field.layout,
        .RecordUpdate => |record_update| record_update.layout,
        .AccountFieldSet => |field_set| field_set.layout,
        .ArrayLit => |array_lit| array_lit.layout,
        .ArrayGet => |array_get| array_get.layout,
        .ArrayLength => |array_length| array_length.layout,
        .ArraySet => |array_set| array_set.layout,
        .ArrayMake => |array_make| array_make.layout,
        .RefMake => |ref_make| ref_make.layout,
        .RefGet => |ref_get| ref_get.layout,
        .RefSet => |ref_set| ref_set.layout,
    };
}

const EnvBinding = struct {
    name: []const u8,
    previous: ?Value,
};

fn patternMatches(
    allocator: std.mem.Allocator,
    pattern: ir.Pattern,
    value: Value,
    env: *std.StringHashMap(Value),
    inserted: *std.ArrayList(EnvBinding),
) EvalError!bool {
    return switch (pattern) {
        .Wildcard => true,
        .Constant => |constant| constantPatternMatches(constant, value),
        .Alias => |alias| blk: {
            if (!try patternMatches(allocator, alias.pattern.*, value, env, inserted)) break :blk false;
            if (std.mem.eql(u8, alias.name, "_")) break :blk true;
            const previous = env.get(alias.name);
            try env.put(alias.name, value);
            try inserted.append(allocator, .{ .name = alias.name, .previous = previous });
            break :blk true;
        },
        .Var => |var_pattern| blk: {
            if (std.mem.eql(u8, var_pattern.name, "_")) break :blk true;
            const previous = env.get(var_pattern.name);
            try env.put(var_pattern.name, value);
            try inserted.append(allocator, .{ .name = var_pattern.name, .previous = previous });
            break :blk true;
        },
        .Ctor => |ctor_pattern| blk: {
            if (try listPatternMatches(allocator, ctor_pattern, value, env, inserted)) |matched| {
                break :blk matched;
            }
            const ctor_value = switch (value) {
                .Ctor => |ctor| ctor,
                else => break :blk false,
            };
            if (!std.mem.eql(u8, ctor_pattern.name, ctor_value.name)) break :blk false;
            if (ctor_pattern.args.len != ctor_value.args.len) break :blk false;
            for (ctor_pattern.args, ctor_value.args) |arg_pattern, arg_value| {
                if (!try patternMatches(allocator, arg_pattern, arg_value, env, inserted)) break :blk false;
            }
            break :blk true;
        },
        .Tuple => |items| blk: {
            const tuple = switch (value) {
                .Tuple => |tuple_items| tuple_items,
                else => break :blk false,
            };
            if (items.len != tuple.len) break :blk false;
            for (items, tuple) |item_pattern, item_value| {
                if (!try patternMatches(allocator, item_pattern, item_value, env, inserted)) break :blk false;
            }
            break :blk true;
        },
        .Record => |fields| blk: {
            const record = switch (value) {
                .Record => |record_value| record_value,
                else => break :blk false,
            };
            for (fields) |field| {
                const field_value = findRecordValue(record, field.name) orelse break :blk false;
                if (!try patternMatches(allocator, field.pattern, field_value, env, inserted)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn constantPatternMatches(pattern: ir.PatternConstant, value: Value) bool {
    return switch (pattern) {
        .Int => |expected| switch (value) {
            .Int => |actual| actual == expected,
            else => false,
        },
        .Char => |expected| switch (value) {
            .Int => |actual| actual == expected,
            else => false,
        },
        .String => |expected| switch (value) {
            .String => |actual| std.mem.eql(u8, actual, expected),
            else => false,
        },
    };
}

fn listPatternMatches(
    allocator: std.mem.Allocator,
    ctor_pattern: ir.PatternCtor,
    value: Value,
    env: *std.StringHashMap(Value),
    inserted: *std.ArrayList(EnvBinding),
) EvalError!?bool {
    if (!std.mem.eql(u8, ctor_pattern.name, "[]") and !std.mem.eql(u8, ctor_pattern.name, "::")) return null;
    const list = switch (value) {
        .List => |list_value| list_value,
        else => return false,
    };
    switch (list.*) {
        .nil => {
            if (!std.mem.eql(u8, ctor_pattern.name, "[]")) return false;
            return ctor_pattern.args.len == 0;
        },
        .cons => |cell| {
            if (!std.mem.eql(u8, ctor_pattern.name, "::") or ctor_pattern.args.len != 2) return false;
            if (!try patternMatches(allocator, ctor_pattern.args[0], cell.head, env, inserted)) return false;
            if (!try patternMatches(allocator, ctor_pattern.args[1], .{ .List = cell.tail }, env, inserted)) return false;
            return true;
        },
    }
}

fn restoreEnv(env: *std.StringHashMap(Value), inserted: []const EnvBinding) void {
    var index = inserted.len;
    while (index > 0) {
        index -= 1;
        const binding = inserted[index];
        if (binding.previous) |previous| {
            env.getPtr(binding.name).?.* = previous;
        } else {
            _ = env.remove(binding.name);
        }
    }
}

fn valueToU64(value: Value) EvalError!u64 {
    return switch (value) {
        // Match the Solana BPF entrypoint contract: signed i64 results are
        // reinterpreted via their bit pattern into u64, so a negative integer
        // such as -1 surfaces to the loader as 0xFFFF_FFFF_FFFF_FFFF.
        .Int => |int| @as(u64, @bitCast(int)),
        .Bool, .String, .Ctor, .List, .Tuple, .Record, .Lambda, .Closure, .Array, .Ref => error.UnsupportedExpr,
    };
}

fn makeExpr(comptime expr: ir.Expr) *const ir.Expr {
    const S = struct {
        const value = expr;
    };
    return &S.value;
}

fn makeTy(comptime ty: ir.Ty) *const ir.Ty {
    const S = struct {
        const value = ty;
    };
    return &S.value;
}

fn testLet(comptime name: []const u8, comptime value: i64) ir.Decl {
    return .{ .Let = .{
        .name = name,
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Constant = .{
                .value = .{ .Int = value },
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
}

test "interpreter evaluates M0 integer constants directly from Core IR" {
    const zero_decls = [_]ir.Decl{testLet("entrypoint", 0)};
    const answer_decls = [_]ir.Decl{testLet("entrypoint", 42)};

    try std.testing.expectEqual(@as(u64, 0), try evalModule(.{ .decls = &zero_decls }));
    try std.testing.expectEqual(@as(u64, 42), try evalModule(.{ .decls = &answer_decls }));
}

test "interpreter pins i64 arithmetic wrap edge cases" {
    try std.testing.expectEqual(std.math.minInt(i64), wrappingAdd(std.math.maxInt(i64), 1));
    try std.testing.expectEqual(std.math.maxInt(i64), wrappingSub(std.math.minInt(i64), 1));
    try std.testing.expectEqual(std.math.minInt(i64), wrappingMul(std.math.minInt(i64), -1));
    try std.testing.expectEqual(std.math.minInt(i64), try truncatingDiv(std.math.minInt(i64), -1));
    try std.testing.expectEqual(@as(i64, 0), try truncatingMod(std.math.minInt(i64), -1));
    try std.testing.expectError(error.DivisionByZero, truncatingDiv(0, 0));
    try std.testing.expectError(error.DivisionByZero, truncatingMod(0, 0));
    try std.testing.expectEqualStrings(division_by_zero_marker, panicMarker(error.DivisionByZero).?);
}

test "interpreter comparisons produce bool constructors consumed by if" {
    var env = std.StringHashMap(Value).init(std.testing.allocator);
    defer env.deinit();

    const cmp_true = try evalPrim(std.testing.allocator, .{
        .op = .Le,
        .args = &.{
            makeExpr(.{ .Constant = .{ .value = .{ .Int = 1 }, .ty = .Int, .layout = layout.intConstant() } }),
            makeExpr(.{ .Constant = .{ .value = .{ .Int = 2 }, .ty = .Int, .layout = layout.intConstant() } }),
        },
        .ty = .Bool,
        .layout = layout.intConstant(),
    }, &env);
    switch (cmp_true) {
        .Ctor => |ctor| try std.testing.expectEqualStrings("true", ctor.name),
        else => return error.TestUnexpectedResult,
    }

    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .If = .{
                .cond = makeExpr(.{ .Prim = .{
                    .op = .Gt,
                    .args = &.{
                        makeExpr(.{ .Constant = .{ .value = .{ .Int = 3 }, .ty = .Int, .layout = layout.intConstant() } }),
                        makeExpr(.{ .Constant = .{ .value = .{ .Int = 5 }, .ty = .Int, .layout = layout.intConstant() } }),
                    },
                    .ty = .Bool,
                    .layout = layout.intConstant(),
                } }),
                .then_branch = makeExpr(.{ .Constant = .{ .value = .{ .Int = 9 }, .ty = .Int, .layout = layout.intConstant() } }),
                .else_branch = makeExpr(.{ .Constant = .{ .value = .{ .Int = 4 }, .ty = .Int, .layout = layout.intConstant() } }),
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{entrypoint_decl};

    try std.testing.expectEqual(@as(u64, 4), try evalModule(.{ .decls = &decls }));
}

test "interpreter evaluates top-level and nested let variable bindings" {
    const x_decl: ir.Decl = .{ .Let = .{
        .name = "x",
        .value = makeExpr(.{ .Constant = .{
            .value = .{ .Int = 1 },
            .ty = .Int,
            .layout = layout.intConstant(),
        } }),
        .ty = .Int,
        .layout = layout.intConstant(),
    } };
    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Let = .{
                .name = "y",
                .value = makeExpr(.{ .Constant = .{
                    .value = .{ .Int = 7 },
                    .ty = .Int,
                    .layout = layout.intConstant(),
                } }),
                .body = makeExpr(.{ .Var = .{
                    .name = "x",
                    .ty = .Int,
                    .layout = layout.intConstant(),
                } }),
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{ x_decl, entrypoint_decl };

    try std.testing.expectEqual(@as(u64, 1), try evalModule(.{ .decls = &decls }));
}

test "interpreter constructs option constructor values inside lets" {
    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Let = .{
                .name = "_",
                .value = makeExpr(.{ .Ctor = .{
                    .name = "Some",
                    .args = &.{makeExpr(.{ .Constant = .{
                        .value = .{ .Int = 1 },
                        .ty = .Int,
                        .layout = layout.intConstant(),
                    } })},
                    .ty = .{ .Adt = .{ .name = "option", .params = &.{.Int} } },
                    .layout = layout.ctor(1),
                } }),
                .body = makeExpr(.{ .Constant = .{
                    .value = .{ .Int = 0 },
                    .ty = .Int,
                    .layout = layout.intConstant(),
                } }),
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{entrypoint_decl};

    try std.testing.expectEqual(@as(u64, 0), try evalModule(.{ .decls = &decls }));
}

test "interpreter can materialize all F10 whitelisted constructors" {
    const option_params = [_]ir.Ty{.Int};
    const result_ok_params = [_]ir.Ty{ .Int, .Unit };
    const result_error_params = [_]ir.Ty{ .Unit, .Int };
    const ctor_exprs = [_]ir.Expr{
        .{ .Ctor = .{ .name = "None", .args = &.{}, .ty = .{ .Adt = .{ .name = "option", .params = &option_params } }, .layout = layout.ctor(0) } },
        .{ .Ctor = .{ .name = "Some", .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 1 }, .ty = .Int, .layout = layout.intConstant() } })}, .ty = .{ .Adt = .{ .name = "option", .params = &option_params } }, .layout = layout.ctor(1) } },
        .{ .Ctor = .{ .name = "Ok", .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 2 }, .ty = .Int, .layout = layout.intConstant() } })}, .ty = .{ .Adt = .{ .name = "result", .params = &result_ok_params } }, .layout = layout.ctor(1) } },
        .{ .Ctor = .{ .name = "Error", .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 3 }, .ty = .Int, .layout = layout.intConstant() } })}, .ty = .{ .Adt = .{ .name = "result", .params = &result_error_params } }, .layout = layout.ctor(1) } },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.StringHashMap(Value).init(arena.allocator());
    defer env.deinit();
    for (ctor_exprs) |expr| {
        const value = try evalExpr(arena.allocator(), expr, &env);
        const ctor_value = switch (value) {
            .Ctor => |ctor| ctor,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(ctor_value.name.len > 0);
    }
}

test "interpreter matches constructor arms top-to-bottom" {
    const option_ty = ir.Ty{ .Adt = .{ .name = "option", .params = &.{.Int} } };
    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Match = .{
                .scrutinee = makeExpr(.{ .Ctor = .{
                    .name = "Some",
                    .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 1 }, .ty = .Int, .layout = layout.intConstant() } })},
                    .ty = option_ty,
                    .layout = layout.ctor(1),
                } }),
                .arms = &.{
                    .{
                        .pattern = .{ .Ctor = .{
                            .name = "Some",
                            .args = &.{.{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } }},
                        } },
                        .body = makeExpr(.{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } }),
                    },
                    .{
                        .pattern = .{ .Ctor = .{ .name = "None", .args = &.{} } },
                        .body = makeExpr(.{ .Constant = .{ .value = .{ .Int = 0 }, .ty = .Int, .layout = layout.intConstant() } }),
                    },
                },
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{entrypoint_decl};

    try std.testing.expectEqual(@as(u64, 1), try evalModule(.{ .decls = &decls }));
}

test "interpreter represents lists as nil/cons values and matches them" {
    const list_ty = ir.Ty{ .Adt = .{ .name = "list", .params = &.{.Int} } };
    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Match = .{
                .scrutinee = makeExpr(.{ .Ctor = .{
                    .name = "::",
                    .args = &.{
                        makeExpr(.{ .Constant = .{ .value = .{ .Int = 6 }, .ty = .Int, .layout = layout.intConstant() } }),
                        makeExpr(.{ .Ctor = .{
                            .name = "[]",
                            .args = &.{},
                            .ty = list_ty,
                            .layout = layout.ctor(0),
                        } }),
                    },
                    .ty = list_ty,
                    .layout = layout.ctor(2),
                } }),
                .arms = &.{
                    .{
                        .pattern = .{ .Ctor = .{ .name = "[]", .args = &.{} } },
                        .body = makeExpr(.{ .Constant = .{ .value = .{ .Int = 0 }, .ty = .Int, .layout = layout.intConstant() } }),
                    },
                    .{
                        .pattern = .{ .Ctor = .{
                            .name = "::",
                            .args = &.{
                                .{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } },
                                .{ .Var = .{ .name = "rest", .ty = list_ty, .layout = layout.ctor(2) } },
                            },
                        } },
                        .body = makeExpr(.{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } }),
                    },
                },
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{entrypoint_decl};

    try std.testing.expectEqual(@as(u64, 6), try evalModule(.{ .decls = &decls }));
}

test "interpreter supports wildcard and variable match patterns" {
    const entrypoint_decl: ir.Decl = .{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .Match = .{
                .scrutinee = makeExpr(.{ .Constant = .{ .value = .{ .Int = 4 }, .ty = .Int, .layout = layout.intConstant() } }),
                .arms = &.{
                    .{
                        .pattern = .{ .Var = .{ .name = "n", .ty = .Int, .layout = layout.intConstant() } },
                        .body = makeExpr(.{ .Var = .{ .name = "n", .ty = .Int, .layout = layout.intConstant() } }),
                    },
                    .{
                        .pattern = .Wildcard,
                        .body = makeExpr(.{ .Constant = .{ .value = .{ .Int = 0 }, .ty = .Int, .layout = layout.intConstant() } }),
                    },
                },
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } };
    const decls = [_]ir.Decl{entrypoint_decl};

    try std.testing.expectEqual(@as(u64, 4), try evalModule(.{ .decls = &decls }));
}

test "interpreter evaluates a recursive top-level function" {
    const decls = [_]ir.Decl{
        .{ .Let = .{
            .name = "loop",
            .value = makeExpr(.{ .Lambda = .{
                .params = &.{.{ .name = "n", .ty = .Int }},
                .body = makeExpr(.{ .If = .{
                    .cond = makeExpr(.{ .Prim = .{
                        .op = .Le,
                        .args = &.{
                            makeExpr(.{ .Var = .{ .name = "n", .ty = .Int, .layout = layout.intConstant() } }),
                            makeExpr(.{ .Constant = .{ .value = .{ .Int = 0 }, .ty = .Int, .layout = layout.intConstant() } }),
                        },
                        .ty = .Bool,
                        .layout = layout.intConstant(),
                    } }),
                    .then_branch = makeExpr(.{ .Constant = .{ .value = .{ .Int = 7 }, .ty = .Int, .layout = layout.intConstant() } }),
                    .else_branch = makeExpr(.{ .App = .{
                        .callee = makeExpr(.{ .Var = .{ .name = "loop", .ty = .Unit, .layout = layout.topLevelLambda() } }),
                        .args = &.{makeExpr(.{ .Prim = .{
                            .op = .Sub,
                            .args = &.{
                                makeExpr(.{ .Var = .{ .name = "n", .ty = .Int, .layout = layout.intConstant() } }),
                                makeExpr(.{ .Constant = .{ .value = .{ .Int = 1 }, .ty = .Int, .layout = layout.intConstant() } }),
                            },
                            .ty = .Int,
                            .layout = layout.intConstant(),
                        } })},
                        .ty = .Int,
                        .layout = layout.intConstant(),
                    } }),
                    .ty = .Int,
                    .layout = layout.intConstant(),
                } }),
                .ty = .Unit,
                .layout = layout.topLevelLambda(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
            .is_rec = true,
        } },
        .{ .Let = .{
            .name = "entrypoint",
            .value = makeExpr(.{ .Lambda = .{
                .params = &.{},
                .body = makeExpr(.{ .App = .{
                    .callee = makeExpr(.{ .Var = .{ .name = "loop", .ty = .Unit, .layout = layout.topLevelLambda() } }),
                    .args = &.{makeExpr(.{ .Constant = .{ .value = .{ .Int = 3 }, .ty = .Int, .layout = layout.intConstant() } })},
                    .ty = .Int,
                    .layout = layout.intConstant(),
                } }),
                .ty = .Unit,
                .layout = layout.topLevelLambda(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } },
    };

    try std.testing.expectEqual(@as(u64, 7), try evalModule(.{ .decls = &decls }));
}

test "unknown two-arg names are not intercepted as fixed helpers for list args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const list = try allocator.create(ListValue);
    list.* = .nil;

    var env = std.StringHashMap(Value).init(allocator);
    defer env.deinit();
    try env.put("xs", .{ .List = list });

    const args = [_]*const ir.Expr{
        makeExpr(.{ .Var = .{ .name = "xs", .ty = .{ .Adt = .{ .name = "list", .params = &.{.Int} } }, .layout = layout.structPack() } }),
        makeExpr(.{ .Constant = .{ .value = .{ .Int = 7 }, .ty = .Int, .layout = layout.intConstant() } }),
    };

    try std.testing.expectEqual(@as(?Value, null), try evalStdlibApp(allocator, "pick_second", &args, &env));
}

test "unknown two-arg names are not intercepted as fixed helpers for closure args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = std.StringHashMap(Value).init(allocator);
    defer env.deinit();
    try env.put("f", .{ .Lambda = .{
        .params = &.{.{ .name = "x", .ty = .Int }},
        .body = makeExpr(.{ .Var = .{ .name = "x", .ty = .Int, .layout = layout.intConstant() } }),
        .ty = .{ .Arrow = .{ .params = &.{.Int}, .ret = makeTy(.Int) } },
        .layout = layout.topLevelLambda(),
    } });

    const args = [_]*const ir.Expr{
        makeExpr(.{ .Var = .{ .name = "f", .ty = .{ .Arrow = .{ .params = &.{.Int}, .ret = makeTy(.Int) } }, .layout = layout.topLevelLambda() } }),
        makeExpr(.{ .Constant = .{ .value = .{ .Int = 7 }, .ty = .Int, .layout = layout.intConstant() } }),
    };

    try std.testing.expectEqual(@as(?Value, null), try evalStdlibApp(allocator, "make_generator", &args, &env));
}

test "interpreter backend trait exposes direct eval and rejects source emission" {
    const decls = [_]ir.Decl{testLet("entrypoint", 7)};
    const module = ir.Module{ .decls = &decls };
    var interpreter: Interpreter = .{};
    const backend = interpreter.backend();

    try std.testing.expectEqual(@as(u64, 7), try backend.evalModule(module));
    try std.testing.expectError(error.NotImplemented, backend.emitModule(module));
    try std.testing.expectEqualStrings(
        "interpreter does not yet implement source emission",
        errorMessage(error.NotImplemented),
    );
}

test "interpreter handles bool equality and not" {
    // Models a program shaped like:
    //   let entrypoint _ = if not (true = false) then 1 else 0
    // After ANF lowering, `not` becomes `if e then false else true` and `=`
    // on bools becomes `Prim Eq` on `Ctor true`/`Ctor false` values. The test
    // covers both the bool-aware Eq path and the desugared not branch.

    // (true = false) is false, so `not (true = false)` is true, taking the
    // outer `then` branch, which yields 1.
    const decls = comptime [_]ir.Decl{.{ .Let = .{
        .name = "entrypoint",
        .value = makeExpr(.{ .Lambda = .{
            .params = &.{},
            .body = makeExpr(.{ .If = .{
                .cond = makeExpr(.{ .If = .{
                    .cond = makeExpr(.{ .Prim = .{
                        .op = .Eq,
                        .args = &.{
                            makeExpr(.{ .Ctor = .{ .name = "true", .args = &.{}, .ty = .Bool, .layout = layout.intConstant() } }),
                            makeExpr(.{ .Ctor = .{ .name = "false", .args = &.{}, .ty = .Bool, .layout = layout.intConstant() } }),
                        },
                        .ty = .Bool,
                        .layout = layout.intConstant(),
                    } }),
                    .then_branch = makeExpr(.{ .Ctor = .{ .name = "false", .args = &.{}, .ty = .Bool, .layout = layout.intConstant() } }),
                    .else_branch = makeExpr(.{ .Ctor = .{ .name = "true", .args = &.{}, .ty = .Bool, .layout = layout.intConstant() } }),
                    .ty = .Bool,
                    .layout = layout.intConstant(),
                } }),
                .then_branch = makeExpr(.{ .Constant = .{ .value = .{ .Int = 1 }, .ty = .Int, .layout = layout.intConstant() } }),
                .else_branch = makeExpr(.{ .Constant = .{ .value = .{ .Int = 0 }, .ty = .Int, .layout = layout.intConstant() } }),
                .ty = .Int,
                .layout = layout.intConstant(),
            } }),
            .ty = .Unit,
            .layout = layout.topLevelLambda(),
        } }),
        .ty = .Unit,
        .layout = layout.topLevelLambda(),
    } }};

    try std.testing.expectEqual(@as(u64, 1), try evalModule(.{ .decls = &decls }));

    // Verify Prim Eq also works on string values directly via evalPrim.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.StringHashMap(Value).init(arena.allocator());
    defer env.deinit();
    const string_args = comptime [_]*const ir.Expr{
        makeExpr(.{ .Constant = .{ .value = .{ .String = "abc" }, .ty = .String, .layout = layout.intConstant() } }),
        makeExpr(.{ .Constant = .{ .value = .{ .String = "abc" }, .ty = .String, .layout = layout.intConstant() } }),
    };
    const cmp_strings = try evalPrim(arena.allocator(), .{
        .op = .Eq,
        .args = &string_args,
        .ty = .Bool,
        .layout = layout.intConstant(),
    }, &env);
    try std.testing.expect(try boolValue(cmp_strings));

    // And on integers (unchanged path).
    const int_args = comptime [_]*const ir.Expr{
        makeExpr(.{ .Constant = .{ .value = .{ .Int = 1 }, .ty = .Int, .layout = layout.intConstant() } }),
        makeExpr(.{ .Constant = .{ .value = .{ .Int = 2 }, .ty = .Int, .layout = layout.intConstant() } }),
    };
    const cmp_ints = try evalPrim(arena.allocator(), .{
        .op = .Ne,
        .args = &int_args,
        .ty = .Bool,
        .layout = layout.intConstant(),
    }, &env);
    try std.testing.expect(try boolValue(cmp_ints));
}

test "interpreter unsupported module shapes raise recognisable stub errors" {
    const missing_entrypoint_decls = [_]ir.Decl{testLet("not_entrypoint", 0)};
    const module_without_entrypoint = ir.Module{ .decls = &missing_entrypoint_decls };

    try std.testing.expectError(error.EntrypointNotFound, evalModule(module_without_entrypoint));
    try std.testing.expectEqualStrings(
        "interpreter does not yet implement module without entrypoint",
        errorMessage(error.EntrypointNotFound),
    );

    // Negative integer results must be reinterpreted to u64 via their bit
    // pattern, matching the Solana BPF entrypoint contract used by the Zig
    // native and BPF backends. `-1` therefore lowers to 0xFFFF_FFFF_FFFF_FFFF.
    const negative_decls = [_]ir.Decl{testLet("entrypoint", -1)};
    try std.testing.expectEqual(
        @as(u64, 0xFFFF_FFFF_FFFF_FFFF),
        try evalModule(.{ .decls = &negative_decls }),
    );

    const min_decls = [_]ir.Decl{testLet("entrypoint", std.math.minInt(i64))};
    try std.testing.expectEqual(
        @as(u64, 0x8000_0000_0000_0000),
        try evalModule(.{ .decls = &min_decls }),
    );
}
