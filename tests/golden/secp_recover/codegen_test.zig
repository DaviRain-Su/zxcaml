//! Codegen golden for the stdlib `Crypto.secp256k1_recover` binding.
//!
//! RESPONSIBILITIES:
//! - Compile a tiny OCaml source that calls `Crypto.secp256k1_recover`.
//! - Keep a focused generated-Zig snapshot for the signature-recovery syscall call site.
//! - Ensure the generated native program still type-checks with the runtime wrapper.

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

fn appendSecpRecoverLines(out: *std.ArrayList(u8), allocator: Allocator, source: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOf(u8, trimmed, "sol_secp256k1_recover") != null) {
            try out.appendSlice(allocator, trimmed);
            try out.append(allocator, '\n');
        }
    }
}

test "secp_recover golden: Crypto.secp256k1_recover lowers to recovery syscall wrapper" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const output = "/tmp/zxcaml_secp_recover_codegen_bin";
    const build_argv = [_][]const u8{
        codegen_options.omlz_bin,
        "build",
        "--target=native",
        "tests/golden/secp_recover/crypto_secp_recover.ml",
        "-o",
        output,
        "--keep-zig",
    };
    const build = try runCommand(allocator, io, &build_argv);
    defer allocator.free(build.stdout);
    defer allocator.free(build.stderr);

    if (build.exit_code != 0) {
        std.debug.print("secp_recover codegen build failed\nstdout:\n{s}\nstderr:\n{s}\n", .{ build.stdout, build.stderr });
    }
    try std.testing.expectEqual(@as(u8, 0), build.exit_code);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, "out/program.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(source);

    var actual = std.ArrayList(u8).empty;
    defer actual.deinit(allocator);
    try appendSecpRecoverLines(&actual, allocator, source);

    const expected = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "tests/golden/secp_recover/crypto_secp_recover.zig.snapshot",
        allocator,
        .limited(4096),
    );
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, actual.items);
}
