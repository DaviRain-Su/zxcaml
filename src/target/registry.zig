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

fn isBuildDispatchSupported(target: TargetContract) bool {
    return target.support_status == .supported;
}

pub fn supportedTargets(allocator: std.mem.Allocator) ![]*const TargetContract {
    return supportedTargetsInRegistry(allocator, registry[0..]);
}

fn supportedTargetsInRegistry(allocator: std.mem.Allocator, targets: []const TargetContract) ![]*const TargetContract {
    var supported = std.ArrayList(*const TargetContract).empty;
    defer supported.deinit(allocator);

    for (targets) |*target| {
        if (!isBuildDispatchSupported(target.*)) continue;
        try supported.append(allocator, target);
    }

    return supported.toOwnedSlice(allocator);
}

pub fn lookupByCliName(name: []const u8) ?*const TargetContract {
    return lookupByCliNameInRegistry(registry[0..], name);
}

fn lookupByCliNameInRegistry(targets: []const TargetContract, name: []const u8) ?*const TargetContract {
    for (targets) |*target| {
        if (!isBuildDispatchSupported(target.*)) continue;
        if (std.mem.eql(u8, target.cli_name, name)) return target;
    }
    return null;
}

pub fn resolveBuildTarget(name: []const u8) !*const TargetContract {
    return resolveBuildTargetInRegistry(registry[0..], name);
}

fn resolveBuildTargetInRegistry(targets: []const TargetContract, name: []const u8) !*const TargetContract {
    return lookupByCliNameInRegistry(targets, name) orelse error.UnsupportedBuildTarget;
}

pub fn acceptedTargetNamesText(allocator: std.mem.Allocator) ![]u8 {
    return acceptedTargetNamesTextInRegistry(allocator, registry[0..]);
}

fn acceptedTargetNamesTextInRegistry(allocator: std.mem.Allocator, targets: []const TargetContract) ![]u8 {
    var rendered = std.ArrayList(u8).empty;
    defer rendered.deinit(allocator);

    var supported_count: usize = 0;
    for (targets) |target| {
        if (isBuildDispatchSupported(target)) supported_count += 1;
    }

    var emitted_count: usize = 0;
    for (targets) |target| {
        if (!isBuildDispatchSupported(target)) continue;

        if (emitted_count > 0) {
            const separator = if (emitted_count + 1 == supported_count) " or " else ", ";
            try rendered.appendSlice(allocator, separator);
        }
        try rendered.appendSlice(allocator, target.cli_name);
        emitted_count += 1;
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

fn syntheticUnsupportedTarget(name: []const u8, support_status: SupportStatus) TargetContract {
    return .{
        .cli_name = name,
        .family = .native,
        .support_status = support_status,
        .backend_facade = "zig_codegen",
        .backend_output_language = "zig",
        .artifact_type = .executable,
        .runtime_adapter = "runtime/zig/synthetic_entry.zig",
        .host_adapter = "none",
        .entrypoint_contract = "synthetic unsupported fixture",
        .calling_convention = "fixture ABI",
        .memory_plan = "fixture only",
        .panic_error_strategy = "fixture only",
        .build_dispatch = .native,
        .keep_zig_supported = true,
        .requires_output_path = false,
        .supports_no_srcmap = false,
    };
}

fn syntheticUnsupportedFixture() [4]TargetContract {
    return .{
        registry[0],
        syntheticUnsupportedTarget("wasm", .experimental),
        registry[1],
        syntheticUnsupportedTarget("near", .reserved),
    };
}

test "registry: supported targets are exactly native and bpf" {
    const supported = try supportedTargets(std.testing.allocator);
    defer std.testing.allocator.free(supported);

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
    const supported = try supportedTargets(std.testing.allocator);
    defer std.testing.allocator.free(supported);

    for (supported) |target| {
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

test "registry: synthetic unsupported entries stay out of supported target names" {
    const fixture = syntheticUnsupportedFixture();

    const supported = try supportedTargetsInRegistry(std.testing.allocator, fixture[0..]);
    defer std.testing.allocator.free(supported);

    try std.testing.expectEqual(@as(usize, 2), supported.len);
    try std.testing.expectEqualStrings("native", supported[0].cli_name);
    try std.testing.expectEqualStrings("bpf", supported[1].cli_name);
}

test "registry: synthetic unsupported entries stay out of accepted target diagnostics" {
    const fixture = syntheticUnsupportedFixture();

    const rendered = try acceptedTargetNamesTextInRegistry(std.testing.allocator, fixture[0..]);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("native or bpf", rendered);
}

test "registry: synthetic unsupported entries cannot become build dispatch targets" {
    const fixture = syntheticUnsupportedFixture();

    const native = try resolveBuildTargetInRegistry(fixture[0..], "native");
    try std.testing.expectEqual(BuildDispatch.native, native.build_dispatch);

    const bpf = try resolveBuildTargetInRegistry(fixture[0..], "bpf");
    try std.testing.expectEqual(BuildDispatch.bpf, bpf.build_dispatch);

    try std.testing.expectError(error.UnsupportedBuildTarget, resolveBuildTargetInRegistry(fixture[0..], "wasm"));
    try std.testing.expectError(error.UnsupportedBuildTarget, resolveBuildTargetInRegistry(fixture[0..], "near"));
}
