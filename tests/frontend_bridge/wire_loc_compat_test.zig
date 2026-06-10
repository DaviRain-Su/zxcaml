//! Regression tests for DX2 frontend bridge wire-location compatibility.

const std = @import("std");
const ttree = @import("ttree");

// Verification anchor: compat_1_1|loc_unknown|Loc.unknown
test "compat_1_1 loc_unknown maps missing loc to Loc.unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try ttree.parseModule(
        &arena,
        "(zxcaml-cir 1.1 (module (let entrypoint (lambda (_) (var input)))))",
    );
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);

    const decl = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => return error.TestUnexpectedResult,
    };
    const lambda = switch (decl.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(lambda.loc.isUnknown());
    try std.testing.expectEqualDeep(ttree.Loc.unknown, lambda.loc);

    const body_var = switch (lambda.body.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(body_var.loc.isUnknown());
    try std.testing.expectEqualDeep(ttree.Loc.unknown, body_var.loc);
}

test "wire 1.2 optional loc populates node locations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try ttree.parseModule(
        &arena,
        \\(zxcaml-cir 1.2
        \\  (module
        \\    (let entrypoint
        \\      (lambda (_)
        \\        (var input (loc "tests/frontend_bridge/wire_loc_compat_test.ml" 2 10 2 15))
        \\        (loc "tests/frontend_bridge/wire_loc_compat_test.ml" 1 0 2 15)))))
    );
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);

    const decl = switch (module.decls[0]) {
        .Let => |let_decl| let_decl,
        .LetRecGroup => return error.TestUnexpectedResult,
    };
    const lambda = switch (decl.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!lambda.loc.isUnknown());
    try std.testing.expectEqualStrings("tests/frontend_bridge/wire_loc_compat_test.ml", lambda.loc.file);
    try std.testing.expectEqual(@as(u32, 1), lambda.loc.line);
    try std.testing.expectEqual(@as(u32, 0), lambda.loc.col);
    try std.testing.expectEqual(@as(u32, 2), lambda.loc.end_line);
    try std.testing.expectEqual(@as(u32, 15), lambda.loc.end_col);

    const body_var = switch (lambda.body.*) {
        .Var => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!body_var.loc.isUnknown());
    try std.testing.expectEqualStrings("tests/frontend_bridge/wire_loc_compat_test.ml", body_var.loc.file);
    try std.testing.expectEqual(@as(u32, 2), body_var.loc.line);
    try std.testing.expectEqual(@as(u32, 10), body_var.loc.col);
    try std.testing.expectEqual(@as(u32, 2), body_var.loc.end_line);
    try std.testing.expectEqual(@as(u32, 15), body_var.loc.end_col);
}

// Verification anchor: wire_1_3|lambda_param_types|typed
test "wire 1.3 typed lambda params populate param_types with typed and any entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try ttree.parseModule(
        &arena,
        \\(zxcaml-cir 1.3
        \\  (module
        \\    (let entrypoint
        \\      (lambda ((x (ty (type-ref int))) (y (ty (any))))
        \\        (var x)))))
    );

    try std.testing.expectEqual(@as(usize, 1), module.decls.len);
    const let_decl = switch (module.decls[0]) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const lambda = switch (let_decl.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(@as(usize, 2), lambda.params.len);
    try std.testing.expectEqual(@as(usize, 2), lambda.param_types.len);
    try std.testing.expectEqualStrings("x", lambda.params[0]);
    try std.testing.expectEqualStrings("y", lambda.params[1]);

    // First param: explicit int type.
    const first_ty = lambda.param_types[0] orelse
        return error.TestUnexpectedResult;
    switch (first_ty) {
        .TypeRef => |ref| {
            try std.testing.expectEqualStrings("int", ref.name);
            try std.testing.expectEqual(@as(usize, 0), ref.args.len);
        },
        else => return error.TestUnexpectedResult,
    }

    // Second param: `(any)` sentinel maps to null.
    try std.testing.expect(lambda.param_types[1] == null);
}

// Verification anchor: wire_1_7|lambda_param_annotated|ty_bang
test "wire 1.7 ty! params set param_annotated while ty params stay false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try ttree.parseModule(
        &arena,
        \\(zxcaml-cir 1.7
        \\  (module
        \\    (let entrypoint
        \\      (lambda ((m (ty! (type-ref account_meta))) (y (ty (type-ref int))) (z (ty! (any))))
        \\        (var y)))))
    );

    const let_decl = switch (module.decls[0]) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const lambda = switch (let_decl.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(@as(usize, 3), lambda.params.len);
    try std.testing.expectEqual(@as(usize, 3), lambda.param_types.len);
    try std.testing.expectEqual(@as(usize, 3), lambda.param_annotated.len);

    // First param: explicitly annotated account_meta.
    try std.testing.expect(lambda.param_annotated[0]);
    const first_ty = lambda.param_types[0] orelse
        return error.TestUnexpectedResult;
    switch (first_ty) {
        .TypeRef => |ref| try std.testing.expectEqualStrings("account_meta", ref.name),
        else => return error.TestUnexpectedResult,
    }

    // Second param: inferred type, not annotated.
    try std.testing.expect(!lambda.param_annotated[1]);
    try std.testing.expect(lambda.param_types[1] != null);

    // Third param: annotated but `(any)` sentinel still maps to null.
    try std.testing.expect(lambda.param_annotated[2]);
    try std.testing.expect(lambda.param_types[2] == null);
}

// Verification anchor: wire_1_2|lambda_param_types|legacy
test "wire 1.2 legacy bare-atom params produce all-null param_types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try ttree.parseModule(
        &arena,
        "(zxcaml-cir 1.2 (module (let entrypoint (lambda (x y) (var x)))))",
    );

    const let_decl = switch (module.decls[0]) {
        .Let => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const lambda = switch (let_decl.body) {
        .Lambda => |value| value,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(@as(usize, 2), lambda.params.len);
    try std.testing.expectEqual(@as(usize, 2), lambda.param_types.len);
    try std.testing.expect(lambda.param_types[0] == null);
    try std.testing.expect(lambda.param_types[1] == null);
}
