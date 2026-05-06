//! Native build orchestration for emitted Zig source.
//!
//! RESPONSIBILITIES:
//! - Materialise runtime helper files next to generated `out/program.zig`.
//! - Drive `zig build-exe -O ReleaseSmall` for `--target=native`.
//! - Keep the native path independent from `sbpf-linker` and BPF tooling.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Options for the developer-convenience native build path.
pub const NativeBuildOptions = struct {
    generated_zig_path: []const u8 = "out/program.zig",
    native_entry_path: []const u8 = "out/native_entry.zig",
    output_path: []const u8,
};

const RuntimeFile = struct {
    src_path: []const u8,
    out_path: []const u8,
};

const runtime_files = [_]RuntimeFile{
    .{ .src_path = "runtime/zig/arena.zig", .out_path = "out/runtime/arena.zig" },
    .{ .src_path = "runtime/zig/account.zig", .out_path = "out/runtime/account.zig" },
    .{ .src_path = "runtime/zig/cpi.zig", .out_path = "out/runtime/cpi.zig" },
    .{ .src_path = "runtime/zig/programs/common.zig", .out_path = "out/runtime/programs/common.zig" },
    .{ .src_path = "runtime/zig/programs/transfer_sol.zig", .out_path = "out/runtime/programs/transfer_sol.zig" },
    .{ .src_path = "runtime/zig/programs/vault.zig", .out_path = "out/runtime/programs/vault.zig" },
    .{ .src_path = "runtime/zig/programs/vault_v2.zig", .out_path = "out/runtime/programs/vault_v2.zig" },
    .{ .src_path = "runtime/zig/programs/hackathon_greet.zig", .out_path = "out/runtime/programs/hackathon_greet.zig" },
    .{ .src_path = "runtime/zig/programs/token_vault.zig", .out_path = "out/runtime/programs/token_vault.zig" },
    .{ .src_path = "runtime/zig/programs/escrow_full.zig", .out_path = "out/runtime/programs/escrow_full.zig" },
    .{ .src_path = "runtime/zig/programs/dao_voting.zig", .out_path = "out/runtime/programs/dao_voting.zig" },
    .{ .src_path = "runtime/zig/programs/ata_transfer.zig", .out_path = "out/runtime/programs/ata_transfer.zig" },
    .{ .src_path = "runtime/zig/programs/spl_burn.zig", .out_path = "out/runtime/programs/spl_burn.zig" },
    .{ .src_path = "runtime/zig/programs/spl_close_account.zig", .out_path = "out/runtime/programs/spl_close_account.zig" },
    .{ .src_path = "runtime/zig/programs/spl_revoke.zig", .out_path = "out/runtime/programs/spl_revoke.zig" },
    .{ .src_path = "runtime/zig/programs/order_book.zig", .out_path = "out/runtime/programs/order_book.zig" },
    .{ .src_path = "runtime/zig/programs/ata.zig", .out_path = "out/runtime/programs/ata.zig" },
    .{ .src_path = "runtime/zig/bs58.zig", .out_path = "out/runtime/bs58.zig" },
    .{ .src_path = "runtime/zig/panic.zig", .out_path = "out/runtime/panic.zig" },
    .{ .src_path = "runtime/zig/prelude.zig", .out_path = "out/runtime/prelude.zig" },
    .{ .src_path = "runtime/zig/spl_token.zig", .out_path = "out/runtime/spl_token.zig" },
    .{ .src_path = "runtime/zig/syscalls.zig", .out_path = "out/runtime/syscalls.zig" },
    .{ .src_path = "runtime/zig/native_entry.zig", .out_path = "out/native_entry.zig" },
};

/// Builds a hosted native executable from generated Zig source.
pub fn buildNative(allocator: Allocator, io: Io, options: NativeBuildOptions) !void {
    try materializeRuntime(allocator, io);

    const emit_bin_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{options.output_path});
    defer allocator.free(emit_bin_arg);

    const argv = [_][]const u8{
        "zig",
        "build-exe",
        "-O",
        "ReleaseSmall",
        emit_bin_arg,
        options.native_entry_path,
    };

    const completed = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(completed.stdout);
    defer allocator.free(completed.stderr);

    if (completed.stdout.len > 0) try writeStdout(io, completed.stdout);
    if (completed.stderr.len > 0) try writeStderr(io, completed.stderr);

    switch (completed.term) {
        .exited => |code| {
            if (code == 0) return;
            return error.NativeBuildFailed;
        },
        .signal, .stopped, .unknown => return error.NativeBuildFailed,
    }
}

fn materializeRuntime(allocator: Allocator, io: Io) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/runtime");
    try cwd.createDirPath(io, "out/runtime/programs");

    inline for (runtime_files) |file| {
        const contents = try cwd.readFileAlloc(io, file.src_path, allocator, .limited(128 * 1024));
        defer allocator.free(contents);

        try cwd.writeFile(io, .{
            .sub_path = file.out_path,
            .data = contents,
            .flags = .{ .truncate = true },
        });
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

test "native build argv uses zig build-exe and never references sbpf-linker" {
    const emit_bin_arg = try std.fmt.allocPrint(std.testing.allocator, "-femit-bin={s}", .{"/tmp/m0_zero"});
    defer std.testing.allocator.free(emit_bin_arg);

    const argv = [_][]const u8{
        "zig",
        "build-exe",
        "-O",
        "ReleaseSmall",
        emit_bin_arg,
        "out/native_entry.zig",
    };

    try std.testing.expectEqualStrings("zig", argv[0]);
    try std.testing.expectEqualStrings("build-exe", argv[1]);
    try std.testing.expectEqualStrings("-O", argv[2]);
    try std.testing.expectEqualStrings("ReleaseSmall", argv[3]);
    try std.testing.expect(std.mem.indexOf(u8, emit_bin_arg, "/tmp/m0_zero") != null);
    for (argv) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "sbpf-linker") == null);
    }
}
