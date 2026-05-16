//! CLI characterization tests for the experimental generic WASM smoke target.
//!
//! RESPONSIBILITIES:
//! - Verify a pure numeric fixture builds to a nonempty `.wasm` artifact.
//! - Verify the emitted artifact stays import-free and passes real Node
//!   WebAssembly acceptance with BigInt results.
//! - Verify Solana host/account APIs are rejected under `--target=wasm`
//!   before artifact creation with actionable diagnostics.

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

fn expectCommandSuccess(result: CommandResult, argv_label: []const u8) !void {
    if (result.exit_code != 0) {
        std.debug.print(
            "{s} failed\nexit={d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ argv_label, result.exit_code, result.stdout, result.stderr },
        );
    }
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

fn fileExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn runWasmBuild(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    output_path: []const u8,
) !CommandResult {
    const argv = [_][]const u8{
        cli_options.omlz_bin,
        "build",
        "--target=wasm",
        source_path,
        "-o",
        output_path,
    };
    return runCommand(allocator, io, &argv);
}

fn runNodeAcceptance(
    allocator: Allocator,
    io: Io,
    wasm_path: []const u8,
) !CommandResult {
    const argv = [_][]const u8{
        "node",
        "tests/wasm/mtf1_acceptance.mjs",
        wasm_path,
    };
    return runCommand(allocator, io, &argv);
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

fn outputContainsNeedle(stdout: []const u8, stderr: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, stdout, needle) != null or
        std.mem.indexOf(u8, stderr, needle) != null;
}

test "cli: wasm pure numeric fixture builds and passes Node acceptance" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const output_path = "/tmp/zxcaml_mtf1_acceptance_contract.wasm";

    cwd.deleteFile(io, output_path) catch {};

    const build_result = try runWasmBuild(
        allocator,
        io,
        "examples/mtf1_pure_numeric.ml",
        output_path,
    );
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    try expectCommandSuccess(build_result, "omlz build --target=wasm examples/mtf1_pure_numeric.ml");

    try std.testing.expect(fileExists(io, output_path));
    try expectWasmHeader(allocator, io, output_path);

    const node_result = try runNodeAcceptance(allocator, io, output_path);
    defer allocator.free(node_result.stdout);
    defer allocator.free(node_result.stderr);
    try expectCommandSuccess(node_result, "node tests/wasm/mtf1_acceptance.mjs");
    try std.testing.expect(outputContainsNeedle(node_result.stdout, node_result.stderr, "imports=[]"));
    try std.testing.expect(outputContainsNeedle(node_result.stdout, node_result.stderr, "exports=memory,entrypoint"));
    try std.testing.expect(outputContainsNeedle(node_result.stdout, node_result.stderr, "entrypointType=bigint"));
    try std.testing.expect(outputContainsNeedle(node_result.stdout, node_result.stderr, "entrypointValue=42"));
}

test "cli: wasm rejects Solana syscall capabilities before artifact creation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const output_path = "/tmp/zxcaml_mtf1_reject_syscall.wasm";

    cwd.deleteFile(io, output_path) catch {};

    const result = try runWasmBuild(
        allocator,
        io,
        "examples/syscall_test.ml",
        output_path,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "target `wasm`"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "Solana host API"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "Syscall.sol_sha256"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "pure logic only"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "--target=bpf"));
    try std.testing.expect(!fileExists(io, output_path));
}

test "cli: wasm rejects Solana account helpers before artifact creation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const output_path = "/tmp/zxcaml_mtf1_reject_account_api.wasm";

    cwd.deleteFile(io, output_path) catch {};

    const result = try runWasmBuild(
        allocator,
        io,
        "examples/account_guard.ml",
        output_path,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "target `wasm`"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "Solana host API"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "Account.is_signer"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "pure logic only"));
    try std.testing.expect(outputContainsNeedle(result.stdout, result.stderr, "--target=bpf"));
    try std.testing.expect(!fileExists(io, output_path));
}
