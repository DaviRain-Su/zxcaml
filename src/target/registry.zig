const std = @import("std");

pub const Family = enum {
    native,
    solana_sbf,
    generic_wasm,
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
    wasm_module,
};

pub const BuildDispatch = enum {
    native,
    bpf,
    wasm,
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

fn isSupportedTarget(target: TargetContract) bool {
    return target.support_status == .supported;
}

fn isBuildDispatchable(target: TargetContract) bool {
    return switch (target.support_status) {
        .supported, .experimental => true,
        .reserved, .accepted => false,
    };
}

pub fn supportedTargets(allocator: std.mem.Allocator) ![]*const TargetContract {
    return supportedTargetsInRegistry(allocator, registry[0..]);
}

fn supportedTargetsInRegistry(allocator: std.mem.Allocator, targets: []const TargetContract) ![]*const TargetContract {
    var supported = std.ArrayList(*const TargetContract).empty;
    defer supported.deinit(allocator);

    for (targets) |*target| {
        if (!isSupportedTarget(target.*)) continue;
        try supported.append(allocator, target);
    }

    return supported.toOwnedSlice(allocator);
}

pub fn lookupByCliName(name: []const u8) ?*const TargetContract {
    return lookupByCliNameInRegistry(registry[0..], name);
}

fn lookupByCliNameInRegistry(targets: []const TargetContract, name: []const u8) ?*const TargetContract {
    for (targets) |*target| {
        if (std.mem.eql(u8, target.cli_name, name)) return target;
    }
    return null;
}

pub fn resolveBuildTarget(name: []const u8) !*const TargetContract {
    return resolveBuildTargetInRegistry(registry[0..], name);
}

fn resolveBuildTargetInRegistry(targets: []const TargetContract, name: []const u8) !*const TargetContract {
    const target = lookupByCliNameInRegistry(targets, name) orelse return error.UnsupportedBuildTarget;
    if (!isBuildDispatchable(target.*)) return error.UnsupportedBuildTarget;
    return target;
}

pub fn acceptedTargetNamesText(allocator: std.mem.Allocator) ![]u8 {
    return acceptedTargetNamesTextInRegistry(allocator, registry[0..]);
}

fn acceptedTargetNamesTextInRegistry(allocator: std.mem.Allocator, targets: []const TargetContract) ![]u8 {
    var rendered = std.ArrayList(u8).empty;
    defer rendered.deinit(allocator);

    var supported_count: usize = 0;
    for (targets) |target| {
        if (isBuildDispatchable(target)) supported_count += 1;
    }

    var emitted_count: usize = 0;
    for (targets) |target| {
        if (!isBuildDispatchable(target)) continue;

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
    .{
        .cli_name = "wasm",
        .family = .generic_wasm,
        .support_status = .experimental,
        .backend_facade = "zig_codegen",
        .backend_output_language = "zig",
        .artifact_type = .wasm_module,
        .runtime_adapter = "experimental generic freestanding wasm runtime",
        .host_adapter = "none (import-free)",
        .entrypoint_contract = "exported pure functions",
        .calling_convention = "WebAssembly export ABI",
        .memory_plan = "freestanding linear memory + arena",
        .panic_error_strategy = "trap aborts module",
        .build_dispatch = .wasm,
        .keep_zig_supported = true,
        .requires_output_path = false,
        .supports_no_srcmap = false,
    },
};

fn syntheticUnsupportedTarget(name: []const u8, support_status: SupportStatus) TargetContract {
    const is_wasm = std.mem.eql(u8, name, "wasm");
    return .{
        .cli_name = name,
        .family = if (is_wasm) .generic_wasm else .native,
        .support_status = support_status,
        .backend_facade = "zig_codegen",
        .backend_output_language = "zig",
        .artifact_type = if (is_wasm) .wasm_module else .executable,
        .runtime_adapter = if (is_wasm) "experimental generic freestanding wasm runtime" else "runtime/zig/synthetic_entry.zig",
        .host_adapter = if (is_wasm) "none (import-free)" else "none",
        .entrypoint_contract = if (is_wasm) "exported pure functions" else "synthetic unsupported fixture",
        .calling_convention = if (is_wasm) "WebAssembly export ABI" else "fixture ABI",
        .memory_plan = if (is_wasm) "freestanding linear memory + arena" else "fixture only",
        .panic_error_strategy = if (is_wasm) "trap aborts module" else "fixture only",
        .build_dispatch = if (is_wasm) .wasm else .native,
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

test "registry: lookup exposes experimental generic wasm metadata" {
    const target = lookupByCliName("wasm") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("wasm", target.cli_name);
    try std.testing.expectEqualStrings("generic_wasm", @tagName(target.family));
    try std.testing.expectEqual(SupportStatus.experimental, target.support_status);
    try std.testing.expectEqualStrings("zig_codegen", target.backend_facade);
    try std.testing.expectEqualStrings("zig", target.backend_output_language);
    try std.testing.expectEqualStrings("wasm_module", @tagName(target.artifact_type));
    try std.testing.expectEqualStrings("experimental generic freestanding wasm runtime", target.runtime_adapter);
    try std.testing.expectEqualStrings("none (import-free)", target.host_adapter);
    try std.testing.expectEqualStrings("exported pure functions", target.entrypoint_contract);
    try std.testing.expectEqualStrings("WebAssembly export ABI", target.calling_convention);
    try std.testing.expectEqualStrings("freestanding linear memory + arena", target.memory_plan);
    try std.testing.expectEqualStrings("trap aborts module", target.panic_error_strategy);
    try std.testing.expectEqualStrings("wasm", @tagName(target.build_dispatch));
    try std.testing.expect(target.keep_zig_supported);
    try std.testing.expect(!target.requires_output_path);
    try std.testing.expect(!target.supports_no_srcmap);
}

test "registry: support status semantics only expose current supported targets" {
    const supported = try supportedTargets(std.testing.allocator);
    defer std.testing.allocator.free(supported);

    for (supported) |target| {
        try std.testing.expectEqual(SupportStatus.supported, target.support_status);
    }
}

test "registry: exact lowercase wasm is dispatchable while future targets stay rejected" {
    const wasm = try resolveBuildTarget("wasm");
    try std.testing.expectEqualStrings("wasm", wasm.cli_name);
    try std.testing.expectEqual(SupportStatus.experimental, wasm.support_status);
    try std.testing.expectEqualStrings("wasm", @tagName(wasm.build_dispatch));

    try std.testing.expectEqual(@as(?*const TargetContract, null), lookupByCliName("near"));
    try std.testing.expectEqual(@as(?*const TargetContract, null), lookupByCliName("evm"));
    try std.testing.expectError(error.UnsupportedBuildTarget, resolveBuildTarget("near"));
    try std.testing.expectError(error.UnsupportedBuildTarget, resolveBuildTarget("evm"));
    try std.testing.expectError(error.UnsupportedBuildTarget, resolveBuildTarget("wasm32"));
    try std.testing.expectError(error.UnsupportedBuildTarget, resolveBuildTarget("generic-wasm"));
    try std.testing.expectError(error.UnsupportedBuildTarget, resolveBuildTarget("webassembly"));
    try std.testing.expectError(error.UnsupportedBuildTarget, resolveBuildTarget("WASM"));
}

test "registry: accepted target diagnostic is registry-derived" {
    const rendered = try acceptedTargetNamesText(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("native, bpf or wasm", rendered);
}

test "registry: dispatch kind resolves from looked-up target" {
    const native = try resolveBuildTarget("native");
    try std.testing.expectEqual(BuildDispatch.native, native.build_dispatch);

    const bpf = try resolveBuildTarget("bpf");
    try std.testing.expectEqual(BuildDispatch.bpf, bpf.build_dispatch);

    const wasm = try resolveBuildTarget("wasm");
    try std.testing.expectEqualStrings("wasm", @tagName(wasm.build_dispatch));
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

    try std.testing.expectEqualStrings("native, wasm or bpf", rendered);
}

test "registry: synthetic experimental entries are dispatchable while reserved ones are not" {
    const fixture = syntheticUnsupportedFixture();

    const native = try resolveBuildTargetInRegistry(fixture[0..], "native");
    try std.testing.expectEqual(BuildDispatch.native, native.build_dispatch);

    const wasm = try resolveBuildTargetInRegistry(fixture[0..], "wasm");
    try std.testing.expectEqualStrings("wasm", @tagName(wasm.build_dispatch));

    const bpf = try resolveBuildTargetInRegistry(fixture[0..], "bpf");
    try std.testing.expectEqual(BuildDispatch.bpf, bpf.build_dispatch);

    try std.testing.expectError(error.UnsupportedBuildTarget, resolveBuildTargetInRegistry(fixture[0..], "near"));
}
