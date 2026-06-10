//! Minimal command-line entrypoint for the `omlz` compiler driver.
//!
//! RESPONSIBILITIES:
//! - Print the package version declared in `build.zig.zon`.
//! - Parse top-level CLI flags and dispatch each implemented subcommand to
//!   its handler in `src/omlz/` (check, run, idl, build, bench, test, fmt,
//!   unmap, doctor, lsp-bench).
//! - Run the frontend subprocess once per input-driven command and hand the
//!   parsed module to the handler.
//! - Reject all unimplemented commands with a non-zero exit status.
//!
//! Subcommand behavior lives in `src/omlz/` (see docs/07-repo-layout.md);
//! this file owns dispatch, `doctor`, and `--explain` only.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const pipeline = @import("driver/pipeline.zig");
const driver_doctor = @import("driver/doctor.zig");
const cli = @import("omlz/cli_surface.zig");
const cmd_common = @import("omlz/cmd_common.zig");
const cutover_check = @import("omlz/cutover_check.zig");
const check_cmd = @import("omlz/check_cmd.zig");
const run_cmd = @import("omlz/run_cmd.zig");
const idl_cmd = @import("omlz/idl_cmd.zig");
const build_cmd = @import("omlz/build_cmd.zig");
const bench_cmd = @import("omlz/bench_cmd.zig");
const srcmap_cmd = @import("omlz/srcmap_cmd.zig");
const target_registry = @import("target/registry.zig");
const diag_explain = @import("util/diag_explain.zig");
const core_static_report = @import("core/static_report.zig");
const omlz_test = @import("omlz/test.zig");
const omlz_fmt = @import("omlz/fmt.zig");
const omlz_lsp_bench = @import("omlz/lsp_bench.zig");

const writeStdout = cmd_common.writeStdout;
const writeStderr = cmd_common.writeStderr;
const frontendOptions = cmd_common.frontendOptions;
const shouldPrintGenericFrontendFailure = cmd_common.shouldPrintGenericFrontendFailure;
const validateCutoverApiUsageOrReport = cutover_check.validateCutoverApiUsageOrReport;

/// Parses top-level CLI flags and dispatches implemented bootstrap commands.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const command = cli.commandKind(args);

    if (command == cli.CommandKind.version) {
        try writeStdout(init.io, build_options.version);
        try writeStdout(init.io, "\n");
        return;
    }

    if (command == cli.CommandKind.help) {
        try cli.writeHelp(init.io, build_options.version);
        return;
    }

    if (try cli.writeCommandHelpIfRequested(init.io, args)) {
        return;
    }

    if (command == cli.CommandKind.doctor) {
        if (args.len != 2) {
            try writeStderr(init.io, "error: unsupported doctor option; run `omlz doctor --help` for usage.\n");
            std.process.exit(1);
        }
        try runDoctor(init, args[0]);
        return;
    } else if (command == cli.CommandKind.bench) {
        const bench_args = cli.parseBenchArgs(args) catch |err| {
            switch (err) {
                error.HelpRequested => {
                    _ = try cli.writeCommandHelp(init.io, cli.CommandKind.bench);
                    return;
                },
                else => {
                    try writeStderr(init.io, "error: unsupported bench option; run `omlz bench --help` for usage.\n");
                    std.process.exit(1);
                },
            }
        };
        try bench_cmd.runBench(init, args[0], bench_args);
        return;
    } else if (command == cli.CommandKind.@"test") {
        try omlz_test.run(init, args[0], args);
        return;
    } else if (command == cli.CommandKind.fmt) {
        try omlz_fmt.run(init, args[0], args);
        return;
    } else if (command == cli.CommandKind.lsp_bench) {
        try omlz_lsp_bench.run(init, args[0], args);
        return;
    } else if (command == cli.CommandKind.unmap) {
        const unmap_args = cli.parseUnmapArgs(args) catch {
            try writeStderr(init.io, "error: unsupported unmap option; run `omlz unmap --help` for usage.\n");
            std.process.exit(1);
        };
        try srcmap_cmd.runUnmap(init, unmap_args);
        return;
    } else if (command == cli.CommandKind.check) {
        const check_args = cli.parseCheckArgs(args) catch {
            try writeStderr(init.io, "error: unsupported check option; run `omlz --help` for usage.\n");
            std.process.exit(1);
        };
        if (check_args.explain_code) |code| {
            try runExplain(init, code);
            return;
        }
        const frontend_options = try frontendOptions(init, check_args.diagnostics, check_args.wire_version);

        var result = pipeline.runFrontendFromArgv0WithOptions(init.gpa, init.io, init.minimal.environ, args[0], check_args.input_file, frontend_options) catch |err| {
            if (shouldPrintGenericFrontendFailure(err)) {
                try writeStderr(init.io, "error: failed to run zxc-frontend subprocess\n");
            }
            std.process.exit(1);
        };
        defer result.deinit();

        switch (result) {
            .success => |parsed| {
                if (!try validateCutoverApiUsageOrReport(init.gpa, init.io, parsed.module, check_args.input_file)) {
                    std.process.exit(1);
                }
                if (check_args.emit != null and check_args.no_alloc) {
                    try writeStderr(init.io, "error: --no-alloc cannot be combined with --emit\n");
                    std.process.exit(1);
                }
                const report_kinds_opt: ?core_static_report.Kinds = blk: {
                    if (check_args.report) |raw| {
                        const parsed_kinds = core_static_report.parseKinds(raw) catch {
                            try writeStderr(init.io, "error[E0200]: unknown --report kind; expected csv of cu,stack or all\n");
                            std.process.exit(1);
                        };
                        break :blk parsed_kinds;
                    }
                    break :blk null;
                };
                if (check_args.emit) |emit_kind| {
                    if (std.mem.eql(u8, emit_kind, "core-ir") or std.mem.eql(u8, emit_kind, "core-ir-with-loc")) {
                        try check_cmd.emitCoreIr(init, parsed.module, check_args);
                        return;
                    }

                    try writeStderr(init.io, "error: unsupported --emit value; expected core-ir or core-ir-with-loc\n");
                    std.process.exit(1);
                }
                if (check_args.no_alloc) {
                    try check_cmd.runNoAllocCheck(init, parsed.module, check_args.diagnostics, report_kinds_opt);
                    return;
                }
                try check_cmd.runRegionInferenceCheck(init, parsed.module, check_args.diagnostics, report_kinds_opt);
                return;
            },
            .failed => |code| std.process.exit(if (code == 0) 1 else code),
        }
    } else if (command == cli.CommandKind.run) {
        const run_args = cli.parseInputSubcommandArgs(args) catch {
            try writeStderr(init.io, "error: unsupported run option; run `omlz --help` for usage.\n");
            std.process.exit(1);
        };
        const frontend_options = try frontendOptions(init, run_args.diagnostics, null);

        var result = pipeline.runFrontendFromArgv0WithOptions(init.gpa, init.io, init.minimal.environ, args[0], run_args.input_file, frontend_options) catch |err| {
            if (shouldPrintGenericFrontendFailure(err)) {
                try writeStderr(init.io, "error: failed to run zxc-frontend subprocess\n");
            }
            std.process.exit(1);
        };
        defer result.deinit();

        switch (result) {
            .success => |parsed| {
                if (!try validateCutoverApiUsageOrReport(init.gpa, init.io, parsed.module, run_args.input_file)) {
                    std.process.exit(1);
                }
                try run_cmd.runModule(init, parsed.module);
            },
            .failed => |code| std.process.exit(if (code == 0) 1 else code),
        }
        return;
    } else if (command == cli.CommandKind.idl) {
        const idl_args = cli.parseInputSubcommandArgs(args) catch {
            try writeStderr(init.io, "error: unsupported idl option; run `omlz --help` for usage.\n");
            std.process.exit(1);
        };
        const frontend_options = try frontendOptions(init, idl_args.diagnostics, null);

        var result = pipeline.runFrontendFromArgv0WithOptions(init.gpa, init.io, init.minimal.environ, args[0], idl_args.input_file, frontend_options) catch |err| {
            if (shouldPrintGenericFrontendFailure(err)) {
                try writeStderr(init.io, "error: failed to run zxc-frontend subprocess\n");
            }
            std.process.exit(1);
        };
        defer result.deinit();

        switch (result) {
            .success => |parsed| {
                if (!try validateCutoverApiUsageOrReport(init.gpa, init.io, parsed.module, idl_args.input_file)) {
                    std.process.exit(1);
                }
                try idl_cmd.emitIdl(init, parsed.module, idl_args.input_file);
            },
            .failed => |code| std.process.exit(if (code == 0) 1 else code),
        }
        return;
    } else if (command == cli.CommandKind.build) {
        const build_args = cli.parseBuildArgs(args) catch |err| switch (err) {
            error.DuplicateTargetFlag => {
                try writeStderr(init.io, "error: duplicate `--target=<value>` flag; pass exactly one build target.\n");
                std.process.exit(1);
            },
            else => {
                try writeStderr(init.io, "error: unsupported build option; run `omlz --help` for usage.\n");
                std.process.exit(1);
            },
        };
        const frontend_options = try frontendOptions(init, build_args.diagnostics, null);

        const resolved_target = target_registry.resolveBuildTarget(build_args.target) catch {
            try build_cmd.writeUnsupportedBuildTarget(init.io, init.gpa);
            std.process.exit(1);
        };
        try build_cmd.validateBuildArgsForTargetOrExit(init.io, resolved_target, build_args);
        if (resolved_target.requires_output_path and build_args.output_path == null) {
            try writeStderr(init.io, "error: native builds require -o <out>.\n");
            std.process.exit(1);
        }

        var result = pipeline.runFrontendFromArgv0WithOptions(init.gpa, init.io, init.minimal.environ, args[0], build_args.input_file, frontend_options) catch |err| {
            if (shouldPrintGenericFrontendFailure(err)) {
                try writeStderr(init.io, "error: failed to run zxc-frontend subprocess\n");
            }
            std.process.exit(1);
        };
        defer result.deinit();

        switch (result) {
            .success => |parsed| {
                if (!try validateCutoverApiUsageOrReport(init.gpa, init.io, parsed.module, build_args.input_file)) {
                    std.process.exit(1);
                }
                switch (resolved_target.build_dispatch) {
                    .bpf => try build_cmd.buildBpf(init, resolved_target, parsed.module, build_args),
                    .native => try build_cmd.buildNative(init, resolved_target, parsed.module, build_args),
                    .wasm => try build_cmd.buildWasm(init, resolved_target, parsed.module, build_args),
                    .near => try build_cmd.buildNear(init, resolved_target, parsed.module, build_args),
                }
            },
            .failed => |code| std.process.exit(if (code == 0) 1 else code),
        }
        return;
    }

    try writeStderr(init.io, "error: unsupported command or option; run `omlz --help` for usage.\n");
    std.process.exit(1);
}

fn runDoctor(init: std.process.Init, argv0: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &file_writer.interface;

    const ok = try driver_doctor.run(
        init.arena.allocator(),
        init.io,
        init.minimal.environ,
        argv0,
        writer,
    );
    try writer.flush();

    if (!ok) std.process.exit(1);
}

fn runExplain(init: std.process.Init, code: []const u8) !void {
    const entry = diag_explain.lookup(code) orelse {
        try writeStderr(init.io, "Unknown diagnostic code `");
        try writeStderr(init.io, code);
        try writeStderr(init.io, "`. Run `omlz check --help` for --explain usage; known codes are listed in docs/diagnostics.md.\n");
        std.process.exit(1);
    };

    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &file_writer.interface;
    try diag_explain.render(writer, code, entry);
    try writer.flush();
}

test "package version comes from build manifest" {
    try std.testing.expectEqualStrings("0.1.0", build_options.version);
}

test "parse F07 native build arguments without requiring keep-zig" {
    const args = [_][]const u8{
        "omlz",
        "build",
        "--target=native",
        "examples/m0_zero.ml",
        "-o",
        "/tmp/m0",
    };

    const parsed = try cli.parseBuildArgs(&args);
    try std.testing.expectEqualStrings("native", parsed.target);
    try std.testing.expect(!parsed.keep_zig);
    try std.testing.expectEqualStrings("examples/m0_zero.ml", parsed.input_file);
    try std.testing.expectEqualStrings("/tmp/m0", parsed.output_path.?);
}

test {
    _ = @import("backend/api.zig");
    _ = @import("backend/interp.zig");
    _ = @import("backend/zig_codegen.zig");
    _ = @import("core/anf.zig");
    _ = @import("core/const_fold.zig");
    _ = @import("core/dce.zig");
    _ = @import("core/inline.zig");
    _ = @import("core/ir.zig");
    _ = @import("core/layout.zig");
    _ = @import("core/pretty.zig");
    _ = @import("core/static_report.zig");
    _ = @import("core/types.zig");
    _ = @import("driver/build.zig");
    _ = @import("driver/bpf.zig");
    _ = @import("driver/doctor.zig");
    _ = @import("driver/idl.zig");
    _ = @import("lower/arena.zig");
    _ = @import("lower/lir.zig");
    _ = @import("lower/region_infer.zig");
    _ = @import("lower/strategy.zig");
    _ = @import("omlz/test.zig");
    _ = @import("omlz/cmd_common.zig");
    _ = @import("omlz/cutover_check.zig");
    _ = @import("omlz/check_cmd.zig");
    _ = @import("omlz/run_cmd.zig");
    _ = @import("omlz/idl_cmd.zig");
    _ = @import("omlz/build_cmd.zig");
    _ = @import("omlz/bench_cmd.zig");
    _ = @import("omlz/srcmap_cmd.zig");
    _ = pipeline;
    _ = @import("frontend_bridge/sexp_lexer.zig");
    _ = @import("frontend_bridge/sexp_parser.zig");
    _ = @import("target/capability.zig");
    _ = @import("target/registry.zig");
    _ = @import("frontend_bridge/ttree.zig");
}
