//! Native build orchestration for emitted Zig source.
//!
//! RESPONSIBILITIES:
//! - Materialise runtime helper files next to generated `out/program.zig`.
//! - Drive `zig build-exe -O ReleaseSmall` for `--target=native`.
//! - Keep the native path independent from `sbpf-linker` and BPF tooling.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const exec = @import("exec.zig");
const runtime_bundle = @import("runtime_bundle.zig");

/// Options for the developer-convenience native build path.
pub const NativeBuildOptions = struct {
    generated_zig_path: []const u8 = "out/program.zig",
    native_entry_path: []const u8 = "out/native_entry.zig",
    output_path: []const u8,
};

/// Builds a hosted native executable from generated Zig source.
pub fn buildNative(allocator: Allocator, io: Io, options: NativeBuildOptions) !void {
    try runtime_bundle.materializeRuntime(allocator, io, .native);

    const emit_bin_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{options.output_path});
    defer allocator.free(emit_bin_arg);

    var argv = std.ArrayList([]const u8).empty;
    defer {
        for (argv.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-Mroot=")) allocator.free(arg);
        }
        argv.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{
        "zig",
        "build-exe",
        "-O",
        "ReleaseSmall",
    });
    try runtime_bundle.appendVendoredSdkModuleArgs(allocator, &argv, options.native_entry_path);
    try argv.append(allocator, emit_bin_arg);

    try exec.runAndForward(allocator, io, argv.items, error.NativeBuildFailed, .{});
}

test "native build wiring references vendored SDK modules and never references sbpf-linker" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).empty;
    defer {
        for (argv.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-Mroot=")) allocator.free(arg);
        }
        argv.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{
        "zig",
        "build-exe",
        "-O",
        "ReleaseSmall",
    });
    try runtime_bundle.appendVendoredSdkModuleArgs(allocator, &argv, "out/native_entry.zig");
    try argv.append(allocator, "-femit-bin=/tmp/m0_zero");

    try std.testing.expectEqualStrings("zig", argv.items[0]);
    try std.testing.expectEqualStrings("build-exe", argv.items[1]);
    try std.testing.expectEqualStrings("-O", argv.items[2]);
    try std.testing.expectEqualStrings("ReleaseSmall", argv.items[3]);
    const joined = try std.mem.join(allocator, " ", argv.items);
    defer allocator.free(joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "vendored_sdk") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "out/native_entry.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, argv.items[argv.items.len - 1], "/tmp/m0_zero") != null);
    for (argv.items) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "sbpf-linker") == null);
    }
}
