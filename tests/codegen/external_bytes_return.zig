//! Regression test for external bytes-return codegen.
//!
//! RESPONSIBILITIES:
//! - Compile an OCaml source that declares `sol_sha256 : bytes -> bytes`.
//! - Verify the generated Zig hoists the runtime `[32]u8` hash storage before slicing.
//! - Execute the hosted native binary so the generated source is type-checked.

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

test "external sol_sha256 bytes return is sliced and native code compiles" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const output = "/tmp/zxcaml_external_bytes_return_bin";
    const build_argv = [_][]const u8{
        codegen_options.omlz_bin,
        "build",
        "--target=native",
        "tests/codegen/external_bytes_return.ml",
        "-o",
        output,
        "--keep-zig",
    };
    const build = try runCommand(allocator, io, &build_argv);
    defer allocator.free(build.stdout);
    defer allocator.free(build.stderr);

    if (build.exit_code != 0) {
        std.debug.print("external bytes-return build failed\nstdout:\n{s}\nstderr:\n{s}\n", .{ build.stdout, build.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), build.exit_code);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, "out/program.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(source);

    const hoist_index = std.mem.indexOf(u8, source, "    var omlz_external_bytes_") orelse return error.TestUnexpectedResult;
    const return_index = std.mem.indexOf(u8, source, "    return @intCast(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hoist_index < return_index);
    try std.testing.expect(std.mem.indexOf(u8, source, ": [32]u8 = undefined;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const omlz_external_bytes_") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, " = syscalls.sol_sha256(input);") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "syscalls.sol_sha256(input)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "[0..];") != null);

    const run_argv = [_][]const u8{output};
    const run = try runCommand(allocator, io, &run_argv);
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);
    try std.testing.expectEqual(@as(u8, 0), run.exit_code);
}
