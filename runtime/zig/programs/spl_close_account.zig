//! Runtime entrypoint for the spl_close_account example.
//!
//! The Mollusk fixture uses program-owned mocked SPL Token accounts. The helper
//! witnesses the SPL Token CloseAccount builder, transfers lamports directly,
//! and zeroes packed token account data instead of invoking Tokenkeg.

const std = @import("std");
const Arena = @import("../arena.zig").Arena;
const account = @import("../account.zig");
const cpi = @import("../cpi.zig");
const spl_token = @import("../spl_token.zig");
const common = @import("common.zig");

const Pubkey = cpi.Pubkey;
const isTokenProgramKey = common.isTokenProgramKey;
const programIdFromInput = common.programIdFromInput;
const pubkeyEq = common.pubkeyEq;
const readU64LeSlice = common.readU64LeSlice;

const token_account_len: usize = spl_token.token_account_len;
const token_account_owner_offset: usize = 32;
const token_account_amount_offset: usize = 64;
const token_account_state_offset: usize = 108;

/// Processes the ZxCaml mocked SPL Token CloseAccount example.
pub fn zxcaml_spl_close_account_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len != spl_token.close_account_instruction_data_len) return 1;
    if (views.len < 4) return 1;

    const program_id = programIdFromInput(input);
    const account_to_close = views[0];
    const destination = views[1];
    const authority = views[2];
    const token_program = views[3];

    if (!account_to_close.is_writable or !destination.is_writable) return 1;
    if (!authority.is_signer) return 1;
    if (!pubkeyEq(account_to_close.owner, program_id)) return 1;
    if (!isTokenProgramKey(token_program.key)) return 1;
    if (!tokenAccountInitialized(account_to_close.data)) return 1;
    if (!tokenAccountOwnerEquals(account_to_close.data, authority.key)) return 1;
    if (tokenAmount(account_to_close.data) != 0) return 1;

    // Witness the SPL Token CloseAccount builder. The direct lamport/data
    // mutation below mirrors the established mocked-token convention.
    var metas: [spl_token.close_account_account_count]cpi.SolAccountMeta = undefined;
    var data: [spl_token.close_account_instruction_data_len]u8 = undefined;
    const ix = spl_token.closeAccountInstruction(account_to_close.key, destination.key, authority.key, &metas, &data);
    if (ix.data_len != spl_token.close_account_instruction_data_len) return 1;
    if (ix.account_len != spl_token.close_account_account_count) return 1;
    if (ix.data[0] != spl_token.close_account_discriminator) return 1;

    const transferred_lamports = account_to_close.lamports.*;
    destination.lamports.* = std.math.add(u64, destination.lamports.*, transferred_lamports) catch return 1;
    account_to_close.lamports.* = 0;
    @memset(account_to_close.data, 0);
    return 0;
}

fn tokenAccountInitialized(data: []const u8) bool {
    return data.len >= token_account_len and data[token_account_state_offset] == 1;
}

fn tokenAccountOwnerEquals(data: []const u8, expected_owner: *const Pubkey) bool {
    if (data.len < token_account_len) return false;
    return std.mem.eql(u8, data[token_account_owner_offset..][0..32], expected_owner[0..]);
}

fn tokenAmount(data: []const u8) u64 {
    return readU64LeSlice(data[token_account_amount_offset..][0..8]);
}
