const shared = @import("shared.zig");

const program_error = shared.program_error;
const pubkey_mod = shared.pubkey_mod;
const ProgramError = shared.ProgramError;
const Pubkey = shared.Pubkey;

/// Assert two `Pubkey`s are equal, else log + fail.
///
/// Routes through `pubkey.pubkeyEq` which lowers to a 4×u64
/// immediate compare — much cheaper than a generic `meta.eql` over
/// `[32]u8`.
pub inline fn requireKeysEq(
    comptime src: @import("std").builtin.SourceLocation,
    a: *const Pubkey,
    b: *const Pubkey,
    comptime tag: []const u8,
    err: ProgramError,
) ProgramError!void {
    if (!pubkey_mod.pubkeyEq(a, b)) return program_error.fail(src, tag, err);
}

/// Assert two `Pubkey`s differ, else log + fail.
pub inline fn requireKeysNeq(
    comptime src: @import("std").builtin.SourceLocation,
    a: *const Pubkey,
    b: *const Pubkey,
    comptime tag: []const u8,
    err: ProgramError,
) ProgramError!void {
    if (pubkey_mod.pubkeyEq(a, b)) return program_error.fail(src, tag, err);
}
