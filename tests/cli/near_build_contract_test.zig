//! CLI characterization tests for the experimental NEAR no-storage target contract.
//!
//! RESPONSIBILITIES:
//! - Verify only exact lowercase `--target=near` is accepted.
//! - Verify duplicate target flags fail before frontend/build side effects.
//! - Verify BPF-only source-map flags and misleading output suffixes are rejected
//!   before artifact creation with target-aware diagnostics.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli_options = @import("cli_options");

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn runCommand(allocator: Allocator, io: Io, argv: []const []const u8) !CommandResult {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
}

fn fileExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn outputContainsNeedle(stdout: []const u8, stderr: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, stdout, needle) != null or
        std.mem.indexOf(u8, stderr, needle) != null;
}

fn expectCommandSuccess(result: CommandResult, argv_label: []const u8) !void {
    if (result.exit_code != 0) {
        std.debug.print(
            "{s} failed\nexit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ argv_label, result.exit_code, result.stdout, result.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

fn runNearBuildWithArgs(
    allocator: Allocator,
    io: Io,
    target_flags: []const []const u8,
    extra_args: []const []const u8,
    source_path: []const u8,
    output_path: []const u8,
) !CommandResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, cli_options.omlz_bin);
    try argv.append(allocator, "build");
    try argv.appendSlice(allocator, target_flags);
    try argv.appendSlice(allocator, extra_args);
    try argv.append(allocator, source_path);
    try argv.append(allocator, "-o");
    try argv.append(allocator, output_path);

    return runCommand(allocator, io, argv.items);
}

fn runNearBuild(
    allocator: Allocator,
    io: Io,
    extra_args: []const []const u8,
    source_path: []const u8,
    output_path: ?[]const u8,
) !CommandResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, cli_options.omlz_bin);
    try argv.append(allocator, "build");
    try argv.append(allocator, "--target=near");
    try argv.appendSlice(allocator, extra_args);
    try argv.append(allocator, source_path);
    if (output_path) |path| {
        try argv.append(allocator, "-o");
        try argv.append(allocator, path);
    }

    return runCommand(allocator, io, argv.items);
}

fn expectWasmHeader(allocator: Allocator, io: Io, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024));
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 8);
    try std.testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x61), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x73), bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x6d), bytes[3]);
}

fn inspectNearWasm(allocator: Allocator, io: Io, wasm_path: []const u8) !CommandResult {
    const argv = [_][]const u8{
        "node",
        "tests/near/inspect_near_wasm.mjs",
        wasm_path,
    };
    return runCommand(allocator, io, &argv);
}

test "cli: near aliases fail before artifact side effects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const cases = [_]struct {
        target_flag: []const u8,
        output_path: []const u8,
    }{
        .{ .target_flag = "--target=NEAR", .output_path = "/tmp/zxcaml_near_alias_uppercase.wasm" },
        .{ .target_flag = "--target=Near", .output_path = "/tmp/zxcaml_near_alias_titlecase.wasm" },
        .{ .target_flag = "--target=near-wasm", .output_path = "/tmp/zxcaml_near_alias_near_wasm.wasm" },
        .{ .target_flag = "--target=near_no_storage", .output_path = "/tmp/zxcaml_near_alias_underscore.wasm" },
        .{ .target_flag = "--target=near-sdk", .output_path = "/tmp/zxcaml_near_alias_sdk.wasm" },
        .{ .target_flag = "--target=near-protocol", .output_path = "/tmp/zxcaml_near_alias_protocol.wasm" },
    };

    for (cases) |case| {
        cwd.deleteFile(io, case.output_path) catch {};

        const result = try runNearBuildWithArgs(
            allocator,
            io,
            &.{case.target_flag},
            &.{},
            "tests/fixtures/does_not_exist.ml",
            case.output_path,
        );
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try std.testing.expect(result.exit_code != 0);
        try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "unsupported build target; expected native, bpf, wasm or near."));
        try std.testing.expect(!outputContainsNeedle(result.stdout, result.stderr, "failed to run zxc-frontend subprocess"));
        try std.testing.expect(!fileExists(io, case.output_path));
    }
}

test "cli: near fixture builds to an explicit wasm artifact with the expected import/export ABI" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const output_path = "/tmp/zxcaml_mtf2_near_contract.wasm";

    cwd.deleteFile(io, output_path) catch {};
    defer cwd.deleteFile(io, output_path) catch {};

    const build_result = try runNearBuild(
        allocator,
        io,
        &.{"--keep-zig"},
        "examples/mtf2_near_no_storage.ml",
        output_path,
    );
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    try expectCommandSuccess(build_result, "omlz build --target=near examples/mtf2_near_no_storage.ml");

    try std.testing.expect(fileExists(io, output_path));
    try expectWasmHeader(allocator, io, output_path);
    try std.testing.expect(fileExists(io, "out/program.zig"));

    const inspect_result = try inspectNearWasm(allocator, io, output_path);
    defer allocator.free(inspect_result.stdout);
    defer allocator.free(inspect_result.stderr);
    try expectCommandSuccess(inspect_result, "node tests/near/inspect_near_wasm.mjs");
    try std.testing.expect(outputContainsNeedle(inspect_result.stdout, inspect_result.stderr, "imports=env.input:(i64)->(),env.register_len:(i64)->(i64),env.read_register:(i64,i64)->(),env.log_utf8:(i64,i64)->(),env.value_return:(i64,i64)->(),env.panic_utf8:(i64,i64)->()"));
    try std.testing.expect(outputContainsNeedle(inspect_result.stdout, inspect_result.stderr, "exports=memory:memory,entrypoint:()->()"));
}

test "cli: near defaults output to out/<program>.wasm" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const output_path = "out/mtf2_near_no_storage.wasm";

    cwd.deleteFile(io, output_path) catch {};
    defer cwd.deleteFile(io, output_path) catch {};

    const result = try runNearBuild(
        allocator,
        io,
        &.{},
        "examples/mtf2_near_no_storage.ml",
        null,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectCommandSuccess(result, "omlz build --target=near examples/mtf2_near_no_storage.ml");

    try std.testing.expect(fileExists(io, output_path));
    try expectWasmHeader(allocator, io, output_path);
}

test "cli: near rejects Solana syscall capabilities before artifact creation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const output_path = "/tmp/zxcaml_mtf2_near_reject_syscall.wasm";

    cwd.deleteFile(io, output_path) catch {};

    const result = try runNearBuild(
        allocator,
        io,
        &.{},
        "examples/syscall_test.ml",
        output_path,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "target `near`"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "Solana host API"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "Syscall.sol_sha256"));
    try std.testing.expect(!fileExists(io, output_path));
}

test "cli: near rejects account-shaped Solana entrypoints before artifact creation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const output_path = "/tmp/zxcaml_mtf2_near_reject_log_accounts.wasm";

    cwd.deleteFile(io, output_path) catch {};

    const result = try runNearBuild(
        allocator,
        io,
        &.{},
        "examples/log_accounts.ml",
        output_path,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "target `near`"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "Solana account API"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "account-shaped accounts parameter"));
    try std.testing.expect(!fileExists(io, output_path));
}

test "cli: near rejects duplicate target flags before artifact creation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const output_path = "/tmp/zxcaml_near_duplicate_target.wasm";

    cwd.deleteFile(io, output_path) catch {};

    const result = try runNearBuildWithArgs(
        allocator,
        io,
        &.{ "--target=near", "--target=wasm" },
        &.{},
        "tests/fixtures/does_not_exist.ml",
        output_path,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "duplicate `--target=<value>` flag"));
    try std.testing.expect(!outputContainsNeedle(result.stdout, result.stderr, "failed to run zxc-frontend subprocess"));
    try std.testing.expect(!fileExists(io, output_path));
}

test "cli: near rejects --no-srcmap before artifact creation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const output_path = "/tmp/zxcaml_near_no_srcmap.wasm";

    cwd.deleteFile(io, output_path) catch {};

    const result = try runNearBuildWithArgs(
        allocator,
        io,
        &.{"--target=near"},
        &.{"--no-srcmap"},
        "tests/fixtures/does_not_exist.ml",
        output_path,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "--no-srcmap"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "target `near`"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "--target=bpf"));
    try std.testing.expect(!outputContainsNeedle(result.stdout, result.stderr, "failed to run zxc-frontend subprocess"));
    try std.testing.expect(!fileExists(io, output_path));
}

test "cli: near rejects misleading explicit output suffixes before artifact creation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const cases = [_][]const u8{
        "/tmp/zxcaml_near_wrong_suffix.so",
        "/tmp/zxcaml_near_wrong_suffix.map",
        "/tmp/zxcaml_near_wrong_suffix",
    };

    for (cases) |output_path| {
        cwd.deleteFile(io, output_path) catch {};

        const result = try runNearBuildWithArgs(
            allocator,
            io,
            &.{"--target=near"},
            &.{},
            "tests/fixtures/does_not_exist.ml",
            output_path,
        );
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try std.testing.expect(result.exit_code != 0);
        try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "target `near`"));
        try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "experimental NEAR no-storage adapter"));
        try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "requires -o <path.wasm>"));
        try std.testing.expect(!outputContainsNeedle(result.stdout, result.stderr, "failed to run zxc-frontend subprocess"));
        try std.testing.expect(!fileExists(io, output_path));
    }
}
