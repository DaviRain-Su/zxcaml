//! Regression test for region-aware let storage codegen.
//!
//! RESPONSIBILITIES:
//! - Compile an OCaml source with both non-escaping and escaping let bindings.
//! - Verify Stack-region lets become typed Zig stack locals.
//! - Verify Arena-region lets still allocate through the runtime arena.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const codegen_options = @import("codegen_options");

fn runCommand(allocator: Allocator, io: Io, argv: []const []const u8) !struct { stdout: []u8, stderr: []u8, exit_code: u8 } {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
}

test "region let storage emits stack locals and arena slots" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const output = "/tmp/zxcaml_region_let_storage_bin";
    const build_argv = [_][]const u8{
        codegen_options.omlz_bin,
        "build",
        "--target=native",
        "tests/codegen/region_let_storage.ml",
        "-o",
        output,
        "--keep-zig",
    };
    const build = try runCommand(allocator, io, &build_argv);
    defer allocator.free(build.stdout);
    defer allocator.free(build.stderr);

    if (build.exit_code != 0) {
        std.debug.print("region let storage build failed\nstdout:\n{s}\nstderr:\n{s}\n", .{ build.stdout, build.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), build.exit_code);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, "out/program.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "var stack_local: i64 =") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const arena_local = arena.allocOneOrTrap(i64);") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "arena_local.* = @as(i64, 4);") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "omlz_user_id(arena, arena_local.*)") != null);

    const stack_index = std.mem.indexOf(u8, source, "var stack_local: i64 =") orelse return error.TestUnexpectedResult;
    const arena_index = std.mem.indexOf(u8, source, "const arena_local = arena.allocOneOrTrap(i64);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(stack_index < arena_index);

    const run_argv = [_][]const u8{output};
    const run = try runCommand(allocator, io, &run_argv);
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);
    try std.testing.expectEqual(@as(u8, 0), run.exit_code);
}
