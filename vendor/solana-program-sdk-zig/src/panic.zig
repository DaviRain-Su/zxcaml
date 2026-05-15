//! Minimal panic handler for Solana BPF programs
//!
//! Avoids std.debug dependencies to minimize binary size.
//! On BPF: calls sol_log_ then aborts.
//! On host: uses std.debug.panic for better debugging.
//!
//! Usage in your program's root file:
//!   pub const panic = @import("solana_program_sdk").panic.Panic;

const std = @import("std");
const bpf = @import("bpf.zig");

extern fn sol_log_(ptr: [*]const u8, len: u64) callconv(.c) void;

/// Panic namespace for Solana programs
/// Use as: pub const panic = solana_program_sdk.panic.Panic;
pub const Panic = struct {
    pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
        _ = error_return_trace;
        _ = ret_addr;

        if (bpf.is_bpf_program) {
            // In BPF: log the panic message and abort
            sol_log_(msg.ptr, msg.len);
            @trap();
        } else {
            // On host: use standard panic for better debugging
            std.debug.panic("{s}", .{msg});
        }
    }
};
