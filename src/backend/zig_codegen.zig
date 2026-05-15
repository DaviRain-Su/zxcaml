//! ZigBackend package facade.
//!
//! This file is the public entry point for the Zig codegen backend: every
//! caller imports `backend/zig_codegen.zig`, never the sub-modules directly.
//! The implementation lives under `src/backend/zig_codegen/` and is split
//! by concern (top-level driver, declarations, expressions, match emission,
//! runtime/stdlib imports, and shared helpers); this shim re-exports the
//! small public surface so the split is invisible to consumers.

const driver = @import("zig_codegen/driver.zig");
const common = @import("zig_codegen/common.zig");

pub const EmitError = common.EmitError;
pub const emitModule = driver.emitModule;

comptime {
    _ = @import("zig_codegen/tests.zig");
}
