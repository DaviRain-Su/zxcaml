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
    // std.c.clock_gettime requires explicit libc linkage on Linux (Zig 0.16+).
    if (target.result.os.tag == .linux) {
        exe.root_module.link_libc = true;
    }

    const install_omlz = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_omlz.step);

    const lsp_root_module = b.createModule(.{
        .root_source_file = b.path("src/lsp/lsp_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_root_module.addOptions("build_options", build_options);
    lsp_root_module.addImport("frontend_fmt", b.createModule(.{
        .root_source_file = b.path("src/frontend/fmt.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const lsp_exe = b.addExecutable(.{
        .name = "omlz-lsp",
        .root_module = lsp_root_module,
    });

    const lsp_bench_module = b.createModule(.{
        .root_source_file = b.path("tests/lsp/lsp_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lsp_bench_exe = b.addExecutable(.{
        .name = "lsp-bench",
        .root_module = lsp_bench_module,
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

    const install_lsp_bench = b.addInstallArtifact(lsp_bench_exe, .{});
    install_lsp_bench.step.dependOn(&install_lsp.step);
    b.getInstallStep().dependOn(&install_lsp_bench.step);

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

    const runtime_sysvar_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/sysvar.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_sysvar_tests = b.addTest(.{
        .root_module = runtime_sysvar_test_module,
    });
    const run_runtime_sysvar_tests = b.addRunArtifact(runtime_sysvar_tests);

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

    const runtime_ata_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/ata_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_ata_tests = b.addTest(.{
        .name = "runtime-ata-test",
        .root_module = runtime_ata_test_module,
    });
    const run_runtime_ata_tests = b.addRunArtifact(runtime_ata_tests);

    const vendored_solana_program_sdk_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/sdk/solana_program_sdk_m4.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vendored_solana_sdk_m2_module = b.createModule(.{
        .root_source_file = b.path("vendor/solana-program-sdk-zig/src/zxcaml_m2_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vendored_solana_program_sdk_module.addImport("solana_sdk_m2", vendored_solana_sdk_m2_module);
    const vendored_solana_codec_module = b.createModule(.{
        .root_source_file = b.path("vendor/solana-program-sdk-zig/packages/solana-codec/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vendored_solana_codec_module.addImport("solana_program_sdk", vendored_solana_program_sdk_module);
    const vendored_spl_token_module = b.createModule(.{
        .root_source_file = b.path("vendor/solana-program-sdk-zig/packages/spl-token/src/zxcaml_m4_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vendored_spl_token_module.addImport("solana_program_sdk", vendored_solana_program_sdk_module);
    vendored_spl_token_module.addImport("solana_codec", vendored_solana_codec_module);
    const vendored_spl_ata_module = b.createModule(.{
        .root_source_file = b.path("vendor/solana-program-sdk-zig/packages/spl-ata/src/zxcaml_m4_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vendored_spl_ata_module.addImport("solana_program_sdk", vendored_solana_program_sdk_module);

    const vendored_sdk_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/sdk/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vendored_sdk_module.addImport("solana_sdk_m2", vendored_solana_sdk_m2_module);
    runtime_syscalls_test_module.addImport("vendored_sdk", vendored_sdk_module);
    runtime_sysvar_test_module.addImport("vendored_sdk", vendored_sdk_module);
    runtime_cpi_test_module.addImport("vendored_sdk", vendored_sdk_module);
    runtime_spl_token_test_module.addImport("vendored_sdk", vendored_sdk_module);
    runtime_ata_test_module.addImport("vendored_sdk", vendored_sdk_module);
    runtime_spl_token_test_module.addImport("solana_program_sdk", vendored_solana_program_sdk_module);
    runtime_spl_token_test_module.addImport("solana_codec", vendored_solana_codec_module);
    runtime_spl_token_test_module.addImport("spl_token_m4", vendored_spl_token_module);
    runtime_ata_test_module.addImport("solana_program_sdk", vendored_solana_program_sdk_module);
    runtime_ata_test_module.addImport("solana_codec", vendored_solana_codec_module);
    runtime_ata_test_module.addImport("spl_token_m4", vendored_spl_token_module);
    runtime_ata_test_module.addImport("spl_ata_m4", vendored_spl_ata_module);

    const vendored_sdk_import_smoke_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/sdk/import_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    vendored_sdk_import_smoke_module.addImport("vendored_sdk", vendored_sdk_module);
    const vendored_sdk_import_smoke_tests = b.addTest(.{
        .name = "vendored-sdk-import-smoke",
        .root_module = vendored_sdk_import_smoke_module,
    });
    const run_vendored_sdk_import_smoke_tests = b.addRunArtifact(vendored_sdk_import_smoke_tests);
    const vendored_sdk_import_smoke_step = b.step("vendored-sdk-import-smoke", "Run vendored SDK import smoke tests");
    vendored_sdk_import_smoke_step.dependOn(&run_vendored_sdk_import_smoke_tests.step);

    const runtime_programs_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/programs_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_programs_test_module.addImport("vendored_sdk", vendored_sdk_module);
    runtime_programs_test_module.addImport("solana_program_sdk", vendored_solana_program_sdk_module);
    runtime_programs_test_module.addImport("solana_codec", vendored_solana_codec_module);
    runtime_programs_test_module.addImport("spl_token_m4", vendored_spl_token_module);
    runtime_programs_test_module.addImport("spl_ata_m4", vendored_spl_ata_module);
    const runtime_programs_tests = b.addTest(.{
        .name = "runtime-programs-test",
        .root_module = runtime_programs_test_module,
    });
    const run_runtime_programs_tests = b.addRunArtifact(runtime_programs_tests);

    const runtime_bs58_test_module = b.createModule(.{
        .root_source_file = b.path("runtime/zig/bs58.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_bs58_tests = b.addTest(.{
        .name = "runtime-bs58-test",
        .root_module = runtime_bs58_test_module,
    });
    const run_runtime_bs58_tests = b.addRunArtifact(runtime_bs58_tests);

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

    // OTEST2 property-test golden snapshots live in a subdirectory so the
    // sealed M-OTEST snapshots remain untouched.
    const otest_prop_golden_test_module = b.createModule(.{
        .root_source_file = b.path("tests/golden/otest_prop/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    otest_prop_golden_test_module.addOptions("golden_options", golden_options);
    otest_prop_golden_test_module.addImport("test_util", test_util_module);
    const otest_prop_golden_tests = b.addTest(.{
        .root_module = otest_prop_golden_test_module,
    });
    const run_otest_prop_golden_tests = b.addRunArtifact(otest_prop_golden_tests);
    run_otest_prop_golden_tests.step.dependOn(b.getInstallStep());
    run_otest_prop_golden_tests.step.dependOn(&run_golden_tests.step);
    run_otest_prop_golden_tests.setCwd(b.path(""));

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

    // OTEST CLI integration tests: verify `omlz test` discovery, reporting,
    // filtering, JSON Lines output, colors, and exit codes.
    const otest_cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/omlz_test_subcommand_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const otest_cli_tests = b.addTest(.{
        .root_module = otest_cli_test_module,
    });
    const run_otest_cli_tests = b.addRunArtifact(otest_cli_tests);
    run_otest_cli_tests.step.dependOn(b.getInstallStep());
    run_otest_cli_tests.step.dependOn(&run_cli_tests.step);
    run_otest_cli_tests.setCwd(b.path(""));

    // FMT CLI integration tests: verify `omlz fmt` help, stdout, check,
    // write, stdin, JSON summary, directory recursion, and exit-code behavior.
    const fmt_cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/omlz_fmt_subcommand_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fmt_cli_options = b.addOptions();
    fmt_cli_options.addOption([]const u8, "omlz_bin", omlz_abs);
    fmt_cli_test_module.addOptions("cli_options", fmt_cli_options);
    const fmt_cli_tests = b.addTest(.{
        .root_module = fmt_cli_test_module,
    });
    const run_fmt_cli_tests = b.addRunArtifact(fmt_cli_tests);
    run_fmt_cli_tests.step.dependOn(b.getInstallStep());
    run_fmt_cli_tests.step.dependOn(&run_otest_cli_tests.step);
    run_fmt_cli_tests.setCwd(b.path(""));

    // LSP bench CLI integration tests (LSPFIX2 / F-LSPFIX2-4): verify the
    // `omlz lsp-bench` wrapper help, defaults, forwarded flags, and env
    // threshold propagation.
    const omlz_lsp_bench_cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/omlz_lsp_bench_subcommand_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const omlz_lsp_bench_cli_options = b.addOptions();
    omlz_lsp_bench_cli_options.addOption([]const u8, "omlz_bin", omlz_abs);
    omlz_lsp_bench_cli_test_module.addOptions("cli_options", omlz_lsp_bench_cli_options);
    const omlz_lsp_bench_cli_tests = b.addTest(.{
        .root_module = omlz_lsp_bench_cli_test_module,
    });
    const run_omlz_lsp_bench_cli_tests = b.addRunArtifact(omlz_lsp_bench_cli_tests);
    run_omlz_lsp_bench_cli_tests.step.dependOn(b.getInstallStep());
    run_omlz_lsp_bench_cli_tests.step.dependOn(&run_fmt_cli_tests.step);
    run_omlz_lsp_bench_cli_tests.setCwd(b.path(""));

    // FMT golden idempotency tests (FMT / F-FMT3): verify committed
    // input/expected pairs are byte-stable under `omlz fmt`.
    const fmt_golden_test_module = b.createModule(.{
        .root_source_file = b.path("tests/omlz_fmt_golden_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fmt_golden_options = b.addOptions();
    fmt_golden_options.addOption([]const u8, "omlz_bin", omlz_abs);
    fmt_golden_test_module.addOptions("cli_options", fmt_golden_options);
    const fmt_golden_tests = b.addTest(.{
        .root_module = fmt_golden_test_module,
    });
    const run_fmt_golden_tests = b.addRunArtifact(fmt_golden_tests);
    run_fmt_golden_tests.step.dependOn(b.getInstallStep());
    run_fmt_golden_tests.step.dependOn(&run_fmt_cli_tests.step);
    run_fmt_golden_tests.setCwd(b.path(""));

    // OTEST parser regression tests: verify frontend pre-scan behavior for
    // comment-contained let% text before the CLI runner executes.
    const parser_otest_test_module = b.createModule(.{
        .root_source_file = b.path("tests/parser_otest_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_otest_tests = b.addTest(.{
        .root_module = parser_otest_test_module,
    });
    const run_parser_otest_tests = b.addRunArtifact(parser_otest_tests);
    run_parser_otest_tests.step.dependOn(b.getInstallStep());
    run_parser_otest_tests.step.dependOn(&run_otest_cli_tests.step);
    run_parser_otest_tests.setCwd(b.path(""));

    // OTEST2 property parser regression tests: accept top-level let%test_prop
    // and reject malformed names/generators/body patterns before runner wiring.
    const parser_otest_prop_test_module = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/otest_prop/parser_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_otest_prop_tests = b.addTest(.{
        .root_module = parser_otest_prop_test_module,
    });
    const run_parser_otest_prop_tests = b.addRunArtifact(parser_otest_prop_tests);
    run_parser_otest_prop_tests.step.dependOn(b.getInstallStep());
    run_parser_otest_prop_tests.step.dependOn(&run_parser_otest_tests.step);
    run_parser_otest_prop_tests.setCwd(b.path(""));

    // OTEST2 generator stdlib regression tests: compile stdlib/generators.ml
    // with upstream OCaml and exercise deterministic sampling/combinators.
    const property_generators_test_module = b.createModule(.{
        .root_source_file = b.path("tests/property_generators_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const property_generators_tests = b.addTest(.{
        .root_module = property_generators_test_module,
    });
    const run_property_generators_tests = b.addRunArtifact(property_generators_tests);
    run_property_generators_tests.step.dependOn(&run_parser_otest_prop_tests.step);
    run_property_generators_tests.setCwd(b.path(""));

    // OTEST2 shrinking stdlib regression tests: compile stdlib/generators.ml
    // with upstream OCaml and exercise deterministic shrink convergence.
    const property_shrinking_test_module = b.createModule(.{
        .root_source_file = b.path("tests/property_shrinking_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const property_shrinking_tests = b.addTest(.{
        .root_module = property_shrinking_test_module,
    });
    const run_property_shrinking_tests = b.addRunArtifact(property_shrinking_tests);
    run_property_shrinking_tests.step.dependOn(&run_property_generators_tests.step);
    run_property_shrinking_tests.setCwd(b.path(""));

    // CLI explanation tests (P9.5 / F-OBS1): verify `omlz check --explain`
    // covers the diagnostics catalog and reports unknown codes cleanly.
    const explain_cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/explain_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const explain_cli_options = b.addOptions();
    explain_cli_options.addOption([]const u8, "omlz_bin", omlz_abs);
    explain_cli_test_module.addOptions("cli_options", explain_cli_options);
    const explain_cli_tests = b.addTest(.{
        .root_module = explain_cli_test_module,
    });
    const run_explain_cli_tests = b.addRunArtifact(explain_cli_tests);
    run_explain_cli_tests.step.dependOn(b.getInstallStep());
    run_explain_cli_tests.setCwd(b.path(""));

    // Benchmark CLI integration tests (P9.5 / F-OBS2): verify the default
    // local BPF timing table and cleanup behavior.
    const bench_cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/bench_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_cli_options = b.addOptions();
    bench_cli_options.addOption([]const u8, "omlz_bin", omlz_abs);
    bench_cli_test_module.addOptions("cli_options", bench_cli_options);
    const bench_cli_tests = b.addTest(.{
        .root_module = bench_cli_test_module,
    });
    const run_bench_cli_tests = b.addRunArtifact(bench_cli_tests);
    run_bench_cli_tests.step.dependOn(b.getInstallStep());
    // Bench writes the shared generated sources under out/, so keep it
    // serialized with determinism and the other CLI tests that spawn
    // `omlz build`.
    run_bench_cli_tests.step.dependOn(&run_determinism_tests.step);
    run_bench_cli_tests.step.dependOn(&run_explain_cli_tests.step);
    run_bench_cli_tests.setCwd(b.path(""));

    // Doctor CLI integration tests (P9.5 / F-OBS3): verify local toolchain
    // self-check output and help behavior.
    const doctor_cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/doctor_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const doctor_cli_options = b.addOptions();
    doctor_cli_options.addOption([]const u8, "omlz_bin", omlz_abs);
    doctor_cli_test_module.addOptions("cli_options", doctor_cli_options);
    const doctor_cli_tests = b.addTest(.{
        .root_module = doctor_cli_test_module,
    });
    const run_doctor_cli_tests = b.addRunArtifact(doctor_cli_tests);
    run_doctor_cli_tests.step.dependOn(b.getInstallStep());
    run_doctor_cli_tests.step.dependOn(&run_bench_cli_tests.step);
    run_doctor_cli_tests.setCwd(b.path(""));

    // Static profiling report CLI integration tests (R5):
    // verify `omlz check --report=<kinds>` emits deterministic CU/stack
    // sections, rejects unknown kinds with E0200, and matches the golden
    // snapshot for the factorial example.
    const report_cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/report_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const report_cli_options = b.addOptions();
    report_cli_options.addOption([]const u8, "omlz_bin", omlz_abs);
    report_cli_test_module.addOptions("cli_options", report_cli_options);
    const report_cli_tests = b.addTest(.{
        .root_module = report_cli_test_module,
    });
    const run_report_cli_tests = b.addRunArtifact(report_cli_tests);
    run_report_cli_tests.step.dependOn(b.getInstallStep());
    run_report_cli_tests.step.dependOn(&run_doctor_cli_tests.step);
    run_report_cli_tests.setCwd(b.path(""));

    // Source-map CLI integration tests (P9 / F-SRCMAP-3): verify BPF builds
    // emit deterministic sidecar maps by default and honor --no-srcmap.
    const srcmap_cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/srcmap_build_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const srcmap_cli_options = b.addOptions();
    srcmap_cli_options.addOption([]const u8, "omlz_bin", omlz_abs);
    srcmap_cli_test_module.addOptions("cli_options", srcmap_cli_options);
    const srcmap_module = b.createModule(.{
        .root_source_file = b.path("src/driver/srcmap.zig"),
        .target = target,
        .optimize = optimize,
    });
    srcmap_cli_test_module.addImport("srcmap", srcmap_module);
    const srcmap_cli_tests = b.addTest(.{
        .root_module = srcmap_cli_test_module,
    });
    const run_srcmap_cli_tests = b.addRunArtifact(srcmap_cli_tests);
    run_srcmap_cli_tests.step.dependOn(b.getInstallStep());
    // Avoid concurrent tests racing on out/program.zig.
    run_srcmap_cli_tests.step.dependOn(&run_determinism_tests.step);
    run_srcmap_cli_tests.step.dependOn(&run_doctor_cli_tests.step);
    run_srcmap_cli_tests.step.dependOn(&run_report_cli_tests.step);
    run_srcmap_cli_tests.setCwd(b.path(""));

    // Source-map unmap CLI integration tests (P9 / F-SRCMAP-5): verify
    // reverse PC lookup from both sidecar JSON and embedded ELF section.
    const unmap_cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/unmap_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unmap_cli_options = b.addOptions();
    unmap_cli_options.addOption([]const u8, "omlz_bin", omlz_abs);
    unmap_cli_test_module.addOptions("cli_options", unmap_cli_options);
    unmap_cli_test_module.addImport("srcmap", srcmap_module);
    const unmap_cli_tests = b.addTest(.{
        .root_module = unmap_cli_test_module,
    });
    const run_unmap_cli_tests = b.addRunArtifact(unmap_cli_tests);
    run_unmap_cli_tests.step.dependOn(b.getInstallStep());
    // Reuse the source-map build harness ordering to avoid races on out/program.zig.
    run_unmap_cli_tests.step.dependOn(&run_srcmap_cli_tests.step);
    run_unmap_cli_tests.setCwd(b.path(""));

    // Direct BPF build characterization tests (M1): verify SOLANA_ZIG override
    // semantics, current generated Zig refresh, and sidecar/unmap behavior.
    const bpf_build_contract_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/bpf_build_contract_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bpf_build_contract_options = b.addOptions();
    bpf_build_contract_options.addOption([]const u8, "omlz_bin", omlz_abs);
    bpf_build_contract_test_module.addOptions("cli_options", bpf_build_contract_options);
    bpf_build_contract_test_module.addImport("srcmap", srcmap_module);
    const bpf_build_contract_tests = b.addTest(.{
        .root_module = bpf_build_contract_test_module,
    });
    const run_bpf_build_contract_tests = b.addRunArtifact(bpf_build_contract_tests);
    run_bpf_build_contract_tests.step.dependOn(b.getInstallStep());
    run_bpf_build_contract_tests.step.dependOn(&run_unmap_cli_tests.step);
    run_bpf_build_contract_tests.setCwd(b.path(""));

    // Generic WASM build characterization tests (MTF-1): verify a pure
    // freestanding fixture builds to import-free WebAssembly and host-bound
    // Solana APIs are rejected before artifact creation.
    const wasm_build_contract_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/wasm_build_contract_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wasm_build_contract_options = b.addOptions();
    wasm_build_contract_options.addOption([]const u8, "omlz_bin", omlz_abs);
    wasm_build_contract_test_module.addOptions("cli_options", wasm_build_contract_options);
    const wasm_build_contract_tests = b.addTest(.{
        .root_module = wasm_build_contract_test_module,
    });
    const run_wasm_build_contract_tests = b.addRunArtifact(wasm_build_contract_tests);
    run_wasm_build_contract_tests.step.dependOn(b.getInstallStep());
    run_wasm_build_contract_tests.step.dependOn(&run_bpf_build_contract_tests.step);
    run_wasm_build_contract_tests.setCwd(b.path(""));

    // Experimental NEAR CLI contract tests (MTF-2 / MTF2-CLI-1): verify exact
    // target grammar, duplicate-target rejection, and pre-build diagnostics
    // without claiming broad NEAR adapter readiness.
    const near_build_contract_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/near_build_contract_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const near_build_contract_options = b.addOptions();
    near_build_contract_options.addOption([]const u8, "omlz_bin", omlz_abs);
    near_build_contract_test_module.addOptions("cli_options", near_build_contract_options);
    const near_build_contract_tests = b.addTest(.{
        .root_module = near_build_contract_test_module,
    });
    const run_near_build_contract_tests = b.addRunArtifact(near_build_contract_tests);
    run_near_build_contract_tests.step.dependOn(b.getInstallStep());
    run_near_build_contract_tests.step.dependOn(&run_wasm_build_contract_tests.step);
    run_near_build_contract_tests.setCwd(b.path(""));

    // Source-map determinism property test (P9 / F-SRCMAP-6): verify repeated
    // BPF builds of the same source produce byte-identical `.map` JSON.
    const srcmap_determinism_test_module = b.createModule(.{
        .root_source_file = b.path("tests/property/srcmap_determinism_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const srcmap_det_options = b.addOptions();
    srcmap_det_options.addOption([]const u8, "omlz_bin", omlz_abs);
    srcmap_determinism_test_module.addOptions("srcmap_det_options", srcmap_det_options);
    const srcmap_determinism_tests = b.addTest(.{
        .root_module = srcmap_determinism_test_module,
    });
    const run_srcmap_determinism_tests = b.addRunArtifact(srcmap_determinism_tests);
    run_srcmap_determinism_tests.step.dependOn(b.getInstallStep());
    // The property build writes out/program.zig and out/hackathon_greet.map,
    // so keep it serialized with the other source-map CLI integration tests.
    run_srcmap_determinism_tests.step.dependOn(&run_near_build_contract_tests.step);
    run_srcmap_determinism_tests.setCwd(b.path(""));

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

    // LSP latency probe tests (LSPFIX2 / F-LSPFIX2-1): verify generated probe
    // documents before the runtime harness delegates latency checks to the
    // compiled Zig stdio client.
    const lsp_bench_test_module = b.createModule(.{
        .root_source_file = b.path("tests/lsp/lsp_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lsp_bench_tests = b.addTest(.{
        .root_module = lsp_bench_test_module,
    });
    const run_lsp_bench_tests = b.addRunArtifact(lsp_bench_tests);
    run_lsp_bench_tests.setCwd(b.path(""));

    // End-to-end LSP harness (P9 / F-LSP-7): exercise every Python stdlib
    // client scenario through the installed omlz-lsp binary.  The harness
    // invokes both zig-out/bin/omlz-lsp and omlz check, so depend explicitly
    // on the install steps for both user-facing binaries.
    const run_lsp_harness = b.addSystemCommand(&.{ "python3", "tests/lsp/run_lsp_check.py", "all" });
    run_lsp_harness.step.dependOn(&install_omlz.step);
    run_lsp_harness.step.dependOn(&install_lsp.step);
    // Keep OCaml generator compilation tests from competing with the
    // latency-sensitive LSP harness.
    run_property_generators_tests.step.dependOn(&run_lsp_harness.step);
    // Keep the public `omlz lsp-bench` CLI integration tests from spawning
    // benchmark LSP servers in parallel with the latency-sensitive harness.
    run_omlz_lsp_bench_cli_tests.step.dependOn(&run_lsp_harness.step);

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

    // Formatter core tests (FMT / F-FMT1): verify canonical OCaml-ish token
    // stream formatting and fixed-point idempotency before CLI/LSP wiring.
    const frontend_fmt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontend/fmt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_frontend_fmt_tests = b.addRunArtifact(frontend_fmt_tests);
    run_frontend_fmt_tests.setCwd(b.path(""));

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
    run_codegen_external_bytes_tests.step.dependOn(&run_srcmap_determinism_tests.step);
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

    const keccak_codegen_test_module = b.createModule(.{
        .root_source_file = b.path("tests/golden/keccak/codegen_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    keccak_codegen_test_module.addOptions("codegen_options", codegen_options);
    const keccak_codegen_tests = b.addTest(.{
        .root_module = keccak_codegen_test_module,
    });
    const run_keccak_codegen_tests = b.addRunArtifact(keccak_codegen_tests);
    run_keccak_codegen_tests.step.dependOn(&run_codegen_pattern_extensions_tests.step);
    run_keccak_codegen_tests.step.dependOn(b.getInstallStep());
    run_keccak_codegen_tests.setCwd(b.path(""));

    const blake3_codegen_test_module = b.createModule(.{
        .root_source_file = b.path("tests/golden/blake3/codegen_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    blake3_codegen_test_module.addOptions("codegen_options", codegen_options);
    const blake3_codegen_tests = b.addTest(.{
        .root_module = blake3_codegen_test_module,
    });
    const run_blake3_codegen_tests = b.addRunArtifact(blake3_codegen_tests);
    run_blake3_codegen_tests.step.dependOn(&run_keccak_codegen_tests.step);
    run_blake3_codegen_tests.step.dependOn(b.getInstallStep());
    run_blake3_codegen_tests.setCwd(b.path(""));

    const secp_recover_codegen_test_module = b.createModule(.{
        .root_source_file = b.path("tests/golden/secp_recover/codegen_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    secp_recover_codegen_test_module.addOptions("codegen_options", codegen_options);
    const secp_recover_codegen_tests = b.addTest(.{
        .root_module = secp_recover_codegen_test_module,
    });
    const run_secp_recover_codegen_tests = b.addRunArtifact(secp_recover_codegen_tests);
    run_secp_recover_codegen_tests.step.dependOn(&run_blake3_codegen_tests.step);
    run_secp_recover_codegen_tests.step.dependOn(b.getInstallStep());
    run_secp_recover_codegen_tests.setCwd(b.path(""));

    const secp_recover_direct_codegen_test_module = b.createModule(.{
        .root_source_file = b.path("tests/golden/secp_recover/codegen_direct_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    secp_recover_direct_codegen_test_module.addOptions("codegen_options", codegen_options);
    const secp_recover_direct_codegen_tests = b.addTest(.{
        .root_module = secp_recover_direct_codegen_test_module,
    });
    const run_secp_recover_direct_codegen_tests = b.addRunArtifact(secp_recover_direct_codegen_tests);
    run_secp_recover_direct_codegen_tests.step.dependOn(&run_secp_recover_codegen_tests.step);
    run_secp_recover_direct_codegen_tests.step.dependOn(b.getInstallStep());
    run_secp_recover_direct_codegen_tests.setCwd(b.path(""));

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
    test_step.dependOn(&run_runtime_sysvar_tests.step);
    test_step.dependOn(&run_runtime_cpi_tests.step);
    test_step.dependOn(&run_runtime_spl_token_tests.step);
    test_step.dependOn(&run_runtime_ata_tests.step);
    test_step.dependOn(&run_vendored_sdk_import_smoke_tests.step);
    test_step.dependOn(&run_runtime_programs_tests.step);
    test_step.dependOn(&run_runtime_bs58_tests.step);
    test_step.dependOn(&run_runtime_prelude_tests.step);
    test_step.dependOn(&run_core_no_alloc_tests.step);
    test_step.dependOn(&run_determinism_tests.step);
    test_step.dependOn(&run_golden_tests.step);
    test_step.dependOn(&run_otest_prop_golden_tests.step);
    test_step.dependOn(&run_ui_tests.step);
    test_step.dependOn(&run_idl_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_otest_cli_tests.step);
    test_step.dependOn(&run_fmt_cli_tests.step);
    test_step.dependOn(&run_omlz_lsp_bench_cli_tests.step);
    test_step.dependOn(&run_fmt_golden_tests.step);
    test_step.dependOn(&run_parser_otest_tests.step);
    test_step.dependOn(&run_parser_otest_prop_tests.step);
    test_step.dependOn(&run_property_generators_tests.step);
    test_step.dependOn(&run_property_shrinking_tests.step);
    test_step.dependOn(&run_explain_cli_tests.step);
    test_step.dependOn(&run_bench_cli_tests.step);
    test_step.dependOn(&run_report_cli_tests.step);
    test_step.dependOn(&run_srcmap_cli_tests.step);
    test_step.dependOn(&run_unmap_cli_tests.step);
    test_step.dependOn(&run_bpf_build_contract_tests.step);
    test_step.dependOn(&run_wasm_build_contract_tests.step);
    test_step.dependOn(&run_srcmap_determinism_tests.step);
    test_step.dependOn(&run_lsp_scaffold_tests.step);
    test_step.dependOn(&run_lsp_jsonrpc_tests.step);
    test_step.dependOn(&run_lsp_bench_tests.step);
    test_step.dependOn(&run_lsp_harness.step);
    test_step.dependOn(&run_render_tests.step);
    test_step.dependOn(&run_bridge_wire_compat_tests.step);
    test_step.dependOn(&run_core_loc_tests.step);
    test_step.dependOn(&run_srcmap_tests.step);
    test_step.dependOn(&run_frontend_fmt_tests.step);
    test_step.dependOn(&run_codegen_external_bytes_tests.step);
    test_step.dependOn(&run_codegen_region_let_storage_tests.step);
    test_step.dependOn(&run_codegen_pattern_extensions_tests.step);
    test_step.dependOn(&run_keccak_codegen_tests.step);
    test_step.dependOn(&run_blake3_codegen_tests.step);
    test_step.dependOn(&run_secp_recover_codegen_tests.step);
    test_step.dependOn(&run_secp_recover_direct_codegen_tests.step);
}
