//! `spl-memo` — Zig client for the SPL Memo program.
//!
//! Dual-target: works both as an on-chain CPI helper and as an
//! off-chain instruction builder.
//!
//! ## On-chain use
//!
//! ```zig
//! const spl_memo = @import("spl_memo");
//!
//! fn process(ctx: *sol.InstructionContext) sol.ProgramResult {
//!     const a = try ctx.parseAccountsWith(.{ .{ "memo_program", .{} } });
//!     try spl_memo.cpi.memoNoSigners("hello on-chain", a.memo_program.toCpi());
//! }
//! ```
//!
//! ## Off-chain use (host code constructing a transaction)
//!
//! ```zig
//! const ix = spl_memo.instruction.memoNoSigners("hello off-chain");
//! // ...serialise `ix` into a transaction with your client of choice.
//! ```
//!
//! Re-exports both submodules and the program-ID constants flat so
//! the consumer can pick whichever spelling reads best at the call
//! site.

pub const id = @import("id.zig");
pub const instruction = @import("instruction.zig");
pub const cpi = @import("cpi.zig");

/// Modern SPL Memo program ID (v2).
pub const PROGRAM_ID = id.PROGRAM_ID;

/// Legacy v1 program ID (kept for indexer compatibility).
pub const PROGRAM_ID_V1 = id.PROGRAM_ID_V1;

test {
    @import("std").testing.refAllDecls(@This());
}
