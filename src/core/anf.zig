//! Public facade for ANF lowering. Implementation lives in focused modules
//! under `src/core/anf/` to keep Core source files small.

const std = @import("std");
const ttree = @import("../frontend_bridge/ttree.zig");
const ir = @import("ir.zig");
const module_lower = @import("anf/module.zig");

pub const LowerError = module_lower.LowerError;

pub fn lowerModule(arena: *std.heap.ArenaAllocator, module: ttree.Module) LowerError!ir.Module {
    return module_lower.lowerModule(arena, module);
}
