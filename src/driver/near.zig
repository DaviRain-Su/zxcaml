//! NEAR no-storage build orchestration for emitted Zig source.
//!
//! RESPONSIBILITIES:
//! - Materialise the NEAR runtime shim next to generated `out/program.zig`.
//! - Invoke Zig for `wasm32-freestanding` method-style module output.
//! - Publish the final `.wasm` only after a successful build.
//! - Avoid native, Solana/BPF, npm, and sandbox acceptance tooling.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const exec = @import("exec.zig");
const target_manifest = @import("../target/manifest.zig");

pub const NearBuildOptions = struct {
    near_entry_path: []const u8 = "out/near_entry.zig",
    output_path: []const u8,
    quiet: bool = false,
};

fn appendNearBuildArgs(
    allocator: Allocator,
    argv: *std.ArrayList([]const u8),
    options: NearBuildOptions,
) !void {
    const root_module_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{options.near_entry_path});
    errdefer allocator.free(root_module_arg);
    const emit_bin_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{options.output_path});
    errdefer allocator.free(emit_bin_arg);

    try argv.appendSlice(allocator, &.{
        "zig",
        "build-exe",
        "-target",
        "wasm32-freestanding",
        "-O",
        "ReleaseSmall",
        "-fno-entry",
        "--export=entrypoint",
    });
    try argv.append(allocator, root_module_arg);
    try argv.append(allocator, emit_bin_arg);
}

fn temporaryArtifactPath(allocator: Allocator, output_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.omlz-near.tmp", .{output_path});
}

fn publishBuiltArtifact(io: Io, temp_output_path: []const u8, final_output_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(final_output_path)) |dir_path| {
        if (std.fs.path.isAbsolute(dir_path)) {
            std.Io.Dir.accessAbsolute(io, dir_path, .{}) catch |err| switch (err) {
                error.FileNotFound => try std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir),
                else => return err,
            };
        } else {
            try cwd.createDirPath(io, dir_path);
        }
    }
    if (std.fs.path.isAbsolute(final_output_path)) {
        std.Io.Dir.deleteFileAbsolute(io, final_output_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try std.Io.Dir.renameAbsolute(temp_output_path, final_output_path, io);
        return;
    }

    cwd.deleteFile(io, final_output_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try cwd.rename(temp_output_path, cwd, final_output_path, io);
}

pub fn buildNear(allocator: Allocator, io: Io, options: NearBuildOptions) !void {
    try target_manifest.materializeRuntimeForDispatch(allocator, io, .near);

    const temp_output_path = try temporaryArtifactPath(allocator, options.output_path);
    defer allocator.free(temp_output_path);
    defer std.Io.Dir.cwd().deleteFile(io, temp_output_path) catch {};

    var argv = std.ArrayList([]const u8).empty;
    defer {
        for (argv.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-Mroot=") or std.mem.startsWith(u8, arg, "-femit-bin=")) {
                allocator.free(arg);
            }
        }
        argv.deinit(allocator);
    }

    try appendNearBuildArgs(allocator, &argv, .{
        .near_entry_path = options.near_entry_path,
        .output_path = temp_output_path,
        .quiet = options.quiet,
    });

    try exec.runAndForward(allocator, io, argv.items, error.NearBuildFailed, .{
        .forward_success_output = !options.quiet,
    });
    try publishBuiltArtifact(io, temp_output_path, options.output_path);
}

test "near build argv targets freestanding module output and excludes native, Solana, and sandbox tooling" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).empty;
    defer {
        for (argv.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-Mroot=") or std.mem.startsWith(u8, arg, "-femit-bin=")) {
                allocator.free(arg);
            }
        }
        argv.deinit(allocator);
    }

    try appendNearBuildArgs(allocator, &argv, .{
        .near_entry_path = "out/near_entry.zig",
        .output_path = "/tmp/mtf2-near-smoke.wasm",
    });

    try std.testing.expectEqualStrings("zig", argv.items[0]);
    try std.testing.expectEqualStrings("build-exe", argv.items[1]);
    try std.testing.expectEqualStrings("-target", argv.items[2]);
    try std.testing.expectEqualStrings("wasm32-freestanding", argv.items[3]);

    const joined = try std.mem.join(allocator, " ", argv.items);
    defer allocator.free(joined);

    try std.testing.expect(std.mem.indexOf(u8, joined, "-femit-bin=/tmp/mtf2-near-smoke.wasm") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-Mroot=out/near_entry.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-fno-entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--export=entrypoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "solana-zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "sbf-solana") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "out/native_entry.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "out/bpf_entry.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "out/wasm_entry.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "near-sandbox") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "neard") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "npm") == null);
}

test "near build leaves the final artifact path untouched when zig compilation fails" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const output_path = "/tmp/zxcaml_near_failed_publish_guard.wasm";
    const sentinel = "stale artifact must remain untouched";

    try cwd.writeFile(io, .{
        .sub_path = output_path,
        .data = sentinel,
        .flags = .{ .truncate = true },
    });
    defer cwd.deleteFile(io, output_path) catch {};

    try std.testing.expectError(error.NearBuildFailed, buildNear(allocator, io, .{
        .near_entry_path = "out/definitely_missing_near_entry.zig",
        .output_path = output_path,
        .quiet = true,
    }));

    const preserved = try cwd.readFileAlloc(io, output_path, allocator, .limited(1024));
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings(sentinel, preserved);
}
