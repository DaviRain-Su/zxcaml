//! Lowering strategy extension point from Core IR into backend-specific LIR.
//!
//! RESPONSIBILITIES:
//! - Define the trait-shaped surface for Core IR lowering strategies.
//! - Keep future memory strategies pluggable without changing backends.
//! - Expose the M0 module-lowering operation consumed by the driver.

const ir = @import("../core/ir.zig");
const lir = @import("lir.zig");

/// Runtime-polymorphic lowering strategy.
pub const LoweringStrategy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Lowers a Core IR module into Lowered IR.
    pub fn lowerModule(self: LoweringStrategy, module: ir.Module) !lir.LModule {
        return self.vtable.lowerModule(self.ptr, module);
    }
};

/// Method table implemented by concrete lowering strategies.
pub const VTable = struct {
    lowerModule: *const fn (ptr: *anyopaque, module: ir.Module) anyerror!lir.LModule,
};
