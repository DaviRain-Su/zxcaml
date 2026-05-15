const std = @import("std");

/// `zig build` exposes:
///   * `test` — run the package's host-side unit tests.
///
/// On-chain example programs that *use* this package live in
/// `examples/`, but they're built from `program-test/build.zig`
/// (which has the SBF target wiring + integration test harness).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sol_dep = b.dependency("solana_program_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const sol_mod = sol_dep.module("solana_program_sdk");

    const spl_ata_mod = b.addModule("spl_ata", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "solana_program_sdk", .module = sol_mod },
        },
    });

    const tests = b.addTest(.{ .root_module = spl_ata_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run host-side unit tests");
    test_step.dependOn(&run_tests.step);
}
