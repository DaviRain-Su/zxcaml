//! Minimal command-line entrypoint for the `omlz` compiler driver.
//!
//! RESPONSIBILITIES:
//! - Print the package version declared in `build.zig.zon`.
//! - Print bootstrap usage for planned subcommands.
//! - Reject all unimplemented commands with a non-zero exit status.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

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
        \\  omlz check <file.ml>   (not yet implemented)
        \\  omlz build <file.ml>   (not yet implemented)
        \\  omlz run <file.ml>     (not yet implemented)
        \\
    );
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

test "package version comes from build manifest" {
    try std.testing.expectEqualStrings("0.1.0", build_options.version);
}
