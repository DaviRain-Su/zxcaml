//! Shared subprocess execution for build drivers.
//!
//! RESPONSIBILITIES:
//! - Run an argv vector, forward captured stdout/stderr to this process's
//!   streams, and map a non-zero exit (or signal) to the caller's failure
//!   error.
//! - Support quiet builds (forward output only on failure) and an optional
//!   stderr filter for noisy external tooling.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ForwardingOptions = struct {
    environ_map: ?*const std.process.Environ.Map = null,
    /// When false, captured output is only forwarded if the child failed
    /// (quiet builds).
    forward_success_output: bool = true,
    /// Stderr forwarding hook; drivers can filter tool noise (e.g. the BPF
    /// driver drops macOS static-archive `dlopen` probe warnings).
    stderr_forward: *const fn (Io, []const u8) anyerror!void = writeStderr,
};

pub fn runAndForward(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
    failure: anyerror,
    options: ForwardingOptions,
) !void {
    const completed = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = options.environ_map,
    });
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    const success = switch (completed.term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };

    if (options.forward_success_output or !success) {
        if (completed.stdout.len > 0) try writeStdout(io, completed.stdout);
        if (completed.stderr.len > 0) try options.stderr_forward(io, completed.stderr);
    }

    if (success) return;
    return failure;
}

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
