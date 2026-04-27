//! Minimal command-line entrypoint for the `omlz` compiler driver.
//!
//! RESPONSIBILITIES:
//! - Print the package version declared in `build.zig.zon`.
//! - Dispatch `omlz check <file.ml>` through the OCaml frontend subprocess.
//! - Emit the M0 Core IR contract with `omlz check --emit=core-ir <file.ml>`.
//! - Reject all unimplemented commands with a non-zero exit status.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const pipeline = @import("driver/pipeline.zig");
const core_anf = @import("core/anf.zig");
const core_pretty = @import("core/pretty.zig");

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
                        try emitCoreIr(init, parsed.module);
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
        \\  omlz check --emit=core-ir <file.ml>
        \\  omlz build <file.ml>   (not yet implemented)
        \\  omlz run <file.ml>     (not yet implemented)
        \\
    );
}

const CheckArgs = struct {
    emit: ?[]const u8,
    input_file: []const u8,
};

fn parseCheckArgs(args: []const []const u8) !CheckArgs {
    if (args.len == 3) return .{ .emit = null, .input_file = args[2] };
    if (args.len == 4 and std.mem.startsWith(u8, args[2], "--emit=")) {
        return .{ .emit = args[2]["--emit=".len..], .input_file = args[3] };
    }
    return error.UnsupportedCheckArgs;
}

fn emitCoreIr(init: std.process.Init, module: @import("frontend_bridge/ttree.zig").Module) !void {
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

    try writeStdout(init.io, rendered);
    try writeStdout(init.io, "\n");
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
        error.MalformedConstant,
        => false,
        else => true,
    };
}

test "package version comes from build manifest" {
    try std.testing.expectEqualStrings("0.1.0", build_options.version);
}

test {
    _ = @import("core/anf.zig");
    _ = @import("core/ir.zig");
    _ = @import("core/layout.zig");
    _ = @import("core/pretty.zig");
    _ = pipeline;
    _ = @import("frontend_bridge/sexp_lexer.zig");
    _ = @import("frontend_bridge/sexp_parser.zig");
    _ = @import("frontend_bridge/ttree.zig");
}
