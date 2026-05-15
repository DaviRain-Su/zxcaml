const std = @import("std");
const core_ir = @import("../core/ir.zig");
const target_registry = @import("registry.zig");

pub const Capability = enum {
    solana_host_api,
    account_data_mutation,

    pub fn label(self: Capability) []const u8 {
        return switch (self) {
            .solana_host_api => "Solana host API",
            .account_data_mutation => "Solana account mutation",
        };
    }
};

pub const CapabilityUsage = struct {
    capability: Capability,
    api_surface: []const u8,
    loc: ?core_ir.Loc = null,
};

pub const CapabilityPolicy = struct {
    target: *const target_registry.TargetContract,
    supported_capabilities: []const Capability,
    unsupported_guidance: []const u8,
};

pub const UnsupportedCapabilityDiagnostic = struct {
    target_cli_name: []const u8,
    capability: Capability,
    api_surface: []const u8,
    loc: ?core_ir.Loc,
    guidance: []const u8,
};

pub const ScanResult = union(enum) {
    ok,
    unsupported: UnsupportedCapabilityDiagnostic,
};

const current_supported_capabilities = [_]Capability{
    .solana_host_api,
    .account_data_mutation,
};

pub fn capabilityPolicyForTarget(target: *const target_registry.TargetContract) CapabilityPolicy {
    if (target.support_status != .supported) {
        return .{
            .target = target,
            .supported_capabilities = &.{},
            .unsupported_guidance = "This target is not currently supported; use a currently implemented target or remove the target-specific API.",
        };
    }

    return .{
        .target = target,
        .supported_capabilities = current_supported_capabilities[0..],
        .unsupported_guidance = "This target/capability pairing is not supported.",
    };
}

pub fn collectCapabilityUsages(allocator: std.mem.Allocator, module: core_ir.Module) ![]CapabilityUsage {
    var collector = UsageCollector{
        .allocator = allocator,
        .usages = std.ArrayList(CapabilityUsage).empty,
    };
    defer collector.usages.deinit(allocator);

    try collector.collectModule(module);
    return collector.usages.toOwnedSlice(allocator);
}

pub fn scanCapabilityUsages(policy: CapabilityPolicy, usages: []const CapabilityUsage) !ScanResult {
    for (usages) |usage| {
        if (policySupportsCapability(policy, usage.capability)) continue;
        return .{
            .unsupported = .{
                .target_cli_name = policy.target.cli_name,
                .capability = usage.capability,
                .api_surface = usage.api_surface,
                .loc = usage.loc,
                .guidance = policy.unsupported_guidance,
            },
        };
    }
    return .ok;
}

pub fn scanTargetModuleCapabilities(
    allocator: std.mem.Allocator,
    target: *const target_registry.TargetContract,
    module: core_ir.Module,
) !ScanResult {
    const usages = try collectCapabilityUsages(allocator, module);
    defer allocator.free(usages);
    return scanCapabilityUsages(capabilityPolicyForTarget(target), usages);
}

pub fn renderUnsupportedCapabilityDiagnostic(
    allocator: std.mem.Allocator,
    diagnostic: UnsupportedCapabilityDiagnostic,
) ![]u8 {
    const api_surface = try renderedApiSurface(allocator, diagnostic);
    defer if (api_surface.ptr != diagnostic.api_surface.ptr) allocator.free(api_surface);

    if (diagnostic.loc) |loc| {
        return std.fmt.allocPrint(
            allocator,
            "error: target `{s}` does not support {s} `{s}` at {s}:{d}:{d}.\nhelp: {s}\n",
            .{
                diagnostic.target_cli_name,
                diagnostic.capability.label(),
                api_surface,
                loc.file,
                loc.line,
                loc.col,
                diagnostic.guidance,
            },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "error: target `{s}` does not support {s} `{s}`.\nhelp: {s}\n",
        .{
            diagnostic.target_cli_name,
            diagnostic.capability.label(),
            api_surface,
            diagnostic.guidance,
        },
    );
}

fn policySupportsCapability(policy: CapabilityPolicy, capability: Capability) bool {
    for (policy.supported_capabilities) |supported| {
        if (supported == capability) return true;
    }
    return false;
}

fn isSolanaHostExternal(external: core_ir.ExternalDecl) bool {
    const name_prefixes = [_][]const u8{
        "Syscall.",
        "Sysvar.",
        "Cpi.",
        "Crypto.",
        "SplToken.",
        "Account.",
        "Pubkey.",
    };
    for (name_prefixes) |prefix| {
        if (std.mem.startsWith(u8, external.name, prefix)) return true;
    }

    const symbol_prefixes = [_][]const u8{
        "sol_",
        "sysvar.",
        "Cpi.",
        "spl_token.",
    };
    for (symbol_prefixes) |prefix| {
        if (std.mem.startsWith(u8, external.symbol, prefix)) return true;
    }

    return false;
}

const UsageCollector = struct {
    allocator: std.mem.Allocator,
    usages: std.ArrayList(CapabilityUsage),

    fn collectModule(self: *UsageCollector, module: core_ir.Module) !void {
        for (module.externals) |external| {
            if (!isSolanaHostExternal(external)) continue;
            try self.appendUsage(.{
                .capability = .solana_host_api,
                .api_surface = external.name,
                .loc = null,
            });
        }

        for (module.decls) |decl| {
            switch (decl) {
                .Let => |let_decl| try self.collectExpr(let_decl.value),
                .LetGroup => |group| {
                    for (group.bindings) |binding| {
                        try self.collectExpr(binding.value);
                    }
                },
            }
        }
    }

    fn collectExpr(self: *UsageCollector, expr: *const core_ir.Expr) !void {
        switch (expr.*) {
            .Lambda => |value| try self.collectExpr(value.body),
            .Constant, .Var => {},
            .App => |value| {
                try self.collectExpr(value.callee);
                for (value.args) |arg| try self.collectExpr(arg);
            },
            .Let => |value| {
                try self.collectExpr(value.value);
                try self.collectExpr(value.body);
            },
            .LetGroup => |value| {
                for (value.bindings) |binding| {
                    try self.collectExpr(binding.value);
                }
                try self.collectExpr(value.body);
            },
            .Assert => |value| try self.collectExpr(value.condition),
            .If => |value| {
                try self.collectExpr(value.cond);
                try self.collectExpr(value.then_branch);
                try self.collectExpr(value.else_branch);
            },
            .Prim => |value| for (value.args) |arg| try self.collectExpr(arg),
            .Ctor => |value| for (value.args) |arg| try self.collectExpr(arg),
            .Match => |value| {
                try self.collectExpr(value.scrutinee);
                for (value.arms) |arm| {
                    if (arm.guard) |guard| try self.collectExpr(guard);
                    try self.collectExpr(arm.body);
                }
            },
            .Tuple => |value| for (value.items) |item| try self.collectExpr(item),
            .TupleProj => |value| try self.collectExpr(value.tuple_expr),
            .Record => |value| {
                for (value.fields) |field| {
                    try self.collectExpr(field.value);
                }
            },
            .RecordField => |value| try self.collectExpr(value.record_expr),
            .RecordUpdate => |value| {
                try self.collectExpr(value.base_expr);
                for (value.fields) |field| {
                    try self.collectExpr(field.value);
                }
            },
            .AccountFieldSet => |value| {
                try self.appendUsage(.{
                    .capability = .account_data_mutation,
                    .api_surface = value.field_name,
                    .loc = value.loc,
                });
                try self.collectExpr(value.account_expr);
                try self.collectExpr(value.value);
            },
            .ArrayLit => |value| for (value.elems) |elem| try self.collectExpr(elem),
            .ArrayGet => |value| {
                try self.collectExpr(value.arr);
                try self.collectExpr(value.idx);
            },
            .ArrayLength => |value| try self.collectExpr(value.arr),
            .ArraySet => |value| {
                try self.collectExpr(value.arr);
                try self.collectExpr(value.idx);
                try self.collectExpr(value.value);
            },
            .ArrayMake => |value| try self.collectExpr(value.init),
            .RefMake => |value| try self.collectExpr(value.init),
            .RefGet => |value| try self.collectExpr(value.target),
            .RefSet => |value| {
                try self.collectExpr(value.target);
                try self.collectExpr(value.value);
            },
        }
    }

    fn appendUsage(self: *UsageCollector, usage: CapabilityUsage) !void {
        for (self.usages.items) |existing| {
            if (!std.mem.eql(u8, existing.api_surface, usage.api_surface)) continue;
            if (existing.capability != usage.capability) continue;
            if (locEql(existing.loc, usage.loc)) return;
        }
        try self.usages.append(self.allocator, usage);
    }
};

fn locEql(lhs: ?core_ir.Loc, rhs: ?core_ir.Loc) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    const left = lhs.?;
    const right = rhs.?;
    return std.mem.eql(u8, left.file, right.file) and
        left.line == right.line and
        left.col == right.col and
        left.end_line == right.end_line and
        left.end_col == right.end_col;
}

fn renderedApiSurface(allocator: std.mem.Allocator, diagnostic: UnsupportedCapabilityDiagnostic) ![]const u8 {
    return switch (diagnostic.capability) {
        .account_data_mutation => std.fmt.allocPrint(allocator, "Account.{s} <-", .{diagnostic.api_surface}),
        else => diagnostic.api_surface,
    };
}

fn sampleLoc() core_ir.Loc {
    return .{
        .file = "examples/future_capability.ml",
        .line = 7,
        .col = 3,
        .end_line = 7,
        .end_col = 19,
    };
}

fn syntheticTarget(cli_name: []const u8) target_registry.TargetContract {
    return .{
        .cli_name = cli_name,
        .family = .native,
        .support_status = .reserved,
        .backend_facade = "synthetic",
        .backend_output_language = "zig",
        .artifact_type = .executable,
        .runtime_adapter = "runtime/zig/synthetic_entry.zig",
        .host_adapter = "synthetic",
        .entrypoint_contract = "synthetic fixture",
        .calling_convention = "synthetic fixture",
        .memory_plan = "synthetic fixture",
        .panic_error_strategy = "synthetic fixture",
        .build_dispatch = .native,
        .keep_zig_supported = false,
        .requires_output_path = false,
        .supports_no_srcmap = false,
    };
}

test "capability scan accepts selected target metadata and current capability usage" {
    const native = target_registry.lookupByCliName("native") orelse return error.TestUnexpectedResult;
    const usages = [_]CapabilityUsage{
        .{ .capability = .solana_host_api, .api_surface = "Cpi.invoke", .loc = sampleLoc() },
        .{ .capability = .account_data_mutation, .api_surface = "Account.data <-", .loc = sampleLoc() },
    };

    try std.testing.expectEqual(ScanResult.ok, try scanCapabilityUsages(capabilityPolicyForTarget(native), &usages));
}

test "capability scan remains non-regressing for supported native and bpf targets" {
    const native = target_registry.lookupByCliName("native") orelse return error.TestUnexpectedResult;
    const bpf = target_registry.lookupByCliName("bpf") orelse return error.TestUnexpectedResult;
    const usages = [_]CapabilityUsage{
        .{ .capability = .solana_host_api, .api_surface = "Syscall.sol_log", .loc = sampleLoc() },
        .{ .capability = .account_data_mutation, .api_surface = "Account.data <-", .loc = sampleLoc() },
    };

    try std.testing.expectEqual(ScanResult.ok, try scanCapabilityUsages(capabilityPolicyForTarget(native), &usages));
    try std.testing.expectEqual(ScanResult.ok, try scanCapabilityUsages(capabilityPolicyForTarget(bpf), &usages));
}

test "synthetic unsupported capability diagnostic is target-aware and actionable" {
    const unsupported_target = syntheticTarget("wasm");
    const usages = [_]CapabilityUsage{
        .{ .capability = .solana_host_api, .api_surface = "Cpi.invoke", .loc = sampleLoc() },
    };
    const result = try scanCapabilityUsages(.{
        .target = &unsupported_target,
        .supported_capabilities = &.{},
        .unsupported_guidance = "This target is reserved for future pure-logic work; remove the Solana-only API or use --target=bpf.",
    }, &usages);

    switch (result) {
        .ok => return error.TestExpectedUnsupportedCapability,
        .unsupported => |diagnostic| {
            try std.testing.expectEqualStrings("wasm", diagnostic.target_cli_name);
            try std.testing.expectEqual(Capability.solana_host_api, diagnostic.capability);
            try std.testing.expectEqualStrings("Cpi.invoke", diagnostic.api_surface);
            try std.testing.expectEqual(sampleLoc().line, diagnostic.loc.?.line);

            const rendered = try renderUnsupportedCapabilityDiagnostic(std.testing.allocator, diagnostic);
            defer std.testing.allocator.free(rendered);

            try std.testing.expect(std.mem.indexOf(u8, rendered, "wasm") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "Cpi.invoke") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "examples/future_capability.ml:7:3") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "use --target=bpf") != null);
        },
    }
}

test "reserved future targets remain unable to bypass CLI registry dispatch" {
    try std.testing.expectError(error.UnsupportedBuildTarget, target_registry.resolveBuildTarget("wasm"));
    try std.testing.expectError(error.UnsupportedBuildTarget, target_registry.resolveBuildTarget("near"));
    try std.testing.expectError(error.UnsupportedBuildTarget, target_registry.resolveBuildTarget("evm"));
}
