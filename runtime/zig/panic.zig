//! Runtime panic hook for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Provide one user-program panic function for generated code to call.
//! - Terminate without attempting recovery or allocation.
//! - Emit a stable marker on hosted targets and use a no-return path on BPF/freestanding.

const std = @import("std");
const builtin = @import("builtin");

/// Stable user-observable marker for integer division or modulus by zero.
pub const division_by_zero_marker = "ZXCAML_PANIC:division_by_zero";

/// Stable user-observable marker for failed OCaml `assert` expressions.
pub const assert_failure_marker = "ZXCAML_PANIC:assert_failure";

/// Panics with the stable division-by-zero marker.
pub fn divisionByZero() noreturn {
    panic(division_by_zero_marker);
}

/// Panics with the stable assert-failure marker.
pub fn assertFailure() noreturn {
    panic(assert_failure_marker);
}

/// Aborts execution for an unrecoverable user-program panic.
pub fn panic(msg: []const u8) noreturn {
    if (comptime builtin.os.tag == .freestanding) {
        while (true) {}
    } else {
        std.debug.print("{s}\n", .{msg});
        std.process.exit(101);
    }
}
