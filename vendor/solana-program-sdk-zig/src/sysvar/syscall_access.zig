const shared = @import("shared.zig");
const program_error = shared.program_error;
const Pubkey = shared.Pubkey;
const ProgramError = shared.ProgramError;
const bpf = shared.bpf;

// =============================================================================
// sol_get_sysvar — generic offset-based sysvar read syscall.
//
// Unlike the individual `Clock::get` / `Rent::get` syscalls (which are
// being deprecated in solana-program 4.x), `sol_get_sysvar` lets a
// program read **any** sysvar by ID, optionally at an offset. This is
// the only way to read large sysvars like `SlotHashes` or
// `StakeHistory` without having the account passed in.
//
// Return codes (per agave bpf_loader/syscalls/sysvar.rs):
//   0 = SUCCESS
//   1 = OFFSET_LENGTH_EXCEEDS_SYSVAR — `offset + length` past the data
//   2 = SYSVAR_NOT_FOUND               — sysvar ID isn't known
// =============================================================================

extern fn sol_get_sysvar(
    sysvar_id_addr: *const u8,
    result: *u8,
    offset: u64,
    length: u64,
) callconv(.c) u64;

/// Read `length` bytes of `sysvar_id`'s account data starting at
/// `offset` into `dst`. `dst.len` must be at least `length`.
///
/// Maps the runtime's two error codes onto `ProgramError` and logs a
/// tag so each failure mode is distinguishable on the transaction
/// log (the wire u64 alone wouldn't be — `InvalidArgument` /
/// `UnsupportedSysvar` are both extremely common values):
///
///   - `OFFSET_LENGTH_EXCEEDS_SYSVAR` (rc=1) →
///     `tag:"sysvar:offset_out_of_range"`, `InvalidArgument`.
///   - `SYSVAR_NOT_FOUND` (rc=2) →
///     `tag:"sysvar:not_found"`, `UnsupportedSysvar`.
///   - Any other non-zero rc →
///     `tag:"sysvar:unexpected"`, `UnsupportedSysvar`.
///
/// On host targets this returns `UnsupportedSysvar` — there's no
/// runtime to query.
pub fn getSysvarBytes(
    dst: []u8,
    sysvar_id_addr: *const Pubkey,
    offset: u64,
    length: u64,
) ProgramError!void {
    if (dst.len < length) {
        return program_error.fail(@src(), "sysvar:dst_too_small", ProgramError.InvalidArgument);
    }

    if (bpf.is_bpf_program) {
        const rc = sol_get_sysvar(
            @as(*const u8, @ptrCast(sysvar_id_addr)),
            @as(*u8, @ptrCast(dst.ptr)),
            offset,
            length,
        );
        return switch (rc) {
            0 => {},
            1 => program_error.fail(@src(), "sysvar:offset_out_of_range", ProgramError.InvalidArgument),
            2 => program_error.fail(@src(), "sysvar:not_found", ProgramError.UnsupportedSysvar),
            else => program_error.fail(@src(), "sysvar:unexpected", ProgramError.UnsupportedSysvar),
        };
    } else {
        return ProgramError.UnsupportedSysvar;
    }
}
