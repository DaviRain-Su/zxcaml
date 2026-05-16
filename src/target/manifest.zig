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
    .{ .src_path = "runtime/zig/entry_context.zig", .out_path = "out/runtime/entry_context.zig" },
    .{ .src_path = "runtime/zig/programs/common.zig", .out_path = "out/runtime/programs/common.zig" },
    .{ .src_path = "runtime/zig/programs/transfer_sol.zig", .out_path = "out/runtime/programs/transfer_sol.zig" },
    .{ .src_path = "runtime/zig/programs/vault.zig", .out_path = "out/runtime/programs/vault.zig" },
    .{ .src_path = "runtime/zig/programs/vault_v2.zig", .out_path = "out/runtime/programs/vault_v2.zig" },
    .{ .src_path = "runtime/zig/programs/hackathon_greet.zig", .out_path = "out/runtime/programs/hackathon_greet.zig" },
    .{ .src_path = "runtime/zig/programs/combined.zig", .out_path = "out/runtime/programs/combined.zig" },
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
    .{ .src_path = "runtime/zig/sdk/root.zig", .out_path = "out/runtime/sdk/root.zig" },
    .{ .src_path = "runtime/zig/sdk/import_smoke.zig", .out_path = "out/runtime/sdk/import_smoke.zig" },
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

const wasm_entry_runtime_file: RuntimeFile = .{
    .src_path = "runtime/wasm/entry.zig",
    .out_path = "out/wasm_entry.zig",
};

const near_entry_runtime_file: RuntimeFile = .{
    .src_path = "runtime/near/entry.zig",
    .out_path = "out/near_entry.zig",
};

const shared_runtime_files = expected_shared_runtime_files;
const native_runtime_files = shared_runtime_files ++ [_]RuntimeFile{native_entry_runtime_file};
const bpf_runtime_files = shared_runtime_files ++ [_]RuntimeFile{bpf_entry_runtime_file};
const wasm_runtime_files = [_]RuntimeFile{
    .{ .src_path = "runtime/zig/arena.zig", .out_path = "out/runtime/arena.zig" },
    .{ .src_path = "runtime/wasm/account.zig", .out_path = "out/runtime/account.zig" },
    .{ .src_path = "runtime/zig/panic.zig", .out_path = "out/runtime/panic.zig" },
    .{ .src_path = "runtime/zig/prelude.zig", .out_path = "out/runtime/prelude.zig" },
    wasm_entry_runtime_file,
};
const near_runtime_files = [_]RuntimeFile{
    .{ .src_path = "runtime/zig/arena.zig", .out_path = "out/runtime/arena.zig" },
    .{ .src_path = "runtime/near/account.zig", .out_path = "out/runtime/account.zig" },
    .{ .src_path = "runtime/near/host.zig", .out_path = "out/runtime/near_host.zig" },
    .{ .src_path = "runtime/zig/panic.zig", .out_path = "out/runtime/panic.zig" },
    .{ .src_path = "runtime/zig/prelude.zig", .out_path = "out/runtime/prelude.zig" },
    near_entry_runtime_file,
};

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
    .{
        .cli_name = "wasm",
        .build_dispatch = .wasm,
        .files = wasm_runtime_files[0..],
        .entry_src_path = wasm_entry_runtime_file.src_path,
        .entry_out_path = wasm_entry_runtime_file.out_path,
    },
    .{
        .cli_name = "near",
        .build_dispatch = .near,
        .files = near_runtime_files[0..],
        .entry_src_path = near_entry_runtime_file.src_path,
        .entry_out_path = near_entry_runtime_file.out_path,
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

const expected_wasm_runtime_files = wasm_runtime_files;
const expected_near_runtime_files = near_runtime_files;

test "runtime manifest: implemented targets include native, bpf, wasm, and near" {
    const supported = try target_registry.supportedTargets(std.testing.allocator);
    defer std.testing.allocator.free(supported);

    const implemented = implementedTargets();
    try std.testing.expectEqual(@as(usize, 4), implemented.len);
    try std.testing.expectEqual(@as(usize, 2), supported.len);
    try std.testing.expectEqualStrings("native", implemented[0].cli_name);
    try std.testing.expectEqualStrings("bpf", implemented[1].cli_name);
    try std.testing.expectEqualStrings("wasm", implemented[2].cli_name);
    try std.testing.expectEqualStrings("near", implemented[3].cli_name);
}

test "runtime manifest: native runtime files mirror the current materialization" {
    const manifest = runtimeManifestForDispatch(.native);
    try expectRuntimeFiles(expected_native_runtime_files[0..], manifest.files);
}

test "runtime manifest: bpf runtime files mirror the current materialization" {
    const manifest = runtimeManifestForDispatch(.bpf);
    try expectRuntimeFiles(expected_bpf_runtime_files[0..], manifest.files);
}

test "runtime manifest: wasm runtime files stay target-specific and minimal" {
    const manifest = runtimeManifestForDispatch(.wasm);
    try expectRuntimeFiles(expected_wasm_runtime_files[0..], manifest.files);
}

test "runtime manifest: near runtime files stay target-specific and minimal" {
    const manifest = runtimeManifestForDispatch(.near);
    try expectRuntimeFiles(expected_near_runtime_files[0..], manifest.files);
}

test "runtime manifest: entry shims remain target specific" {
    const native = runtimeManifestForDispatch(.native);
    try std.testing.expectEqualStrings("runtime/zig/native_entry.zig", native.entry_src_path);
    try std.testing.expectEqualStrings("out/native_entry.zig", native.entry_out_path);

    const bpf = runtimeManifestForDispatch(.bpf);
    try std.testing.expectEqualStrings("runtime/zig/bpf_entry.zig", bpf.entry_src_path);
    try std.testing.expectEqualStrings("out/bpf_entry.zig", bpf.entry_out_path);

    const wasm = runtimeManifestForDispatch(.wasm);
    try std.testing.expectEqualStrings("runtime/wasm/entry.zig", wasm.entry_src_path);
    try std.testing.expectEqualStrings("out/wasm_entry.zig", wasm.entry_out_path);

    const near = runtimeManifestForDispatch(.near);
    try std.testing.expectEqualStrings("runtime/near/entry.zig", near.entry_src_path);
    try std.testing.expectEqualStrings("out/near_entry.zig", near.entry_out_path);
}

test "runtime manifest: vendored SDK adapter root materializes for native and bpf entry builds" {
    for (implementedTargets()) |manifest| {
        if (manifest.build_dispatch == .wasm or manifest.build_dispatch == .near) continue;
        for (manifest.files) |file| {
            if (std.mem.eql(u8, file.src_path, "runtime/zig/sdk/root.zig")) {
                try std.testing.expectEqualStrings("out/runtime/sdk/root.zig", file.out_path);
                break;
            }
        } else {
            return error.MissingVendoredSdkRuntimeRoot;
        }
    }
}

test "runtime manifest: shared and target specific files stay duplicate free" {
    for (implementedTargets()) |manifest| {
        try validateRuntimeFileList(manifest.files);
    }
}

test "runtime manifest: wasm excludes solana, bpf, sdk, and source-map files" {
    const manifest = runtimeManifestForDispatch(.wasm);

    for (manifest.files) |file| {
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "bpf_entry") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "native_entry") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "sdk/root.zig") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "syscalls.zig") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "sysvar.zig") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "spl_token.zig") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "programs/") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.out_path, ".so") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.out_path, ".map") == null);
    }
}

test "runtime manifest: near excludes solana, native, generic-wasm-only, wasi, and source-map files" {
    const manifest = runtimeManifestForDispatch(.near);

    for (manifest.files) |file| {
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "bpf_entry") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "native_entry") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "wasm/") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "sdk/root.zig") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "syscalls.zig") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "sysvar.zig") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "spl_token.zig") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "programs/") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.src_path, "wasi") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.out_path, ".so") == null);
        try std.testing.expect(std.mem.indexOf(u8, file.out_path, ".map") == null);
    }
}
