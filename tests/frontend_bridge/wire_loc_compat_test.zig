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
