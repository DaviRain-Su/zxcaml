const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const driver_bpf = @import("../driver/bpf.zig");
const target_registry = @import("registry.zig");

pub const Severity = enum {
    required,
    optional,
};

pub const Status = enum {
    ok,
    warn,
    fail,
};

pub const ToolRequirement = struct {
    label: []const u8,
    severity: Severity,
};

pub const ToolProbe = struct {
    label: []const u8,
    severity: Severity,
    status: Status,
    detail: []const u8,
};

pub const CommandOutput = struct {
    ok: bool,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    owned: bool = false,

    pub fn deinit(self: CommandOutput, allocator: Allocator) void {
        if (!self.owned) return;
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const CommandRunner = struct {
    context: *anyopaque,
    runFn: *const fn (context: *anyopaque, allocator: Allocator, io: Io, argv: []const []const u8) CommandOutput,

    pub fn run(self: CommandRunner, allocator: Allocator, io: Io, argv: []const []const u8) CommandOutput {
        return self.runFn(self.context, allocator, io, argv);
    }
};

const ToolKind = enum {
    zig,
    solana_zig,
    llvm_objcopy,
    solana,
    cargo,
};

const ToolSpec = struct {
    kind: ToolKind,
    requirement: ToolRequirement,
};

const native_tool_specs = [_]ToolSpec{
    .{
        .kind = .zig,
        .requirement = .{
            .label = "zig",
            .severity = .required,
        },
    },
};

const bpf_tool_specs = [_]ToolSpec{
    .{
        .kind = .zig,
        .requirement = .{
            .label = "zig",
            .severity = .required,
        },
    },
    .{
        .kind = .solana_zig,
        .requirement = .{
            .label = "solana-zig",
            .severity = .required,
        },
    },
    .{
        .kind = .llvm_objcopy,
        .requirement = .{
            .label = "llvm-objcopy",
            .severity = .optional,
        },
    },
    .{
        .kind = .solana,
        .requirement = .{
            .label = "solana",
            .severity = .optional,
        },
    },
    .{
        .kind = .cargo,
        .requirement = .{
            .label = "cargo",
            .severity = .optional,
        },
    },
};

const native_requirements = [_]ToolRequirement{
    native_tool_specs[0].requirement,
};

const bpf_requirements = [_]ToolRequirement{
    bpf_tool_specs[0].requirement,
    bpf_tool_specs[1].requirement,
    bpf_tool_specs[2].requirement,
    bpf_tool_specs[3].requirement,
    bpf_tool_specs[4].requirement,
};

var system_runner_context: u8 = 0;

pub fn toolRequirementsForTarget(target: *const target_registry.TargetContract) []const ToolRequirement {
    return switch (target.build_dispatch) {
        .native => native_requirements[0..],
        .bpf => bpf_requirements[0..],
    };
}

pub fn collectTargetToolProbes(
    allocator: Allocator,
    io: Io,
    target: *const target_registry.TargetContract,
    environ: std.process.Environ,
) ![]ToolProbe {
    const solana_zig_env = std.process.Environ.getAlloc(environ, allocator, "SOLANA_ZIG") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    defer if (solana_zig_env) |value| allocator.free(value);

    return collectTargetToolProbesWith(allocator, io, target, solana_zig_env, .{
        .context = &system_runner_context,
        .runFn = runSystemCommand,
    });
}

pub fn collectTargetToolProbesWith(
    allocator: Allocator,
    io: Io,
    target: *const target_registry.TargetContract,
    solana_zig_env: ?[]const u8,
    runner: CommandRunner,
) ![]ToolProbe {
    const specs = toolSpecsForTarget(target);
    var probes = std.ArrayList(ToolProbe).empty;
    defer probes.deinit(allocator);

    for (specs) |spec| {
        try probes.append(allocator, try probeToolSpec(allocator, io, spec, solana_zig_env, runner));
    }

    return probes.toOwnedSlice(allocator);
}

pub fn hasBlockingFailure(probes: []const ToolProbe) bool {
    for (probes) |probe| {
        if (probe.severity == .required and probe.status == .fail) return true;
    }
    return false;
}

fn toolSpecsForTarget(target: *const target_registry.TargetContract) []const ToolSpec {
    return switch (target.build_dispatch) {
        .native => native_tool_specs[0..],
        .bpf => bpf_tool_specs[0..],
    };
}

fn probeToolSpec(
    allocator: Allocator,
    io: Io,
    spec: ToolSpec,
    solana_zig_env: ?[]const u8,
    runner: CommandRunner,
) !ToolProbe {
    return switch (spec.kind) {
        .zig => try probeVersionCommand(allocator, io, spec.requirement, runner, &.{ "zig", "version" }, "not found"),
        .solana_zig => try probeSolanaZig(allocator, io, spec.requirement, solana_zig_env, runner),
        .llvm_objcopy => try probeOptionalFixedCommand(
            allocator,
            io,
            spec.requirement,
            runner,
            &.{ "llvm-objcopy", "--version" },
            "not found; BPF source-map embedding will degrade to sidecar-only",
        ),
        .solana => try probeOptionalFixedCommand(allocator, io, spec.requirement, runner, &.{ "solana", "--version" }, "not found"),
        .cargo => try probeOptionalFixedCommand(allocator, io, spec.requirement, runner, &.{ "cargo", "--version" }, "not found"),
    };
}

fn probeVersionCommand(
    allocator: Allocator,
    io: Io,
    requirement: ToolRequirement,
    runner: CommandRunner,
    argv: []const []const u8,
    failure_fallback: []const u8,
) !ToolProbe {
    const output = runner.run(allocator, io, argv);
    defer output.deinit(allocator);

    if (output.ok) {
        return .{
            .label = requirement.label,
            .severity = requirement.severity,
            .status = .ok,
            .detail = try allocator.dupe(u8, firstLine(output.stdout)),
        };
    }

    return .{
        .label = requirement.label,
        .severity = requirement.severity,
        .status = statusForFailure(requirement.severity),
        .detail = try detailForFailure(allocator, output, failure_fallback),
    };
}

fn probeOptionalFixedCommand(
    allocator: Allocator,
    io: Io,
    requirement: ToolRequirement,
    runner: CommandRunner,
    argv: []const []const u8,
    failure_detail: []const u8,
) !ToolProbe {
    const output = runner.run(allocator, io, argv);
    defer output.deinit(allocator);

    if (output.ok) {
        const detail = firstLine(output.stdout);
        return .{
            .label = requirement.label,
            .severity = requirement.severity,
            .status = .ok,
            .detail = try allocator.dupe(u8, if (detail.len == 0) requirement.label else detail),
        };
    }

    return .{
        .label = requirement.label,
        .severity = requirement.severity,
        .status = .warn,
        .detail = failure_detail,
    };
}

fn probeSolanaZig(
    allocator: Allocator,
    io: Io,
    requirement: ToolRequirement,
    solana_zig_env: ?[]const u8,
    runner: CommandRunner,
) !ToolProbe {
    const resolved = if (solana_zig_env) |raw|
        driver_bpf.parseSolanaZigEnv(raw) catch {
            return .{
                .label = requirement.label,
                .severity = requirement.severity,
                .status = .fail,
                .detail = "SOLANA_ZIG=0 is no longer supported (see CHANGELOG); unset, set to 1, or use a command/path",
            };
        }
    else
        "solana-zig";

    const argv = [_][]const u8{ resolved, "version" };
    const output = runner.run(allocator, io, &argv);
    defer output.deinit(allocator);

    if (output.ok) {
        return .{
            .label = requirement.label,
            .severity = requirement.severity,
            .status = .ok,
            .detail = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ firstLine(output.stdout), resolved }),
        };
    }

    const failure = try detailForFailure(allocator, output, "not found");
    defer allocator.free(failure);

    return .{
        .label = requirement.label,
        .severity = requirement.severity,
        .status = .fail,
        .detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ resolved, failure }),
    };
}

fn runSystemCommand(context: *anyopaque, allocator: Allocator, io: Io, argv: []const []const u8) CommandOutput {
    _ = context;
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch |err| {
        return .{
            .ok = false,
            .exit_code = 1,
            .stdout = "",
            .stderr = @errorName(err),
        };
    };

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };

    return .{
        .ok = exit_code == 0,
        .exit_code = exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .owned = true,
    };
}

fn statusForFailure(severity: Severity) Status {
    return switch (severity) {
        .required => .fail,
        .optional => .warn,
    };
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "";
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..end], " \t\r");
}

fn detailForFailure(allocator: Allocator, output: CommandOutput, fallback: []const u8) ![]const u8 {
    const stderr_line = firstLine(output.stderr);
    if (stderr_line.len != 0) return allocator.dupe(u8, stderr_line);

    const stdout_line = firstLine(output.stdout);
    if (stdout_line.len != 0) return allocator.dupe(u8, stdout_line);

    return allocator.dupe(u8, fallback);
}

fn argvEql(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

const FakeRunner = struct {
    const Response = struct {
        argv: []const []const u8,
        output: CommandOutput,
    };

    responses: []const Response,
    call_count: usize = 0,

    fn run(context: *anyopaque, allocator: Allocator, io: Io, argv: []const []const u8) CommandOutput {
        _ = allocator;
        _ = io;
        const self: *FakeRunner = @ptrCast(@alignCast(context));
        self.call_count += 1;
        for (self.responses) |response| {
            if (argvEql(response.argv, argv)) return response.output;
        }
        return .{
            .ok = false,
            .exit_code = 1,
            .stdout = "",
            .stderr = "FileNotFound",
        };
    }

    fn commandRunner(self: *FakeRunner) CommandRunner {
        return .{
            .context = self,
            .runFn = run,
        };
    }
};

fn expectRequirement(requirement: ToolRequirement, label: []const u8, severity: Severity) !void {
    try std.testing.expectEqualStrings(label, requirement.label);
    try std.testing.expectEqual(severity, requirement.severity);
}

fn findProbe(probes: []const ToolProbe, label: []const u8) ?ToolProbe {
    for (probes) |probe| {
        if (std.mem.eql(u8, probe.label, label)) return probe;
    }
    return null;
}

test "preflight: native tool contract stays isolated from Solana-only tools" {
    const native = target_registry.lookupByCliName("native") orelse return error.TestUnexpectedResult;
    const requirements = toolRequirementsForTarget(native);

    try std.testing.expectEqual(@as(usize, 1), requirements.len);
    try expectRequirement(requirements[0], "zig", .required);
}

test "preflight: bpf tool contract distinguishes required and optional tools" {
    const bpf = target_registry.lookupByCliName("bpf") orelse return error.TestUnexpectedResult;
    const requirements = toolRequirementsForTarget(bpf);

    try std.testing.expectEqual(@as(usize, 5), requirements.len);
    try expectRequirement(requirements[0], "zig", .required);
    try expectRequirement(requirements[1], "solana-zig", .required);
    try expectRequirement(requirements[2], "llvm-objcopy", .optional);
    try expectRequirement(requirements[3], "solana", .optional);
    try expectRequirement(requirements[4], "cargo", .optional);
}

test "preflight: native probes avoid Solana-specific tool execution" {
    const native = target_registry.lookupByCliName("native") orelse return error.TestUnexpectedResult;
    var runner = FakeRunner{
        .responses = &.{
            .{
                .argv = &.{ "zig", "version" },
                .output = .{ .ok = true, .exit_code = 0, .stdout = "0.16.0\n", .stderr = "" },
            },
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const probes = try collectTargetToolProbesWith(arena.allocator(), std.testing.io, native, null, runner.commandRunner());

    try std.testing.expectEqual(@as(usize, 1), probes.len);
    try std.testing.expectEqual(@as(usize, 1), runner.call_count);
    try std.testing.expectEqualStrings("zig", probes[0].label);
    try std.testing.expectEqual(Status.ok, probes[0].status);
    try std.testing.expect(!hasBlockingFailure(probes));
}

test "preflight: bpf probes preserve SOLANA_ZIG defaults and invalid zero" {
    const bpf = target_registry.lookupByCliName("bpf") orelse return error.TestUnexpectedResult;
    var runner = FakeRunner{
        .responses = &.{
            .{
                .argv = &.{ "zig", "version" },
                .output = .{ .ok = true, .exit_code = 0, .stdout = "0.16.0\n", .stderr = "" },
            },
            .{
                .argv = &.{ "solana-zig", "version" },
                .output = .{ .ok = true, .exit_code = 0, .stdout = "solana-zig 0.16.0\n", .stderr = "" },
            },
            .{
                .argv = &.{ "/tmp/custom-solana-zig", "version" },
                .output = .{ .ok = true, .exit_code = 0, .stdout = "custom 0.16.0\n", .stderr = "" },
            },
        },
    };
    var default_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer default_arena.deinit();
    const default_probes = try collectTargetToolProbesWith(default_arena.allocator(), std.testing.io, bpf, " 1 \n", runner.commandRunner());
    try std.testing.expectEqual(Status.ok, (findProbe(default_probes, "solana-zig") orelse return error.TestUnexpectedResult).status);

    var custom_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer custom_arena.deinit();
    const custom_probes = try collectTargetToolProbesWith(custom_arena.allocator(), std.testing.io, bpf, " /tmp/custom-solana-zig ", runner.commandRunner());
    try std.testing.expectEqual(Status.ok, (findProbe(custom_probes, "solana-zig") orelse return error.TestUnexpectedResult).status);

    var invalid_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer invalid_arena.deinit();
    const invalid_probes = try collectTargetToolProbesWith(invalid_arena.allocator(), std.testing.io, bpf, "0", runner.commandRunner());
    const invalid_probe = findProbe(invalid_probes, "solana-zig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Status.fail, invalid_probe.status);
    try std.testing.expect(std.mem.indexOf(u8, invalid_probe.detail, "SOLANA_ZIG=0") != null);
    try std.testing.expect(hasBlockingFailure(invalid_probes));
}

test "preflight: required failures block while optional failures warn" {
    const bpf = target_registry.lookupByCliName("bpf") orelse return error.TestUnexpectedResult;
    var runner = FakeRunner{
        .responses = &.{
            .{
                .argv = &.{ "zig", "version" },
                .output = .{ .ok = true, .exit_code = 0, .stdout = "0.16.0\n", .stderr = "" },
            },
            .{
                .argv = &.{ "solana-zig", "version" },
                .output = .{ .ok = false, .exit_code = 1, .stdout = "", .stderr = "missing solana-zig" },
            },
            .{
                .argv = &.{ "llvm-objcopy", "--version" },
                .output = .{ .ok = false, .exit_code = 1, .stdout = "", .stderr = "FileNotFound" },
            },
            .{
                .argv = &.{ "solana", "--version" },
                .output = .{ .ok = true, .exit_code = 0, .stdout = "solana-cli 3.1.12\n", .stderr = "" },
            },
            .{
                .argv = &.{ "cargo", "--version" },
                .output = .{ .ok = true, .exit_code = 0, .stdout = "cargo 1.94.1\n", .stderr = "" },
            },
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const probes = try collectTargetToolProbesWith(arena.allocator(), std.testing.io, bpf, null, runner.commandRunner());

    const solana_zig_probe = findProbe(probes, "solana-zig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Status.fail, solana_zig_probe.status);
    try std.testing.expect(std.mem.indexOf(u8, solana_zig_probe.detail, "missing solana-zig") != null);

    try std.testing.expectEqual(Status.warn, (findProbe(probes, "llvm-objcopy") orelse return error.TestUnexpectedResult).status);
    try std.testing.expect(hasBlockingFailure(probes));
}
