//! `omlz check` subcommand implementation.
//!
//! RESPONSIBILITIES:
//! - Emit the optimized Core IR contract for `--emit=core-ir` and
//!   `--emit=core-ir-with-loc`, including `--bless` snapshot writing.
//! - Run the `--no-alloc` allocation proof and render `DX2-NOALLOC`
//!   failures.
//! - Run checked region inference for the default check path and render
//!   `DX2-REGION` failures.
//! - Emit static `--report` summaries (compute units, stack depth).
const std = @import("std");
const cmd_common = @import("cmd_common.zig");
const cli = @import("cli_surface.zig");
const frontend_bridge = @import("../frontend_bridge/ttree.zig");
const core_ir = @import("../core/ir.zig");
const core_no_alloc = @import("../core/no_alloc.zig");
const core_pretty = @import("../core/pretty.zig");
const core_static_report = @import("../core/static_report.zig");
const region_infer = @import("../lower/region_infer.zig");

const writeStdout = cmd_common.writeStdout;
const writeStderr = cmd_common.writeStderr;
const DiagnosticFlags = cli.DiagnosticFlags;
const CheckArgs = cli.CheckArgs;

pub fn emitCoreIr(init: std.process.Init, module: frontend_bridge.Module, check_args: CheckArgs) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const optimized_core_module = try cmd_common.lowerAndOptimizeOrExit(init, &core_arena, module);

    const include_locs = if (check_args.emit) |emit_kind| std.mem.eql(u8, emit_kind, "core-ir-with-loc") else false;
    const rendered = core_pretty.formatModuleWithOptions(init.gpa, optimized_core_module, .{ .include_locs = include_locs }) catch |err| {
        try writeStderr(init.io, "error: failed to pretty-print Core IR: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    defer init.gpa.free(rendered);

    if (check_args.bless) {
        const snapshot_path = try deriveSnapshotPath(init.gpa, check_args.input_file);
        defer init.gpa.free(snapshot_path);

        const cwd = std.Io.Dir.cwd();
        cwd.writeFile(init.io, .{
            .sub_path = snapshot_path,
            .data = rendered,
            .flags = .{ .truncate = true },
        }) catch |err| {
            try writeStderr(init.io, "error: failed to write snapshot ");
            try writeStderr(init.io, snapshot_path);
            try writeStderr(init.io, ": ");
            try writeStderr(init.io, @errorName(err));
            try writeStderr(init.io, "\n");
            std.process.exit(1);
        };
        try writeStdout(init.io, "blessed: ");
        try writeStdout(init.io, snapshot_path);
        try writeStdout(init.io, "\n");
    } else {
        if (check_args.wire_version) |wire_version| {
            try writeStdout(init.io, "(version ");
            try writeStdout(init.io, wire_version);
            try writeStdout(init.io, ")\n");
        }
        try writeStdout(init.io, rendered);
        try writeStdout(init.io, "\n");
    }
}

pub fn runNoAllocCheck(init: std.process.Init, module: frontend_bridge.Module, flags: DiagnosticFlags, report_kinds: ?core_static_report.Kinds) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const optimized_core_module = try cmd_common.lowerAndOptimizeOrExit(init, &core_arena, module);

    const result = core_no_alloc.checkModule(init.gpa, optimized_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to run no_alloc analysis: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    var failed = false;
    switch (result) {
        .Pass => try writeStdout(init.io, "no_alloc: PASS\n"),
        .Fail => |site| {
            try renderNoAllocFailure(init, site, flags);
            failed = true;
        },
    }

    if (report_kinds) |kinds| {
        try emitStaticReport(init, optimized_core_module, kinds);
    }

    if (failed) std.process.exit(1);
}

fn renderNoAllocFailure(init: std.process.Init, site: core_no_alloc.Site, flags: DiagnosticFlags) !void {
    const message = try noAllocFailureMessage(init.gpa, site);
    defer init.gpa.free(message);
    try cmd_common.renderErrorDiagnostic(init, site.loc, "DX2-NOALLOC", message, flags);
}

fn noAllocFailureMessage(allocator: std.mem.Allocator, site: core_no_alloc.Site) ![]u8 {
    if (site.kind == .ConstructorPayload) {
        if (site.detail) |constructor| {
            return std.fmt.allocPrint(
                allocator,
                "no_alloc failure in function `{s}`: constructor `{s}` carries an arena-allocated payload",
                .{ site.function_name, constructor },
            );
        }
    }

    if (site.detail) |detail| {
        return std.fmt.allocPrint(
            allocator,
            "no_alloc failure in function `{s}`: {s} `{s}` is not allowed in a no_alloc context",
            .{ site.function_name, core_no_alloc.allocationDescription(site.kind), detail },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "no_alloc failure in function `{s}`: {s} is not allowed in a no_alloc context",
        .{ site.function_name, core_no_alloc.allocationDescription(site.kind) },
    );
}

pub fn runRegionInferenceCheck(init: std.process.Init, module: frontend_bridge.Module, flags: DiagnosticFlags, report_kinds: ?core_static_report.Kinds) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const optimized_core_module = try cmd_common.lowerAndOptimizeOrExit(init, &core_arena, module);

    const region_result = region_infer.inferModuleChecked(&core_arena, optimized_core_module) catch |err| {
        try writeStderr(init.io, "error: failed to infer Core IR regions: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };

    var inferred_or_fallback: core_ir.Module = optimized_core_module;
    var region_failed = false;
    switch (region_result) {
        .Pass => |inferred| inferred_or_fallback = inferred,
        .Fail => |site| {
            try cmd_common.renderRegionFailure(init, site, flags);
            region_failed = true;
        },
    }

    if (report_kinds) |kinds| {
        try emitStaticReport(init, inferred_or_fallback, kinds);
    }

    if (region_failed) std.process.exit(1);
}

fn emitStaticReport(
    init: std.process.Init,
    module: core_ir.Module,
    kinds: core_static_report.Kinds,
) !void {
    const rendered = core_static_report.run(init.gpa, module, kinds) catch |err| {
        try writeStderr(init.io, "report failed: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        return;
    };
    defer init.gpa.free(rendered);
    try writeStdout(init.io, rendered);
}

/// Derives the `.core.snapshot` path from an `.ml` input path.
fn deriveSnapshotPath(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, input_path, ".ml")) {
        const stem = input_path[0 .. input_path.len - 3];
        return std.fmt.allocPrint(allocator, "{s}.core.snapshot", .{stem});
    }
    return std.fmt.allocPrint(allocator, "{s}.core.snapshot", .{input_path});
}
