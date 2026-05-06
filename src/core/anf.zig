//! Public facade for ANF lowering. Implementation lives in focused modules
//! under `src/core/anf/` to keep Core source files small.

const std = @import("std");
const ttree = @import("../frontend_bridge/ttree.zig");
const ir = @import("ir.zig");
const module_lower = @import("anf/module.zig");

pub const LowerError = module_lower.LowerError;

pub fn lowerModule(arena: *std.heap.ArenaAllocator, module: ttree.Module) LowerError!ir.Module {
    return module_lower.lowerModule(arena, module);
}

fn lowerSexpForTest(frontend_arena: *std.heap.ArenaAllocator, core_arena: *std.heap.ArenaAllocator, bytes: []const u8) !ir.Module {
    const parsed = try ttree.parseModule(frontend_arena, bytes);
    return lowerModule(core_arena, parsed);
}

fn expectLetName(decl: ir.Decl, expected: []const u8) !ir.Let {
    const let_decl = switch (decl) {
        .Let => |value| value,
        .LetGroup => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(expected, let_decl.name);
    return let_decl;
}

test "otest anf: zero tests do not synthesize registry" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();
    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerSexpForTest(
        &frontend_arena,
        &core_arena,
        "(zxcaml-cir 1.2 (module (let entrypoint (lambda (_) (const-int 0)))))",
    );
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);
    _ = try expectLetName(module.decls[0], "entrypoint");
}

test "otest anf: one test emits thunk then registry" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();
    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerSexpForTest(
        &frontend_arena,
        &core_arena,
        "(zxcaml-cir 1.2 (module (let __otest_unit_0__ (lambda (_) (ctor \"()\"))) (let __otest_registry__ (ctor \"::\" (tuple (items (const-string \"demo\") (var __otest_unit_0__))) (ctor \"[]\")))))",
    );
    try std.testing.expectEqual(@as(usize, 2), module.decls.len);
    const thunk = try expectLetName(module.decls[0], "__otest_unit_0__");
    _ = try expectLetName(module.decls[1], "__otest_registry__");
    const lambda = switch (thunk.value.*) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), lambda.params.len);
}

test "otest anf: thunk has unit-to-unit arrow type" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();
    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerSexpForTest(
        &frontend_arena,
        &core_arena,
        "(zxcaml-cir 1.2 (module (let __otest_unit_0__ (lambda (_) (ctor \"()\"))) (let __otest_registry__ (ctor \"::\" (tuple (items (const-string \"demo\") (var __otest_unit_0__))) (ctor \"[]\")))))",
    );
    const thunk = try expectLetName(module.decls[0], "__otest_unit_0__");
    const arrow = switch (thunk.ty) {
        .Arrow => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), arrow.params.len);
    switch (arrow.params[0]) {
        .Unit => {},
        else => return error.TestUnexpectedResult,
    }
    switch (arrow.ret.*) {
        .Unit => {},
        else => return error.TestUnexpectedResult,
    }
}

test "otest anf: registry type is list of string thunk pairs" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();
    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerSexpForTest(
        &frontend_arena,
        &core_arena,
        "(zxcaml-cir 1.2 (module (let __otest_unit_0__ (lambda (_) (ctor \"()\"))) (let __otest_registry__ (ctor \"::\" (tuple (items (const-string \"demo\") (var __otest_unit_0__))) (ctor \"[]\")))))",
    );
    const registry = try expectLetName(module.decls[1], "__otest_registry__");
    const list_ty = switch (registry.ty) {
        .Adt => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("list", list_ty.name);
    try std.testing.expectEqual(@as(usize, 1), list_ty.params.len);
    const pair_ty = switch (list_ty.params[0]) {
        .Tuple => |items| items,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), pair_ty.len);
    switch (pair_ty[0]) {
        .String => {},
        else => return error.TestUnexpectedResult,
    }
    _ = switch (pair_ty[1]) {
        .Arrow => |value| value,
        else => return error.TestUnexpectedResult,
    };
}

test "otest anf: two tests preserve source order" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();
    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerSexpForTest(
        &frontend_arena,
        &core_arena,
        "(zxcaml-cir 1.2 (module (let __otest_unit_0__ (lambda (_) (Assert (prim \"=\" (const-int 1) (const-int 1))))) (let __otest_unit_1__ (lambda (_) (Assert (prim \"=\" (const-int 2) (const-int 2))))) (let __otest_registry__ (ctor \"::\" (tuple (items (const-string \"first\") (var __otest_unit_0__))) (ctor \"::\" (tuple (items (const-string \"second\") (var __otest_unit_1__))) (ctor \"[]\"))))))",
    );
    try std.testing.expectEqual(@as(usize, 3), module.decls.len);
    _ = try expectLetName(module.decls[0], "__otest_unit_0__");
    _ = try expectLetName(module.decls[1], "__otest_unit_1__");
    _ = try expectLetName(module.decls[2], "__otest_registry__");
}

test "otest anf: mixed regular lets and tests preserve interleaving" {
    var frontend_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frontend_arena.deinit();
    var core_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer core_arena.deinit();

    const module = try lowerSexpForTest(
        &frontend_arena,
        &core_arena,
        "(zxcaml-cir 1.2 (module (let before (const-int 41)) (let __otest_unit_0__ (lambda (_) (Assert (prim \"=\" (prim \"+\" (var before) (const-int 1)) (const-int 42))))) (let after (lambda (_) (prim \"+\" (var before) (const-int 1)))) (let __otest_registry__ (ctor \"::\" (tuple (items (const-string \"middle\") (var __otest_unit_0__))) (ctor \"[]\")))))",
    );
    try std.testing.expectEqual(@as(usize, 4), module.decls.len);
    _ = try expectLetName(module.decls[0], "before");
    _ = try expectLetName(module.decls[1], "__otest_unit_0__");
    _ = try expectLetName(module.decls[2], "after");
    _ = try expectLetName(module.decls[3], "__otest_registry__");
}
