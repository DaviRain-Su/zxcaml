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
    return zxcaml_order_book_process_with_program_id(arena, programIdFromInput(input), views, instruction_data);
}

pub fn zxcaml_order_book_process_with_program_id(arena: *Arena, program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len == 0) return 1;

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

const OrderBookPda = struct {
    order_id: [8]u8,
    order: Pubkey,
};

const OrderBookTestAccount = struct {
    key: Pubkey = [_]u8{0} ** 32,
    owner: Pubkey = [_]u8{0} ** 32,
    lamports: u64 = 0,
    rent_epoch: u64 = 0,
    data: [token_account_len]u8 = [_]u8{0} ** token_account_len,

    fn view(self: *OrderBookTestAccount, is_signer: bool, is_writable: bool, data_len: usize) account.AccountView {
        return .{
            .is_signer = is_signer,
            .is_writable = is_writable,
            .executable = false,
            .key = &self.key,
            .lamports = &self.lamports,
            .data = self.data[0..data_len],
            .owner = &self.owner,
            .rent_epoch = &self.rent_epoch,
        };
    }
};

const OrderBookTestFixture = struct {
    program_id: Pubkey = [_]u8{41} ** 32,
    order_id: [8]u8 = [_]u8{0} ** 8,
    order: OrderBookTestAccount = .{ .lamports = 9 },
    maker_base: OrderBookTestAccount = .{ .key = [_]u8{1} ** 32 },
    taker_base: OrderBookTestAccount = .{ .key = [_]u8{2} ** 32 },
    taker_quote: OrderBookTestAccount = .{ .key = [_]u8{3} ** 32 },
    maker_quote: OrderBookTestAccount = .{ .key = [_]u8{4} ** 32 },
    maker: OrderBookTestAccount = .{ .key = [_]u8{5} ** 32, .lamports = 20 },
    taker: OrderBookTestAccount = .{ .key = [_]u8{6} ** 32, .lamports = 30 },
    base_mint: Pubkey = [_]u8{0xb1} ** 32,
    quote_mint: Pubkey = [_]u8{0xc2} ** 32,

    fn init() OrderBookTestFixture {
        var fixture = OrderBookTestFixture{};
        const pda = findOrderBookPda(&fixture.maker.key, &fixture.program_id);
        fixture.order_id = pda.order_id;
        fixture.order.key = pda.order;
        fixture.order.owner = fixture.program_id;
        fixture.maker_base.owner = fixture.program_id;
        fixture.taker_base.owner = fixture.program_id;
        fixture.taker_quote.owner = fixture.program_id;
        fixture.maker_quote.owner = fixture.program_id;
        fixture.writeTokenAccounts();
        return fixture;
    }

    fn writeTokenAccounts(self: *OrderBookTestFixture) void {
        writeOrderBookTokenAccount(&self.maker_base.data, &self.base_mint, &self.maker.key, 100);
        writeOrderBookTokenAccount(&self.taker_base.data, &self.base_mint, &self.taker.key, 5);
        writeOrderBookTokenAccount(&self.taker_quote.data, &self.quote_mint, &self.taker.key, 1_000);
        writeOrderBookTokenAccount(&self.maker_quote.data, &self.quote_mint, &self.maker.key, 10);
    }

    fn writePostedOrder(self: *OrderBookTestFixture, side: u8, remaining_base: u64, price: u64) void {
        @memset(self.order.data[0..order_state_len], 0);
        @memcpy(self.order.data[order_maker_offset..][0..32], self.maker.key[0..]);
        self.order.data[order_side_offset] = side;
        writeU64Le(self.order.data[order_base_amount_offset..][0..8], remaining_base);
        writeU64Le(self.order.data[order_price_offset..][0..8], price);
    }

    fn postViews(self: *OrderBookTestFixture, order_writable: bool, maker_signer: bool) [2]account.AccountView {
        return .{
            self.order.view(false, order_writable, order_state_len),
            self.maker.view(maker_signer, false, token_account_len),
        };
    }

    fn fillViews(self: *OrderBookTestFixture, taker_signer: bool) [7]account.AccountView {
        return .{
            self.order.view(false, true, order_state_len),
            self.maker_base.view(false, true, token_account_len),
            self.taker_base.view(false, true, token_account_len),
            self.taker_quote.view(false, true, token_account_len),
            self.maker_quote.view(false, true, token_account_len),
            self.maker.view(false, true, token_account_len),
            self.taker.view(taker_signer, false, token_account_len),
        };
    }
};

fn findOrderBookPda(maker_key: *const Pubkey, program_id: *const Pubkey) OrderBookPda {
    for (0..256) |byte| {
        const order_id: [8]u8 = [_]u8{@intCast(byte)} ** 8;
        var order_seed: [5]u8 = .{ 'o', 'r', 'd', 'e', 'r' };
        var maker_seed = maker_key.*;
        var id_seed = order_id;
        var bump_seed: [1]u8 = .{255};
        var seeds = [_]SolSignerSeed{
            SolSignerSeed.fromSlice(order_seed[0..]),
            SolSignerSeed.fromSlice(maker_seed[0..]),
            SolSignerSeed.fromSlice(id_seed[0..]),
            SolSignerSeed.fromSlice(bump_seed[0..]),
        };
        var order: Pubkey = undefined;
        if (sol_create_program_address(seeds[0..], program_id, &order) == success) {
            return .{ .order_id = order_id, .order = order };
        }
    }
    @panic("unable to find bump-255 order PDA fixture");
}

fn writeOrderBookProgramInput(input: []u8, program_id: Pubkey) void {
    @memset(input, 0);
    writeU64Le(input[0..8], 0);
    writeU64Le(input[8..16], 0);
    @memcpy(input[16..48], program_id[0..]);
}

fn writeOrderBookPostIx(out: []u8, order_id: [8]u8, side: u8, base_amount: u64, price: u64) void {
    out[0] = 0x01;
    @memcpy(out[1..9], order_id[0..]);
    out[9] = side;
    writeU64Le(out[10..18], base_amount);
    writeU64Le(out[18..26], price);
}

fn writeOrderBookFillIx(out: []u8, quantity: u64) void {
    out[0] = 0x02;
    writeU64Le(out[1..9], quantity);
}

fn writeOrderBookTokenAccount(data: *[token_account_len]u8, mint: *const Pubkey, owner: *const Pubkey, amount: u64) void {
    @memset(data[0..], 0);
    @memcpy(data[token_account_mint_offset..][0..32], mint[0..]);
    @memcpy(data[token_account_owner_offset..][0..32], owner[0..]);
    writeU64Le(data[token_account_amount_offset..][0..8], amount);
    data[token_account_state_offset] = 1;
}

test "order_book post writes maker side amount and price" {
    var arena: Arena = undefined;
    var fixture = OrderBookTestFixture.init();
    @memset(fixture.order.data[0..order_state_len], 0xaa);
    var views = fixture.postViews(true, true);
    var input: [48]u8 = undefined;
    writeOrderBookProgramInput(input[0..], fixture.program_id);
    var ix: [26]u8 = undefined;
    writeOrderBookPostIx(ix[0..], fixture.order_id, 1, 12, 7);
    try std.testing.expectEqual(success, zxcaml_order_book_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqualSlices(u8, fixture.maker.key[0..], fixture.order.data[order_maker_offset..][0..32]);
    try std.testing.expectEqual(@as(u8, 1), fixture.order.data[order_side_offset]);
    try std.testing.expectEqual(@as(u64, 12), readU64LeSlice(fixture.order.data[order_base_amount_offset..][0..8]));
    try std.testing.expectEqual(@as(u64, 7), readU64LeSlice(fixture.order.data[order_price_offset..][0..8]));
}

test "order_book fill partially transfers base and quote tokens" {
    var arena: Arena = undefined;
    var fixture = OrderBookTestFixture.init();
    fixture.writePostedOrder(0, 10, 4);
    var views = fixture.fillViews(true);
    var input: [48]u8 = undefined;
    writeOrderBookProgramInput(input[0..], fixture.program_id);
    var ix: [9]u8 = undefined;
    writeOrderBookFillIx(ix[0..], 3);
    try std.testing.expectEqual(success, zxcaml_order_book_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 97), tokenAmount(fixture.maker_base.data[0..]));
    try std.testing.expectEqual(@as(u64, 8), tokenAmount(fixture.taker_base.data[0..]));
    try std.testing.expectEqual(@as(u64, 988), tokenAmount(fixture.taker_quote.data[0..]));
    try std.testing.expectEqual(@as(u64, 22), tokenAmount(fixture.maker_quote.data[0..]));
    try std.testing.expectEqual(@as(u64, 7), readU64LeSlice(fixture.order.data[order_base_amount_offset..][0..8]));
}

test "order_book fill fully closes order and refunds lamports" {
    var arena: Arena = undefined;
    var fixture = OrderBookTestFixture.init();
    fixture.writePostedOrder(0, 4, 2);
    var views = fixture.fillViews(true);
    var input: [48]u8 = undefined;
    writeOrderBookProgramInput(input[0..], fixture.program_id);
    var ix: [9]u8 = undefined;
    writeOrderBookFillIx(ix[0..], 4);
    try std.testing.expectEqual(success, zxcaml_order_book_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 96), tokenAmount(fixture.maker_base.data[0..]));
    try std.testing.expectEqual(@as(u64, 9), tokenAmount(fixture.taker_base.data[0..]));
    try std.testing.expectEqual(@as(u64, 992), tokenAmount(fixture.taker_quote.data[0..]));
    try std.testing.expectEqual(@as(u64, 18), tokenAmount(fixture.maker_quote.data[0..]));
    try std.testing.expectEqual(@as(u64, 0), fixture.order.lamports);
    try std.testing.expectEqual(@as(u64, 29), fixture.maker.lamports);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** order_state_len), fixture.order.data[0..order_state_len]);
}

test "order_book fill rejects quantity greater than remaining" {
    var arena: Arena = undefined;
    var fixture = OrderBookTestFixture.init();
    fixture.writePostedOrder(0, 2, 4);
    var views = fixture.fillViews(true);
    var input: [48]u8 = undefined;
    writeOrderBookProgramInput(input[0..], fixture.program_id);
    var ix: [9]u8 = undefined;
    writeOrderBookFillIx(ix[0..], 3);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_order_book_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 100), tokenAmount(fixture.maker_base.data[0..]));
    try std.testing.expectEqual(@as(u64, 5), tokenAmount(fixture.taker_base.data[0..]));
}

test "order_book fill rejects token mint mismatch" {
    var arena: Arena = undefined;
    var fixture = OrderBookTestFixture.init();
    fixture.writePostedOrder(0, 10, 4);
    fixture.taker_base.data[token_account_mint_offset] ^= 0xff;
    var views = fixture.fillViews(true);
    var input: [48]u8 = undefined;
    writeOrderBookProgramInput(input[0..], fixture.program_id);
    var ix: [9]u8 = undefined;
    writeOrderBookFillIx(ix[0..], 3);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_order_book_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 100), tokenAmount(fixture.maker_base.data[0..]));
    try std.testing.expectEqual(@as(u64, 5), tokenAmount(fixture.taker_base.data[0..]));
}

test "order_book post rejects side outside bid ask range" {
    var arena: Arena = undefined;
    var fixture = OrderBookTestFixture.init();
    var views = fixture.postViews(true, true);
    var input: [48]u8 = undefined;
    writeOrderBookProgramInput(input[0..], fixture.program_id);
    var ix: [26]u8 = undefined;
    writeOrderBookPostIx(ix[0..], fixture.order_id, 2, 12, 7);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_order_book_process(&arena, input[0..].ptr, views[0..], ix[0..]));
}

test "order_book post rejects zero amount and zero price" {
    var arena: Arena = undefined;
    var fixture = OrderBookTestFixture.init();
    var views = fixture.postViews(true, true);
    var input: [48]u8 = undefined;
    writeOrderBookProgramInput(input[0..], fixture.program_id);
    var zero_amount_ix: [26]u8 = undefined;
    writeOrderBookPostIx(zero_amount_ix[0..], fixture.order_id, 1, 0, 7);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_order_book_process(&arena, input[0..].ptr, views[0..], zero_amount_ix[0..]));
    var zero_price_ix: [26]u8 = undefined;
    writeOrderBookPostIx(zero_price_ix[0..], fixture.order_id, 1, 12, 0);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_order_book_process(&arena, input[0..].ptr, views[0..], zero_price_ix[0..]));
}

test "order_book fill rejects checkedMulU64 overflow" {
    var arena: Arena = undefined;
    var fixture = OrderBookTestFixture.init();
    fixture.writePostedOrder(0, 2, std.math.maxInt(u64));
    var views = fixture.fillViews(true);
    var input: [48]u8 = undefined;
    writeOrderBookProgramInput(input[0..], fixture.program_id);
    var ix: [9]u8 = undefined;
    writeOrderBookFillIx(ix[0..], 2);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_order_book_process(&arena, input[0..].ptr, views[0..], ix[0..]));
}

test "order_book fill rejects stored side outside bid ask range" {
    var arena: Arena = undefined;
    var fixture = OrderBookTestFixture.init();
    fixture.writePostedOrder(9, 10, 4);
    var views = fixture.fillViews(true);
    var input: [48]u8 = undefined;
    writeOrderBookProgramInput(input[0..], fixture.program_id);
    var ix: [9]u8 = undefined;
    writeOrderBookFillIx(ix[0..], 3);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_order_book_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 100), tokenAmount(fixture.maker_base.data[0..]));
    try std.testing.expectEqual(@as(u64, 5), tokenAmount(fixture.taker_base.data[0..]));
}
