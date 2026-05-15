const std = @import("std");

pub const Family = enum {
    native,
    solana_sbf,
};

pub const SupportStatus = enum {
    reserved,
    experimental,
    accepted,
    supported,
};

pub const ArtifactType = enum {
    executable,
    solana_shared_object,
};

pub const BuildDispatch = enum {
    native,
    bpf,
};

pub const TargetContract = struct {
    cli_name: []const u8,
    family: Family,
    support_status: SupportStatus,
    backend_facade: []const u8,
    backend_output_language: []const u8,
    artifact_type: ArtifactType,
    runtime_adapter: []const u8,
    host_adapter: []const u8,
    entrypoint_contract: []const u8,
    calling_convention: []const u8,
    memory_plan: []const u8,
    panic_error_strategy: []const u8,
    build_dispatch: BuildDispatch,
    keep_zig_supported: bool,
    requires_output_path: bool,
    supports_no_srcmap: bool,
};

pub fn supportedTargets() []const TargetContract {
    return registry[0..];
}

pub fn lookupByCliName(name: []const u8) ?*const TargetContract {
    for (&registry) |*target| {
        if (std.mem.eql(u8, target.cli_name, name)) return target;
    }
    return null;
}

pub fn resolveBuildTarget(name: []const u8) !*const TargetContract {
    return lookupByCliName(name) orelse error.UnsupportedBuildTarget;
}

pub fn acceptedTargetNamesText(allocator: std.mem.Allocator) ![]u8 {
    var rendered = std.ArrayList(u8).empty;
    defer rendered.deinit(allocator);

    const targets = supportedTargets();
    for (targets, 0..) |target, index| {
        if (index > 0) {
            const separator = if (index + 1 == targets.len) " or " else ", ";
            try rendered.appendSlice(allocator, separator);
        }
        try rendered.appendSlice(allocator, target.cli_name);
    }

    return rendered.toOwnedSlice(allocator);
}

const registry = [_]TargetContract{
    .{
        .cli_name = "native",
        .family = .native,
        .support_status = .supported,
        .backend_facade = "zig_codegen",
        .backend_output_language = "zig",
        .artifact_type = .executable,
        .runtime_adapter = "runtime/zig/native_entry.zig",
        .host_adapter = "none",
        .entrypoint_contract = "native main(argc, argv)",
        .calling_convention = "host ABI",
        .memory_plan = "native process stack + arena",
        .panic_error_strategy = "panic aborts process",
        .build_dispatch = .native,
        .keep_zig_supported = true,
        .requires_output_path = true,
        .supports_no_srcmap = false,
    },
    .{
        .cli_name = "bpf",
        .family = .solana_sbf,
        .support_status = .supported,
        .backend_facade = "zig_codegen",
        .backend_output_language = "zig",
        .artifact_type = .solana_shared_object,
        .runtime_adapter = "runtime/zig/bpf_entry.zig",
        .host_adapter = "solana syscalls + solana-zig",
        .entrypoint_contract = "solana entrypoint(program_id, accounts, instruction_data)",
        .calling_convention = "Solana SBF ABI",
        .memory_plan = "3 KiB stack-bounded arena",
        .panic_error_strategy = "panic aborts entrypoint",
        .build_dispatch = .bpf,
        .keep_zig_supported = true,
        .requires_output_path = false,
        .supports_no_srcmap = true,
    },
};

test "registry: supported targets are exactly native and bpf" {
    const supported = supportedTargets();
    try std.testing.expectEqual(@as(usize, 2), supported.len);
    try std.testing.expectEqualStrings("native", supported[0].cli_name);
    try std.testing.expectEqualStrings("bpf", supported[1].cli_name);
}

test "registry: lookup exposes native metadata" {
    const target = lookupByCliName("native") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("native", target.cli_name);
    try std.testing.expectEqual(Family.native, target.family);
    try std.testing.expectEqual(SupportStatus.supported, target.support_status);
    try std.testing.expectEqualStrings("zig_codegen", target.backend_facade);
    try std.testing.expectEqualStrings("zig", target.backend_output_language);
    try std.testing.expectEqual(ArtifactType.executable, target.artifact_type);
    try std.testing.expectEqualStrings("runtime/zig/native_entry.zig", target.runtime_adapter);
    try std.testing.expectEqualStrings("none", target.host_adapter);
    try std.testing.expectEqualStrings("native main(argc, argv)", target.entrypoint_contract);
    try std.testing.expectEqualStrings("host ABI", target.calling_convention);
    try std.testing.expectEqualStrings("native process stack + arena", target.memory_plan);
    try std.testing.expectEqualStrings("panic aborts process", target.panic_error_strategy);
    try std.testing.expectEqual(BuildDispatch.native, target.build_dispatch);
    try std.testing.expect(target.keep_zig_supported);
    try std.testing.expect(target.requires_output_path);
    try std.testing.expect(!target.supports_no_srcmap);
}

test "registry: lookup exposes bpf metadata" {
    const target = lookupByCliName("bpf") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("bpf", target.cli_name);
    try std.testing.expectEqual(Family.solana_sbf, target.family);
    try std.testing.expectEqual(SupportStatus.supported, target.support_status);
    try std.testing.expectEqualStrings("zig_codegen", target.backend_facade);
    try std.testing.expectEqualStrings("zig", target.backend_output_language);
    try std.testing.expectEqual(ArtifactType.solana_shared_object, target.artifact_type);
    try std.testing.expectEqualStrings("runtime/zig/bpf_entry.zig", target.runtime_adapter);
    try std.testing.expectEqualStrings("solana syscalls + solana-zig", target.host_adapter);
    try std.testing.expectEqualStrings("solana entrypoint(program_id, accounts, instruction_data)", target.entrypoint_contract);
    try std.testing.expectEqualStrings("Solana SBF ABI", target.calling_convention);
    try std.testing.expectEqualStrings("3 KiB stack-bounded arena", target.memory_plan);
    try std.testing.expectEqualStrings("panic aborts entrypoint", target.panic_error_strategy);
    try std.testing.expectEqual(BuildDispatch.bpf, target.build_dispatch);
    try std.testing.expect(target.keep_zig_supported);
    try std.testing.expect(!target.requires_output_path);
    try std.testing.expect(target.supports_no_srcmap);
}

test "registry: support status semantics only expose current supported targets" {
    for (supportedTargets()) |target| {
        try std.testing.expectEqual(SupportStatus.supported, target.support_status);
    }
}

test "registry: unsupported build targets stay rejected" {
    try std.testing.expectEqual(@as(?*const TargetContract, null), lookupByCliName("wasm"));
    try std.testing.expectEqual(@as(?*const TargetContract, null), lookupByCliName("near"));
    try std.testing.expectEqual(@as(?*const TargetContract, null), lookupByCliName("evm"));
    try std.testing.expectError(error.UnsupportedBuildTarget, resolveBuildTarget("wasm"));
}

test "registry: accepted target diagnostic is registry-derived" {
    const rendered = try acceptedTargetNamesText(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("native or bpf", rendered);
}

test "registry: dispatch kind resolves from looked-up target" {
    const native = try resolveBuildTarget("native");
    try std.testing.expectEqual(BuildDispatch.native, native.build_dispatch);

    const bpf = try resolveBuildTarget("bpf");
    try std.testing.expectEqual(BuildDispatch.bpf, bpf.build_dispatch);
}
