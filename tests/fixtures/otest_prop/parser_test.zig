//! Parser regression tests for `let%test_prop` frontend pre-scan behavior.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const zxc_frontend_bin = "zig-out/bin/zxc-frontend";

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn runCommand(allocator: Allocator, io: Io, argv: []const []const u8) !CommandResult {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
}

fn freeResult(allocator: Allocator, result: CommandResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn expectFrontendAccepts(path: []const u8, source: []const u8, expected_fragments: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    try cwd.writeFile(io, .{ .sub_path = path, .data = source });
    defer cwd.deleteFile(io, path) catch {};

    const result = try runCommand(
        allocator,
        io,
        &.{ zxc_frontend_bin, "--emit=sexp", "--wire=1.1", path },
    );
    defer freeResult(allocator, result);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    for (expected_fragments) |fragment| {
        try std.testing.expect(contains(result.stdout, fragment));
    }
}

fn expectFrontendRejects(path: []const u8, source: []const u8, expected_message: []const u8) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    try cwd.writeFile(io, .{ .sub_path = path, .data = source });
    defer cwd.deleteFile(io, path) catch {};

    const result = try runCommand(
        allocator,
        io,
        &.{ zxc_frontend_bin, "--emit=sexp", "--wire=1.1", path },
    );
    defer freeResult(allocator, result);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(contains(result.stderr, expected_message));
}

test "otest_prop parser: accepts fun-body single parameter" {
    try expectFrontendAccepts(
        "/tmp/zxcaml_otest_prop_fun_body.ml",
        "let gen = ()\n" ++
            "let%test_prop \"identity\" gen = fun x -> assert (x = x)\n",
        &.{ "identity", "\"prop\"", "__otest_prop_0__", "__otest_registry__" },
    );
}

test "otest_prop parser: accepts explicit single identifier parameter" {
    try expectFrontendAccepts(
        "/tmp/zxcaml_otest_prop_single_param.ml",
        "let gen = ()\n" ++
            "let%test_prop \"explicit\" gen x = assert (x = x)\n",
        &.{ "explicit", "__otest_body_0__", "lambda (x)" },
    );
}

test "otest_prop parser: accepts tuple identifier parameter" {
    try expectFrontendAccepts(
        "/tmp/zxcaml_otest_prop_tuple_param.ml",
        "let pair_gen = ()\n" ++
            "let%test_prop \"pair\" pair_gen (a, b) = assert (a = b)\n",
        &.{ "pair", "tuple_project", "var a", "var b" },
    );
}

test "otest_prop parser: ignores extension text inside comments" {
    try expectFrontendAccepts(
        "/tmp/zxcaml_otest_prop_comment.ml",
        "(* let%test_prop \"not real\" gen = fun x -> x *)\n" ++
            "let gen = ()\n" ++
            "let%test_prop \"real\" gen = fun x -> assert (x = x)\n",
        &.{ "real", "__otest_prop_0__", "__otest_registry__" },
    );
}

test "otest_prop parser: rejects missing name" {
    try expectFrontendRejects(
        "/tmp/zxcaml_otest_prop_missing_name.ml",
        "let gen = ()\n" ++
            "let%test_prop gen = fun x -> assert (x = x)\n",
        "expected a string literal test name after let%test_prop",
    );
}

test "otest_prop parser: rejects empty name" {
    try expectFrontendRejects(
        "/tmp/zxcaml_otest_prop_empty_name.ml",
        "let gen = ()\n" ++
            "let%test_prop \"\" gen = fun x -> assert (x = x)\n",
        "let%test_prop requires a non-empty test name",
    );
}

test "otest_prop parser: rejects missing generator" {
    try expectFrontendRejects(
        "/tmp/zxcaml_otest_prop_missing_generator.ml",
        "let%test_prop \"missing generator\" = fun x -> assert (x = x)\n",
        "expected a generator expression after let%test_prop test name",
    );
}

test "otest_prop parser: rejects non-trivial tuple parameter" {
    try expectFrontendRejects(
        "/tmp/zxcaml_otest_prop_bad_tuple_param.ml",
        "let gen = ()\n" ++
            "let%test_prop \"bad pattern\" gen (Some x) = assert true\n",
        "body parameter pattern must be a single identifier or a tuple of identifiers",
    );
}

test "otest_prop parser: rejects missing body" {
    try expectFrontendRejects(
        "/tmp/zxcaml_otest_prop_missing_body.ml",
        "let gen = ()\n" ++
            "let%test_prop \"missing body\" gen =\n",
        "expected a property body after `=`",
    );
}

test "otest_prop parser: rejects nested property binding" {
    try expectFrontendRejects(
        "/tmp/zxcaml_otest_prop_nested.ml",
        "let gen = ()\n" ++
            "let entrypoint _ =\n" ++
            "  let%test_prop \"nested\" gen = fun x -> assert (x = x) in\n" ++
            "  ()\n",
        "let%test_prop is only supported as a top-level binding",
    );
}
