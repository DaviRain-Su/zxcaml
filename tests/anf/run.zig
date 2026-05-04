const std = @import("std");
const ttree = @import("../../src/frontend_bridge/ttree.zig");
const ir = @import("../../src/core/ir.zig");
const layout = @import("../../src/core/layout.zig");
const pretty = @import("../../src/core/pretty.zig");
const anf = @import("../../src/core/anf.zig");
const type_ops = @import("../../src/core/anf/type_ops.zig");

const lowerModule = anf.lowerModule;
const exprTy = type_ops.exprTy;
const isAccountTy = type_ops.isAccountTy;

test "lower M0 constant module through ANF to Core IR" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let entrypoint (lambda (_input) (const-int 0)))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);

    const let_decl = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    try std.testing.expectEqualStrings("entrypoint", let_decl.name);
    const lambda = switch (let_decl.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(layout.Layout{ .region = .Arena, .repr = .Flat }, lambda.layout);
    try std.testing.expectEqual(@as(usize, 1), lambda.params.len);
    try std.testing.expectEqualStrings("_input", lambda.params[0].name);

    const constant = switch (lambda.body.*) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    switch (constant.value) {
        .Int => |value| try std.testing.expectEqual(@as(i64, 0), value),
        .String => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(layout.Layout{ .region = .Static, .repr = .Flat }, constant.layout);

    const printed = try pretty.formatModule(std.testing.allocator, module);
    defer std.testing.allocator.free(printed);
    try std.testing.expectEqualStrings(
        "(module (let entrypoint (lambda (_input :ty (arrow unit int) :layout (arena flat)) (const 0 :ty int :layout (static flat)))))",
        printed,
    );
}

test "lower top-level and nested lets with lexical var references" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let x (const-int 1)) (let entrypoint (lambda (_input) (let y (const-int 7) (var x))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    try std.testing.expectEqual(@as(usize, 2), module.decls.len);

    const top_level = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    try std.testing.expectEqualStrings("x", top_level.name);
    try std.testing.expectEqual(ir.Ty.Int, top_level.ty);
    try std.testing.expectEqual(layout.intConstant(), top_level.layout);

    const entrypoint = switch (module.decls[1]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const nested = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("y", nested.name);
    const var_ref = switch (nested.body.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("x", var_ref.name);
    try std.testing.expectEqual(layout.intConstant(), var_ref.layout);
}

test "lower max_int and min_int as pinned i64 constants" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let entrypoint (lambda (_) (let _ (prim \"+\" (var max_int) (const-int 1)) (prim \"-\" (var min_int) (const-int 1)))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const first_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const add = switch (first_let.value.*) {
        .Prim => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const max_const = switch (add.args[0].*) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), max_const.value.Int);

    const sub = switch (first_let.body.*) {
        .Prim => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const min_const = switch (sub.args[0].*) {
        .Constant => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), min_const.value.Int);
}

test "marks only self calls in tail position" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let-rec loop (lambda (n acc) (if (prim \"=\" (var n) (const-int 0)) (var acc) (app (var loop) (prim \"-\" (var n) (const-int 1)) (prim \"+\" (var acc) (var n)))))) (let-rec sum (lambda (n) (prim \"+\" (var n) (app (var sum) (prim \"-\" (var n) (const-int 1))))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const loop_decl = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const loop_lambda = switch (loop_decl.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const loop_if = switch (loop_lambda.body.*) {
        .If => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const tail_app = switch (loop_if.else_branch.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(tail_app.is_tail_call);

    const sum_decl = switch (module.decls[1]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const sum_lambda = switch (sum_decl.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const non_tail_prim = switch (sum_lambda.body.*) {
        .Prim => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const non_tail_app = switch (non_tail_prim.args[1].*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!non_tail_app.is_tail_call);
}

test "does not mark shadowed recursive name as self tail call" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let-rec f (lambda (n) (let f (lambda (x) (prim \"+\" (var x) (const-int 1))) (app (var f) (var n)))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const f_decl = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const f_lambda = switch (f_decl.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const shadowing_let = switch (f_lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const shadowed_app = switch (shadowing_let.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!shadowed_app.is_tail_call);
}

test "lower Syscall module calls as typed builtin applications" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.8 (module (let entrypoint (lambda (message) (let _ (app (var Syscall.sol_log) (var message)) (app (var Syscall.sol_remaining_compute_units) (ctor \"()\")))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const log_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const log_app = switch (log_let.value.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const log_callee = switch (log_app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Syscall.sol_log", log_callee.name);
    try std.testing.expectEqual(ir.Ty.Unit, log_app.ty);
    try std.testing.expectEqual(ir.Ty.String, exprTy(log_app.args[0].*));

    const remaining_app = switch (log_let.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const remaining_callee = switch (remaining_app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Syscall.sol_remaining_compute_units", remaining_callee.name);
    try std.testing.expectEqual(ir.Ty.Int, remaining_app.ty);
}

test "lower external declarations into callable Core bindings" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 1.0 (module (external (name \"sol_log\") (type (arrow string unit)) (symbol \"sol_log_\")) (let entrypoint (lambda (_input) (app (var sol_log) (const-string \"hi\"))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    try std.testing.expectEqual(@as(usize, 1), module.externals.len);
    try std.testing.expectEqualStrings("sol_log", module.externals[0].name);
    try std.testing.expectEqualStrings("sol_log_", module.externals[0].symbol);

    const external_ty = switch (module.externals[0].ty) {
        .Arrow => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), external_ty.params.len);
    try std.testing.expectEqual(ir.Ty.String, external_ty.params[0]);
    try std.testing.expectEqual(ir.Ty.Unit, external_ty.ret.*);

    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const app = switch (lambda.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const callee = switch (app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("sol_log", callee.name);
    try std.testing.expectEqual(ir.Ty.Unit, app.ty);
}

test "lower CPI return-data calls as typed builtin applications" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.8 (module (let entrypoint (lambda (_input) (let _ (app (var Cpi.set_return_data) (const-string \"ok\")) (app (var Cpi.get_return_data) (ctor \"()\")))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const set_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const set_app = switch (set_let.value.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const set_callee = switch (set_app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Cpi.set_return_data", set_callee.name);
    try std.testing.expectEqual(ir.Ty.Unit, set_app.ty);
    try std.testing.expectEqual(ir.Ty.String, exprTy(set_app.args[0].*));

    const get_app = switch (set_let.body.*) {
        .App => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const get_callee = switch (get_app.callee.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Cpi.get_return_data", get_callee.name);
    try std.testing.expectEqual(ir.Ty.String, get_app.ty);
}

test "lower account field assignment as typed account mutation" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.9 (module (record_type_decl (name account) (params) (fields ((key (type-ref bytes)) (lamports (type-ref int)) (data (type-ref bytes)) (owner (type-ref bytes)) (is_signer (type-ref bool)) (is_writable (type-ref bool)) (executable (type-ref bool))))) (let entrypoint (lambda (account) (field_set (var account) lamports (const-int 42))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(isAccountTy(lambda.params[0].ty));
    const field_set = switch (lambda.body.*) {
        .AccountFieldSet => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("lamports", field_set.field_name);
    try std.testing.expectEqual(ir.Ty.Unit, field_set.ty);
    try std.testing.expectEqual(ir.Ty.Int, exprTy(field_set.value.*));
}

test "lower constructor expressions with layout policy" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let entrypoint (lambda (_input) (let _ (ctor Some (const-int 1)) (const-int 0))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const nested = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const ctor_expr = switch (nested.value.*) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Some", ctor_expr.name);
    try std.testing.expectEqual(@as(usize, 1), ctor_expr.args.len);
    try std.testing.expectEqual(layout.Layout{ .region = .Arena, .repr = .Boxed }, ctor_expr.layout);

    const printed = try pretty.formatModule(std.testing.allocator, module);
    defer std.testing.allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "(ctor Some") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, ":layout (arena boxed)") != null);
}

test "lower list constructors and cons patterns with list layout policy" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let entrypoint (lambda (_) (let-rec sum (lambda (xs) (match (var xs) (case (ctor \"[]\") (const-int 0)) (case (ctor \"::\" (var x) (var rest)) (prim \"+\" (var x) (app (var sum) (var rest)))))) (app (var sum) (ctor \"::\" (const-int 1) (ctor \"[]\"))))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const sum_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const sum_lambda = switch (sum_let.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("list", switch (sum_lambda.params[0].ty) {
        .Adt => |adt| adt.name,
        else => return error.TestUnexpectedResult,
    });

    const list_arg = switch (sum_let.body.*) {
        .App => |app| switch (app.args[0].*) {
            .Let => |let_expr| switch (let_expr.body.*) {
                .Ctor => |ctor| ctor,
                else => return error.TestUnexpectedResult,
            },
            .Ctor => |ctor| ctor,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("::", list_arg.name);
    try std.testing.expectEqual(layout.Layout{ .region = .Arena, .repr = .Boxed }, list_arg.layout);

    const printed = try pretty.formatModule(std.testing.allocator, module);
    defer std.testing.allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "(ctor ::") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, ":layout (arena boxed)") != null);
}

test "lower basic match expressions with top-to-bottom arms" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.4 (module (let entrypoint (lambda (_input) (match (ctor Some (const-int 1)) (case (ctor Some (var x)) (var x)) (case (ctor None) (const-int 0)))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const scrutinee_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, scrutinee_let.name, "__omlz_match_scrutinee_"));
    const match_expr = switch (scrutinee_let.body.*) {
        .Match => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), match_expr.arms.len);
    const some_pattern = switch (match_expr.arms[0].pattern) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Some", some_pattern.name);
    const bound = switch (some_pattern.args[0]) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("x", bound.name);

    const printed = try pretty.formatModule(std.testing.allocator, module);
    defer std.testing.allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "(match") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "((pattern (ctor Some (var x)))") != null);
}

test "lower user-defined ADT constructors with explicit tags" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.5 (module (type_decl (name t) (params) (variants ((A (payload_types)) (B (payload_types)) (C (payload_types (type-ref int)))))) (let entrypoint (lambda (_) (match (ctor C (const-int 42)) (case (ctor A) (const-int 0)) (case (ctor C (var x)) (var x)))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    try std.testing.expectEqual(@as(usize, 1), module.type_decls.len);
    try std.testing.expectEqualStrings("t", module.type_decls[0].name);
    try std.testing.expectEqual(@as(u32, 2), module.type_decls[0].variants[2].tag);

    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const scrutinee_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const ctor_expr = switch (scrutinee_let.value.*) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("C", ctor_expr.name);
    try std.testing.expectEqual(@as(u32, 2), ctor_expr.tag);
    try std.testing.expectEqualStrings("t", ctor_expr.type_name.?);

    const printed = try pretty.formatModule(std.testing.allocator, module);
    defer std.testing.allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "(type t (variants (A :tag 0) (B :tag 1) (C :tag 2 :payload (type-ref int))))") != null);
}

test "lower user-defined ADT constructor type parameters from payload types" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.5 (module (type_decl (name box) (params 'a) (variants ((Box (payload_types (type-var 'a)))))) (let entrypoint (lambda (_) (let flag (prim \"=\" (const-int 1) (const-int 1)) (match (ctor Box (var flag)) (case (ctor Box (var boxed_flag)) (if (var boxed_flag) (const-int 0) (const-int 1)))))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const flag_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const scrutinee_let = switch (flag_let.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const ctor_expr = switch (scrutinee_let.value.*) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const adt = switch (ctor_expr.ty) {
        .Adt => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("box", adt.name);
    try std.testing.expectEqual(@as(usize, 1), adt.params.len);
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Ty), .Bool), std.meta.activeTag(adt.params[0]));

    const match_expr = switch (scrutinee_let.body.*) {
        .Match => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const box_pattern = switch (match_expr.arms[0].pattern) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const flag_pattern = switch (box_pattern.args[0]) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Ty), .Bool), std.meta.activeTag(flag_pattern.ty));
}

test "lower nullary user ADT constructor type parameters from match context" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.5 (module (type_decl (name option) (params 'a) (variants ((None (payload_types)) (Some (payload_types (type-var 'a)))))) (let entrypoint (lambda (_) (match (ctor None) (case (ctor Some (var flag)) (if (var flag) (const-int 0) (const-int 1))) (case (ctor None) (const-int 2)))))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const entrypoint = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const lambda = switch (entrypoint.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const scrutinee_let = switch (lambda.body.*) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const ctor_expr = switch (scrutinee_let.value.*) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const adt = switch (ctor_expr.ty) {
        .Adt => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("option", adt.name);
    try std.testing.expectEqual(@as(usize, 1), adt.params.len);
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Ty), .Bool), std.meta.activeTag(adt.params[0]));

    const match_expr = switch (scrutinee_let.body.*) {
        .Match => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const some_pattern = switch (match_expr.arms[0].pattern) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const flag_pattern = switch (some_pattern.args[0]) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Ty), .Bool), std.meta.activeTag(flag_pattern.ty));
}

test "lower nullary user ADT constructor without context stays polymorphic" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();

    const frontend = try ttree.parseModule(
        &frontend_arena,
        "(zxcaml-cir 0.5 (module (type_decl (name option) (params 'a) (variants ((None (payload_types)) (Some (payload_types (type-var 'a)))))) (let value (ctor None))))",
    );

    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerModule(&core_arena, frontend);
    const value_decl = switch (module.decls[0]) {
        .Let => |value| value,
        .LetGroup => unreachable,
    };
    const ctor_expr = switch (value_decl.value.*) {
        .Ctor => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const adt = switch (ctor_expr.ty) {
        .Adt => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("option", adt.name);
    try std.testing.expectEqual(@as(usize, 1), adt.params.len);
    const type_var = switch (adt.params[0]) {
        .Var => |name| name,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("'a", type_var);
}
