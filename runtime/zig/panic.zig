//! Runtime panic hook for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Provide one user-program panic function for generated code to call.
//! - Abort immediately without attempting recovery or allocation.
//! - Remain tiny so the BPF-safe variant can replace/extend it in F08.

/// Aborts execution for an unrecoverable user-program panic.
pub fn panic(msg: []const u8) noreturn {
    _ = msg;
    @trap();
}
