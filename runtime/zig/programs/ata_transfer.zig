//! Runtime entrypoint for the ata_transfer example.
//!
//! The Mollusk fixture intentionally uses program-owned mocked SPL Token
//! accounts.  Initialize witnesses the ATA CreateIdempotent builder and then
//! writes the canonical SPL Token account layout directly; Transfer mutates the
//! amount fields directly instead of invoking Tokenkeg, matching token_vault's
//! test-only convention.

const std = @import("std");
const Arena = @import("../arena.zig").Arena;
const account = @import("../account.zig");
const cpi = @import("../cpi.zig");
const spl_token = @import("../spl_token.zig");
const ata = @import("ata.zig");
const common = @import("common.zig");

const Pubkey = cpi.Pubkey;
const isSystemProgramKey = common.isSystemProgramKey;
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

/// Processes the ZxCaml ATA + mocked SPL Token transfer example.
///
/// Instruction discriminators:
/// - `0x00` Initialize: accounts are funding, destination ATA, owner, mint,
///   System Program, SPL Token program. The helper witnesses
///   `ata.createIdempotent` and initializes the destination token bytes.
/// - `0x01` Transfer: accounts are source ATA, destination ATA, authority,
///   mint, System Program, SPL Token program. Amount is a little-endian u64.
pub fn zxcaml_ata_transfer_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len == 0) return 1;

    const program_id = programIdFromInput(input);
    return switch (instruction_data[0]) {
        0x00 => initialize(program_id, views, instruction_data),
        0x01 => transfer(program_id, views, instruction_data),
        else => 1,
    };
}

fn initialize(program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    if (instruction_data.len != 1) return 1;
    if (views.len < 6) return 1;

    const funding = views[0];
    const destination_ata = views[1];
    const owner = views[2];
    const mint = views[3];
    const system_program = views[4];
    const token_program = views[5];

    if (!funding.is_signer or !funding.is_writable) return 1;
    if (!destination_ata.is_writable) return 1;
    if (!pubkeyEq(destination_ata.owner, program_id)) return 1;
    if (!isSystemProgramKey(system_program.key)) return 1;
    if (!isTokenProgramKey(token_program.key)) return 1;
    if (destination_ata.data.len < token_account_len) return 1;

    // Witness the ATA CreateIdempotent builder from F-EX2-RT-ATA.  The harness
    // does not register the ATA program builtin, so the effect below is the
    // mocked account-data initialization used for this milestone.
    var metas: [ata.create_idempotent_account_count]cpi.SolAccountMeta = undefined;
    var data: [ata.create_idempotent_instruction_data_len]u8 = undefined;
    const ix = ata.createIdempotent(
        funding.key,
        destination_ata.key,
        owner.key,
        mint.key,
        &metas,
        &data,
    );
    if (ix.data_len != ata.create_idempotent_instruction_data_len) return 1;
    if (ix.data[0] != ata.create_idempotent_discriminator) return 1;

    @memset(destination_ata.data[0..token_account_len], 0);
    @memcpy(destination_ata.data[token_account_mint_offset..][0..32], mint.key[0..]);
    @memcpy(destination_ata.data[token_account_owner_offset..][0..32], owner.key[0..]);
    writeU64Le(destination_ata.data[token_account_amount_offset..][0..8], 0);
    destination_ata.data[token_account_state_offset] = 1;
    return 0;
}

fn transfer(program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    if (instruction_data.len != spl_token.transfer_instruction_data_len) return 1;
    if (views.len < 6) return 1;

    const source_ata = views[0];
    const destination_ata = views[1];
    const authority = views[2];
    const token_program = views[5];

    if (!source_ata.is_writable or !destination_ata.is_writable) return 1;
    if (!authority.is_signer) return 1;
    if (!pubkeyEq(source_ata.owner, program_id)) return 1;
    if (!pubkeyEq(destination_ata.owner, program_id)) return 1;
    if (!isTokenProgramKey(token_program.key)) return 1;
    if (!tokenAccountOwnerEquals(source_ata.data, authority.key)) return 1;
    if (!tokenAccountInitialized(source_ata.data) or !tokenAccountInitialized(destination_ata.data)) return 1;
    if (!tokenMintsEqual(source_ata.data, destination_ata.data)) return 1;

    const amount = readU64LeSlice(instruction_data[1..9]);
    if (amount == 0) return 1;
    return tokenTransfer(source_ata.data, destination_ata.data, amount);
}

fn tokenTransfer(source_data: []u8, destination_data: []u8, amount: u64) u64 {
    if (source_data.len < token_account_len or destination_data.len < token_account_len) return 1;
    const source_amount = tokenAmount(source_data);
    const destination_amount = tokenAmount(destination_data);
    if (source_amount < amount) return 1;
    const new_destination_amount = std.math.add(u64, destination_amount, amount) catch return 1;
    writeTokenAmount(source_data, source_amount - amount);
    writeTokenAmount(destination_data, new_destination_amount);
    return 0;
}

fn tokenAccountInitialized(data: []const u8) bool {
    return data.len >= token_account_len and data[token_account_state_offset] == 1;
}

fn tokenAccountOwnerEquals(data: []const u8, expected_owner: *const Pubkey) bool {
    if (data.len < token_account_len) return false;
    return std.mem.eql(u8, data[token_account_owner_offset..][0..32], expected_owner[0..]);
}

fn tokenMintsEqual(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len < token_account_len or rhs.len < token_account_len) return false;
    return std.mem.eql(u8, lhs[token_account_mint_offset..][0..32], rhs[token_account_mint_offset..][0..32]);
}

fn tokenAmount(data: []const u8) u64 {
    return readU64LeSlice(data[token_account_amount_offset..][0..8]);
}

fn writeTokenAmount(data: []u8, amount: u64) void {
    writeU64Le(data[token_account_amount_offset..][0..8], amount);
}
