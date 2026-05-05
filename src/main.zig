//! Minimal command-line entrypoint for the `omlz` compiler driver.
//!
//! RESPONSIBILITIES:
//! - Print the package version declared in `build.zig.zon`.
//! - Dispatch `omlz check <file.ml>` through the OCaml frontend subprocess.
//! - Emit the M0 Core IR contract with `omlz check --emit=core-ir <file.ml>`.
//! - Dispatch `omlz run <file.ml>` through frontend → ANF → interpreter.
//! - Dispatch `omlz idl <file.ml>` through frontend → ANF → JSON IDL emission.
//! - Dispatch `omlz build --target=native <file.ml> -o <out>` through Zig source emission and build-exe.
//! - Dispatch `omlz build --target=bpf <file.ml> -o <out.so>` through Zig bitcode emission and sbpf-linker.
//! - Reject all unimplemented commands with a non-zero exit status.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const pipeline = @import("driver/pipeline.zig");
const driver_build = @import("driver/build.zig");
const driver_bpf = @import("driver/bpf.zig");
const driver_idl = @import("driver/idl.zig");
const driver_srcmap = @import("driver/srcmap.zig");
const diag = @import("util/diag.zig");
const diag_explain = @import("util/diag_explain.zig");
const render = @import("util/render.zig");
const interp = @import("backend/interp.zig");
const zig_codegen = @import("backend/zig_codegen.zig");
const core_anf = @import("core/anf.zig");
const core_const_fold = @import("core/const_fold.zig");
const core_dce = @import("core/dce.zig");
const core_inline = @import("core/inline.zig");
const core_ir = @import("core/ir.zig");
const core_no_alloc = @import("core/no_alloc.zig");
const core_pretty = @import("core/pretty.zig");
const arena_lower = @import("lower/arena.zig");
const region_infer = @import("lower/region_infer.zig");

/// Parses top-level CLI flags and dispatches implemented bootstrap commands.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try writeStdout(init.io, build_options.version);
        try writeStdout(init.io, "\n");
        return;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try writeHelp(init.io);
        return;
    }

    if (args.len == 3 and std.mem.eql(u8, args[2], "--help")) {
        if (std.mem.eql(u8, args[1], "check")) {
            try writeCheckHelp(init.io);
            return;
        }
        if (std.mem.eql(u8, args[1], "build")) {
            try writeBuildHelp(init.io);
            return;
        }
        if (std.mem.eql(u8, args[1], "idl")) {
            try writeIdlHelp(init.io);
            return;
        }
        if (std.mem.eql(u8, args[1], "run")) {
            try writeRunHelp(init.io);
            return;
        }
        if (std.mem.eql(u8, args[1], "unmap")) {
            try writeUnmapHelp(init.io);
            return;
        }
    }

    if (args.len >= 3 and std.mem.eql(u8, args[1], "unmap")) {
        const unmap_args = parseUnmapArgs(args) catch {
            try writeStderr(init.io, "error: unsupported unmap option; run `omlz unmap --help` for usage.\n");
            std.process.exit(1);
        };
        try runUnmap(init, unmap_args);
        return;
    }

    if (args.len >= 3 and std.mem.eql(u8, args[1], "check")) {
        const check_args = parseCheckArgs(args) catch {
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
                if (check_args.emit != null and check_args.no_alloc) {
                    try writeStderr(init.io, "error: --no-alloc cannot be combined with --emit\n");
                    std.process.exit(1);
                }
                if (check_args.emit) |emit_kind| {
                    if (std.mem.eql(u8, emit_kind, "core-ir") or std.mem.eql(u8, emit_kind, "core-ir-with-loc")) {
                        try emitCoreIr(init, parsed.module, check_args);
                        return;
                    }

                    try writeStderr(init.io, "error: unsupported --emit value; expected core-ir or core-ir-with-loc\n");
                    std.process.exit(1);
                }
                if (check_args.no_alloc) {
                    try runNoAllocCheck(init, parsed.module, check_args.diagnostics);
                    return;
                }
                try runRegionInferenceCheck(init, parsed.module, check_args.diagnostics);
                return;
            },
            .failed => |code| std.process.exit(if (code == 0) 1 else code),
        }
    }

    if (args.len >= 3 and std.mem.eql(u8, args[1], "run")) {
        const run_args = parseInputSubcommandArgs(args) catch {
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
            .success => |parsed| try runModule(init, parsed.module),
            .failed => |code| std.process.exit(if (code == 0) 1 else code),
        }
        return;
    }

    if (args.len >= 3 and std.mem.eql(u8, args[1], "idl")) {
        const idl_args = parseInputSubcommandArgs(args) catch {
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
            .success => |parsed| try emitIdl(init, parsed.module, idl_args.input_file),
            .failed => |code| std.process.exit(if (code == 0) 1 else code),
        }
        return;
    }

    if (args.len >= 3 and std.mem.eql(u8, args[1], "build")) {
        const build_args = parseBuildArgs(args) catch {
            try writeStderr(init.io, "error: unsupported build option; run `omlz --help` for usage.\n");
            std.process.exit(1);
        };
        const frontend_options = try frontendOptions(init, build_args.diagnostics, null);

        if (!std.mem.eql(u8, build_args.target, "native") and !std.mem.eql(u8, build_args.target, "bpf")) {
            try writeStderr(init.io, "error: unsupported build target; expected native or bpf.\n");
            std.process.exit(1);
        }
        if (std.mem.eql(u8, build_args.target, "native") and build_args.output_path == null) {
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
                if (std.mem.eql(u8, build_args.target, "bpf")) {
                    try buildBpf(init, parsed.module, build_args);
                } else {
                    try buildNative(init, parsed.module, build_args);
                }
            },
            .failed => |code| std.process.exit(if (code == 0) 1 else code),
        }
        return;
    }

    try writeStderr(init.io, "error: unsupported command or option; run `omlz --help` for usage.\n");
    std.process.exit(1);
}

fn writeHelp(io: Io) !void {
    try writeStdout(io,
        \\omlz 
    );
    try writeStdout(io, build_options.version);
    try writeStdout(io,
        \\
        \\Usage:
        \\  omlz --version
        \\  omlz --help
        \\  omlz check <file.ml>
        \\  omlz check --no-alloc <file.ml>
        \\  omlz check --explain <CODE>
        \\  omlz check --emit=core-ir [--bless] [--wire=1.1] <file.ml>
        \\  omlz check --emit=core-ir-with-loc <file.ml>
        \\  omlz idl <file.ml>
        \\  omlz build --target=native [--keep-zig] <file.ml> -o <out>
        \\  omlz build --target=bpf [--keep-zig] [--no-srcmap] <file.ml> [-o <out.so>]
        \\  omlz run <file.ml>
        \\  omlz unmap --pc <addr> [--map <file.map> | --so <file.so>]
        \\
    );
}

fn writeCheckHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz check <file.ml>
        \\  omlz check --no-alloc <file.ml>
        \\  omlz check --explain <CODE>
        \\  omlz check --emit=core-ir [--bless] [--wire=1.1] <file.ml>
        \\  omlz check --emit=core-ir-with-loc <file.ml>
        \\
        \\Flags:
        \\  --no-alloc       Prove the program performs no Core IR allocations.
        \\  --explain <CODE> Explain a stable diagnostic code from docs/diagnostics.md.
        \\  --emit=core-ir   Print the lowered Core IR instead of only checking.
        \\  --emit=core-ir-with-loc
        \\                   Print Core IR with source-location annotations.
        \\  --wire=1.1       Deprecated: ask zxc-frontend to emit old wire 1.1 sexp.
        \\  --bless          Rewrite the Core IR golden snapshot for the input.
        \\  --error-format=human|json|oneline
        \\                   Select diagnostic output format (default: human).
        \\  --color=auto|always|never
        \\                   Control ANSI colors in human diagnostics (default: auto).
        \\
    );
}

fn writeBuildHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz build --target=native [--keep-zig] <file.ml> -o <out>
        \\  omlz build --target=bpf [--keep-zig] [--no-srcmap] <file.ml> [-o <out.so>]
        \\
        \\Flags:
        \\  --target=native  Build a native executable for local testing.
        \\  --target=bpf     Build a Solana BPF shared object.
        \\  --keep-zig       Keep the generated Zig source under out/program.zig.
        \\  --no-srcmap      Skip the default out/<name>.map BPF source-map sidecar.
        \\  -o <path>        Write the compiled artifact to the given path.
        \\  --error-format=human|json|oneline
        \\                   Select diagnostic output format (default: human).
        \\  --color=auto|always|never
        \\                   Control ANSI colors in human diagnostics (default: auto).
        \\
    );
}

fn writeIdlHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz idl <file.ml>
        \\
        \\Emits Anchor-compatible IDL JSON for the given OCaml source file.
        \\
        \\Flags:
        \\  --error-format=human|json|oneline
        \\                   Select diagnostic output format (default: human).
        \\  --color=auto|always|never
        \\                   Control ANSI colors in human diagnostics (default: auto).
        \\
    );
}

fn writeRunHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz run <file.ml>
        \\
        \\Runs the given OCaml source file through the tree-walk interpreter.
        \\
        \\Flags:
        \\  --error-format=human|json|oneline
        \\                   Select diagnostic output format (default: human).
        \\  --color=auto|always|never
        \\                   Control ANSI colors in human diagnostics (default: auto).
        \\
    );
}

fn writeUnmapHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz unmap --pc <addr> [--map <file.map> | --so <file.so>]
        \\
        \\Looks up a BPF program counter in a ZxCaml source map.  The map may be
        \\read from the JSON sidecar or from the .zxcaml.srcmap ELF section.
        \\
        \\Flags:
        \\  --pc <addr>       Program counter to look up (decimal or 0x-prefixed hex).
        \\  --map <file.map>  Read a source-map sidecar JSON file.
        \\  --so <file.so>    Read the embedded .zxcaml.srcmap ELF section.
        \\
    );
}

const DiagnosticFlags = struct {
    error_format: diag.ErrorFormat = .human,
    color: render.Color = .auto,
};

const CheckArgs = struct {
    emit: ?[]const u8,
    input_file: []const u8,
    bless: bool = false,
    no_alloc: bool = false,
    wire_version: ?[]const u8 = null,
    explain_code: ?[]const u8 = null,
    diagnostics: DiagnosticFlags = .{},
};

fn parseCheckArgs(args: []const []const u8) !CheckArgs {
    var emit: ?[]const u8 = null;
    var input_file: ?[]const u8 = null;
    var bless = false;
    var no_alloc = false;
    var wire_version: ?[]const u8 = null;
    var explain_code: ?[]const u8 = null;
    var diagnostics: DiagnosticFlags = .{};

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (parseDiagnosticFlag(arg, &diagnostics) catch return error.UnsupportedCheckArgs) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--emit=")) {
            emit = arg["--emit=".len..];
        } else if (std.mem.eql(u8, arg, "--bless")) {
            bless = true;
        } else if (std.mem.eql(u8, arg, "--no-alloc")) {
            no_alloc = true;
        } else if (std.mem.eql(u8, arg, "--explain")) {
            if (explain_code != null) return error.UnsupportedCheckArgs;
            index += 1;
            if (index >= args.len) return error.UnsupportedCheckArgs;
            explain_code = args[index];
        } else if (std.mem.startsWith(u8, arg, "--explain=")) {
            if (explain_code != null) return error.UnsupportedCheckArgs;
            explain_code = arg["--explain=".len..];
        } else if (std.mem.startsWith(u8, arg, "--wire=")) {
            const requested = arg["--wire=".len..];
            if (!std.mem.eql(u8, requested, "1.1")) return error.UnsupportedCheckArgs;
            wire_version = requested;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedCheckArgs;
        } else if (input_file == null) {
            input_file = arg;
        } else {
            return error.UnsupportedCheckArgs;
        }
    }

    if (explain_code != null and (input_file != null or emit != null or bless or no_alloc or wire_version != null)) {
        return error.UnsupportedCheckArgs;
    }

    return .{
        .emit = emit,
        .input_file = input_file orelse if (explain_code != null) "" else return error.UnsupportedCheckArgs,
        .bless = bless,
        .no_alloc = no_alloc,
        .wire_version = wire_version,
        .explain_code = explain_code,
        .diagnostics = diagnostics,
    };
}

const BuildArgs = struct {
    target: []const u8,
    keep_zig: bool,
    input_file: []const u8,
    output_path: ?[]const u8,
    srcmap: bool = true,
    diagnostics: DiagnosticFlags = .{},
};

fn parseBuildArgs(args: []const []const u8) !BuildArgs {
    var target: ?[]const u8 = null;
    var keep_zig = false;
    var input_file: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var srcmap = true;
    var diagnostics: DiagnosticFlags = .{};

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (parseDiagnosticFlag(arg, &diagnostics) catch return error.UnsupportedBuildArgs) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            target = arg["--target=".len..];
        } else if (std.mem.eql(u8, arg, "--keep-zig")) {
            keep_zig = true;
        } else if (std.mem.eql(u8, arg, "--no-srcmap")) {
            srcmap = false;
        } else if (std.mem.eql(u8, arg, "-o")) {
            index += 1;
            if (index >= args.len) return error.UnsupportedBuildArgs;
            output_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedBuildArgs;
        } else if (input_file == null) {
            input_file = arg;
        } else {
            return error.UnsupportedBuildArgs;
        }
    }

    return .{
        .target = target orelse return error.UnsupportedBuildArgs,
        .keep_zig = keep_zig,
        .input_file = input_file orelse return error.UnsupportedBuildArgs,
        .output_path = output_path,
        .srcmap = srcmap,
        .diagnostics = diagnostics,
    };
}

const InputSubcommandArgs = struct {
    input_file: []const u8,
    diagnostics: DiagnosticFlags = .{},
};

const SourceMapSource = union(enum) {
    map: []const u8,
    so: []const u8,
};

const UnmapArgs = struct {
    pc: u32,
    source: SourceMapSource,
};

fn parseInputSubcommandArgs(args: []const []const u8) !InputSubcommandArgs {
    var input_file: ?[]const u8 = null;
    var diagnostics: DiagnosticFlags = .{};

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (parseDiagnosticFlag(arg, &diagnostics) catch return error.UnsupportedInputSubcommandArgs) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedInputSubcommandArgs;
        } else if (input_file == null) {
            input_file = arg;
        } else {
            return error.UnsupportedInputSubcommandArgs;
        }
    }

    return .{
        .input_file = input_file orelse return error.UnsupportedInputSubcommandArgs,
        .diagnostics = diagnostics,
    };
}

fn parseUnmapArgs(args: []const []const u8) !UnmapArgs {
    var pc: ?u32 = null;
    var source: ?SourceMapSource = null;

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--pc")) {
            index += 1;
            if (index >= args.len) return error.UnsupportedUnmapArgs;
            pc = try parsePc(args[index]);
        } else if (std.mem.startsWith(u8, arg, "--pc=")) {
            pc = try parsePc(arg["--pc=".len..]);
        } else if (std.mem.eql(u8, arg, "--map")) {
            if (source != null) return error.UnsupportedUnmapArgs;
            index += 1;
            if (index >= args.len) return error.UnsupportedUnmapArgs;
            source = .{ .map = args[index] };
        } else if (std.mem.startsWith(u8, arg, "--map=")) {
            if (source != null) return error.UnsupportedUnmapArgs;
            source = .{ .map = arg["--map=".len..] };
        } else if (std.mem.eql(u8, arg, "--so")) {
            if (source != null) return error.UnsupportedUnmapArgs;
            index += 1;
            if (index >= args.len) return error.UnsupportedUnmapArgs;
            source = .{ .so = args[index] };
        } else if (std.mem.startsWith(u8, arg, "--so=")) {
            if (source != null) return error.UnsupportedUnmapArgs;
            source = .{ .so = arg["--so=".len..] };
        } else {
            return error.UnsupportedUnmapArgs;
        }
    }

    return .{
        .pc = pc orelse return error.UnsupportedUnmapArgs,
        .source = source orelse return error.UnsupportedUnmapArgs,
    };
}

fn parsePc(text: []const u8) !u32 {
    if (text.len == 0) return error.InvalidProgramCounter;
    const raw = if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X"))
        try std.fmt.parseInt(u64, text[2..], 16)
    else
        try std.fmt.parseInt(u64, text, 10);
    return std.math.cast(u32, raw) orelse error.InvalidProgramCounter;
}

fn parseDiagnosticFlag(arg: []const u8, flags: *DiagnosticFlags) !bool {
    if (std.mem.startsWith(u8, arg, "--error-format=")) {
        flags.error_format = diag.parseErrorFormat(arg["--error-format=".len..]) catch return error.UnsupportedDiagnosticFlag;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--color=")) {
        flags.color = diag.parseColor(arg["--color=".len..]) catch return error.UnsupportedDiagnosticFlag;
        return true;
    }
    return false;
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

fn diagnosticOutputOptions(init: std.process.Init, flags: DiagnosticFlags) !diag.OutputOptions {
    return .{
        .error_format = flags.error_format,
        .color = flags.color,
        // TTY autodetection follows the investigation report's §5 guidance:
        // resolve `auto` at the CLI edge, not inside the pure renderer.
        .stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false,
        .no_color_env = try hasNoColorEnv(init.gpa, init.minimal.environ),
    };
}

fn frontendOptions(init: std.process.Init, flags: DiagnosticFlags, wire_version: ?[]const u8) !pipeline.FrontendOptions {
    return .{
        .diagnostics = try diagnosticOutputOptions(init, flags),
        .wire_version = wire_version,
    };
}

fn hasNoColorEnv(allocator: std.mem.Allocator, environ: std.process.Environ) !bool {
    const value = std.process.Environ.getAlloc(environ, allocator, "NO_COLOR") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        else => |e| return e,
    };
    allocator.free(value);
    return true;
}

fn emitCoreIr(init: std.process.Init, module: @import("frontend_bridge/ttree.zig").Module, check_args: CheckArgs) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const core_module = core_anf.lowerModule(&core_arena, module) catch |err| {
        try writeStderr(init.io, "error: failed to lower Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const folded_core_module = core_const_fold.foldModule(&core_arena, core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const dce_core_module = core_dce.eliminateModule(&core_arena, folded_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to eliminate dead Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const inlined_core_module = core_inline.inlineModule(&core_arena, dce_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to inline Core IR functions: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const optimized_core_module = core_const_fold.foldModule(&core_arena, inlined_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants after inlining: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    const include_locs = if (check_args.emit) |emit_kind| std.mem.eql(u8, emit_kind, "core-ir-with-loc") else false;
    const rendered = core_pretty.formatModuleWithOptions(init.gpa, optimized_core_module, .{ .include_locs = include_locs }) catch |err| {
        try writeStderr(init.io, "error: failed to pretty-print Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    defer init.gpa.free(rendered);

    if (check_args.bless) {
        const snapshot_path = try deriveSnapshotPath(init.gpa, check_args.input_file);
        defer init.gpa.free(snapshot_path);

        const cwd = std.Io.Dir.cwd();
        cwd.writeFile(init.io, .{
            .sub_path = snapshot_path,
            .data = rendered,
            .flags = .{ .truncate = true },
        }) catch |err| {
            try writeStderr(init.io, "error: failed to write snapshot ");
            try writeStderr(init.io, snapshot_path);
            try writeStderr(init.io, ": ");
            try writeStderr(init.io, @errorName(err));
            try writeStderr(init.io, "\n");
            std.process.exit(1);
        };
        try writeStdout(init.io, "blessed: ");
        try writeStdout(init.io, snapshot_path);
        try writeStdout(init.io, "\n");
    } else {
        if (check_args.wire_version) |wire_version| {
            try writeStdout(init.io, "(version ");
            try writeStdout(init.io, wire_version);
            try writeStdout(init.io, ")\n");
        }
        try writeStdout(init.io, rendered);
        try writeStdout(init.io, "\n");
    }
}

fn runNoAllocCheck(init: std.process.Init, module: @import("frontend_bridge/ttree.zig").Module, flags: DiagnosticFlags) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const core_module = core_anf.lowerModule(&core_arena, module) catch |err| {
        try writeStderr(init.io, "error: failed to lower Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const folded_core_module = core_const_fold.foldModule(&core_arena, core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const dce_core_module = core_dce.eliminateModule(&core_arena, folded_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to eliminate dead Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const inlined_core_module = core_inline.inlineModule(&core_arena, dce_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to inline Core IR functions: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const optimized_core_module = core_const_fold.foldModule(&core_arena, inlined_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants after inlining: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    const result = core_no_alloc.checkModule(init.gpa, optimized_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to run no_alloc analysis: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    switch (result) {
        .Pass => try writeStdout(init.io, "no_alloc: PASS\n"),
        .Fail => |site| {
            try renderNoAllocFailure(init, site, flags);
            std.process.exit(1);
        },
    }
}

fn renderNoAllocFailure(init: std.process.Init, site: core_no_alloc.Site, flags: DiagnosticFlags) !void {
    const message = try noAllocFailureMessage(init.gpa, site);
    defer init.gpa.free(message);

    const loc = site.loc orelse @import("core/ir.zig").Loc.unknown;
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), init.io, &buffer);
    const writer = &file_writer.interface;
    try diag.render(writer, init.gpa, init.io, .{
        .file = loc.file,
        .line = loc.line,
        .col = loc.col,
        .end_line = loc.end_line,
        .end_col = loc.end_col,
        .severity = "error",
        .code = "DX2-NOALLOC",
        .message = message,
    }, try diagnosticOutputOptions(init, flags));
    try writer.flush();
}

fn noAllocFailureMessage(allocator: std.mem.Allocator, site: core_no_alloc.Site) ![]u8 {
    if (site.kind == .ConstructorPayload) {
        if (site.detail) |constructor| {
            return std.fmt.allocPrint(
                allocator,
                "no_alloc failure in function `{s}`: constructor `{s}` carries an arena-allocated payload",
                .{ site.function_name, constructor },
            );
        }
    }

    if (site.detail) |detail| {
        return std.fmt.allocPrint(
            allocator,
            "no_alloc failure in function `{s}`: {s} `{s}` is not allowed in a no_alloc context",
            .{ site.function_name, core_no_alloc.allocationDescription(site.kind), detail },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "no_alloc failure in function `{s}`: {s} is not allowed in a no_alloc context",
        .{ site.function_name, core_no_alloc.allocationDescription(site.kind) },
    );
}

fn runRegionInferenceCheck(init: std.process.Init, module: @import("frontend_bridge/ttree.zig").Module, flags: DiagnosticFlags) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const core_module = core_anf.lowerModule(&core_arena, module) catch |err| {
        try writeStderr(init.io, "error: failed to lower Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const folded_core_module = core_const_fold.foldModule(&core_arena, core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const dce_core_module = core_dce.eliminateModule(&core_arena, folded_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to eliminate dead Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const inlined_core_module = core_inline.inlineModule(&core_arena, dce_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to inline Core IR functions: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const optimized_core_module = core_const_fold.foldModule(&core_arena, inlined_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants after inlining: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    _ = try inferRegionsOrExit(init, &core_arena, optimized_core_module, flags);
}

fn inferRegionsOrExit(
    init: std.process.Init,
    core_arena: *std.heap.ArenaAllocator,
    optimized_core_module: core_ir.Module,
    flags: DiagnosticFlags,
) !core_ir.Module {
    const result = region_infer.inferModuleChecked(core_arena, optimized_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to infer Core IR regions: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    return switch (result) {
        .Pass => |inferred| inferred,
        .Fail => |site| {
            try renderRegionFailure(init, site, flags);
            std.process.exit(1);
        },
    };
}

fn renderRegionFailure(init: std.process.Init, site: region_infer.Site, flags: DiagnosticFlags) !void {
    const message = try regionFailureMessage(init.gpa, site);
    defer init.gpa.free(message);

    const loc = site.loc orelse core_ir.Loc.unknown;
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), init.io, &buffer);
    const writer = &file_writer.interface;
    try diag.render(writer, init.gpa, init.io, .{
        .file = loc.file,
        .line = loc.line,
        .col = loc.col,
        .end_line = loc.end_line,
        .end_col = loc.end_col,
        .severity = "error",
        .code = "DX2-REGION",
        .message = message,
    }, try diagnosticOutputOptions(init, flags));
    try writer.flush();
}

fn regionFailureMessage(allocator: std.mem.Allocator, site: region_infer.Site) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "region inference failure: {s}",
        .{region_infer.failureDescription(site.kind)},
    );
}

/// Derives the `.core.snapshot` path from an `.ml` input path.
fn deriveSnapshotPath(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, input_path, ".ml")) {
        const stem = input_path[0 .. input_path.len - 3];
        return std.fmt.allocPrint(allocator, "{s}.core.snapshot", .{stem});
    }
    return std.fmt.allocPrint(allocator, "{s}.core.snapshot", .{input_path});
}

fn runModule(init: std.process.Init, module: @import("frontend_bridge/ttree.zig").Module) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const core_module = core_anf.lowerModule(&core_arena, module) catch |err| {
        try writeStderr(init.io, "error: failed to lower Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const folded_core_module = core_const_fold.foldModule(&core_arena, core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const dce_core_module = core_dce.eliminateModule(&core_arena, folded_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to eliminate dead Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const inlined_core_module = core_inline.inlineModule(&core_arena, dce_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to inline Core IR functions: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const optimized_core_module = core_const_fold.foldModule(&core_arena, inlined_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants after inlining: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    var interpreter: interp.Interpreter = .{};
    const value = interpreter.backend().evalModule(optimized_core_module) catch |err| {
        if (interp.panicMarker(err)) |marker| {
            try writeStderr(init.io, marker);
            try writeStderr(init.io, "\n");
        } else {
            try writeStderr(init.io, "error: ");
            try writeStderr(init.io, interp.errorMessage(err));
            try writeStderr(init.io, "\n");
        }
        std.process.exit(1);
    };

    var buffer: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "{d}\n", .{value});
    try writeStdout(init.io, rendered);
}

fn emitIdl(init: std.process.Init, module: @import("frontend_bridge/ttree.zig").Module, input_file: []const u8) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const core_module = core_anf.lowerModule(&core_arena, module) catch |err| {
        try writeStderr(init.io, "error: failed to lower Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const folded_core_module = core_const_fold.foldModule(&core_arena, core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const dce_core_module = core_dce.eliminateModule(&core_arena, folded_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to eliminate dead Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const inlined_core_module = core_inline.inlineModule(&core_arena, dce_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to inline Core IR functions: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const optimized_core_module = core_const_fold.foldModule(&core_arena, inlined_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants after inlining: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    const program_name = try deriveProgramName(init.gpa, input_file);
    defer init.gpa.free(program_name);

    const rendered = driver_idl.emitModuleStdout(init.gpa, optimized_core_module, .{ .program_name = program_name }) catch |err| {
        try writeStderr(init.io, "error: failed to emit IDL: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    defer init.gpa.free(rendered);

    try writeStdout(init.io, rendered);
}

fn deriveProgramName(allocator: std.mem.Allocator, input_file: []const u8) ![]u8 {
    const basename = std.fs.path.basename(input_file);
    const stem = if (std.mem.endsWith(u8, basename, ".ml")) basename[0 .. basename.len - 3] else basename;
    return allocator.dupe(u8, stem);
}

fn buildNative(
    init: std.process.Init,
    module: @import("frontend_bridge/ttree.zig").Module,
    build_args: BuildArgs,
) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const core_module = core_anf.lowerModule(&core_arena, module) catch |err| {
        try writeStderr(init.io, "error: failed to lower Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const folded_core_module = core_const_fold.foldModule(&core_arena, core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const dce_core_module = core_dce.eliminateModule(&core_arena, folded_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to eliminate dead Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const inlined_core_module = core_inline.inlineModule(&core_arena, dce_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to inline Core IR functions: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const optimized_core_module = core_const_fold.foldModule(&core_arena, inlined_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants after inlining: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const inferred_core_module = try inferRegionsOrExit(init, &core_arena, optimized_core_module, build_args.diagnostics);

    var lowered_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer lowered_arena.deinit();

    var impl: arena_lower.ArenaStrategy = .{ .allocator = lowered_arena.allocator() };
    const lowered_module = impl.loweringStrategy().lowerModule(inferred_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to lower with ArenaStrategy: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    const source = zig_codegen.emitModule(init.gpa, lowered_module) catch |err| {
        try writeStderr(init.io, "error: failed to emit Zig source: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    defer init.gpa.free(source);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    try cwd.writeFile(init.io, .{
        .sub_path = "out/program.zig",
        .data = source,
        .flags = .{ .truncate = true },
    });

    driver_build.buildNative(init.gpa, init.io, .{
        .generated_zig_path = "out/program.zig",
        .native_entry_path = "out/native_entry.zig",
        .output_path = build_args.output_path.?,
    }) catch |err| {
        try writeStderr(init.io, "error: native build failed: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
}

fn buildBpf(
    init: std.process.Init,
    module: @import("frontend_bridge/ttree.zig").Module,
    build_args: BuildArgs,
) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const core_module = core_anf.lowerModule(&core_arena, module) catch |err| {
        try writeStderr(init.io, "error: failed to lower Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const folded_core_module = core_const_fold.foldModule(&core_arena, core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const dce_core_module = core_dce.eliminateModule(&core_arena, folded_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to eliminate dead Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const inlined_core_module = core_inline.inlineModule(&core_arena, dce_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to inline Core IR functions: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const optimized_core_module = core_const_fold.foldModule(&core_arena, inlined_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants after inlining: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const inferred_core_module = try inferRegionsOrExit(init, &core_arena, optimized_core_module, build_args.diagnostics);

    var lowered_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer lowered_arena.deinit();

    var impl: arena_lower.ArenaStrategy = .{ .allocator = lowered_arena.allocator() };
    const lowered_module = impl.loweringStrategy().lowerModule(inferred_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to lower with ArenaStrategy: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    const source = zig_codegen.emitModule(init.gpa, lowered_module) catch |err| {
        try writeStderr(init.io, "error: failed to emit Zig source: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    defer init.gpa.free(source);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "out");
    try cwd.writeFile(init.io, .{
        .sub_path = "out/program.zig",
        .data = source,
        .flags = .{ .truncate = true },
    });

    const source_map_program = try sourceMapProgramName(init.gpa, build_args.input_file);
    defer init.gpa.free(source_map_program);

    const output_path = build_args.output_path orelse try sourceMapOutputPath(init.gpa, source_map_program, ".so");
    defer if (build_args.output_path == null) init.gpa.free(output_path);

    var source_map_input: ?driver_bpf.SourceMapInput = null;
    var source_map_hook: ?driver_bpf.SourceMapHook = null;
    var source_map_context: SourceMapSidecarContext = undefined;
    var source_map_path: ?[]const u8 = null;
    defer if (source_map_path) |path| init.gpa.free(path);

    if (build_args.srcmap) {
        // Investigation report §4 fixed the sidecar contract: minified,
        // deterministic JSON in out/<program>.map with no timestamps or IDs.
        source_map_path = try sourceMapOutputPath(init.gpa, source_map_program, ".map");
        source_map_input = .{
            .program = source_map_program,
            .module = inferred_core_module,
        };
        source_map_context = .{
            .allocator = init.gpa,
            .io = init.io,
            .path = source_map_path.?,
        };
        source_map_hook = .{
            .context = &source_map_context,
            .emit = emitSourceMapSidecar,
        };
    }

    driver_bpf.buildBpf(init.gpa, init.io, .{
        .output_path = output_path,
        .environ = init.minimal.environ,
        .source_map = source_map_input,
        .source_map_hook = source_map_hook,
    }) catch |err| {
        if (err != error.SbpfLinkerMissing) {
            try writeStderr(init.io, "error: BPF build failed: ");
            try writeStderr(init.io, @errorName(err));
            try writeStderr(init.io, "\n");
        }
        std.process.exit(1);
    };
}

fn sourceMapProgramName(allocator: std.mem.Allocator, input_file: []const u8) ![]const u8 {
    const base = std.fs.path.basename(input_file);
    const stem = if (std.mem.endsWith(u8, base, ".ml")) base[0 .. base.len - ".ml".len] else base;
    return allocator.dupe(u8, stem);
}

fn sourceMapOutputPath(allocator: std.mem.Allocator, program: []const u8, extension: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "out/{s}{s}", .{ program, extension });
}

const SourceMapSidecarContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
};

fn emitSourceMapSidecar(context: *anyopaque, build: driver_bpf.SourceMapBuild) anyerror!void {
    const sidecar: *SourceMapSidecarContext = @ptrCast(@alignCast(context));
    const bytes = try driver_srcmap.serializeJson(sidecar.allocator, build.schema);
    defer sidecar.allocator.free(bytes);

    try std.Io.Dir.cwd().writeFile(sidecar.io, .{
        .sub_path = sidecar.path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}

fn runUnmap(init: std.process.Init, unmap_args: UnmapArgs) !void {
    const map_bytes = switch (unmap_args.source) {
        .map => |path| std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(16 * 1024 * 1024)) catch |err| {
            try writeSourceMapLoadError(init.io, path, err);
            std.process.exit(1);
        },
        .so => |path| driver_srcmap.readEmbeddedSectionJson(init.gpa, init.io, path) catch |err| {
            try writeSourceMapLoadError(init.io, path, err);
            std.process.exit(1);
        },
    };
    defer init.gpa.free(map_bytes);

    var parsed = driver_srcmap.deserializeJson(init.gpa, map_bytes) catch |err| {
        try writeStderr(init.io, "error: invalid source map: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    defer parsed.deinit();

    const lookup = driver_srcmap.lookupPc(parsed.value, unmap_args.pc) orelse {
        try writeNoSourceMapEntry(init.io, unmap_args.pc);
        std.process.exit(1);
    };

    const rendered = try std.fmt.allocPrint(
        init.gpa,
        "{s}{s}:{d}:{d}\n",
        .{ if (lookup.exact) "" else "~", lookup.entry.ml_file, lookup.entry.ml_line, lookup.entry.ml_col },
    );
    defer init.gpa.free(rendered);
    try writeStdout(init.io, rendered);
}

fn writeSourceMapLoadError(io: Io, path: []const u8, err: anyerror) !void {
    try writeStderr(io, "error: failed to load source map from ");
    try writeStderr(io, path);
    try writeStderr(io, ": ");
    try writeStderr(io, @errorName(err));
    try writeStderr(io, "\n");
}

fn writeNoSourceMapEntry(io: Io, pc: u32) !void {
    var buffer: [64]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "error: no source map entry for pc=0x{x}\n", .{pc});
    try writeStderr(io, rendered);
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

fn writeStderr(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

fn shouldPrintGenericFrontendFailure(err: anyerror) bool {
    return switch (err) {
        error.FrontendNotFound,
        error.EmptyInput,
        error.ExpectedExpression,
        error.UnmatchedParen,
        error.UnexpectedRightParen,
        error.TrailingInput,
        error.BadAtom,
        error.UnterminatedString,
        error.BadStringEscape,
        error.IntegerOverflow,
        error.InvalidHeader,
        error.WireFormatVersionMismatch,
        error.ExpectedList,
        error.ExpectedAtom,
        error.ExpectedInteger,
        error.UnexpectedAtom,
        error.UnsupportedNode,
        error.MalformedModule,
        error.MalformedDecl,
        error.MalformedLambda,
        error.MalformedLet,
        error.MalformedVar,
        error.MalformedCtor,
        error.MalformedConstant,
        => false,
        else => true,
    };
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

    const parsed = try parseBuildArgs(&args);
    try std.testing.expectEqualStrings("native", parsed.target);
    try std.testing.expect(!parsed.keep_zig);
    try std.testing.expectEqualStrings("examples/m0_zero.ml", parsed.input_file);
    try std.testing.expectEqualStrings("/tmp/m0", parsed.output_path.?);
}

test {
    _ = @import("backend/api.zig");
    _ = @import("backend/interp.zig");
    _ = @import("backend/llvm_stub.zig");
    _ = @import("backend/ocaml_stub.zig");
    _ = @import("backend/zig_codegen.zig");
    _ = @import("core/anf.zig");
    _ = @import("core/const_fold.zig");
    _ = @import("core/dce.zig");
    _ = @import("core/inline.zig");
    _ = @import("core/ir.zig");
    _ = @import("core/layout.zig");
    _ = @import("core/pretty.zig");
    _ = @import("core/types.zig");
    _ = @import("driver/build.zig");
    _ = @import("driver/bpf.zig");
    _ = @import("driver/idl.zig");
    _ = @import("lower/arena.zig");
    _ = @import("lower/lir.zig");
    _ = @import("lower/region_infer.zig");
    _ = @import("lower/strategy.zig");
    _ = pipeline;
    _ = @import("frontend_bridge/sexp_lexer.zig");
    _ = @import("frontend_bridge/sexp_parser.zig");
    _ = @import("frontend_bridge/ttree.zig");
}
