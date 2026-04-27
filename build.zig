//! Single build driver for the ZxCaml walking skeleton.
//!
//! RESPONSIBILITIES:
//! - Build and install the `omlz` executable from `src/main.zig`.
//! - Build and install the OCaml `zxc-frontend` glue via ocamlfind.
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

    const frontend_output = b.getInstallPath(.bin, "zxc-frontend");
    const install_bin_dir = std.fs.path.dirname(frontend_output).?;
    const make_install_bin = b.addSystemCommand(&.{ "mkdir", "-p", install_bin_dir });
    const frontend = b.addSystemCommand(&.{
        "opam",
        "exec",
        "--switch=zxcaml-p1",
        "--",
        "ocamlfind",
        "ocamlopt",
        "-package",
        "compiler-libs.common",
        "-linkpkg",
        "-I",
        "src/frontend",
        "src/frontend/zxc_subset.ml",
        "src/frontend/zxc_sexp.ml",
        "src/frontend/zxc_frontend.ml",
        "-o",
        frontend_output,
    });
    frontend.step.dependOn(&make_install_bin.step);
    const cleanup_frontend = b.addSystemCommand(&.{
        "rm",
        "-f",
        "src/frontend/zxc_subset.cmi",
        "src/frontend/zxc_subset.cmx",
        "src/frontend/zxc_subset.o",
        "src/frontend/zxc_sexp.cmi",
        "src/frontend/zxc_sexp.cmx",
        "src/frontend/zxc_sexp.o",
        "src/frontend/zxc_frontend.cmi",
        "src/frontend/zxc_frontend.cmx",
        "src/frontend/zxc_frontend.o",
    });
    cleanup_frontend.step.dependOn(&frontend.step);
    b.getInstallStep().dependOn(&cleanup_frontend.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const runtime_arena_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/arena.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_arena_tests = b.addTest(.{
        .root_module = runtime_arena_test_module,
    });
    const run_runtime_arena_tests = b.addRunArtifact(runtime_arena_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_runtime_arena_tests.step);
}
