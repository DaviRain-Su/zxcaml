const shared = @import("shared.zig");
const pubkey = shared.pubkey;
const program_error = shared.program_error;
const AccountInfo = shared.AccountInfo;
const ProgramError = shared.ProgramError;
const ID = shared.ID;
const readU16LE = shared.readU16LE;
const IntrospectedInstruction = @import("model.zig").IntrospectedInstruction;

// =============================================================================
// Public API — mirrors solana-program's `sysvar::instructions` free funcs
// =============================================================================

/// Load the index of the currently-executing instruction within the
/// transaction. The instructions sysvar stores this in its trailing
/// 2 bytes.
///
/// Returns `UnsupportedSysvar` if `info` is not the canonical sysvar
/// account. Mirrors `solana_program::sysvar::instructions::load_current_index_checked`.
pub fn loadCurrentIndexChecked(info: AccountInfo) ProgramError!u16 {
    if (!pubkey.pubkeyEqComptime(info.key(), ID)) {
        return error.UnsupportedSysvar;
    }
    const buf = info.data();
    if (buf.len < 2) return error.InvalidAccountData;
    return readU16LE(buf, buf.len - 2);
}

/// Load the instruction at absolute index `idx` within the
/// transaction. Returns an `IntrospectedInstruction` whose
/// internal pointers reference the sysvar account's data.
///
/// Mirrors `solana_program::sysvar::instructions::load_instruction_at_checked`.
pub fn loadInstructionAtChecked(
    idx: u16,
    info: AccountInfo,
) ProgramError!IntrospectedInstruction {
    if (!pubkey.pubkeyEqComptime(info.key(), ID)) {
        return error.UnsupportedSysvar;
    }
    return deserialize(idx, info.data());
}

/// Load an instruction by **relative** offset from the current
/// instruction. `0` is the current instruction; `-1` is the previous
/// one; `+1` is the next one. Returns `InvalidArgument` on under/overflow.
///
/// Mirrors `solana_program::sysvar::instructions::get_instruction_relative`.
pub fn getInstructionRelative(
    relative: i64,
    info: AccountInfo,
) ProgramError!IntrospectedInstruction {
    const current = try loadCurrentIndexChecked(info);
    const target_i64 = @as(i64, @intCast(current)) + relative;
    if (target_i64 < 0) {
        return program_error.fail(@src(), "sysvar_ix:relative_underflow", error.InvalidArgument);
    }
    const target: u16 = @intCast(target_i64);
    return deserialize(target, info.data());
}

pub fn deserialize(idx: u16, data: []const u8) ProgramError!IntrospectedInstruction {
    if (data.len < 2) return error.InvalidAccountData;
    const num_instructions = readU16LE(data, 0);
    if (idx >= num_instructions) {
        return program_error.fail(@src(), "sysvar_ix:index_out_of_range", error.InvalidArgument);
    }

    // Read the offset of instruction `idx` from the table at byte 2.
    const offset_table = 2 + @as(usize, idx) * 2;
    if (offset_table + 2 > data.len) return error.InvalidAccountData;
    const ix_start = readU16LE(data, offset_table);
    if (ix_start + 2 > data.len) return error.InvalidAccountData;

    // Walk the instruction to find its total size so we can hand back
    // a tight slice.
    var cursor: usize = ix_start;
    const num_accounts = readU16LE(data, cursor);
    cursor += 2;
    // Each account meta = 1 (meta_byte) + 32 (pubkey).
    cursor += @as(usize, num_accounts) * (1 + 32);
    if (cursor + 32 > data.len) return error.InvalidAccountData; // program_id
    cursor += 32;
    if (cursor + 2 > data.len) return error.InvalidAccountData;
    const data_len = readU16LE(data, cursor);
    cursor += 2;
    if (cursor + data_len > data.len) return error.InvalidAccountData;
    const ix_end = cursor + data_len;

    return .{ .bytes = data[ix_start..ix_end] };
}
