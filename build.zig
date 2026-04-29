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

    const runtime_account_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/account.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_account_tests = b.addTest(.{
        .root_module = runtime_account_test_module,
    });
    const run_runtime_account_tests = b.addRunArtifact(runtime_account_tests);

    const runtime_prelude_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/prelude.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_prelude_tests = b.addTest(.{
        .root_module = runtime_prelude_test_module,
    });
    const run_runtime_prelude_tests = b.addRunArtifact(runtime_prelude_tests);

    // Determinism property test (F16 / G09): runs every .ml in examples/
    // through both interpreter and Zig native, byte-diffs the results.
    const determinism_test_module = b.createModule(.{
        .root_source_file = b.path("tests/property/determinism.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Pass the absolute path to omlz so the test can invoke it as a subprocess
    // regardless of the test runner's working directory.
    const det_options = b.addOptions();
    // b.path().getPath() resolves to an absolute path joined with the build root.
    const omlz_abs = b.path("zig-out/bin/omlz").getPath(b);
    const test_util_module = b.createModule(.{
        .root_source_file = b.path("tests/test_util.zig"),
        .target = target,
        .optimize = optimize,
    });
    det_options.addOption([]const u8, "omlz_bin", omlz_abs);
    determinism_test_module.addOptions("det_options", det_options);
    determinism_test_module.addImport("test_util", test_util_module);
    const determinism_tests = b.addTest(.{
        .root_module = determinism_test_module,
    });
    const run_determinism_tests = b.addRunArtifact(determinism_tests);
    // The determinism harness invokes `omlz` as a subprocess, so omlz
    // (and zxc-frontend) must be built before the test runs.
    run_determinism_tests.step.dependOn(b.getInstallStep());
    // Set working directory to the project root so relative paths resolve.
    run_determinism_tests.setCwd(b.path(""));

    // Golden tests (F17 / G10): verify Core IR pretty-printer output
    // matches committed `.core.snapshot` files in tests/golden/.
    const golden_test_module = b.createModule(.{
        .root_source_file = b.path("tests/golden/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    const golden_options = b.addOptions();
    golden_options.addOption([]const u8, "omlz_bin", omlz_abs);
    golden_test_module.addOptions("golden_options", golden_options);
    golden_test_module.addImport("test_util", test_util_module);
    const golden_tests = b.addTest(.{
        .root_module = golden_test_module,
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);
    // The golden harness invokes `omlz` as a subprocess, so omlz
    // (and zxc-frontend) must be built before the test runs.
    run_golden_tests.step.dependOn(b.getInstallStep());
    // Set working directory to the project root so relative paths resolve.
    run_golden_tests.setCwd(b.path(""));

    // UI tests (F18 / G11): end-to-end `omlz run` checks against `.expected`
    // files in tests/ui/.  Positive tests (exit 0) diff stdout; negative tests
    // (exit non-zero) diff stderr.
    const ui_test_module = b.createModule(.{
        .root_source_file = b.path("tests/ui/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ui_options = b.addOptions();
    ui_options.addOption([]const u8, "omlz_bin", omlz_abs);
    ui_test_module.addOptions("ui_options", ui_options);
    ui_test_module.addImport("test_util", test_util_module);
    const ui_tests = b.addTest(.{
        .root_module = ui_test_module,
    });
    const run_ui_tests = b.addRunArtifact(ui_tests);
    // The UI harness invokes `omlz` as a subprocess, so omlz
    // (and zxc-frontend) must be built before the test runs.
    run_ui_tests.step.dependOn(b.getInstallStep());
    // Set working directory to the project root so relative paths resolve.
    run_ui_tests.setCwd(b.path(""));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_runtime_arena_tests.step);
    test_step.dependOn(&run_runtime_account_tests.step);
    test_step.dependOn(&run_runtime_prelude_tests.step);
    test_step.dependOn(&run_determinism_tests.step);
    test_step.dependOn(&run_golden_tests.step);
    test_step.dependOn(&run_ui_tests.step);
}
