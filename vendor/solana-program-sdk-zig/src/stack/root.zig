//! Call-stack and processed-sibling-instruction syscalls.
//!
//! These are companion APIs to the instructions sysvar and CPI:
//!
//! - `getStackHeight()` reports the current invoke depth.
//! - `siblingMeta(...)` probes already-processed siblings of the parent invocation.
//! - `getProcessedSiblingInstruction*` fetches sibling data and account metas.
//!
//! Physical layout:
//! - `shared.zig` — imports, aliases, and target gating
//! - `height.zig` — stack-height constant and syscall wrapper
//! - `sibling.zig` — sibling probe/fetch structs and helpers
//!
//! The public API stays flattened as `sol.stack.*`, with the top-level
//! aliases `sol.getStackHeight` and `sol.TRANSACTION_LEVEL_STACK_HEIGHT`
//! preserved at `src/root.zig`.

const std = @import("std");
const shared = @import("shared.zig");
const height_mod = @import("height.zig");
const sibling_mod = @import("sibling.zig");

/// Stack-height constants and syscall wrapper.
pub const TRANSACTION_LEVEL_STACK_HEIGHT = height_mod.TRANSACTION_LEVEL_STACK_HEIGHT;
pub const getStackHeight = height_mod.getStackHeight;

/// Sibling-instruction ABI structs and helpers.
pub const AccountMeta = shared.AccountMeta;
pub const ProcessedSiblingMeta = sibling_mod.ProcessedSiblingMeta;
pub const ProcessedSibling = sibling_mod.ProcessedSibling;
pub const siblingMeta = sibling_mod.siblingMeta;
pub const getProcessedSiblingInstruction = sibling_mod.getProcessedSiblingInstruction;
pub const getProcessedSiblingInstructionAlloc = sibling_mod.getProcessedSiblingInstructionAlloc;

// =============================================================================
// Tests (host-only — syscalls are no-ops off-chain)
// =============================================================================

const testing = std.testing;

test "getStackHeight: host stub returns 0" {
    try testing.expectEqual(@as(u64, 0), getStackHeight());
}

test "siblingMeta: host stub returns null" {
    try testing.expectEqual(@as(?@TypeOf(siblingMeta(0).?), null), siblingMeta(0));
}

test "TRANSACTION_LEVEL_STACK_HEIGHT constant" {
    try testing.expectEqual(@as(u64, 1), TRANSACTION_LEVEL_STACK_HEIGHT);
}

test "ProcessedSiblingMeta layout: 16 bytes, repr(C) compatible" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(ProcessedSiblingMeta));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ProcessedSiblingMeta, "data_len"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(ProcessedSiblingMeta, "accounts_len"));
}
