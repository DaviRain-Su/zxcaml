//! Shared helpers for `omlz` CLI subcommand implementations.
//!
//! RESPONSIBILITIES:
//! - Provide the buffered stdout/stderr write helpers used by every
//!   subcommand handler.
//! - Resolve diagnostic output options (TTY/`NO_COLOR`) at the CLI edge.
//! - Run the shared Core IR optimization pipeline (lower → fold → DCE →
//!   inline → fold) with the canonical error messages.
//! - Run checked region inference and render region failures with the
//!   `DX2-REGION` diagnostic code.
const std = @import("std");
const Io = std.Io;
const pipeline = @import("../driver/pipeline.zig");
const cli = @import("cli_surface.zig");
const diag = @import("../util/diag.zig");
const frontend_bridge = @import("../frontend_bridge/ttree.zig");
const core_anf = @import("../core/anf.zig");
const core_const_fold = @import("../core/const_fold.zig");
const core_dce = @import("../core/dce.zig");
const core_inline = @import("../core/inline.zig");
const core_ir = @import("../core/ir.zig");
const region_infer = @import("../lower/region_infer.zig");

pub const DiagnosticFlags = cli.DiagnosticFlags;

pub fn writeStdout(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

pub fn writeStderr(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

pub fn diagnosticOutputOptions(init: std.process.Init, flags: DiagnosticFlags) !diag.OutputOptions {
    return .{
        .error_format = flags.error_format,
        .color = flags.color,
        // TTY autodetection follows the investigation report's §5 guidance:
        // resolve `auto` at the CLI edge, not inside the pure renderer.
        .stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false,
        .no_color_env = try hasNoColorEnv(init.gpa, init.minimal.environ),
    };
}

pub fn frontendOptions(init: std.process.Init, flags: DiagnosticFlags, wire_version: ?[]const u8) !pipeline.FrontendOptions {
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

/// Runs the canonical Core IR optimization pipeline shared by every
/// subcommand: ANF lowering, constant folding, DCE, inlining, and a final
/// folding pass. Renders the stage-specific error message and exits on
/// failure.
pub fn lowerAndOptimizeOrExit(
    init: std.process.Init,
    core_arena: *std.heap.ArenaAllocator,
    module: frontend_bridge.Module,
) !core_ir.Module {
    const core_module = core_anf.lowerModule(core_arena, module) catch |err| {
        try writeStderr(init.io, "error: failed to lower Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const folded_core_module = core_const_fold.foldModule(core_arena, core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const dce_core_module = core_dce.eliminateModule(core_arena, folded_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to eliminate dead Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    const inlined_core_module = core_inline.inlineModule(core_arena, dce_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to inline Core IR functions: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    return core_const_fold.foldModule(core_arena, inlined_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to fold Core IR constants after inlining: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
}

pub fn inferRegionsOrExit(
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

/// Renders an error-severity diagnostic to stderr with the configured
/// output options. Shared by the no_alloc and region failure paths.
pub fn renderErrorDiagnostic(
    init: std.process.Init,
    loc_opt: ?core_ir.Loc,
    code: []const u8,
    message: []const u8,
    flags: DiagnosticFlags,
) !void {
    const loc = loc_opt orelse core_ir.Loc.unknown;
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
        .code = code,
        .message = message,
    }, try diagnosticOutputOptions(init, flags));
    try writer.flush();
}

pub fn renderRegionFailure(init: std.process.Init, site: region_infer.Site, flags: DiagnosticFlags) !void {
    const message = try regionFailureMessage(init.gpa, site);
    defer init.gpa.free(message);
    try renderErrorDiagnostic(init, site.loc, "DX2-REGION", message, flags);
}

fn regionFailureMessage(allocator: std.mem.Allocator, site: region_infer.Site) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "region inference failure: {s}",
        .{region_infer.failureDescription(site.kind)},
    );
}

pub fn shouldPrintGenericFrontendFailure(err: anyerror) bool {
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
