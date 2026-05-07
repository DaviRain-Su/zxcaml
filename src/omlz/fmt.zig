//! `omlz fmt` subcommand implementation.
//!
//! RESPONSIBILITIES:
//! - Parse formatter CLI flags and discover file inputs (including directory
//!   recursion over `*.ml` files).
//! - Run a lightweight lex-only guard so malformed literals/comments report
//!   exit code 2 without invoking the compiler frontend.
//! - Call the pure formatter core from `src/frontend/fmt.zig`.
//! - Implement check/write/stdin modes without coupling callers to `src/main`.

const std = @import("std");
const Io = std.Io;

const frontend_fmt = @import("../frontend/fmt.zig");

const max_input_bytes = 16 * 1024 * 1024;

const OutputFormat = enum {
    text,
    json,
};

const Args = struct {
    check: bool = false,
    write: bool = false,
    stdin: bool = false,
    no_color: bool = false,
    format: OutputFormat = .text,
    inputs: []const []const u8 = &.{},
};

const FileSummary = struct {
    path: []const u8,
    changed: bool,
    original_bytes: usize,
    formatted_bytes: usize,
};

pub fn writeHelp(io: Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  omlz fmt [OPTIONS] [FILE_OR_DIR...]
        \\
        \\Formats OCaml source with the canonical ZxCaml formatter.
        \\With positional inputs, formatted output is printed to stdout unless
        \\--check or --write is supplied. Directory inputs recurse over *.ml files.
        \\
        \\Options:
        \\  --check              Exit 1 if any input would be reformatted.
        \\  --write              Rewrite files in place.
        \\  --stdin              Read source from stdin and write formatted stdout.
        \\  --format=text|json   Select output format (default: text).
        \\  --no-color           Disable ANSI colors in parse diagnostics.
        \\
    );
}

pub fn run(init: std.process.Init, argv0: []const u8, raw_args: []const []const u8) !void {
    _ = argv0;
    const args = parseArgs(init.gpa, raw_args) catch {
        try writeStderr(init.io, "error: unsupported fmt option; run `omlz fmt --help` for usage.\n");
        std.process.exit(2);
    };

    if (args.stdin) {
        try runStdin(init, args);
        return;
    }

    if (args.inputs.len == 0) {
        try writeStderr(init.io, "error: fmt requires FILE_OR_DIR inputs or --stdin\n");
        std.process.exit(2);
    }

    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(init.gpa);
    for (args.inputs) |input| {
        collectInputPath(init.gpa, init.io, &files, input) catch |err| {
            try writePathError(init.io, input, err);
            std.process.exit(2);
        };
    }
    sortPaths(files.items);

    var summaries = std.ArrayList(FileSummary).empty;
    defer summaries.deinit(init.gpa);

    var any_changed = false;
    for (files.items) |path| {
        const summary = processFile(init, args, path) catch |err| {
            try writePathError(init.io, path, err);
            std.process.exit(2);
        };
        try summaries.append(init.gpa, summary);
        any_changed = any_changed or summary.changed;

        if (args.check and summary.changed) {
            try writeStderr(init.io, path);
            try writeStderr(init.io, "\n");
        }
    }

    if (args.format == .json) {
        for (summaries.items) |summary| try writeJsonSummary(init.io, summary);
    }

    if (args.check and any_changed) std.process.exit(1);
    std.process.exit(0);
}

fn parseArgs(allocator: std.mem.Allocator, raw_args: []const []const u8) !Args {
    var inputs = std.ArrayList([]const u8).empty;
    var args: Args = .{};

    var index: usize = 2;
    while (index < raw_args.len) : (index += 1) {
        const arg = raw_args[index];
        if (std.mem.eql(u8, arg, "--help")) {
            return error.UnsupportedArgs;
        } else if (std.mem.eql(u8, arg, "--check")) {
            args.check = true;
        } else if (std.mem.eql(u8, arg, "--write")) {
            args.write = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            args.stdin = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            args.no_color = true;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            args.format = try parseOutputFormat(arg["--format=".len..]);
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= raw_args.len) return error.UnsupportedArgs;
            args.format = try parseOutputFormat(raw_args[index]);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedArgs;
        } else {
            try inputs.append(allocator, arg);
        }
    }

    if (args.check and args.write) return error.UnsupportedArgs;
    if (args.stdin and (args.write or args.check or inputs.items.len != 0)) return error.UnsupportedArgs;

    args.inputs = try inputs.toOwnedSlice(allocator);
    return args;
}

fn parseOutputFormat(value: []const u8) !OutputFormat {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return error.UnsupportedArgs;
}

fn runStdin(init: std.process.Init, args: Args) !void {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
    const source = stdin_reader.interface.allocRemaining(init.gpa, .limited(max_input_bytes)) catch {
        try writeStderr(init.io, "error: failed to read stdin\n");
        std.process.exit(2);
    };
    defer init.gpa.free(source);

    frontend_fmt.analyze(source) catch |err| {
        try writeStderr(init.io, "error: failed to format stdin: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(2);
    };

    const formatted = frontend_fmt.formatAlloc(init.gpa, source) catch {
        try writeStderr(init.io, "error: failed to format stdin\n");
        std.process.exit(2);
    };
    defer init.gpa.free(formatted);

    if (args.format == .json) {
        try writeJsonSummary(init.io, .{
            .path = "<stdin>",
            .changed = !std.mem.eql(u8, source, formatted),
            .original_bytes = source.len,
            .formatted_bytes = formatted.len,
        });
    } else {
        try writeStdout(init.io, formatted);
    }
    std.process.exit(0);
}

fn processFile(init: std.process.Init, args: Args, path: []const u8) !FileSummary {
    const source = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_input_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => |e| return e,
    };
    defer init.gpa.free(source);

    try frontend_fmt.analyze(source);

    const formatted = try frontend_fmt.formatAlloc(init.gpa, source);
    defer init.gpa.free(formatted);

    const changed = !std.mem.eql(u8, source, formatted);
    if (args.write and changed) {
        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = path,
            .data = formatted,
            .flags = .{ .truncate = true },
        });
    } else if (!args.check and !args.write and args.format == .text) {
        try writeStdout(init.io, formatted);
    }

    return .{
        .path = path,
        .changed = changed,
        .original_bytes = source.len,
        .formatted_bytes = formatted.len,
    };
}

fn collectInputPath(allocator: std.mem.Allocator, io: Io, files: *std.ArrayList([]const u8), path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => |e| return e,
    };

    switch (stat.kind) {
        .file => try files.append(allocator, try allocator.dupe(u8, path)),
        .directory => try collectDirectory(allocator, io, files, path),
        else => return error.InvalidInputKind,
    }
}

fn collectDirectory(allocator: std.mem.Allocator, io: Io, files: *std.ArrayList([]const u8), path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .access_sub_paths = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".ml")) continue;
        const full_path = try std.fs.path.join(allocator, &.{ path, entry.path });
        try files.append(allocator, full_path);
    }
}

fn sortPaths(paths: [][]const u8) void {
    std.mem.sort([]const u8, paths, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

fn writeJsonSummary(io: Io, summary: FileSummary) !void {
    var out = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer out.deinit();

    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(summary.path, .{}, &out.writer);
    try out.writer.writeAll(",\"changed\":");
    try out.writer.writeAll(if (summary.changed) "true" else "false");
    try out.writer.writeAll(",\"original_bytes\":");
    try out.writer.print("{d}", .{summary.original_bytes});
    try out.writer.writeAll(",\"formatted_bytes\":");
    try out.writer.print("{d}", .{summary.formatted_bytes});
    try out.writer.writeAll("}\n");

    try writeStdout(io, out.writer.buffered());
}

fn writePathError(io: Io, path: []const u8, err: anyerror) !void {
    switch (err) {
        error.FileNotFound => {
            try writeStderr(io, "error: file not found: ");
            try writeStderr(io, path);
            try writeStderr(io, "\n");
        },
        error.InvalidInputKind => {
            try writeStderr(io, "error: unsupported input kind: ");
            try writeStderr(io, path);
            try writeStderr(io, "\n");
        },
        else => {
            try writeStderr(io, "error: failed to format ");
            try writeStderr(io, path);
            try writeStderr(io, ": ");
            try writeStderr(io, @errorName(err));
            try writeStderr(io, "\n");
        },
    }
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

test "fmt_args_parse_format_json" {
    const allocator = std.testing.allocator;
    const args = try parseArgs(allocator, &.{ "omlz", "fmt", "--check", "--format=json", "a.ml" });
    defer allocator.free(args.inputs);

    try std.testing.expect(args.check);
    try std.testing.expectEqual(OutputFormat.json, args.format);
    try std.testing.expectEqual(@as(usize, 1), args.inputs.len);
}

test "fmt_args_reject_check_write_combo" {
    try std.testing.expectError(error.UnsupportedArgs, parseArgs(std.testing.allocator, &.{ "omlz", "fmt", "--check", "--write", "a.ml" }));
}
