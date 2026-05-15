//! `omlz doctor` toolchain probes.
//!
//! RESPONSIBILITIES:
//! - Run a small, fixed set of subprocess probes that report whether the host
//!   has the prerequisites for `omlz build --target=bpf`.
//! - Format each probe as a single human-readable status row
//!   (`LABEL: STATUS detail`) printed in a fixed order.
//! - Surface a `FAIL` row for `SOLANA_ZIG=0`, which the CHANGELOG documents as
//!   no longer supported.
//! - Exit non-zero only if at least one probe is `FAIL`; `WARN` and `OK` keep
//!   the exit code at zero.
//!
//! Subprocess invocations are best-effort: capture stderr, never propagate
//! errors out of the doctor command itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const driver_bpf = @import("bpf.zig");
const driver_pipeline = @import("pipeline.zig");

pub const Status = enum {
    ok,
    warn,
    fail,
};

const Probe = struct {
    label: []const u8,
    status: Status,
    detail: []const u8,
};

const CommandOutput = struct {
    ok: bool,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// Runs all probes in the documented order and prints them. Returns true if
/// no probe reported `FAIL`.
pub fn run(
    arena: Allocator,
    io: Io,
    environ: std.process.Environ,
    argv0: []const u8,
    stdout: anytype,
) !bool {
    var has_fail = false;

    try probeZig(arena, io, stdout, &has_fail);
    try probeFrontend(arena, io, stdout, argv0);
    try probeOcamlc(arena, io, stdout, &has_fail);
    try probeSolanaZig(arena, io, environ, stdout, &has_fail);
    try probeLlvmObjcopy(arena, io, environ, stdout);
    try probeOptionalCommand(arena, io, stdout, "solana", &.{ "solana", "--version" });
    try probeOptionalCommand(arena, io, stdout, "cargo", &.{ "cargo", "--version" });

    return !has_fail;
}

fn probeZig(arena: Allocator, io: Io, stdout: anytype, has_fail: *bool) !void {
    const output = runCommand(arena, io, &.{ "zig", "version" });
    if (!output.ok) {
        has_fail.* = true;
        try writeProbe(stdout, .{
            .label = "zig",
            .status = .fail,
            .detail = try detailFor(arena, output, "not found"),
        });
        return;
    }

    const version = firstLine(output.stdout);
    if (versionMajorMinorMatches(version, 0, 16)) {
        try writeProbe(stdout, .{ .label = "zig", .status = .ok, .detail = version });
    } else {
        const detail = try std.fmt.allocPrint(arena, "{s} (expected 0.16.x)", .{version});
        try writeProbe(stdout, .{ .label = "zig", .status = .warn, .detail = detail });
    }
}

fn probeFrontend(arena: Allocator, io: Io, stdout: anytype, argv0: []const u8) !void {
    const sibling = try frontendSibling(arena, argv0);
    if (try fileExists(io, sibling)) {
        try writeProbe(stdout, .{
            .label = "zxc-frontend",
            .status = .ok,
            .detail = sibling,
        });
        return;
    }

    const fallback = driver_pipeline.default_frontend_path;
    if (try fileExists(io, fallback)) {
        try writeProbe(stdout, .{
            .label = "zxc-frontend",
            .status = .ok,
            .detail = fallback,
        });
        return;
    }

    const detail = try std.fmt.allocPrint(
        arena,
        "not found at {s}; run `zig build`",
        .{sibling},
    );
    try writeProbe(stdout, .{
        .label = "zxc-frontend",
        .status = .warn,
        .detail = detail,
    });
}

fn probeOcamlc(arena: Allocator, io: Io, stdout: anytype, has_fail: *bool) !void {
    const direct = runCommand(arena, io, &.{ "ocamlc", "-version" });
    if (direct.ok) {
        const version = firstLine(direct.stdout);
        if (versionMajor(version) == 5) {
            try writeProbe(stdout, .{ .label = "ocamlc", .status = .ok, .detail = version });
        } else {
            const detail = try std.fmt.allocPrint(arena, "{s} (expected 5.x)", .{version});
            try writeProbe(stdout, .{ .label = "ocamlc", .status = .warn, .detail = detail });
        }
        return;
    }

    const via_opam = runCommand(arena, io, &.{ "opam", "exec", "--switch=zxcaml-p1", "--", "ocamlc", "-version" });
    if (via_opam.ok) {
        const version = firstLine(via_opam.stdout);
        const detail = try std.fmt.allocPrint(arena, "{s} (via opam switch zxcaml-p1)", .{version});
        const status: Status = if (versionMajor(version) == 5) .ok else .warn;
        try writeProbe(stdout, .{ .label = "ocamlc", .status = status, .detail = detail });
        return;
    }

    has_fail.* = true;
    try writeProbe(stdout, .{
        .label = "ocamlc",
        .status = .fail,
        .detail = "not found",
    });
}

fn probeSolanaZig(
    arena: Allocator,
    io: Io,
    environ: std.process.Environ,
    stdout: anytype,
    has_fail: *bool,
) !void {
    const raw_env = std.process.Environ.getAlloc(environ, arena, "SOLANA_ZIG") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };

    // Replicate the bpf.zig contract: empty/missing/"1" → "solana-zig",
    // "0" → FAIL (no longer supported per CHANGELOG), other → use as command.
    const resolved = if (raw_env) |raw|
        driver_bpf.parseSolanaZigEnv(raw) catch {
            has_fail.* = true;
            try writeProbe(stdout, .{
                .label = "solana-zig",
                .status = .fail,
                .detail = "SOLANA_ZIG=0 is no longer supported (see CHANGELOG); unset, set to 1, or use a command/path",
            });
            return;
        }
    else
        "solana-zig";

    // `solana-zig` is a Zig-style wrapper, so use the `version` subcommand
    // (mirrors how `bpf.zig` invokes it for `build-lib`).
    const output = runCommand(arena, io, &.{ resolved, "version" });
    if (output.ok) {
        const version = firstLine(output.stdout);
        const detail = try std.fmt.allocPrint(arena, "{s} ({s})", .{ version, resolved });
        try writeProbe(stdout, .{ .label = "solana-zig", .status = .ok, .detail = detail });
        return;
    }

    has_fail.* = true;
    const detail_src = if (output.stderr.len != 0) output.stderr else output.stdout;
    const detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ resolved, firstLine(detail_src) });
    try writeProbe(stdout, .{
        .label = "solana-zig",
        .status = .fail,
        .detail = detail,
    });
}

fn probeLlvmObjcopy(
    arena: Allocator,
    io: Io,
    environ: std.process.Environ,
    stdout: anytype,
) !void {
    const found_on_path = try locateOnPath(arena, io, environ, "llvm-objcopy");
    if (found_on_path) |path| {
        try writeProbe(stdout, .{
            .label = "llvm-objcopy",
            .status = .ok,
            .detail = path,
        });
        return;
    }

    try writeProbe(stdout, .{
        .label = "llvm-objcopy",
        .status = .warn,
        .detail = "not found; BPF source-map embedding will degrade to sidecar-only",
    });
}

fn probeOptionalCommand(
    arena: Allocator,
    io: Io,
    stdout: anytype,
    label: []const u8,
    argv: []const []const u8,
) !void {
    const output = runCommand(arena, io, argv);
    if (output.ok) {
        try writeProbe(stdout, .{
            .label = label,
            .status = .ok,
            .detail = firstLine(output.stdout),
        });
        return;
    }

    try writeProbe(stdout, .{
        .label = label,
        .status = .warn,
        .detail = "not found",
    });
}

fn runCommand(arena: Allocator, io: Io, argv: []const []const u8) CommandOutput {
    const result = std.process.run(arena, io, .{ .argv = argv }) catch |err| {
        return .{ .ok = false, .exit_code = 1, .stdout = "", .stderr = @errorName(err) };
    };
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
    return .{
        .ok = exit_code == 0,
        .exit_code = exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn writeProbe(stdout: anytype, probe: Probe) !void {
    const status_text = switch (probe.status) {
        .ok => "OK",
        .warn => "WARN",
        .fail => "FAIL",
    };
    try stdout.print("{s}: {s: <5} {s}\n", .{
        probe.label,
        status_text,
        probe.detail,
    });
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "";
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..end], " \t\r");
}

fn detailFor(arena: Allocator, output: CommandOutput, fallback: []const u8) ![]const u8 {
    const line = firstLine(output.stderr);
    if (line.len != 0) return arena.dupe(u8, line);
    const out_line = firstLine(output.stdout);
    if (out_line.len != 0) return arena.dupe(u8, out_line);
    return arena.dupe(u8, fallback);
}

fn versionMajor(version: []const u8) ?u32 {
    if (version.len == 0) return null;
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse return null;
    return std.fmt.parseUnsigned(u32, version[0..dot], 10) catch null;
}

fn versionMajorMinorMatches(version: []const u8, want_major: u32, want_minor: u32) bool {
    if (version.len == 0) return false;
    const first_dot = std.mem.indexOfScalar(u8, version, '.') orelse return false;
    const major_str = version[0..first_dot];
    const after_major = version[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, after_major, '.') orelse after_major.len;
    const minor_str = after_major[0..second_dot];

    const major = std.fmt.parseUnsigned(u32, major_str, 10) catch return false;
    const minor = std.fmt.parseUnsigned(u32, minor_str, 10) catch return false;
    return major == want_major and minor == want_minor;
}

fn frontendSibling(arena: Allocator, argv0: []const u8) ![]u8 {
    if (std.fs.path.dirname(argv0)) |dir| {
        return std.fs.path.join(arena, &.{ dir, driver_pipeline.frontend_name });
    }
    return arena.dupe(u8, driver_pipeline.default_frontend_path);
}

fn fileExists(io: Io, path: []const u8) !bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn locateOnPath(
    arena: Allocator,
    io: Io,
    environ: std.process.Environ,
    command: []const u8,
) !?[]const u8 {
    const path_env = std.process.Environ.getAlloc(environ, arena, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };

    var entries = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = try std.fs.path.join(arena, &.{ entry, command });
        if (try fileExists(io, candidate)) return candidate;
    }
    return null;
}

test "parseSolanaZigEnv defaults map to solana-zig" {
    try std.testing.expectEqualStrings("solana-zig", try driver_bpf.parseSolanaZigEnv(""));
    try std.testing.expectEqualStrings("solana-zig", try driver_bpf.parseSolanaZigEnv("1"));
    try std.testing.expectError(error.InvalidSolanaZigCommand, driver_bpf.parseSolanaZigEnv("0"));
    try std.testing.expectEqualStrings("/usr/local/bin/solana-zig", try driver_bpf.parseSolanaZigEnv("/usr/local/bin/solana-zig"));
}

test "versionMajorMinorMatches accepts 0.16.x" {
    try std.testing.expect(versionMajorMinorMatches("0.16.0", 0, 16));
    try std.testing.expect(versionMajorMinorMatches("0.16.5-dev", 0, 16));
    try std.testing.expect(!versionMajorMinorMatches("0.15.1", 0, 16));
    try std.testing.expect(!versionMajorMinorMatches("", 0, 16));
}

test "versionMajor parses the leading integer" {
    try std.testing.expectEqual(@as(?u32, 5), versionMajor("5.1.1"));
    try std.testing.expectEqual(@as(?u32, 5), versionMajor("5.0"));
    try std.testing.expectEqual(@as(?u32, null), versionMajor("five"));
}
