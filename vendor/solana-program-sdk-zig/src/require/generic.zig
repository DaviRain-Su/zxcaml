const shared = @import("shared.zig");

const std = shared.stdlib;
const program_error = shared.program_error;
const ProgramError = shared.ProgramError;

/// Assert `cond`, else log `<file>:<line> <tag>` and return `err`.
///
/// Equivalent to Anchor's `require!(cond, err)` macro.
pub inline fn require(
    comptime src: std.builtin.SourceLocation,
    cond: bool,
    comptime tag: []const u8,
    err: ProgramError,
) ProgramError!void {
    if (!cond) return program_error.fail(src, tag, err);
}

/// Assert `a == b` (any equality-comparable type), else log + fail.
///
/// Works for any type that `std.meta.eql` supports. For `Pubkey`
/// (`[32]u8`) prefer `requireKeysEq` — it goes through the
/// hand-tuned 4×u64 compare path.
pub inline fn requireEq(
    comptime src: std.builtin.SourceLocation,
    a: anytype,
    b: @TypeOf(a),
    comptime tag: []const u8,
    err: ProgramError,
) ProgramError!void {
    if (!std.meta.eql(a, b)) return program_error.fail(src, tag, err);
}

/// Assert `a != b`, else log + fail.
pub inline fn requireNeq(
    comptime src: std.builtin.SourceLocation,
    a: anytype,
    b: @TypeOf(a),
    comptime tag: []const u8,
    err: ProgramError,
) ProgramError!void {
    if (std.meta.eql(a, b)) return program_error.fail(src, tag, err);
}
