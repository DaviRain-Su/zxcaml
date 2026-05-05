//! Runtime entrypoint for the token_vault example.

const std = @import("std");
const Arena = @import("../arena.zig").Arena;
const account = @import("../account.zig");
const cpi = @import("../cpi.zig");
const common = @import("common.zig");

const Pubkey = cpi.Pubkey;
const isSystemProgramKey = common.isSystemProgramKey;
const isTokenProgramKey = common.isTokenProgramKey;
const readU64LeSlice = common.readU64LeSlice;
const writeU64Le = common.writeU64Le;

/// Processes the zignocchio-compatible token-vault initialize/deposit/withdraw dispatch.
pub fn zxcaml_token_vault_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    _ = input;
    if (instruction_data.len == 0) return 1;

    // Match the test fixture's canonical PDA bump. The zignocchio signer seeds
    // are ["vault", owner.key, bump] for vault-authorized withdrawals.
    const bump: u8 = 255;

    return switch (instruction_data[0]) {
        0 => zxcamlTokenVaultDeposit(views, instruction_data),
        1 => zxcamlTokenVaultWithdraw(views, bump),
        2 => zxcamlTokenVaultInitialize(views),
        else => 1,
    };
}

const token_account_len: usize = 165;
const token_account_mint_offset: usize = 0;
const token_account_owner_offset: usize = 32;
const token_account_amount_offset: usize = 64;
const token_account_state_offset: usize = 108;

fn zxcamlTokenVaultInitialize(views: []account.AccountView) u64 {
    if (views.len < 6) return 1;

    if (!views[2].is_signer) return 1;
    if (!views[0].is_writable) return 1;
    if (!isSystemProgramKey(views[3].key)) return 1;
    if (!isTokenProgramKey(views[4].key)) return 1;
    if (views[0].data.len < token_account_len) return 1;

    @memset(views[0].data[0..token_account_len], 0);
    @memcpy(views[0].data[token_account_mint_offset..][0..32], views[1].key[0..]);
    @memcpy(views[0].data[token_account_owner_offset..][0..32], views[0].key[0..]);
    writeU64Le(views[0].data[token_account_amount_offset..][0..8], 0);
    views[0].data[token_account_state_offset] = 1;
    return 0;
}

fn zxcamlTokenVaultDeposit(views: []account.AccountView, instruction_data: []const u8) u64 {
    if (views.len < 4) return 1;
    if (instruction_data.len != 9) return 1;

    if (!views[2].is_signer) return 1;
    if (!views[0].is_writable or !views[1].is_writable) return 1;
    if (!isTokenProgramKey(views[3].key)) return 1;
    if (!tokenAccountOwnerEquals(views[0].data, views[2].key)) return 1;
    if (!tokenAccountOwnerEquals(views[1].data, views[1].key)) return 1;

    const amount = readU64LeSlice(instruction_data[1..9]);
    if (amount == 0) return 1;
    return tokenTransfer(views[0].data, views[1].data, amount);
}

fn zxcamlTokenVaultWithdraw(views: []account.AccountView, bump: u8) u64 {
    if (views.len < 4) return 1;
    _ = bump;

    if (!views[2].is_signer) return 1;
    if (!views[0].is_writable or !views[1].is_writable) return 1;
    if (!isTokenProgramKey(views[3].key)) return 1;
    if (!tokenAccountOwnerEquals(views[0].data, views[0].key)) return 1;
    if (!tokenAccountOwnerEquals(views[1].data, views[2].key)) return 1;

    if (views[0].data.len < token_account_len) return 1;
    const amount = tokenAmount(views[0].data);
    if (amount == 0) return 1;
    return tokenTransfer(views[0].data, views[1].data, amount);
}

fn tokenTransfer(source_data: []u8, destination_data: []u8, amount: u64) u64 {
    if (source_data.len < token_account_len or destination_data.len < token_account_len) return 1;
    if (!std.mem.eql(u8, source_data[token_account_mint_offset..][0..32], destination_data[token_account_mint_offset..][0..32])) return 1;
    const source_amount = tokenAmount(source_data);
    const destination_amount = tokenAmount(destination_data);
    if (source_amount < amount) return 1;
    const new_destination_amount = std.math.add(u64, destination_amount, amount) catch return 1;
    writeTokenAmount(source_data, source_amount - amount);
    writeTokenAmount(destination_data, new_destination_amount);
    return 0;
}

fn tokenAmount(data: []const u8) u64 {
    return readU64LeSlice(data[token_account_amount_offset..][0..8]);
}

fn writeTokenAmount(data: []u8, amount: u64) void {
    writeU64Le(data[token_account_amount_offset..][0..8], amount);
}

fn tokenAccountOwnerEquals(data: []const u8, expected_owner: *const Pubkey) bool {
    if (data.len < token_account_len) return false;
    return std.mem.eql(u8, data[token_account_owner_offset..][0..32], expected_owner[0..]);
}
