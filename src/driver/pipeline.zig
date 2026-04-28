//! Frontend subprocess boundary for the `omlz` compiler pipeline.
//!
//! RESPONSIBILITIES:
//! - Locate `zxc-frontend` first at `zig-out/bin/zxc-frontend`, then on `PATH`.
//! - Invoke `zxc-frontend --emit=sexp <input.ml>` and return stdout as the sexp payload.
//! - Drain stdout and stderr concurrently so large frontend output cannot deadlock the driver.
//! - Forward frontend stderr line-by-line, preserving JSON diagnostics for F20 and prefixing text.
//! - Parse successful stdout into the Zig `frontend_bridge` typed tree mirror.
//!
//! Protocol contract: `omlz check <file.ml>` calls this module, which runs
//! `zxc-frontend --emit=sexp <input.ml>`. Stdout is the versioned
//! S-expression consumed by the Zig frontend bridge in F03. Stderr is a stream
//! of newline-separated diagnostic records: JSON objects are forwarded
//! unchanged until F20 renders them structurally, while unstructured text is
//! echoed as `[zxc-frontend] <line>`. A non-zero frontend exit becomes a
//! non-zero `omlz` exit. If the executable is absent from both the installed
//! sibling path and `PATH`, `omlz` emits the documented INSTALLING.md hint.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const frontend_bridge = @import("../frontend_bridge/ttree.zig");

pub const default_frontend_path = "zig-out/bin/zxc-frontend";
pub const frontend_name = "zxc-frontend";

/// Arena-owned result of a successful frontend bridge parse.
pub const ParsedFrontend = struct {
    arena: std.heap.ArenaAllocator,
    module: frontend_bridge.Module,

    /// Releases all memory owned by the parsed frontend result.
    pub fn deinit(self: *ParsedFrontend) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Raw subprocess result used by tests and by the parse wrapper.
pub const FrontendProcessResult = union(enum) {
    /// Frontend succeeded; caller owns the sexp bytes.
    success: []u8,
    /// Frontend failed; the contained value is the exit code `omlz` should use.
    failed: u8,

    /// Frees any owned payload carried by this process result.
    pub fn deinit(result: *FrontendProcessResult, allocator: Allocator) void {
        switch (result.*) {
            .success => |bytes| allocator.free(bytes),
            .failed => {},
        }
        result.* = undefined;
    }
};

/// Result of invoking and parsing the OCaml frontend subprocess.
pub const FrontendResult = union(enum) {
    /// Frontend succeeded; caller owns the parsed typed tree arena.
    success: ParsedFrontend,
    /// Frontend failed; the contained value is the exit code `omlz` should use.
    failed: u8,

    /// Frees any owned payload carried by this result.
    pub fn deinit(result: *FrontendResult) void {
        switch (result.*) {
            .success => |*parsed| parsed.deinit(),
            .failed => {},
        }
        result.* = undefined;
    }
};

pub const FrontendConfig = struct {
    /// Installed sibling path checked before PATH.
    sibling_path: []const u8 = default_frontend_path,
    /// PATH contents to search. `null` means skip PATH lookup.
    path_env: ?[]const u8 = null,
};

/// Locates and runs `zxc-frontend --emit=sexp <input_file>`.
pub fn runFrontend(
    allocator: Allocator,
    io: Io,
    environ: std.process.Environ,
    input_file: []const u8,
) !FrontendResult {
    const path_env = std.process.Environ.getAlloc(environ, allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => |e| return e,
    };
    defer if (path_env) |path| allocator.free(path);

    return runFrontendWithConfig(allocator, io, input_file, .{ .path_env = path_env });
}

/// Locates the frontend as a sibling of `omlz_argv0`, then on PATH, and runs it.
pub fn runFrontendFromArgv0(
    allocator: Allocator,
    io: Io,
    environ: std.process.Environ,
    omlz_argv0: []const u8,
    input_file: []const u8,
) !FrontendResult {
    const path_env = std.process.Environ.getAlloc(environ, allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => |e| return e,
    };
    defer if (path_env) |path| allocator.free(path);

    const sibling_path = try frontendSiblingFromArgv0(allocator, omlz_argv0);
    defer allocator.free(sibling_path);

    return runFrontendWithConfig(allocator, io, input_file, .{
        .sibling_path = sibling_path,
        .path_env = path_env,
    });
}

/// Locates and runs the frontend with an explicit lookup configuration.
pub fn runFrontendWithConfig(
    allocator: Allocator,
    io: Io,
    input_file: []const u8,
    config: FrontendConfig,
) !FrontendResult {
    const executable = try findFrontendExecutable(allocator, io, config);
    defer allocator.free(executable);
    return runFrontendExecutable(allocator, io, executable, input_file);
}

/// Runs a known frontend executable path with the standard frontend arguments.
pub fn runFrontendExecutable(
    allocator: Allocator,
    io: Io,
    executable: []const u8,
    input_file: []const u8,
) !FrontendResult {
    const argv = [_][]const u8{ executable, "--emit=sexp", input_file };
    return runFrontendArgvParsed(allocator, io, &argv);
}

fn frontendSiblingFromArgv0(allocator: Allocator, omlz_argv0: []const u8) ![]u8 {
    if (std.fs.path.dirname(omlz_argv0)) |dir| {
        return std.fs.path.join(allocator, &.{ dir, frontend_name });
    }
    return allocator.dupe(u8, default_frontend_path);
}

/// Runs an argv vector through the same non-blocking capture path used by the frontend.
pub fn runFrontendArgv(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
) !FrontendProcessResult {
    const completed = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(completed.stderr);

    try forwardFrontendStderr(io, completed.stderr);

    switch (completed.term) {
        .exited => |code| {
            if (code == 0) {
                return .{ .success = completed.stdout };
            }
            allocator.free(completed.stdout);
            return .{ .failed = if (code == 0) 1 else code };
        },
        .signal, .stopped, .unknown => {
            allocator.free(completed.stdout);
            return .{ .failed = 1 };
        },
    }
}

fn runFrontendArgvParsed(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
) !FrontendResult {
    var process_result = try runFrontendArgv(allocator, io, argv);
    defer process_result.deinit(allocator);

    switch (process_result) {
        .failed => |code| return .{ .failed = code },
        .success => |bytes| {
            var parsed_arena = std.heap.ArenaAllocator.init(allocator);
            errdefer parsed_arena.deinit();

            const module = frontend_bridge.parseModule(&parsed_arena, bytes) catch |err| {
                try frontend_bridge.writeParseError(io, bytes, err);
                return err;
            };

            return .{ .success = .{
                .arena = parsed_arena,
                .module = module,
            } };
        },
    }
}

fn findFrontendExecutable(
    allocator: Allocator,
    io: Io,
    config: FrontendConfig,
) ![]u8 {
    if (isExecutable(io, config.sibling_path)) {
        return allocator.dupe(u8, config.sibling_path);
    }

    if (config.path_env) |path_env| {
        var entries = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
        while (entries.next()) |entry| {
            const dir = if (entry.len == 0) "." else entry;
            const candidate = try std.fs.path.join(allocator, &.{ dir, frontend_name });
            errdefer allocator.free(candidate);
            if (isExecutable(io, candidate)) {
                return candidate;
            }
            allocator.free(candidate);
        }
    }

    try writeStderr(io, "zxc-frontend not found at zig-out/bin/zxc-frontend or on PATH; see INSTALLING.md\n");
    return error.FrontendNotFound;
}

fn isExecutable(io: Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

fn forwardFrontendStderr(io: Io, stderr: []const u8) !void {
    // Use a single buffered writer for the entire stderr stream instead of
    // creating a new Io.File.Writer per line.  Creating one writer per call
    // to writeStderr triggers a Zig 0.16 Io.File.Writer first-byte-drop
    // bug where the leading character of each buffer segment is silently
    // swallowed, corrupting JSON diagnostics (the opening `{` is lost).
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (looksLikeJsonDiagnostic(line)) {
            try writer.writeAll(line);
            try writer.writeAll("\n");
        } else {
            try writer.writeAll("[zxc-frontend] ");
            try writer.writeAll(line);
            try writer.writeAll("\n");
        }
    }
    try writer.flush();
}

fn looksLikeJsonDiagnostic(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}';
}

fn writeStderr(io: Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}

test "missing zxc-frontend reports the documented lookup diagnostic" {
    const result = runFrontendWithConfig(std.testing.allocator, std.testing.io, "missing.ml", .{
        .sibling_path = "zig-out/bin/definitely-not-zxc-frontend",
        .path_env = "",
    });

    try std.testing.expectError(error.FrontendNotFound, result);
}

test "non-zero frontend exit becomes a failed frontend result" {
    var result = try runFrontendExecutable(std.testing.allocator, std.testing.io, "/usr/bin/false", "input.ml");
    defer result.deinit();

    switch (result) {
        .success => return error.TestUnexpectedResult,
        .failed => |code| try std.testing.expect(code != 0),
    }
}

test "large frontend stdout is drained without deadlock" {
    const argv = [_][]const u8{ "/bin/sh", "-c", "yes | head -c 1048576" };
    var result = try runFrontendArgv(std.testing.allocator, std.testing.io, &argv);
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .success => |bytes| try std.testing.expectEqual(@as(usize, 1024 * 1024), bytes.len),
        .failed => return error.TestUnexpectedResult,
    }
}
