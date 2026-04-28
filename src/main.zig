//! Minimal command-line entrypoint for the `omlz` compiler driver.
//!
//! RESPONSIBILITIES:
//! - Print the package version declared in `build.zig.zon`.
//! - Dispatch `omlz check <file.ml>` through the OCaml frontend subprocess.
//! - Emit the M0 Core IR contract with `omlz check --emit=core-ir <file.ml>`.
//! - Dispatch `omlz run <file.ml>` through frontend → ANF → interpreter.
//! - Dispatch `omlz build --target=native <file.ml> -o <out>` through Zig source emission and build-exe.
//! - Dispatch `omlz build --target=bpf <file.ml> -o <out.so>` through Zig bitcode emission and sbpf-linker.
//! - Reject all unimplemented commands with a non-zero exit status.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const pipeline = @import("driver/pipeline.zig");
const driver_build = @import("driver/build.zig");
const driver_bpf = @import("driver/bpf.zig");
const interp = @import("backend/interp.zig");
const zig_codegen = @import("backend/zig_codegen.zig");
const core_anf = @import("core/anf.zig");
const core_pretty = @import("core/pretty.zig");
const arena_lower = @import("lower/arena.zig");

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

    if (args.len >= 3 and std.mem.eql(u8, args[1], "check")) {
        const check_args = parseCheckArgs(args) catch {
            try writeStderr(init.io, "error: unsupported check option; run `omlz --help` for usage.\n");
            std.process.exit(1);
        };

        var result = pipeline.runFrontendFromArgv0(init.gpa, init.io, init.minimal.environ, args[0], check_args.input_file) catch |err| {
            if (shouldPrintGenericFrontendFailure(err)) {
                try writeStderr(init.io, "error: failed to run zxc-frontend subprocess\n");
            }
            std.process.exit(1);
        };
        defer result.deinit();

        switch (result) {
            .success => |parsed| {
                if (check_args.emit) |emit_kind| {
                    if (std.mem.eql(u8, emit_kind, "core-ir")) {
                        try emitCoreIr(init, parsed.module, check_args);
                        return;
                    }

                    try writeStderr(init.io, "error: unsupported --emit value; expected core-ir\n");
                    std.process.exit(1);
                }
                return;
            },
            .failed => |code| std.process.exit(if (code == 0) 1 else code),
        }
    }

    if (args.len == 3 and std.mem.eql(u8, args[1], "run")) {
        var result = pipeline.runFrontendFromArgv0(init.gpa, init.io, init.minimal.environ, args[0], args[2]) catch |err| {
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

    if (args.len >= 3 and std.mem.eql(u8, args[1], "build")) {
        const build_args = parseBuildArgs(args) catch {
            try writeStderr(init.io, "error: unsupported build option; run `omlz --help` for usage.\n");
            std.process.exit(1);
        };

        if (!std.mem.eql(u8, build_args.target, "native") and !std.mem.eql(u8, build_args.target, "bpf")) {
            try writeStderr(init.io, "error: unsupported build target; expected native or bpf.\n");
            std.process.exit(1);
        }

        var result = pipeline.runFrontendFromArgv0(init.gpa, init.io, init.minimal.environ, args[0], build_args.input_file) catch |err| {
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
        \\  omlz check --emit=core-ir [--bless] <file.ml>
        \\  omlz build --target=native [--keep-zig] <file.ml> -o <out>
        \\  omlz build --target=bpf [--keep-zig] <file.ml> -o <out.so>
        \\  omlz run <file.ml>
        \\
    );
}

const CheckArgs = struct {
    emit: ?[]const u8,
    input_file: []const u8,
    bless: bool = false,
};

fn parseCheckArgs(args: []const []const u8) !CheckArgs {
    var emit: ?[]const u8 = null;
    var input_file: ?[]const u8 = null;
    var bless = false;

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.startsWith(u8, arg, "--emit=")) {
            emit = arg["--emit=".len..];
        } else if (std.mem.eql(u8, arg, "--bless")) {
            bless = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedCheckArgs;
        } else if (input_file == null) {
            input_file = arg;
        } else {
            return error.UnsupportedCheckArgs;
        }
    }

    return .{
        .emit = emit,
        .input_file = input_file orelse return error.UnsupportedCheckArgs,
        .bless = bless,
    };
}

const BuildArgs = struct {
    target: []const u8,
    keep_zig: bool,
    input_file: []const u8,
    output_path: []const u8,
};

fn parseBuildArgs(args: []const []const u8) !BuildArgs {
    var target: ?[]const u8 = null;
    var keep_zig = false;
    var input_file: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.startsWith(u8, arg, "--target=")) {
            target = arg["--target=".len..];
        } else if (std.mem.eql(u8, arg, "--keep-zig")) {
            keep_zig = true;
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
        .output_path = output_path orelse return error.UnsupportedBuildArgs,
    };
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

    const rendered = core_pretty.formatModule(init.gpa, core_module) catch |err| {
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
        try writeStdout(init.io, rendered);
        try writeStdout(init.io, "\n");
    }
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

    var interpreter: interp.Interpreter = .{};
    const value = interpreter.backend().evalModule(core_module) catch |err| {
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

    var lowered_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer lowered_arena.deinit();

    var impl: arena_lower.ArenaStrategy = .{ .allocator = lowered_arena.allocator() };
    const lowered_module = impl.loweringStrategy().lowerModule(core_module) catch |err| {
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
        .output_path = build_args.output_path,
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

    var lowered_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer lowered_arena.deinit();

    var impl: arena_lower.ArenaStrategy = .{ .allocator = lowered_arena.allocator() };
    const lowered_module = impl.loweringStrategy().lowerModule(core_module) catch |err| {
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

    driver_bpf.buildBpf(init.gpa, init.io, .{
        .output_path = build_args.output_path,
        .environ = init.minimal.environ,
    }) catch |err| {
        if (err != error.SbpfLinkerMissing) {
            try writeStderr(init.io, "error: BPF build failed: ");
            try writeStderr(init.io, @errorName(err));
            try writeStderr(init.io, "\n");
        }
        std.process.exit(1);
    };
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
    try std.testing.expectEqualStrings("/tmp/m0", parsed.output_path);
}

test {
    _ = @import("backend/api.zig");
    _ = @import("backend/interp.zig");
    _ = @import("backend/llvm_stub.zig");
    _ = @import("backend/ocaml_stub.zig");
    _ = @import("backend/zig_codegen.zig");
    _ = @import("core/anf.zig");
    _ = @import("core/ir.zig");
    _ = @import("core/layout.zig");
    _ = @import("core/pretty.zig");
    _ = @import("driver/build.zig");
    _ = @import("driver/bpf.zig");
    _ = @import("lower/arena.zig");
    _ = @import("lower/lir.zig");
    _ = @import("lower/strategy.zig");
    _ = pipeline;
    _ = @import("frontend_bridge/sexp_lexer.zig");
    _ = @import("frontend_bridge/sexp_parser.zig");
    _ = @import("frontend_bridge/ttree.zig");
}
