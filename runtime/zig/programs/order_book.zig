//! Runtime entrypoint for the order_book example.
//!
//! The Mollusk fixture intentionally uses program-owned mocked SPL Token
//! accounts. Fill mutates the packed SPL Token `amount` fields directly instead
//! of invoking Tokenkeg, matching token_vault and ata_transfer's test-only
//! convention for this milestone.

const std = @import("std");
const Arena = @import("../arena.zig").Arena;
const account = @import("../account.zig");
const cpi = @import("../cpi.zig");
const spl_token = @import("../spl_token.zig");
const common = @import("common.zig");

const Pubkey = cpi.Pubkey;
const SolSignerSeed = cpi.SolSignerSeed;
const programIdFromInput = common.programIdFromInput;
const pubkeyEq = common.pubkeyEq;
const readU64LeSlice = common.readU64LeSlice;
const sol_create_program_address = cpi.sol_create_program_address;
const writeU64Le = common.writeU64Le;

const success: u64 = 0;
const order_state_len: usize = 49;
const order_maker_offset: usize = 0;
const order_side_offset: usize = 32;
const order_base_amount_offset: usize = 33;
const order_price_offset: usize = 41;
const token_account_len: usize = spl_token.token_account_len;
const token_account_mint_offset: usize = 0;
const token_account_owner_offset: usize = 32;
const token_account_amount_offset: usize = 64;
const token_account_state_offset: usize = 108;

/// Processes the ZxCaml-original maker/taker order book example.
///
/// PDA fixture convention: tests choose an Order PDA whose canonical bump is
/// 255 for seeds `["order", maker_pubkey, order_id_le]`.  This helper verifies
/// that bumped address directly instead of relying on
/// `sol_try_find_program_address` inside BPF.
pub fn zxcaml_order_book_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len == 0) return 1;

    const program_id = programIdFromInput(input);
    return switch (instruction_data[0]) {
        0x01 => postOrder(program_id, views, instruction_data),
        0x02 => fill(program_id, views, instruction_data),
        else => 1,
    };
}

fn postOrder(program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    if (instruction_data.len != 26) return 1;
    if (views.len < 2) return 1;

    const order = views[0];
    const maker = views[1];
    if (!order.is_writable) return 1;
    if (!maker.is_signer) return 1;
    if (!pubkeyEq(order.owner, program_id)) return 1;
    if (order.data.len < order_state_len) return 1;

    const side = instruction_data[9];
    if (side != 0 and side != 1) return 1;
    const base_amount = readU64LeSlice(instruction_data[10..18]);
    const price = readU64LeSlice(instruction_data[18..26]);
    if (base_amount == 0 or price == 0) return 1;

    var order_id_seed: [8]u8 = undefined;
    @memcpy(order_id_seed[0..], instruction_data[1..9]);
    if (!orderPdaMatches(order.key, maker.key, &order_id_seed, program_id)) return 1;

    @memcpy(order.data[order_maker_offset..][0..32], maker.key[0..]);
    order.data[order_side_offset] = side;
    writeU64Le(order.data[order_base_amount_offset..][0..8], base_amount);
    writeU64Le(order.data[order_price_offset..][0..8], price);
    return 0;
}

fn fill(program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    if (instruction_data.len != 9) return 1;
    if (views.len < 7) return 1;

    const order = views[0];
    const maker_base_ata = views[1];
    const taker_base_ata = views[2];
    const taker_quote_ata = views[3];
    const maker_quote_ata = views[4];
    const maker = views[5];
    const taker = views[6];

    if (!order.is_writable) return 1;
    if (!maker_base_ata.is_writable or !taker_base_ata.is_writable) return 1;
    if (!taker_quote_ata.is_writable or !maker_quote_ata.is_writable) return 1;
    if (!maker.is_writable) return 1;
    if (!taker.is_signer) return 1;
    if (!pubkeyEq(order.owner, program_id)) return 1;
    if (!pubkeyEq(maker_base_ata.owner, program_id)) return 1;
    if (!pubkeyEq(taker_base_ata.owner, program_id)) return 1;
    if (!pubkeyEq(taker_quote_ata.owner, program_id)) return 1;
    if (!pubkeyEq(maker_quote_ata.owner, program_id)) return 1;
    if (order.data.len < order_state_len) return 1;

    const quantity = readU64LeSlice(instruction_data[1..9]);
    if (quantity == 0) return 1;
    const remaining_base = readU64LeSlice(order.data[order_base_amount_offset..][0..8]);
    const price = readU64LeSlice(order.data[order_price_offset..][0..8]);
    if (quantity > remaining_base) return 1;
    if (price == 0) return 1;
    const quote_amount = checkedMulU64(price, quantity) catch return 1;

    if (!std.mem.eql(u8, order.data[order_maker_offset..][0..32], maker.key[0..])) return 1;
    const side = order.data[order_side_offset];
    if (side != 0 and side != 1) return 1;

    if (!tokenAccountOwnerEquals(maker_base_ata.data, maker.key)) return 1;
    if (!tokenAccountOwnerEquals(taker_base_ata.data, taker.key)) return 1;
    if (!tokenAccountOwnerEquals(taker_quote_ata.data, taker.key)) return 1;
    if (!tokenAccountOwnerEquals(maker_quote_ata.data, maker.key)) return 1;
    if (!tokenAccountInitialized(maker_base_ata.data) or !tokenAccountInitialized(taker_base_ata.data)) return 1;
    if (!tokenAccountInitialized(taker_quote_ata.data) or !tokenAccountInitialized(maker_quote_ata.data)) return 1;
    if (!tokenMintsEqual(maker_base_ata.data, taker_base_ata.data)) return 1;
    if (!tokenMintsEqual(taker_quote_ata.data, maker_quote_ata.data)) return 1;

    if (tokenTransfer(maker_base_ata.data, taker_base_ata.data, quantity) != success) return 1;
    if (tokenTransfer(taker_quote_ata.data, maker_quote_ata.data, quote_amount) != success) return 1;

    const next_base = remaining_base - quantity;
    if (next_base == 0) {
        return closeOrder(order, maker);
    }

    writeU64Le(order.data[order_base_amount_offset..][0..8], next_base);
    return 0;
}

fn closeOrder(order: account.AccountView, maker: account.AccountView) u64 {
    const close_lamports = order.lamports.*;
    const maker_lamports = maker.lamports.*;
    maker.lamports.* = std.math.add(u64, maker_lamports, close_lamports) catch return 1;
    order.lamports.* = 0;
    @memset(order.data[0..order_state_len], 0);
    return 0;
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

fn checkedMulU64(lhs: u64, rhs: u64) !u64 {
    var result: u64 = 0;
    var addend = lhs;
    var multiplier = rhs;
    while (multiplier != 0) : (multiplier >>= 1) {
        if ((multiplier & 1) == 1) {
            result = try std.math.add(u64, result, addend);
        }
        if (multiplier > 1) {
            addend = try std.math.add(u64, addend, addend);
        }
    }
    return result;
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

fn orderPdaMatches(order_key: *const Pubkey, maker_key: *const Pubkey, order_id_seed: *const [8]u8, program_id: *const Pubkey) bool {
    var order_seed: [5]u8 = .{ 'o', 'r', 'd', 'e', 'r' };
    var maker_seed = maker_key.*;
    var id_seed = order_id_seed.*;
    var bump_seed: [1]u8 = .{255};
    var seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(order_seed[0..]),
        SolSignerSeed.fromSlice(maker_seed[0..]),
        SolSignerSeed.fromSlice(id_seed[0..]),
        SolSignerSeed.fromSlice(bump_seed[0..]),
    };
    var expected: Pubkey = undefined;
    if (sol_create_program_address(seeds[0..], program_id, &expected) != success) return false;
    return pubkeyEq(order_key, &expected);
}
