//! Canonical grouped imports for generated runtime shim surfaces.

pub const entry_context = @import("entry_context.zig");

pub const InstructionContext = entry_context.InstructionContext;
pub const bpf_entry_source = "runtime/zig/bpf_entry.zig";
pub const native_entry_source = "runtime/zig/native_entry.zig";
