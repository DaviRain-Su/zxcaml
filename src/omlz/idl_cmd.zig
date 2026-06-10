//! `omlz idl` subcommand implementation.
//!
//! RESPONSIBILITIES:
//! - Lower and optimize the module, derive the program name from the input
//!   path, and emit the Anchor-compatible JSON IDL to stdout.
const std = @import("std");
const cmd_common = @import("cmd_common.zig");
const driver_idl = @import("../driver/idl.zig");
const frontend_bridge = @import("../frontend_bridge/ttree.zig");

const writeStdout = cmd_common.writeStdout;
const writeStderr = cmd_common.writeStderr;

pub fn emitIdl(init: std.process.Init, module: frontend_bridge.Module, input_file: []const u8) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const optimized_core_module = try cmd_common.lowerAndOptimizeOrExit(init, &core_arena, module);

    const program_name = try deriveProgramName(init.gpa, input_file);
    defer init.gpa.free(program_name);

    const rendered = driver_idl.emitModuleStdout(init.gpa, optimized_core_module, .{ .program_name = program_name }) catch |err| {
        try writeStderr(init.io, "error: failed to emit IDL: ");
        try writeStderr(init.io, @errorName(err));
        try writeStderr(init.io, "\n");
        std.process.exit(1);
    };
    defer init.gpa.free(rendered);

    try writeStdout(init.io, rendered);
}

fn deriveProgramName(allocator: std.mem.Allocator, input_file: []const u8) ![]u8 {
    const basename = std.fs.path.basename(input_file);
    const stem = if (std.mem.endsWith(u8, basename, ".ml")) basename[0 .. basename.len - 3] else basename;
    return allocator.dupe(u8, stem);
}
