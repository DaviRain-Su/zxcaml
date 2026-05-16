const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    lock_path: []const u8 = "build/.omlz-build.lock",
    retries: usize = 600,
    sleep_ns: u64 = 100 * std.time.ns_per_ms,
};

pub const BuildLock = struct {
    path: ?[]u8 = null,
    released: bool = false,

    pub fn deinit(self: *BuildLock, allocator: Allocator, io: Io) void {
        if (self.path) |path| {
            if (!self.released) {
                std.Io.Dir.cwd().deleteFile(io, path) catch {};
                self.released = true;
            }
            allocator.free(path);
        }
    }
};

pub fn acquire(
    allocator: Allocator,
    io: Io,
    environ: ?std.process.Environ,
    options: Options,
) !BuildLock {
    if (environ) |env| {
        const inherited_lock = std.process.Environ.getAlloc(env, allocator, "ZXCAML_BUILD_LOCK_HELD") catch |err| switch (err) {
            error.EnvironmentVariableMissing => null,
            else => return err,
        };
        defer if (inherited_lock) |value| allocator.free(value);
        if (inherited_lock) |value| {
            if (std.mem.eql(u8, value, "1")) return .{};
        }
    }

    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(options.lock_path)) |dir_path| {
        try cwd.createDirPath(io, dir_path);
    }

    for (0..options.retries) |_| {
        const file = cwd.createFile(io, options.lock_path, .{
            .truncate = false,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (options.sleep_ns > 0) try std.Io.sleep(
                    io,
                    std.Io.Duration.fromNanoseconds(@intCast(options.sleep_ns)),
                    .awake,
                );
                continue;
            },
            else => return err,
        };
        file.close(io);
        return .{ .path = try allocator.dupe(u8, options.lock_path) };
    }

    return error.BuildLockUnavailable;
}

test "build lock serializes access through the shared sentinel path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/test-build-lock-{d}.lock",
        .{std.posix.system.getpid()},
    );
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var first = try acquire(
        allocator,
        io,
        null,
        .{
            .lock_path = path,
            .retries = 1,
            .sleep_ns = 0,
        },
    );
    defer first.deinit(allocator, io);

    try std.testing.expectError(error.BuildLockUnavailable, acquire(
        allocator,
        io,
        null,
        .{
            .lock_path = path,
            .retries = 1,
            .sleep_ns = 0,
        },
    ));
}
