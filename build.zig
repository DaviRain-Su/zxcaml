//! Single build driver for the ZxCaml walking skeleton.
//!
//! RESPONSIBILITIES:
//! - Build and install the `omlz` executable from `src/main.zig`.
//! - Build and install the OCaml `zxc-frontend` glue via ocamlfind.
//! - Keep the default target on the host until BPF wiring lands later.
//! - Expose a `zig build test` step for future unit tests.

const std = @import("std");
const manifest = @import("build.zig.zon");

const frontend_sources = [_][]const u8{
    "src/frontend/zxc_subset.ml",
    "src/frontend/zxc_sexp.ml",
    "src/frontend/zxc_frontend.ml",
};

const frontend_artifact_extensions = [_][]const u8{
    ".cmi",
    ".cmx",
    ".o",
};

fn appendArg(args: *std.ArrayList([]const u8), allocator: std.mem.Allocator, arg: []const u8) void {
    args.append(allocator, arg) catch @panic("out of memory while constructing build command");
}

fn appendArgs(args: *std.ArrayList([]const u8), allocator: std.mem.Allocator, more_args: []const []const u8) void {
    args.appendSlice(allocator, more_args) catch @panic("out of memory while constructing build command");
}

fn appendFrontendArtifactCleanupArgs(args: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    for (frontend_sources) |source| {
        if (!std.mem.endsWith(u8, source, ".ml")) {
            @panic("frontend source paths must end in .ml");
        }

        const source_without_ext = source[0 .. source.len - ".ml".len];
        for (frontend_artifact_extensions) |extension| {
            const artifact = std.fmt.allocPrint(
                allocator,
                "{s}{s}",
                .{ source_without_ext, extension },
            ) catch @panic("out of memory while constructing frontend cleanup command");
            appendArg(args, allocator, artifact);
        }
    }
}

/// Defines the build graph for the `omlz` compiler driver.
pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    const optimize = b.standardOptimizeOption(.{});
    const inline_max_nodes = b.option(
        usize,
        "inline_max_nodes",
        "Maximum Core IR nodes in a function body eligible for inlining",
    ) orelse 3;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);
    build_options.addOption(usize, "inline_max_nodes", inline_max_nodes);

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

    const install_omlz = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_omlz.step);

    const lsp_root_module = b.createModule(.{
        .root_source_file = b.path("src/lsp/lsp_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_root_module.addOptions("build_options", build_options);

    const lsp_exe = b.addExecutable(.{
        .name = "omlz-lsp",
        .root_module = lsp_root_module,
    });

    const frontend_output = b.getInstallPath(.bin, "zxc-frontend");
    const install_bin_dir = std.fs.path.dirname(frontend_output).?;
    const make_install_bin = b.addSystemCommand(&.{ "mkdir", "-p", install_bin_dir });

    var frontend_args = std.ArrayList([]const u8).empty;
    appendArgs(&frontend_args, b.allocator, &.{
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
    });
    appendArgs(&frontend_args, b.allocator, &frontend_sources);
    appendArgs(&frontend_args, b.allocator, &.{
        "-o",
        frontend_output,
    });
    const frontend = b.addSystemCommand(frontend_args.items);
    frontend.step.dependOn(&make_install_bin.step);

    var cleanup_frontend_args = std.ArrayList([]const u8).empty;
    appendArgs(&cleanup_frontend_args, b.allocator, &.{ "rm", "-f" });
    appendFrontendArtifactCleanupArgs(&cleanup_frontend_args, b.allocator);
    const cleanup_frontend = b.addSystemCommand(cleanup_frontend_args.items);
    cleanup_frontend.step.dependOn(&frontend.step);
    b.getInstallStep().dependOn(&cleanup_frontend.step);

    const install_lsp = b.addInstallArtifact(lsp_exe, .{});
    install_lsp.step.dependOn(&cleanup_frontend.step);
    b.getInstallStep().dependOn(&install_lsp.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.step.dependOn(b.getInstallStep());

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

    const runtime_syscalls_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/syscalls.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_syscalls_tests = b.addTest(.{
        .root_module = runtime_syscalls_test_module,
    });
    const run_runtime_syscalls_tests = b.addRunArtifact(runtime_syscalls_tests);

    const runtime_cpi_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/cpi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_cpi_tests = b.addTest(.{
        .root_module = runtime_cpi_test_module,
    });
    const run_runtime_cpi_tests = b.addRunArtifact(runtime_cpi_tests);

    const runtime_spl_token_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/spl_token.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_spl_token_tests = b.addTest(.{
        .root_module = runtime_spl_token_test_module,
    });
    const run_runtime_spl_token_tests = b.addRunArtifact(runtime_spl_token_tests);

    const runtime_prelude_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/prelude.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_prelude_tests = b.addTest(.{
        .root_module = runtime_prelude_test_module,
    });
    const run_runtime_prelude_tests = b.addRunArtifact(runtime_prelude_tests);

    const core_no_alloc_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/no_alloc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_no_alloc_tests = b.addTest(.{
        .root_module = core_no_alloc_test_module,
    });
    const run_core_no_alloc_tests = b.addRunArtifact(core_no_alloc_tests);

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

    // IDL tests (G34): verify `omlz idl` emits valid JSON with the expected
    // instruction, account, argument, type, and error-code sections.
    const idl_test_module = b.createModule(.{
        .root_source_file = b.path("tests/idl/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    const idl_options = b.addOptions();
    idl_options.addOption([]const u8, "omlz_bin", omlz_abs);
    idl_test_module.addOptions("idl_options", idl_options);
    const idl_tests = b.addTest(.{
        .root_module = idl_test_module,
    });
    const run_idl_tests = b.addRunArtifact(idl_tests);
    // The IDL harness invokes `omlz` as a subprocess, so omlz
    // (and zxc-frontend) must be built before the test runs.
    run_idl_tests.step.dependOn(b.getInstallStep());
    // Set working directory to the project root so relative paths resolve.
    run_idl_tests.setCwd(b.path(""));

    // CLI tests (Phase 6 / F-E1): verify user-facing command help surfaces.
    const cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/help_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "omlz_bin", omlz_abs);
    cli_test_module.addOptions("cli_options", cli_options);
    const cli_tests = b.addTest(.{
        .root_module = cli_test_module,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    // The CLI harness invokes `omlz` as a subprocess, so omlz
    // (and zxc-frontend) must be built before the test runs.
    run_cli_tests.step.dependOn(b.getInstallStep());
    // Set working directory to the project root so relative paths resolve.
    run_cli_tests.setCwd(b.path(""));

    // LSP scaffold tests (P9 / F-LSP-1): verify omlz-lsp entrypoint and install.
    const lsp_scaffold_test_module = b.createModule(.{
        .root_source_file = b.path("tests/lsp/scaffold_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_scaffold_test_module.addOptions("build_options", build_options);
    lsp_scaffold_test_module.addImport("lsp_main", lsp_root_module);
    const lsp_scaffold_tests = b.addTest(.{
        .root_module = lsp_scaffold_test_module,
    });
    const run_lsp_scaffold_tests = b.addRunArtifact(lsp_scaffold_tests);
    run_lsp_scaffold_tests.step.dependOn(b.getInstallStep());
    run_lsp_scaffold_tests.setCwd(b.path(""));

    // LSP JSON-RPC framing tests (P9 / F-LSP-2): verify Content-Length
    // reader/writer behavior before later protocol handlers rely on it.
    const lsp_jsonrpc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/jsonrpc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lsp_jsonrpc_tests = b.addRunArtifact(lsp_jsonrpc_tests);
    run_lsp_jsonrpc_tests.setCwd(b.path(""));

    // End-to-end LSP harness (P9 / F-LSP-7): exercise every Python stdlib
    // client scenario through the installed omlz-lsp binary.  The harness
    // invokes both zig-out/bin/omlz-lsp and omlz check, so depend explicitly
    // on the install steps for both user-facing binaries.
    const run_lsp_harness = b.addSystemCommand(&.{ "python3", "tests/lsp/run_lsp_check.py", "all" });
    run_lsp_harness.step.dependOn(&install_omlz.step);
    run_lsp_harness.step.dependOn(&install_lsp.step);

    // Renderer tests (P9 / F-DX1-1): verify rustc-style diagnostic rendering.
    const render_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/render_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const render_module = b.createModule(.{
        .root_source_file = b.path("src/util/render.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_test_module.addImport("render", render_module);
    const render_tests = b.addTest(.{
        .root_module = render_test_module,
    });
    const run_render_tests = b.addRunArtifact(render_tests);
    run_render_tests.setCwd(b.path(""));

    // Frontend bridge tests (P9 / F-DX2-2): verify wire 1.1/1.2 loc compatibility.
    const bridge_wire_compat_test_module = b.createModule(.{
        .root_source_file = b.path("tests/frontend_bridge/wire_loc_compat_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ttree_module = b.createModule(.{
        .root_source_file = b.path("src/frontend_bridge/ttree.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_wire_compat_test_module.addImport("ttree", ttree_module);
    const bridge_wire_compat_tests = b.addTest(.{
        .root_module = bridge_wire_compat_test_module,
    });
    const run_bridge_wire_compat_tests = b.addRunArtifact(bridge_wire_compat_tests);
    run_bridge_wire_compat_tests.setCwd(b.path(""));

    // Core IR loc tests (P9 / F-DX2-3): verify wire loc survives Core passes
    // while the default Core IR printer remains loc-free.
    const core_loc_test_module = b.createModule(.{
        .root_source_file = b.path("core_loc_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_loc_options = b.addOptions();
    core_loc_options.addOption([]const u8, "zxc_frontend_bin", b.path("zig-out/bin/zxc-frontend").getPath(b));
    core_loc_options.addOption([]const u8, "omlz_bin", omlz_abs);
    core_loc_test_module.addOptions("core_loc_options", core_loc_options);
    core_loc_test_module.addOptions("build_options", build_options);
    const core_loc_tests = b.addTest(.{
        .root_module = core_loc_test_module,
    });
    const run_core_loc_tests = b.addRunArtifact(core_loc_tests);
    run_core_loc_tests.step.dependOn(b.getInstallStep());
    run_core_loc_tests.setCwd(b.path(""));

    // Source-map schema tests (P9 / F-SRCMAP-1): verify deterministic JSON
    // shape and parser validation before the BPF builder starts emitting maps.
    const srcmap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/driver/srcmap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_srcmap_tests = b.addRunArtifact(srcmap_tests);
    run_srcmap_tests.setCwd(b.path(""));

    // Codegen regression tests: compile focused `.ml` cases and inspect the
    // emitted Zig source.
    const codegen_external_bytes_test_module = b.createModule(.{
        .root_source_file = b.path("tests/codegen/external_bytes_return.zig"),
        .target = target,
        .optimize = optimize,
    });
    const codegen_options = b.addOptions();
    codegen_options.addOption([]const u8, "omlz_bin", omlz_abs);
    codegen_external_bytes_test_module.addOptions("codegen_options", codegen_options);
    const codegen_external_bytes_tests = b.addTest(.{
        .root_module = codegen_external_bytes_test_module,
    });
    const run_codegen_external_bytes_tests = b.addRunArtifact(codegen_external_bytes_tests);
    // This harness invokes `omlz build`, which writes out/program.zig. Keep it
    // after the determinism harness, which also exercises native builds.
    run_codegen_external_bytes_tests.step.dependOn(&run_determinism_tests.step);
    run_codegen_external_bytes_tests.step.dependOn(b.getInstallStep());
    run_codegen_external_bytes_tests.setCwd(b.path(""));

    const codegen_region_let_storage_test_module = b.createModule(.{
        .root_source_file = b.path("tests/codegen/region_let_storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_region_let_storage_test_module.addOptions("codegen_options", codegen_options);
    const codegen_region_let_storage_tests = b.addTest(.{
        .root_module = codegen_region_let_storage_test_module,
    });
    const run_codegen_region_let_storage_tests = b.addRunArtifact(codegen_region_let_storage_tests);
    run_codegen_region_let_storage_tests.step.dependOn(&run_codegen_external_bytes_tests.step);
    run_codegen_region_let_storage_tests.step.dependOn(b.getInstallStep());
    run_codegen_region_let_storage_tests.setCwd(b.path(""));

    const codegen_pattern_extensions_test_module = b.createModule(.{
        .root_source_file = b.path("tests/codegen/pattern_extensions.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_pattern_extensions_test_module.addOptions("codegen_options", codegen_options);
    const codegen_pattern_extensions_tests = b.addTest(.{
        .root_module = codegen_pattern_extensions_test_module,
    });
    const run_codegen_pattern_extensions_tests = b.addRunArtifact(codegen_pattern_extensions_tests);
    run_codegen_pattern_extensions_tests.step.dependOn(&run_codegen_region_let_storage_tests.step);
    run_codegen_pattern_extensions_tests.step.dependOn(b.getInstallStep());
    run_codegen_pattern_extensions_tests.setCwd(b.path(""));

    const anf_test_module = b.createModule(.{
        .root_source_file = b.path("anf_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const anf_tests = b.addTest(.{
        .root_module = anf_test_module,
    });
    const run_anf_tests = b.addRunArtifact(anf_tests);

    const inline_test_module = b.createModule(.{
        .root_source_file = b.path("inline_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    inline_test_module.addOptions("build_options", build_options);
    const inline_tests = b.addTest(.{
        .root_module = inline_test_module,
    });
    const run_inline_tests = b.addRunArtifact(inline_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_anf_tests.step);
    test_step.dependOn(&run_inline_tests.step);
    test_step.dependOn(&run_runtime_arena_tests.step);
    test_step.dependOn(&run_runtime_account_tests.step);
    test_step.dependOn(&run_runtime_syscalls_tests.step);
    test_step.dependOn(&run_runtime_cpi_tests.step);
    test_step.dependOn(&run_runtime_spl_token_tests.step);
    test_step.dependOn(&run_runtime_prelude_tests.step);
    test_step.dependOn(&run_core_no_alloc_tests.step);
    test_step.dependOn(&run_determinism_tests.step);
    test_step.dependOn(&run_golden_tests.step);
    test_step.dependOn(&run_ui_tests.step);
    test_step.dependOn(&run_idl_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_lsp_scaffold_tests.step);
    test_step.dependOn(&run_lsp_jsonrpc_tests.step);
    test_step.dependOn(&run_lsp_harness.step);
    test_step.dependOn(&run_render_tests.step);
    test_step.dependOn(&run_bridge_wire_compat_tests.step);
    test_step.dependOn(&run_core_loc_tests.step);
    test_step.dependOn(&run_srcmap_tests.step);
    test_step.dependOn(&run_codegen_external_bytes_tests.step);
    test_step.dependOn(&run_codegen_region_let_storage_tests.step);
    test_step.dependOn(&run_codegen_pattern_extensions_tests.step);
}
