//! Regression test for P7 literal, or-pattern, and alias-pattern codegen.
//!
//! RESPONSIBILITIES:
//! - Compile OCaml matches that use integer/string/char literal patterns.
//! - Verify or-pattern arms are duplicated into literal comparison branches.
//! - Verify alias patterns bind the full matched value when the body uses it.

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

test "literal, or, and alias patterns emit explicit Zig dispatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const output = "/tmp/zxcaml_pattern_extensions_bin";
    const build_argv = [_][]const u8{
        codegen_options.omlz_bin,
        "build",
        "--target=native",
        "tests/codegen/pattern_extensions.ml",
        "-o",
        output,
        "--keep-zig",
    };
    const build = try runCommand(allocator, io, &build_argv);
    defer allocator.free(build.stdout);
    defer allocator.free(build.stderr);

    if (build.exit_code != 0) {
        std.debug.print("pattern extensions build failed\nstdout:\n{s}\nstderr:\n{s}\n", .{ build.stdout, build.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), build.exit_code);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, "out/program.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "== @as(i64, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "== @as(i64, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "== @as(i64, 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "== @as(i64, 97)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "std.mem.eql(u8, omlz_match_scrutinee_") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "\"hello\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const whole = omlz_match_scrutinee_") != null);

    const first = std.mem.indexOf(u8, source, "== @as(i64, 0)") orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOf(u8, source, "== @as(i64, 1)") orelse return error.TestUnexpectedResult;
    const third = std.mem.indexOf(u8, source, "== @as(i64, 2)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first < second);
    try std.testing.expect(second < third);

    const run_argv = [_][]const u8{output};
    const run = try runCommand(allocator, io, &run_argv);
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);
    try std.testing.expectEqual(@as(u8, 0), run.exit_code);
}
