const std = @import("std");
const core = @import("core.zig");
const ProgramError = core.ProgramError;
const log = @import("../log/root.zig");

// =============================================================================
// Diagnostic helpers — emit a runtime log right before failing.
//
// Programs running on the Solana runtime only return a single u64 to
// the caller, which collapses every error site that maps to the same
// builtin (`InvalidArgument`, `InvalidAccountData`, …) into the same
// wire code. That makes a deployed program hard to debug from the
// outside.
//
// The Rust ecosystem (Anchor, SPL, agave's own programs) all paper
// over this the same way: print a short tag via `msg!(...)` immediately
// before returning. The wire return value stays a builtin so CPI
// callers can still pattern-match on it, but on Explorer / RPC logs
// the tag pinpoints the failure.
//
// The two helpers below are the equivalent of Anchor's `err!`/`error!`
// macros — comptime tags compile down to a single `sol_log_` call.
// Failure paths in this SDK use them; user code can adopt the same
// pattern.
//
// CU cost: `sol_log_` is ~100 CU base + 1 CU per byte. Failures are
// rare on the happy path so this is negligible in practice — and in
// exchange you get a string in the transaction logs that says exactly
// which constraint blew up.
// =============================================================================

/// Extract the file basename from a comptime path string.
///
/// `@src()` returns the full path Zig was compiled with (often the
/// absolute path on disk, ~80+ bytes). For on-chain logs we only want
/// `"info.zig"` not `"/Users/.../solana-program-sdk-zig/src/account/info.zig"`.
/// All work is done in comptime — the result is a comptime `[]const u8`
/// that gets inlined into the final log string.
pub inline fn basename(comptime path: []const u8) []const u8 {
    comptime {
        var i: usize = path.len;
        while (i > 0) : (i -= 1) {
            if (path[i - 1] == '/' or path[i - 1] == '\\') {
                return path[i..];
            }
        }
        return path;
    }
}

/// Build the prefix `"<file>:<line> "` at compile time.
inline fn srcPrefix(comptime src: std.builtin.SourceLocation) []const u8 {
    return comptime std.fmt.comptimePrint("{s}:{d} ", .{ basename(src.file), src.line });
}

/// Log `<file>:<line> <tag>` and return `err`.
///
/// Anchor's `require!` / `error!` macros automatically embed
/// `file!()` / `line!()` in the runtime message. Zig's `@src()`
/// builtin gives the same data but — unlike Rust macros — must be
/// supplied by the caller because `@src()` expands at function
/// definition site, not callsite.
///
/// ```zig
/// return sol.fail(@src(), "vault:wrong_authority", error.IncorrectAuthority);
/// // log: "info.zig:251 vault:wrong_authority"
/// ```
///
/// The entire `"<file>:<line> <tag>"` string is computed at
/// `comptime`; runtime cost is exactly one `sol_log_` syscall.
///
/// Tag convention: `"<module>:<reason>"`. Keep it short — every
/// byte costs ~1 CU when the failure path runs.
pub inline fn fail(
    comptime src: std.builtin.SourceLocation,
    comptime tag: []const u8,
    err: ProgramError,
) ProgramError {
    log.log(comptime srcPrefix(src) ++ tag);
    return err;
}

/// Formatted variant — use sparingly (each argument byte costs CU
/// and the BPF target formats into a 256 B stack buffer). Typical
/// use: include a numeric value alongside the tag for context.
///
/// ```zig
/// return sol.failFmt(@src(), "ix:bad_tag", "got={d}", .{tag},
///                    error.InvalidInstructionData);
/// // log: "context.zig:42 ix:bad_tag got=7"
/// ```
pub inline fn failFmt(
    comptime src: std.builtin.SourceLocation,
    comptime tag: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    err: ProgramError,
) ProgramError {
    log.print(comptime srcPrefix(src) ++ tag ++ " " ++ fmt, args);
    return err;
}
