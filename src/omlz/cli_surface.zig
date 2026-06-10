//! Shared CLI surface helpers for `omlz`.
//!
//! This module centralizes public command identification, help text, and
//! argument parsing so `src/main.zig` can stay focused on command execution.

const std = @import("std");
const Io = std.Io;
const diag = @import("../util/diag.zig");
const render = @import("../util/render.zig");
const omlz_test = @import("test.zig");
const omlz_fmt = @import("fmt.zig");
const omlz_lsp_bench = @import("lsp_bench.zig");

pub const CommandKind = enum {
    version,
    help,
    doctor,
    bench,
    @"test",
    fmt,
    lsp_bench,
    unmap,
    check,
    run,
    idl,
    build,
    unknown,
};

pub const DiagnosticFlags = struct {
    error_format: diag.ErrorFormat = .human,
    color: render.Color = .auto,
};

pub const CheckArgs = struct {
    emit: ?[]const u8,
    input_file: []const u8,
    bless: bool = false,
    no_alloc: bool = false,
    wire_version: ?[]const u8 = null,
    explain_code: ?[]const u8 = null,
    report: ?[]const u8 = null,
    diagnostics: DiagnosticFlags = .{},
};

pub const BuildArgs = struct {
    target: []const u8,
    keep_zig: bool,
    input_file: []const u8,
    output_path: ?[]const u8,
    srcmap: bool = true,
    quiet: bool = false,
    diagnostics: DiagnosticFlags = .{},
};

pub const InputSubcommandArgs = struct {
    input_file: []const u8,
    diagnostics: DiagnosticFlags = .{},
};

pub const SourceMapSource = union(enum) {
    map: []const u8,
    so: []const u8,
};

pub const UnmapArgs = struct {
    pc: u32,
    source: SourceMapSource,
};

pub const BenchArgs = struct {
    warmup_rounds: usize = 0,
    rounds: usize = 0,
    explicit_rounds: bool = false,
};

pub fn commandKind(args: []const []const u8) CommandKind {
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) return .version;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) return .help;
    if (args.len < 2) return .unknown;
    if (std.mem.eql(u8, args[1], "doctor")) return .doctor;
    if (std.mem.eql(u8, args[1], "bench")) return .bench;
    if (std.mem.eql(u8, args[1], "test")) return .@"test";
    if (std.mem.eql(u8, args[1], "fmt")) return .fmt;
    if (std.mem.eql(u8, args[1], "lsp-bench")) return .lsp_bench;
    if (std.mem.eql(u8, args[1], "unmap")) return .unmap;
    if (std.mem.eql(u8, args[1], "check")) return .check;
    if (std.mem.eql(u8, args[1], "run")) return .run;
    if (std.mem.eql(u8, args[1], "idl")) return .idl;
    if (std.mem.eql(u8, args[1], "build")) return .build;
    return .unknown;
}

pub fn writeHelp(io: Io, version: []const u8) !void {
    try writeStdout(io,
        \\omlz 
    );
    try writeStdout(io, version);
    try writeStdout(io,
        \\
        \\Usage:
        \\  omlz --version
        \\  omlz --help
        \\  omlz check <file.ml>
        \\  omlz check --no-alloc <file.ml>
        \\  omlz check --explain <CODE>
        \\  omlz check --emit=core-ir [--bless] [--wire=1.1|--wire=1.5] <file.ml>
        \\  omlz check --emit=core-ir-with-loc <file.ml>
        \\  omlz idl <file.ml>
        \\  omlz build --target=native [--keep-zig] <file.ml> -o <out>
        \\  omlz build --target=bpf [--keep-zig] [--no-srcmap] <file.ml> [-o <out.so>]
        \\  omlz build --target=wasm [--keep-zig] <file.ml> [-o <out.wasm>]
        \\  omlz build --target=near [--keep-zig] <file.ml> [-o <out.wasm>]
        \\  omlz run <file.ml>
        \\  omlz test [--filter SUBSTR] [--format=cargo|json] [FILE...]
        \\  omlz fmt [--check|--write|--stdin] [--format=text|json] [FILE_OR_DIR...]
        \\  omlz lsp-bench [--warmup N] [--rounds K] [--p50 MS] [--p99 MS]
        \\  omlz unmap --pc <addr> [--map <file.map> | --so <file.so>]
        \\  omlz bench [--warmup-rounds N] [--rounds M]
        \\  omlz doctor
        \\
    );
}

pub fn writeCommandHelpIfRequested(io: Io, args: []const []const u8) !bool {
    if (args.len != 3 or !std.mem.eql(u8, args[2], "--help")) return false;

    return writeCommandHelp(io, commandKind(args));
}

pub fn writeCommandHelp(io: Io, command: CommandKind) !bool {
    switch (command) {
        .check => try writeCheckHelp(io),
        .build => try writeBuildHelp(io),
        .idl => try writeIdlHelp(io),
        .run => try writeRunHelp(io),
        .@"test" => try omlz_test.writeHelp(io),
        .fmt => try omlz_fmt.writeHelp(io),
        .lsp_bench => try omlz_lsp_bench.writeHelp(io),
        .unmap => try writeUnmapHelp(io),
        .bench => try writeBenchHelp(io),
        .doctor => try writeDoctorHelp(io),
        else => return false,
    }

    return true;
}

pub fn parseCheckArgs(args: []const []const u8) !CheckArgs {
    var emit: ?[]const u8 = null;
    var input_file: ?[]const u8 = null;
    var bless = false;
    var no_alloc = false;
    var wire_version: ?[]const u8 = null;
    var explain_code: ?[]const u8 = null;
    var report: ?[]const u8 = null;
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
        } else if (std.mem.startsWith(u8, arg, "--report=")) {
            report = arg["--report=".len..];
        } else if (std.mem.startsWith(u8, arg, "--wire=")) {
            const requested = arg["--wire=".len..];
            if (!std.mem.eql(u8, requested, "1.1") and !std.mem.eql(u8, requested, "1.5")) {
                return error.UnsupportedCheckArgs;
            }
            wire_version = requested;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedCheckArgs;
        } else if (input_file == null) {
            input_file = arg;
        } else {
            return error.UnsupportedCheckArgs;
        }
    }

    if (explain_code != null and (input_file != null or emit != null or bless or no_alloc or wire_version != null or report != null)) {
        return error.UnsupportedCheckArgs;
    }

    return .{
        .emit = emit,
        .input_file = input_file orelse if (explain_code != null) "" else return error.UnsupportedCheckArgs,
        .bless = bless,
        .no_alloc = no_alloc,
        .wire_version = wire_version,
        .explain_code = explain_code,
        .report = report,
        .diagnostics = diagnostics,
    };
}

pub fn parseBuildArgs(args: []const []const u8) !BuildArgs {
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
            if (target != null) return error.DuplicateTargetFlag;
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
        .quiet = false,
        .diagnostics = diagnostics,
    };
}

pub fn parseInputSubcommandArgs(args: []const []const u8) !InputSubcommandArgs {
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

pub fn parseUnmapArgs(args: []const []const u8) !UnmapArgs {
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

pub fn parseBenchArgs(raw_args: []const []const u8) !BenchArgs {
    var args: BenchArgs = .{};
    var index: usize = 2;
    while (index < raw_args.len) : (index += 1) {
        const arg = raw_args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--warmup-rounds")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            args.warmup_rounds = try parseBenchCount(raw_args[index]);
            args.explicit_rounds = true;
        } else if (std.mem.startsWith(u8, arg, "--warmup-rounds=")) {
            args.warmup_rounds = try parseBenchCount(arg["--warmup-rounds=".len..]);
            args.explicit_rounds = true;
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            args.rounds = try parseBenchCount(raw_args[index]);
            args.explicit_rounds = true;
        } else if (std.mem.startsWith(u8, arg, "--rounds=")) {
            args.rounds = try parseBenchCount(arg["--rounds=".len..]);
            args.explicit_rounds = true;
        } else {
            return error.UnsupportedArgs;
        }
    }
    return args;
}

fn writeCheckHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz check <file.ml>
        \\  omlz check --no-alloc <file.ml>
        \\  omlz check --report=<kinds> <file.ml>
        \\  omlz check --explain <CODE>
        \\  omlz check --emit=core-ir [--bless] [--wire=1.1|--wire=1.5] <file.ml>
        \\  omlz check --emit=core-ir-with-loc <file.ml>
        \\
        \\Flags:
        \\  --no-alloc       Prove the program performs no Core IR allocations.
        \\  --explain <CODE> Explain a stable diagnostic code from docs/diagnostics.md.
        \\  --emit=core-ir   Print the lowered Core IR instead of only checking.
        \\  --emit=core-ir-with-loc
        \\                   Print Core IR with source-location annotations.
        \\  --report=<kinds> Emit a static profiling report. Accepts a comma-
        \\                   separated list of `cu`, `stack`, or the literal
        \\                   `all`. Output is opt-in and goes to stdout.
        \\  --wire=1.1|1.5   Deprecated: ask zxc-frontend to emit an older wire sexp shape.
        \\  --bless          Rewrite the Core IR golden snapshot for the input.
        \\  --error-format=human|json|oneline
        \\                   Select diagnostic output format (default: human).
        \\  --color=auto|always|never
        \\                   Control ANSI colors in human diagnostics (default: auto).
        \\
    );
}

fn writeDoctorHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz doctor
        \\
        \\Runs local toolchain self-checks for the prerequisites that matter
        \\for `omlz build --target=bpf`. Each probe prints a single status row
        \\formatted as `label: STATUS detail`.
        \\
        \\Probes (in order):
        \\  zig            zig version (expects 0.16.x)
        \\  zxc-frontend   path to the OCaml frontend binary used by omlz check
        \\  ocamlc         OCaml compiler version (expects 5.x)
        \\  solana-zig     solana-zig resolver (env SOLANA_ZIG -> PATH)
        \\  llvm-objcopy   required for embedding BPF source maps
        \\  solana         optional; needed for the Mollusk path
        \\  cargo          optional; needed for the Mollusk path
        \\  surfpool       optional; needed for the local acceptance harness
        \\
        \\Exit code is 0 unless any probe reports FAIL; WARN does not fail.
        \\
    );
}

fn writeBuildHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz build --target=native [--keep-zig] <file.ml> -o <out>
        \\  omlz build --target=bpf [--keep-zig] [--no-srcmap] <file.ml> [-o <out.so>]
        \\  omlz build --target=wasm [--keep-zig] <file.ml> [-o <out.wasm>]
        \\  omlz build --target=near [--keep-zig] <file.ml> [-o <out.wasm>]
        \\
        \\Flags:
        \\  --target=native  Build a native executable for local testing.
        \\  --target=bpf     Build a Solana BPF shared object.
        \\  --target=wasm    Build experimental generic freestanding WASM.
        \\  --target=near    Build an experimental NEAR no-storage adapter .wasm.
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

fn writeBenchHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz bench [--warmup-rounds N] [--rounds M]
        \\
        \\Builds the default local benchmark fixtures with --target=bpf and
        \\prints a markdown table of compile_ms, .so bytes, and source-map
        \\entry counts.  The command does not spawn surfpool or run Mollusk.
        \\
        \\Flags:
        \\  --warmup-rounds <N>  Warm builds to discard before measured warm runs (default: 0)
        \\  --rounds <M>         Warm builds to measure and summarize as warm-median (default: 0)
        \\  --help               Show this help text
        \\
        \\Fixtures:
        \\  examples/hackathon_greet.ml
        \\  examples/escrow_full.ml
        \\  examples/spl_token_transfer.ml
        \\
    );
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

fn parseBenchCount(text: []const u8) !usize {
    if (text.len == 0) return error.UnsupportedArgs;
    return std.fmt.parseUnsigned(usize, text, 10) catch error.UnsupportedArgs;
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}
