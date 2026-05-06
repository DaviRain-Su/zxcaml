//! Runtime entrypoint for the spl_revoke example.
//!
//! The Mollusk fixture uses program-owned mocked SPL Token accounts. The helper
//! witnesses the SPL Token Revoke builder and clears delegate state directly
//! instead of invoking Tokenkeg.

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

const token_account_len: usize = spl_token.token_account_len;
const token_account_owner_offset: usize = 32;
const token_account_state_offset: usize = 108;
const delegate_option_offset: usize = 72;
const delegate_option_len: usize = 4;
const delegate_offset: usize = delegate_option_offset + delegate_option_len;
const delegate_region_end: usize = delegate_offset + spl_token.pubkey_len;
const delegated_amount_offset: usize = 121;
const delegated_amount_end: usize = delegated_amount_offset + @sizeOf(u64);

/// Processes the ZxCaml mocked SPL Token Revoke example.
pub fn zxcaml_spl_revoke_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len != spl_token.revoke_instruction_data_len) return 1;
    if (views.len < 3) return 1;

    const program_id = programIdFromInput(input);
    const source = views[0];
    const authority = views[1];
    const token_program = views[2];

    if (!source.is_writable) return 1;
    if (!authority.is_signer) return 1;
    if (!pubkeyEq(source.owner, program_id)) return 1;
    if (!isTokenProgramKey(token_program.key)) return 1;
    if (!tokenAccountInitialized(source.data)) return 1;
    if (!tokenAccountOwnerEquals(source.data, authority.key)) return 1;

    // Witness the SPL Token Revoke builder. The direct data mutation below is
    // the intended mocked-token effect for Mollusk fixtures.
    var metas: [spl_token.revoke_account_count]cpi.SolAccountMeta = undefined;
    var data: [spl_token.revoke_instruction_data_len]u8 = undefined;
    const ix = spl_token.revokeInstruction(source.key, authority.key, &metas, &data);
    if (ix.data_len != spl_token.revoke_instruction_data_len) return 1;
    if (ix.account_len != spl_token.revoke_account_count) return 1;
    if (ix.data[0] != spl_token.revoke_discriminator) return 1;

    @memset(source.data[delegate_option_offset..delegate_region_end], 0);
    @memset(source.data[delegated_amount_offset..delegated_amount_end], 0);
    return 0;
}

fn tokenAccountInitialized(data: []const u8) bool {
    return data.len >= token_account_len and data[token_account_state_offset] == 1;
}

fn tokenAccountOwnerEquals(data: []const u8, expected_owner: *const Pubkey) bool {
    if (data.len < token_account_len) return false;
    return std.mem.eql(u8, data[token_account_owner_offset..][0..32], expected_owner[0..]);
}
