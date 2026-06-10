//! `omlz unmap` subcommand implementation.
//!
//! RESPONSIBILITIES:
//! - Load a source map from a sidecar `.map` file or from the embedded
//!   `.zxcaml.srcmap` section of a built `.so`.
//! - Look up the requested program counter and print the mapped
//!   `file:line:col` (with a `~` prefix for non-exact matches).
const std = @import("std");
const Io = std.Io;
const cmd_common = @import("cmd_common.zig");
const cli = @import("cli_surface.zig");
const driver_srcmap = @import("../driver/srcmap.zig");

const writeStdout = cmd_common.writeStdout;
const writeStderr = cmd_common.writeStderr;
const UnmapArgs = cli.UnmapArgs;

pub fn runUnmap(init: std.process.Init, unmap_args: UnmapArgs) !void {
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
