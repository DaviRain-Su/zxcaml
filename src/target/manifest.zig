const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const target_registry = @import("registry.zig");

pub const RuntimeFile = struct {
    src_path: []const u8,
    out_path: []const u8,
};

pub const RuntimeManifest = struct {
    cli_name: []const u8,
    build_dispatch: target_registry.BuildDispatch,
    files: []const RuntimeFile,
    entry_src_path: []const u8,
    entry_out_path: []const u8,
};

fn expectRuntimeFiles(expected: []const RuntimeFile, actual: []const RuntimeFile) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |want, index| {
        const got = actual[index];
        try std.testing.expectEqualStrings(want.src_path, got.src_path);
        try std.testing.expectEqualStrings(want.out_path, got.out_path);
    }
}

const expected_shared_runtime_files = [_]RuntimeFile{
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
    .{ .src_path = "runtime/zig/sysvar.zig", .out_path = "out/runtime/sysvar.zig" },
};

const native_entry_runtime_file: RuntimeFile = .{
    .src_path = "runtime/zig/native_entry.zig",
    .out_path = "out/native_entry.zig",
};

const bpf_entry_runtime_file: RuntimeFile = .{
    .src_path = "runtime/zig/bpf_entry.zig",
    .out_path = "out/bpf_entry.zig",
};

const shared_runtime_files = expected_shared_runtime_files;
const native_runtime_files = shared_runtime_files ++ [_]RuntimeFile{native_entry_runtime_file};
const bpf_runtime_files = shared_runtime_files ++ [_]RuntimeFile{bpf_entry_runtime_file};

const manifests = [_]RuntimeManifest{
    .{
        .cli_name = "native",
        .build_dispatch = .native,
        .files = native_runtime_files[0..],
        .entry_src_path = native_entry_runtime_file.src_path,
        .entry_out_path = native_entry_runtime_file.out_path,
    },
    .{
        .cli_name = "bpf",
        .build_dispatch = .bpf,
        .files = bpf_runtime_files[0..],
        .entry_src_path = bpf_entry_runtime_file.src_path,
        .entry_out_path = bpf_entry_runtime_file.out_path,
    },
};

pub fn implementedTargets() []const RuntimeManifest {
    return manifests[0..];
}

pub fn runtimeManifestForDispatch(dispatch: target_registry.BuildDispatch) *const RuntimeManifest {
    for (&manifests) |*manifest| {
        if (manifest.build_dispatch == dispatch) return manifest;
    }
    unreachable;
}

pub fn materializeRuntimeForDispatch(allocator: Allocator, io: Io, dispatch: target_registry.BuildDispatch) !void {
    const manifest = runtimeManifestForDispatch(dispatch);
    try validateRuntimeFileList(manifest.files);

    const cwd = std.Io.Dir.cwd();
    for (manifest.files) |file| {
        if (std.fs.path.dirname(file.out_path)) |dir_path| {
            try cwd.createDirPath(io, dir_path);
        }

        const contents = try cwd.readFileAlloc(io, file.src_path, allocator, .limited(128 * 1024));
        defer allocator.free(contents);

        try cwd.writeFile(io, .{
            .sub_path = file.out_path,
            .data = contents,
            .flags = .{ .truncate = true },
        });
    }
}

fn validateRuntimeFileList(files: []const RuntimeFile) !void {
    for (files, 0..) |file, index| {
        if (file.src_path.len == 0 or file.out_path.len == 0) {
            return error.InvalidRuntimeManifest;
        }

        for (files[index + 1 ..]) |other| {
            if (std.mem.eql(u8, file.src_path, other.src_path) or std.mem.eql(u8, file.out_path, other.out_path)) {
                return error.InvalidRuntimeManifest;
            }
        }
    }
}

const expected_native_runtime_files = expected_shared_runtime_files ++ [_]RuntimeFile{
    .{ .src_path = "runtime/zig/native_entry.zig", .out_path = "out/native_entry.zig" },
};

const expected_bpf_runtime_files = expected_shared_runtime_files ++ [_]RuntimeFile{
    .{ .src_path = "runtime/zig/bpf_entry.zig", .out_path = "out/bpf_entry.zig" },
};

test "runtime manifest: implemented targets stay limited to native and bpf" {
    const supported = try target_registry.supportedTargets(std.testing.allocator);
    defer std.testing.allocator.free(supported);

    const implemented = implementedTargets();
    try std.testing.expectEqual(@as(usize, 2), implemented.len);
    try std.testing.expectEqual(supported.len, implemented.len);
    try std.testing.expectEqualStrings("native", implemented[0].cli_name);
    try std.testing.expectEqualStrings("bpf", implemented[1].cli_name);
}

test "runtime manifest: native runtime files mirror the current materialization" {
    const manifest = runtimeManifestForDispatch(.native);
    try expectRuntimeFiles(expected_native_runtime_files[0..], manifest.files);
}

test "runtime manifest: bpf runtime files mirror the current materialization" {
    const manifest = runtimeManifestForDispatch(.bpf);
    try expectRuntimeFiles(expected_bpf_runtime_files[0..], manifest.files);
}

test "runtime manifest: entry shims remain target specific" {
    const native = runtimeManifestForDispatch(.native);
    try std.testing.expectEqualStrings("runtime/zig/native_entry.zig", native.entry_src_path);
    try std.testing.expectEqualStrings("out/native_entry.zig", native.entry_out_path);

    const bpf = runtimeManifestForDispatch(.bpf);
    try std.testing.expectEqualStrings("runtime/zig/bpf_entry.zig", bpf.entry_src_path);
    try std.testing.expectEqualStrings("out/bpf_entry.zig", bpf.entry_out_path);
}

test "runtime manifest: shared and target specific files stay duplicate free" {
    for (implementedTargets()) |manifest| {
        try validateRuntimeFileList(manifest.files);
    }
}
