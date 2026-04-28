//! Shared helpers for the Zig test harnesses.
//!
//! RESPONSIBILITIES:
//! - Provide Linux-safe corpus file discovery for tests that need glob-like
//!   iteration over repository fixtures.
//! - Avoid Zig 0.16's `std.Io.Dir.iterate`/`iter.next` Linux BADF crash in CI.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Returns basenames in `dir_path` ending with `suffix`, using the host shell
/// instead of Zig's directory iterator to avoid a Zig 0.16 Linux stdlib crash.
pub fn listBasenamesWithSuffix(allocator: Allocator, io: Io, dir_path: []const u8, suffix: []const u8) ![][]u8 {
    const script =
        \\export LC_ALL=C
        \\for f in "$1"/*"$2"; do
        \\  [ -e "$f" ] || continue
        \\  basename "$f"
        \\done
    ;
    const argv = [_][]const u8{ "sh", "-c", script, "zxcaml-list", dir_path, suffix };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.FileListingFailed,
        else => return error.FileListingFailed,
    }

    var names = std.ArrayList([]u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        try names.append(allocator, try allocator.dupe(u8, trimmed));
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return names.toOwnedSlice(allocator);
}

/// Frees a list returned by `listBasenamesWithSuffix`.
pub fn freeStringList(allocator: Allocator, names: [][]u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}
