//! Backend extension point for execution and source-emitting targets.
//!
//! RESPONSIBILITIES:
//! - Define the trait-shaped backend surface consumed by the driver.
//! - Keep direct Core IR execution separate from source emission.
//! - Document the P1 extension point used by the Interpreter and later ZigBackend.
//!
//! EXTENSION POINT: new backends implement this vtable without changing the
//! driver. Interpreters implement `evalModule` over Core IR directly; emitting
//! backends implement `emitModule` and may leave `evalModule` as unsupported.

const ir = @import("../core/ir.zig");

/// Runtime-polymorphic backend trait for compiler execution targets.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Dispatches direct execution of a Core IR module.
    pub fn evalModule(self: Backend, module: ir.Module) !u64 {
        return self.vtable.evalModule(self.ptr, module);
    }

    /// Dispatches source emission for source-generating backends.
    pub fn emitModule(self: Backend, module: ir.Module) ![]const u8 {
        return self.vtable.emitModule(self.ptr, module);
    }
};

/// Backend method table; implementations provide one or both operations.
pub const VTable = struct {
    evalModule: *const fn (ptr: *anyopaque, module: ir.Module) anyerror!u64,
    emitModule: *const fn (ptr: *anyopaque, module: ir.Module) anyerror![]const u8,
};

/// Standard error used when a backend does not support direct evaluation.
pub fn unsupportedEvalModule(_: *anyopaque, _: ir.Module) !u64 {
    return error.NotImplemented;
}

/// Standard error used when a backend does not support source emission.
pub fn unsupportedEmitModule(_: *anyopaque, _: ir.Module) ![]const u8 {
    return error.NotImplemented;
}
