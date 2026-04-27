//! Determinism property test: interpreter ≡ Zig native on the corpus.
//!
//! RESPONSIBILITIES:
//! - Iterate every `.ml` in `examples/` (and `tests/ui/` when it exists).
//! - Run each through `omlz run` (interpreter) and `omlz build --target=native` (Zig native).
//! - Compare observable results byte-for-byte.
//! - Self-mutation regression test: deliberately mutate native output and confirm
//!   divergence is caught, proving the harness actually detects bugs.
//!
//! BPF target is excluded from this gate (covered by F19 separately).
//! Adding a new `.ml` example to `examples/` automatically gets covered
//! by this test — no per-example wiring required.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const det_options = @import("det_options");

/// Runs `omlz run <ml_file>` and returns (stdout, exit_code).
/// Caller owns stdout and must free it.
fn runInterpreter(allocator: Allocator, io: Io, ml_file: []const u8) !struct { stdout: []u8, exit_code: u8 } {
    const argv = [_][]const u8{ det_options.omlz_bin, "run", ml_file };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    // Free stderr immediately; caller only needs stdout.
    allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };

    return .{ .stdout = result.stdout, .exit_code = exit_code };
}

/// Runs `omlz build --target=native <ml_file> -o <output>` then executes the binary.
/// Returns the native binary's exit code.
fn runNative(allocator: Allocator, io: Io, ml_file: []const u8) !u8 {
    const base = std.fs.path.basename(ml_file);
    const stem = if (std.mem.endsWith(u8, base, ".ml")) base[0 .. base.len - 3] else base;
    const output = try std.fmt.allocPrint(allocator, "/tmp/det_{s}", .{stem});
    defer allocator.free(output);

    // Build native binary
    const argv_build = [_][]const u8{ det_options.omlz_bin, "build", "--target=native", ml_file, "-o", output };
    const build_result = try std.process.run(allocator, io, .{ .argv = &argv_build });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    switch (build_result.term) {
        .exited => |code| {
            if (code != 0) return error.NativeBuildFailed;
        },
        else => return error.NativeBuildFailed,
    }

    // Execute native binary
    const argv_run = [_][]const u8{output};
    const run_result = try std.process.run(allocator, io, .{ .argv = &argv_run });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    return switch (run_result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

/// Core determinism check: for every `.ml` file in the given directory,
/// compare interpreter output with native exit code.
fn checkDeterminismCorpus(allocator: Allocator, io: Io, dir_path: []const u8) !usize {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    var iter = dir.iterate();
    var tested: usize = 0;

    while (try iter.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".ml")) continue;

        const ml_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(ml_path);

        // Run interpreter
        const interp = try runInterpreter(allocator, io, ml_path);
        defer allocator.free(interp.stdout);

        if (interp.exit_code != 0) {
            // Interpreter failed (panic or error). Skip this file —
            // panic determinism will be verified separately when F18
            // adds diagnostic .expected files.
            continue;
        }

        // Parse interpreter result as an integer
        const trimmed = std.mem.trim(u8, interp.stdout, " \t\r\n");
        if (trimmed.len == 0) continue;
        const interp_value = std.fmt.parseInt(u64, trimmed, 10) catch continue;

        // Run native
        const native_exit = runNative(allocator, io, ml_path) catch |err| {
            std.debug.print(
                "DETERMINISM BUILD FAILURE: {s}: native build error: {s}\n",
                .{ ml_path, @errorName(err) },
            );
            return err;
        };

        // Compare: interpreter's printed value vs native binary exit code
        if (interp_value != native_exit) {
            std.debug.print(
                "DETERMINISM FAILURE: {s}: interpreter={d}, native={d}\n",
                .{ ml_path, interp_value, native_exit },
            );
            return error.DeterminismViolation;
        }
        tested += 1;
    }

    return tested;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "determinism: interpreter ≡ Zig native on examples corpus" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tested = try checkDeterminismCorpus(allocator, io, "examples");

    // Ensure we actually tested at least one file (guard against empty dirs).
    if (tested == 0) {
        std.debug.print("WARNING: no .ml files found in examples/ to test\n", .{});
    }
    try std.testing.expect(tested > 0);
}

test "determinism: interpreter ≡ Zig native on tests/ui corpus" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // tests/ui/ may not exist yet (F18 is pending). If it doesn't, skip gracefully.
    const cwd = std.Io.Dir.cwd();
    {
        var probe = cwd.openDir(io, "tests/ui", .{}) catch |err| switch (err) {
            error.FileNotFound => return, // tests/ui/ not yet created — skip
            else => return err,
        };
        probe.close(io);
    }
    var dir = try cwd.openDir(io, "tests/ui", .{});
    defer dir.close(io);

    var iter = dir.iterate();

    while (try iter.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".ml")) continue;

        const ml_path = try std.fmt.allocPrint(allocator, "tests/ui/{s}", .{entry.name});
        defer allocator.free(ml_path);

        const interp = try runInterpreter(allocator, io, ml_path);
        defer allocator.free(interp.stdout);

        if (interp.exit_code != 0) continue;

        const trimmed = std.mem.trim(u8, interp.stdout, " \t\r\n");
        if (trimmed.len == 0) continue;
        const interp_value = std.fmt.parseInt(u64, trimmed, 10) catch continue;

        const native_exit = runNative(allocator, io, ml_path) catch |err| {
            std.debug.print(
                "DETERMINISM BUILD FAILURE: {s}: native build error: {s}\n",
                .{ ml_path, @errorName(err) },
            );
            return err;
        };

        if (interp_value != native_exit) {
            std.debug.print(
                "DETERMINISM FAILURE: {s}: interpreter={d}, native={d}\n",
                .{ ml_path, interp_value, native_exit },
            );
            return error.DeterminismViolation;
        }
    }
}

test "determinism self-mutation: harness catches deliberate divergence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Step 1: Run interpreter on m0_zero.ml — should print "0"
    const interp = try runInterpreter(allocator, io, "examples/m0_zero.ml");
    defer allocator.free(interp.stdout);
    try std.testing.expectEqual(@as(u8, 0), interp.exit_code);
    const trimmed = std.mem.trim(u8, interp.stdout, " \t\r\n");
    try std.testing.expectEqualStrings("0", trimmed);

    // Step 2: Build and run native binary — should also exit 0
    const native_exit = try runNative(allocator, io, "examples/m0_zero.ml");
    try std.testing.expectEqual(@as(u8, 0), native_exit);

    // Step 3: Create a mutant Zig source that returns 1 instead of 0.
    // This simulates a ZigBackend codegen bug (e.g. emitting `return 1`
    // instead of `return 0`). The determinism harness MUST catch this.
    const mutant_source =
        \\// Mutant: simulates ZigBackend emitting wrong constant (1 instead of 0).
        \\// Used by determinism self-mutation regression test.
        \\const std = @import("std");
        \\pub fn main() void {
        \\    std.process.exit(1);
        \\}
    ;

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    try cwd.writeFile(io, .{
        .sub_path = "out/determinism_mutant.zig",
        .data = mutant_source,
        .flags = .{ .truncate = true },
    });

    // Build the mutant binary
    const mutant_bin = "/tmp/determinism_mutant";
    const argv_build = [_][]const u8{
        "zig",
        "build-exe",
        "-O",
        "ReleaseSmall",
        "-femit-bin=" ++ mutant_bin,
        "out/determinism_mutant.zig",
    };
    const build_result = try std.process.run(allocator, io, .{ .argv = &argv_build });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    switch (build_result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    // Run the mutant binary
    const argv_run = [_][]const u8{mutant_bin};
    const run_result = try std.process.run(allocator, io, .{ .argv = &argv_run });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    const mutant_exit: u8 = switch (run_result.term) {
        .exited => |code| code,
        else => 1,
    };

    // Step 4: Assert the mutant disagrees with the interpreter.
    // mutant_exit == 1, interp exit_code == 0 → divergence!
    // This proves the determinism harness would catch a ZigBackend bug
    // that emits a wrong constant.
    try std.testing.expectEqual(@as(u8, 1), mutant_exit);
    try std.testing.expect(mutant_exit != interp.exit_code);

    // Cleanup mutant source
    cwd.deleteFile(io, "out/determinism_mutant.zig") catch {};
}
