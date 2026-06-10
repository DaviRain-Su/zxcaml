//! LSP session temp-directory lifecycle and toolchain resolution.
//!
//! RESPONSIBILITIES:
//! - Create the per-PID `/tmp/omlz_lsp_<pid>` scratch directory on demand
//!   and hand out numbered `.ml` document paths inside it.
//! - Sweep stale scratch directories (and legacy flat temp files) left by
//!   dead LSP processes, plus the current PID's own directory on shutdown.
//! - Resolve the `omlz` binary the server spawns for diagnostics, hover,
//!   and test runs.
const std = @import("std");
const Io = std.Io;

/// Historical cwd-relative fallback used when no installed sibling exists.
pub const default_omlz_path = "zig-out/bin/omlz";

/// Resolves the `omlz` binary to spawn: prefer a sibling of the running
/// `omlz-lsp` executable so an installed server works outside the repo
/// root, falling back to the historical cwd-relative path.
pub fn resolveOmlzPath(io: Io, allocator: std.mem.Allocator) ![]u8 {
    if (std.process.executableDirPathAlloc(io, allocator)) |exe_dir| {
        defer allocator.free(exe_dir);
        const candidate = try std.fs.path.join(allocator, &.{ exe_dir, "omlz" });
        if (isExecutable(io, candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    } else |_| {}

    return allocator.dupe(u8, default_omlz_path);
}

fn isExecutable(io: Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

pub fn ensureTempDir(io: Io, allocator: std.mem.Allocator, temp_dir_created: *bool) !void {
    if (temp_dir_created.*) return;

    const tmp_dir_path = try tempDirPath(allocator, std.posix.system.getpid());
    defer allocator.free(tmp_dir_path);

    std.Io.Dir.createDirAbsolute(io, tmp_dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    temp_dir_created.* = true;
}

fn tempDirPath(allocator: std.mem.Allocator, pid: std.posix.pid_t) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/omlz_lsp_{d}", .{pid});
}

pub fn tempPath(allocator: std.mem.Allocator, next_doc_id: *u64) ![]u8 {
    next_doc_id.* += 1;
    return std.fmt.allocPrint(
        allocator,
        "/tmp/omlz_lsp_{d}/{d}.ml",
        .{ std.posix.system.getpid(), next_doc_id.* },
    );
}

pub fn cleanupTempFiles(io: Io, remove_current_pid: bool) !void {
    var tmp_dir = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer tmp_dir.close(io);

    const current_pid = std.posix.system.getpid();
    var iter = tmp_dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                const pid = parseLspTempDirPid(entry.name) orelse continue;
                if (!shouldRemoveTempPath(pid, current_pid, remove_current_pid)) continue;
                tmp_dir.deleteTree(io, entry.name) catch {};
            },
            .file => {
                const pid = parseLegacyTempFilePid(entry.name) orelse continue;
                if (!shouldRemoveTempPath(pid, current_pid, remove_current_pid)) continue;
                tmp_dir.deleteFile(io, entry.name) catch {};
            },
            else => continue,
        }
    }
}

fn parseLspTempDirPid(name: []const u8) ?std.posix.pid_t {
    const prefix = "omlz_lsp_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;

    const rest = name[prefix.len..];
    const parsed = parsePositivePidPrefix(rest) orelse return null;
    if (parsed.consumed != rest.len) return null;
    return parsed.pid;
}

fn parseLegacyTempFilePid(name: []const u8) ?std.posix.pid_t {
    const prefix = "omlz_lsp_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (!std.mem.endsWith(u8, name, ".ml")) return null;

    const rest = name[prefix.len..];
    const parsed = parsePositivePidPrefix(rest) orelse return null;
    if (parsed.consumed >= rest.len or rest[parsed.consumed] != '_') return null;
    return parsed.pid;
}

const ParsedPid = struct {
    pid: std.posix.pid_t,
    consumed: usize,
};

fn parsePositivePidPrefix(rest: []const u8) ?ParsedPid {
    if (rest.len == 0) return null;

    var pid_end: usize = 0;
    while (pid_end < rest.len and std.ascii.isDigit(rest[pid_end])) : (pid_end += 1) {}
    if (pid_end == 0) return null;

    const pid = std.fmt.parseInt(std.posix.pid_t, rest[0..pid_end], 10) catch return null;
    if (pid <= 0) return null;
    return .{ .pid = pid, .consumed = pid_end };
}

fn shouldRemoveTempPath(pid: std.posix.pid_t, current_pid: std.posix.pid_t, remove_current_pid: bool) bool {
    if (pid == current_pid and remove_current_pid) return true;
    return isDeadPid(pid);
}

fn isDeadPid(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @as(std.posix.SIG, @enumFromInt(0))) catch |err| switch (err) {
        error.ProcessNotFound => return true,
        else => return false,
    };
    return false;
}
