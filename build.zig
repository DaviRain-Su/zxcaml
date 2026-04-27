//! Single build driver for the ZxCaml walking skeleton.
//!
//! RESPONSIBILITIES:
//! - Build and install the `omlz` executable from `src/main.zig`.
//! - Keep the default target on the host until BPF wiring lands later.
//! - Expose a `zig build test` step for future unit tests.

const std = @import("std");
const manifest = @import("build.zig.zon");

/// Defines the build graph for the `omlz` compiler driver.
pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "omlz",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
