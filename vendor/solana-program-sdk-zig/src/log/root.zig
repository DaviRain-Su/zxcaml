//! Logging utilities for Solana programs.
//!
//! This module provides syscall-backed logging wrappers plus optional
//! formatted logging helpers with host fallbacks.
//!
//! Physical layout:
//! - `shared.zig` — imports and shared aliases
//! - `raw.zig` — direct syscall wrappers and structured-data logging
//! - `format.zig` — formatted logging helpers and scratch-buffer size
//!
//! The public API stays flattened as `sol.log.*`.

const raw = @import("raw.zig");
const format = @import("format.zig");

/// Direct logging and runtime-introspection wrappers.
pub const log = raw.log;
pub const log64 = raw.log64;
pub const logComputeUnits = raw.logComputeUnits;
pub const logData = raw.logData;
pub const getRemainingComputeUnits = raw.getRemainingComputeUnits;

/// Formatted logging helpers.
pub const default_print_buffer_size = format.default_print_buffer_size;
pub const print = format.print;
pub const printBuffered = format.printBuffered;

// =============================================================================
// Tests
// =============================================================================

test "log: basic" {
    log("test message");
}

test "log: print" {
    print("test format: {d}", .{42});
}

test "log: log64" {
    log64(1, 2, 3, 4, 5);
}

test "log: logComputeUnits" {
    logComputeUnits();
}

test "log: getRemainingComputeUnits" {
    _ = getRemainingComputeUnits();
}
