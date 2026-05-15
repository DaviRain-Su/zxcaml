//! Runtime panic hook for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Provide one user-program panic function for generated code to call.
//! - Terminate without attempting recovery or allocation.
//! - Emit a stable marker on hosted targets and use a no-return path on BPF/freestanding.

const std = @import("std");
const builtin = @import("builtin");

const is_bpf = std.mem.eql(u8, @tagName(builtin.target.cpu.arch), "sbf") or
    builtin.target.cpu.arch == .bpfel or
    builtin.target.cpu.arch == .bpfeb;

/// Direct extern binding to Solana's `sol_log_` syscall. Referenced only on
/// BPF/SBF targets so the symbol is not pulled into hosted link lines.
extern fn sol_log_(ptr: [*]const u8, len: u64) callconv(.c) void;

/// Stable user-observable marker for integer division or modulus by zero.
pub const division_by_zero_marker = "ZXCAML_PANIC:division_by_zero";

/// Stable user-observable marker for failed OCaml `assert` expressions.
pub const assert_failure_marker = "ZXCAML_PANIC:assert_failure";

/// Stable user-observable marker for out-of-bounds array indexing
/// (ADR-015 option B / R9.1 read-only int arrays).
pub const array_oob_marker = "ZXCAML_PANIC:array_oob";

/// Panics with the stable division-by-zero marker.
pub fn divisionByZero() noreturn {
    panic(division_by_zero_marker);
}

/// Panics with the stable assert-failure marker.
pub fn assertFailure() noreturn {
    panic(assert_failure_marker);
}

/// Panics with the stable array-out-of-bounds marker.
pub fn arrayOob() noreturn {
    panic(array_oob_marker);
}

/// Aborts execution for an unrecoverable user-program panic.
pub fn panic(msg: []const u8) noreturn {
    if (comptime is_bpf) {
        sol_log_(msg.ptr, msg.len);
        @trap();
    } else if (comptime builtin.os.tag == .freestanding) {
        @trap();
    } else {
        std.debug.print("{s}\n", .{msg});
        std.process.exit(101);
    }
}
