//! `omlz run` subcommand implementation.
//!
//! RESPONSIBILITIES:
//! - Evaluate the optimized Core IR module through the tree-walk
//!   interpreter and print the entry result.
//! - Surface interpreter panics with their marker text and other
//!   interpreter errors with their canonical messages.
const std = @import("std");
const cmd_common = @import("cmd_common.zig");
const frontend_bridge = @import("../frontend_bridge/ttree.zig");
const interp = @import("../backend/interp.zig");

const writeStdout = cmd_common.writeStdout;
const writeStderr = cmd_common.writeStderr;

pub fn runModule(init: std.process.Init, module: frontend_bridge.Module) !void {
    var core_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer core_arena.deinit();

    const optimized_core_module = try cmd_common.lowerAndOptimizeOrExit(init, &core_arena, module);

    var interpreter: interp.Interpreter = .{};
    const value = interpreter.backend().evalModule(optimized_core_module) catch |err| {
        if (interp.panicMarker(err)) |marker| {
            var panic_buffer: [64]u8 = undefined;
            const rendered = try std.fmt.bufPrint(&panic_buffer, "{s}\n", .{marker});
            try writeStderr(init.io, rendered);
        } else {
            try writeStderr(init.io, "error: ");
            try writeStderr(init.io, interp.errorMessage(err));
            try writeStderr(init.io, "\n");
        }
        std.process.exit(1);
    };

    var buffer: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "{d}\n", .{value});
    try writeStdout(init.io, rendered);
}
