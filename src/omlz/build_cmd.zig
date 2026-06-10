//! `omlz build` subcommand implementation.
//!
//! RESPONSIBILITIES:
//! - Validate build flags against the resolved target contract.
//! - Lower, optimize, capability-check, region-infer, arena-lower, and emit
//!   Zig source for each build dispatch (native, BPF, WASM, NEAR).
//! - Drive the per-target build drivers under the shared build lock.
//! - Emit the deterministic source-map sidecar for BPF builds.
const std = @import("std");
const Io = std.Io;
const cmd_common = @import("cmd_common.zig");
const cli = @import("cli_surface.zig");
const build_lock = @import("../build_lock.zig");
const driver_build = @import("../driver/build.zig");
const driver_bpf = @import("../driver/bpf.zig");
const driver_near = @import("../driver/near.zig");
const driver_srcmap = @import("../driver/srcmap.zig");
const driver_wasm = @import("../driver/wasm.zig");
const frontend_bridge = @import("../frontend_bridge/ttree.zig");
const core_ir = @import("../core/ir.zig");
const arena_lower = @import("../lower/arena.zig");
const zig_codegen = @import("../backend/zig_codegen.zig");
const target_capability = @import("../target/capability.zig");
const target_manifest = @import("../target/manifest.zig");
const target_registry = @import("../target/registry.zig");

const writeStderr = cmd_common.writeStderr;
const BuildArgs = cli.BuildArgs;

fn ensureTargetCapabilitiesOrExit(
    init: std.process.Init,
    target: *const target_registry.TargetContract,
    module: core_ir.Module,
) !void {
    const result = try target_capability.scanTargetModuleCapabilities(init.gpa, target, module);
    switch (result) {
        .ok => {},
        .unsupported => |diagnostic| {
            const rendered = try target_capability.renderUnsupportedCapabilityDiagnostic(init.gpa, diagnostic);
            defer init.gpa.free(rendered);
            try writeStderr(init.io, rendered);
            std.process.exit(1);
        },
    }
}

pub fn validateBuildArgsForTargetOrExit(
    io: Io,
    target: *const target_registry.TargetContract,
    build_args: BuildArgs,
) !void {
    if (!build_args.srcmap and !target.supports_no_srcmap) {
        try writeStderr(io, "error: `--no-srcmap` is only supported for BPF/source-map-capable targets; target `");
        try writeStderr(io, target.cli_name);
        try writeStderr(io, "` does not emit source maps. Use --target=bpf or omit `--no-srcmap`.\n");
        std.process.exit(1);
    }

    if (std.mem.eql(u8, target.cli_name, "near")) {
        if (build_args.output_path) |output_path| {
            if (!std.mem.endsWith(u8, output_path, ".wasm")) {
                try writeStderr(io, "error: target `near` is an experimental NEAR no-storage adapter and requires -o <path.wasm>; got `");
                try writeStderr(io, output_path);
                try writeStderr(io, "`.\n");
                std.process.exit(1);
            }
        }
    }
}

pub fn writeUnsupportedBuildTarget(io: Io, allocator: std.mem.Allocator) !void {
    const accepted = try target_registry.acceptedTargetNamesText(allocator);
    defer allocator.free(accepted);

    const message = try std.fmt.allocPrint(allocator, "error: unsupported build target; expected {s}.\n", .{accepted});
    defer allocator.free(message);

    try writeStderr(io, message);
}

/// Shared front half of every build dispatch: optimize, capability-check,
/// and region-infer the module, leaving the result allocated in
/// `core_arena`.
fn prepareCoreModuleOrExit(
    init: std.process.Init,
    core_arena: *std.heap.ArenaAllocator,
    target: *const target_registry.TargetContract,
    module: frontend_bridge.Module,
    build_args: BuildArgs,
) !core_ir.Module {
    const optimized_core_module = try cmd_common.lowerAndOptimizeOrExit(init, core_arena, module);
    try ensureTargetCapabilitiesOrExit(init, target, optimized_core_module);
    return cmd_common.inferRegionsOrExit(init, core_arena, optimized_core_module, build_args.diagnostics);
}

/// Arena-lowers the inferred module and emits Zig source owned by
/// `init.gpa`. The intermediate lowered module only lives for the emission.
fn emitZigSourceOrExit(init: std.process.Init, inferred_core_module: core_ir.Module) ![]const u8 {
    var lowered_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer lowered_arena.deinit();

    var impl: arena_lower.ArenaStrategy = .{ .allocator = lowered_arena.allocator() };
    const lowered_module = impl.loweringStrategy().lowerModule(inferred_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to lower with ArenaStrategy: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    return zig_codegen.emitModule(init.gpa, lowered_module) catch |err| {
        try writeStderr(init.io, "error: failed to emit Zig source: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
}

pub fn buildNear(
    init: std.process.Init,
    target: *const target_registry.TargetContract,
    module: frontend_bridge.Module,
    build_args: BuildArgs,
) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const inferred_core_module = try prepareCoreModuleOrExit(init, &core_arena, target, module, build_args);
    const source = try emitZigSourceOrExit(init, inferred_core_module);
    defer init.gpa.free(source);

    const program_name = try sourceMapProgramName(init.gpa, build_args.input_file);
    defer init.gpa.free(program_name);

    const output_path = build_args.output_path orelse try sourceMapOutputPath(init.gpa, program_name, ".wasm");
    defer if (build_args.output_path == null) init.gpa.free(output_path);

    const cwd = std.Io.Dir.cwd();
    const near_build_err: ?anyerror = blk: {
        var shared_build_lock = build_lock.acquire(init.gpa, init.io, init.minimal.environ, .{}) catch |err| break :blk err;
        defer shared_build_lock.deinit(init.gpa, init.io);

        try cwd.createDirPath(init.io, "out");
        try cwd.writeFile(init.io, .{
            .sub_path = "out/program.zig",
            .data = source,
            .flags = .{ .truncate = true },
        });

        try target_manifest.materializeRuntimeForDispatch(init.gpa, init.io, .near);

        driver_near.buildNear(init.gpa, init.io, .{
            .near_entry_path = "out/near_entry.zig",
            .output_path = output_path,
            .quiet = build_args.quiet,
        }) catch |err| break :blk err;
        break :blk null;
    };
    if (near_build_err) |err| {
        try writeStderr(init.io, "error: NEAR build failed: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    }
}

pub fn buildNative(
    init: std.process.Init,
    target: *const target_registry.TargetContract,
    module: frontend_bridge.Module,
    build_args: BuildArgs,
) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const inferred_core_module = try prepareCoreModuleOrExit(init, &core_arena, target, module, build_args);
    const source = try emitZigSourceOrExit(init, inferred_core_module);
    defer init.gpa.free(source);

    const cwd = std.Io.Dir.cwd();
    const native_build_err: ?anyerror = blk: {
        var shared_build_lock = build_lock.acquire(init.gpa, init.io, init.minimal.environ, .{}) catch |err| break :blk err;
        defer shared_build_lock.deinit(init.gpa, init.io);

        try cwd.createDirPath(init.io, "out");
        try cwd.writeFile(init.io, .{
            .sub_path = "out/program.zig",
            .data = source,
            .flags = .{ .truncate = true },
        });

        try target_manifest.materializeRuntimeForDispatch(init.gpa, init.io, .native);

        driver_build.buildNative(init.gpa, init.io, .{
            .generated_zig_path = "out/program.zig",
            .native_entry_path = "out/native_entry.zig",
            .output_path = build_args.output_path.?,
        }) catch |err| break :blk err;
        break :blk null;
    };
    if (native_build_err) |err| {
        try writeStderr(init.io, "error: native build failed: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    }
}

pub fn buildBpf(
    init: std.process.Init,
    target: *const target_registry.TargetContract,
    module: frontend_bridge.Module,
    build_args: BuildArgs,
) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const inferred_core_module = try prepareCoreModuleOrExit(init, &core_arena, target, module, build_args);
    const source = try emitZigSourceOrExit(init, inferred_core_module);
    defer init.gpa.free(source);

    const cwd = std.Io.Dir.cwd();
    const source_map_program = try sourceMapProgramName(init.gpa, build_args.input_file);
    defer init.gpa.free(source_map_program);

    const output_path = build_args.output_path orelse try sourceMapOutputPath(init.gpa, source_map_program, ".so");
    defer if (build_args.output_path == null) init.gpa.free(output_path);

    var source_map_input: ?driver_bpf.SourceMapInput = null;
    var source_map_hook: ?driver_bpf.SourceMapHook = null;
    var source_map_context: SourceMapSidecarContext = undefined;
    var source_map_path: ?[]const u8 = null;
    var output_source_map_path: ?[]const u8 = null;
    defer if (source_map_path) |path| init.gpa.free(path);
    defer if (output_source_map_path) |path| init.gpa.free(path);

    if (build_args.srcmap) {
        // Investigation report §4 fixed the canonical sidecar contract:
        // minified, deterministic JSON in out/<program>.map with no
        // timestamps or IDs. When `-o` points elsewhere, mirror the same
        // bytes next to the requested artifact so custom-output `unmap`
        // workflows can read `<output>.map` directly without losing the
        // canonical `out/<program>.map` path that existing validators use.
        source_map_path = try sourceMapOutputPath(init.gpa, source_map_program, ".map");
        if (build_args.output_path) |explicit_output_path| {
            const candidate_output_map = try sourceMapSiblingPathForOutput(init.gpa, explicit_output_path);
            if (std.mem.eql(u8, candidate_output_map, source_map_path.?)) {
                init.gpa.free(candidate_output_map);
            } else {
                output_source_map_path = candidate_output_map;
            }
        }
        source_map_input = .{
            .program = source_map_program,
            .module = inferred_core_module,
        };
        source_map_context = .{
            .allocator = init.gpa,
            .io = init.io,
            .path = source_map_path.?,
            .output_path = output_source_map_path,
        };
        source_map_hook = .{
            .context = &source_map_context,
            .emit = emitSourceMapSidecar,
        };
    }

    const bpf_build_err: ?anyerror = blk: {
        var shared_build_lock = build_lock.acquire(init.gpa, init.io, init.minimal.environ, .{}) catch |err| break :blk err;
        defer shared_build_lock.deinit(init.gpa, init.io);

        try cwd.createDirPath(init.io, "out");
        try cwd.writeFile(init.io, .{
            .sub_path = "out/program.zig",
            .data = source,
            .flags = .{ .truncate = true },
        });

        try target_manifest.materializeRuntimeForDispatch(init.gpa, init.io, .bpf);

        driver_bpf.buildBpf(init.gpa, init.io, .{
            .output_path = output_path,
            .environ = init.minimal.environ,
            .source_map = source_map_input,
            .source_map_hook = source_map_hook,
            .quiet = build_args.quiet,
        }) catch |err| break :blk err;
        break :blk null;
    };
    if (bpf_build_err) |err| {
        switch (err) {
            error.InvalidSolanaZigCommand => {
                try writeStderr(init.io, "error: SOLANA_ZIG=0 is not supported; use unset/empty/1 for default or a direct command/path\n");
            },
            else => {
                try writeStderr(init.io, "error: BPF build failed: ");
                try writeStderr(init.io, @errorName(err));
                try writeStderr(init.io, "\n");
            },
        }
        std.process.exit(1);
    }
}

pub fn buildWasm(
    init: std.process.Init,
    target: *const target_registry.TargetContract,
    module: frontend_bridge.Module,
    build_args: BuildArgs,
) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const inferred_core_module = try prepareCoreModuleOrExit(init, &core_arena, target, module, build_args);
    const source = try emitZigSourceOrExit(init, inferred_core_module);
    defer init.gpa.free(source);

    const program_name = try sourceMapProgramName(init.gpa, build_args.input_file);
    defer init.gpa.free(program_name);

    const output_path = build_args.output_path orelse try sourceMapOutputPath(init.gpa, program_name, ".wasm");
    defer if (build_args.output_path == null) init.gpa.free(output_path);

    const cwd = std.Io.Dir.cwd();
    const wasm_build_err: ?anyerror = blk: {
        var shared_build_lock = build_lock.acquire(init.gpa, init.io, init.minimal.environ, .{}) catch |err| break :blk err;
        defer shared_build_lock.deinit(init.gpa, init.io);

        try cwd.createDirPath(init.io, "out");
        try cwd.writeFile(init.io, .{
            .sub_path = "out/program.zig",
            .data = source,
            .flags = .{ .truncate = true },
        });

        try target_manifest.materializeRuntimeForDispatch(init.gpa, init.io, .wasm);

        driver_wasm.buildWasm(init.gpa, init.io, .{
            .wasm_entry_path = "out/wasm_entry.zig",
            .output_path = output_path,
            .quiet = build_args.quiet,
        }) catch |err| break :blk err;
        break :blk null;
    };
    if (wasm_build_err) |err| {
        try writeStderr(init.io, "error: WASM build failed: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    }
}

pub fn sourceMapProgramName(allocator: std.mem.Allocator, input_file: []const u8) ![]const u8 {
    const base = std.fs.path.basename(input_file);
    const stem = if (std.mem.endsWith(u8, base, ".ml")) base[0 .. base.len - ".ml".len] else base;
    return allocator.dupe(u8, stem);
}

pub fn sourceMapOutputPath(allocator: std.mem.Allocator, program: []const u8, extension: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "out/{s}{s}", .{ program, extension });
}

fn sourceMapSiblingPathForOutput(allocator: std.mem.Allocator, output_path: []const u8) ![]const u8 {
    const extension = std.fs.path.extension(output_path);
    if (extension.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}.map", .{output_path});
    }
    return std.fmt.allocPrint(allocator, "{s}.map", .{output_path[0 .. output_path.len - extension.len]});
}

const SourceMapSidecarContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    output_path: ?[]const u8 = null,
};

fn emitSourceMapSidecar(context: *anyopaque, build: driver_bpf.SourceMapBuild) anyerror!void {
    const sidecar: *SourceMapSidecarContext = @ptrCast(@alignCast(context));
    const bytes = try driver_srcmap.serializeJson(sidecar.allocator, build.schema);
    defer sidecar.allocator.free(bytes);

    try std.Io.Dir.cwd().writeFile(sidecar.io, .{
        .sub_path = sidecar.path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });

    if (sidecar.output_path) |output_path| {
        try std.Io.Dir.cwd().writeFile(sidecar.io, .{
            .sub_path = output_path,
            .data = bytes,
            .flags = .{ .truncate = true },
        });
    }
}

test "source-map sibling path follows explicit build output" {
    const path = try sourceMapSiblingPathForOutput(std.testing.allocator, "/tmp/zxcaml/solana_hello.so");
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/zxcaml/solana_hello.map", path);
}
