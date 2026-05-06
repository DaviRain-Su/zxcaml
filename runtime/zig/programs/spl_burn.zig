//! Runtime entrypoint for the spl_burn example.
//!
//! The Mollusk fixture uses program-owned mocked SPL Token accounts. The helper
//! witnesses the SPL Token Burn builder and then mutates the packed token
//! account amount directly instead of invoking Tokenkeg.

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
const writeU64Le = common.writeU64Le;

const token_account_len: usize = spl_token.token_account_len;
const token_account_mint_offset: usize = 0;
const token_account_owner_offset: usize = 32;
const token_account_amount_offset: usize = 64;
const token_account_state_offset: usize = 108;

/// Processes the ZxCaml mocked SPL Token Burn example.
pub fn zxcaml_spl_burn_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len != spl_token.burn_instruction_data_len) return 1;
    if (views.len < 4) return 1;

    const program_id = programIdFromInput(input);
    const account_to_burn = views[0];
    const mint = views[1];
    const authority = views[2];
    const token_program = views[3];

    if (!account_to_burn.is_writable or !mint.is_writable) return 1;
    if (!authority.is_signer) return 1;
    if (!pubkeyEq(account_to_burn.owner, program_id)) return 1;
    if (!isTokenProgramKey(token_program.key)) return 1;
    if (!tokenAccountInitialized(account_to_burn.data)) return 1;
    if (!tokenAccountOwnerEquals(account_to_burn.data, authority.key)) return 1;
    if (!tokenAccountMintEquals(account_to_burn.data, mint.key)) return 1;

    const amount = readU64LeSlice(instruction_data[1..spl_token.burn_instruction_data_len]);
    if (amount == 0) return 1;

    // Witness the SPL Token Burn builder. Mollusk does not register Tokenkeg as
    // a builtin, so the direct data mutation below is the intended test effect.
    var metas: [spl_token.burn_account_count]cpi.SolAccountMeta = undefined;
    var data: [spl_token.burn_instruction_data_len]u8 = undefined;
    const ix = spl_token.burnInstruction(account_to_burn.key, mint.key, authority.key, amount, &metas, &data);
    if (ix.data_len != spl_token.burn_instruction_data_len) return 1;
    if (ix.account_len != spl_token.burn_account_count) return 1;
    if (ix.data[0] != spl_token.burn_discriminator) return 1;

    const current_amount = tokenAmount(account_to_burn.data);
    if (current_amount < amount) return 1;
    writeTokenAmount(account_to_burn.data, current_amount - amount);
    return 0;
}

fn tokenAccountInitialized(data: []const u8) bool {
    return data.len >= token_account_len and data[token_account_state_offset] == 1;
}

fn tokenAccountOwnerEquals(data: []const u8, expected_owner: *const Pubkey) bool {
    if (data.len < token_account_len) return false;
    return std.mem.eql(u8, data[token_account_owner_offset..][0..32], expected_owner[0..]);
}

fn tokenAccountMintEquals(data: []const u8, expected_mint: *const Pubkey) bool {
    if (data.len < token_account_len) return false;
    return std.mem.eql(u8, data[token_account_mint_offset..][0..32], expected_mint[0..]);
}

fn tokenAmount(data: []const u8) u64 {
    return readU64LeSlice(data[token_account_amount_offset..][0..8]);
}

fn writeTokenAmount(data: []u8, amount: u64) void {
    writeU64Le(data[token_account_amount_offset..][0..8], amount);
}
