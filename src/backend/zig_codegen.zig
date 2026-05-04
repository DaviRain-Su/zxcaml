//! ZigBackend package facade.
//!
//! The implementation lives under `src/backend/zig_codegen/` and is split
//! by concern: top-level driver, declarations, expressions, match emission,
//! runtime/stdlib imports, and shared helpers.

const driver = @import("zig_codegen/driver.zig");
const common = @import("zig_codegen/common.zig");

pub const EmitError = common.EmitError;
pub const emitModule = driver.emitModule;

comptime {
    _ = @import("zig_codegen/tests.zig");
}
