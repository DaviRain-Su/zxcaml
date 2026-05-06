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

const ata_transfer_token_program_key_test: Pubkey = .{
    0x06, 0xdd, 0xf6, 0xe1, 0xd7, 0x65, 0xa1, 0x93,
    0xd9, 0xcb, 0xe1, 0x46, 0xce, 0xeb, 0x79, 0xac,
    0x1c, 0xb4, 0x85, 0xed, 0x5f, 0x5b, 0x37, 0x91,
    0x3a, 0x8c, 0xf5, 0x85, 0x7e, 0xff, 0x00, 0xa9,
};

const AtaTransferTestAccount = struct {
    key: Pubkey = [_]u8{0} ** 32,
    owner: Pubkey = [_]u8{0} ** 32,
    lamports: u64 = 0,
    rent_epoch: u64 = 0,
    data: [token_account_len]u8 = [_]u8{0} ** token_account_len,

    fn view(self: *AtaTransferTestAccount, is_signer: bool, is_writable: bool, data_len: usize) account.AccountView {
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

const AtaTransferTestFixture = struct {
    program_id: Pubkey = [_]u8{0x42} ** 32,
    funding: AtaTransferTestAccount = .{ .key = [_]u8{1} ** 32 },
    source: AtaTransferTestAccount = .{ .key = [_]u8{2} ** 32 },
    destination: AtaTransferTestAccount = .{ .key = [_]u8{3} ** 32 },
    authority: AtaTransferTestAccount = .{ .key = [_]u8{4} ** 32 },
    mint: AtaTransferTestAccount = .{ .key = [_]u8{5} ** 32 },
    system: AtaTransferTestAccount = .{ .key = [_]u8{0} ** 32 },
    token: AtaTransferTestAccount = .{ .key = ata_transfer_token_program_key_test },

    fn init(self: *AtaTransferTestFixture) void {
        self.source.owner = self.program_id;
        self.destination.owner = self.program_id;
        writeAtaTransferTokenAccount(&self.source.data, &self.mint.key, &self.authority.key, 40);
        writeAtaTransferTokenAccount(&self.destination.data, &self.mint.key, &self.authority.key, 2);
    }

    fn initializeViews(self: *AtaTransferTestFixture, funding_signer: bool) [6]account.AccountView {
        return .{
            self.funding.view(funding_signer, true, token_account_len),
            self.destination.view(false, true, token_account_len),
            self.authority.view(false, false, token_account_len),
            self.mint.view(false, false, token_account_len),
            self.system.view(false, false, token_account_len),
            self.token.view(false, false, token_account_len),
        };
    }

    fn transferViews(self: *AtaTransferTestFixture, authority_signer: bool) [6]account.AccountView {
        return .{
            self.source.view(false, true, token_account_len),
            self.destination.view(false, true, token_account_len),
            self.authority.view(authority_signer, false, token_account_len),
            self.mint.view(false, false, token_account_len),
            self.system.view(false, false, token_account_len),
            self.token.view(false, false, token_account_len),
        };
    }
};

fn writeAtaTransferProgramInput(out: []u8, program_id: Pubkey) void {
    @memset(out, 0);
    writeU64Le(out[0..8], 0);
    writeU64Le(out[8..16], 0);
    @memcpy(out[16..48], program_id[0..]);
}

fn writeAtaTransferTokenAccount(data: *[token_account_len]u8, mint: *const Pubkey, owner: *const Pubkey, amount: u64) void {
    @memset(data[0..], 0);
    @memcpy(data[token_account_mint_offset..][0..32], mint[0..]);
    @memcpy(data[token_account_owner_offset..][0..32], owner[0..]);
    writeU64Le(data[token_account_amount_offset..][0..8], amount);
    data[token_account_state_offset] = 1;
}

fn writeAtaTransferIx(out: []u8, amount: u64) void {
    out[0] = 0x01;
    writeU64Le(out[1..9], amount);
}

test "ata_transfer initialize writes destination ATA token layout" {
    var arena: Arena = undefined;
    var fixture = AtaTransferTestFixture{};
    fixture.init();
    @memset(fixture.destination.data[0..], 0xaa);
    var views = fixture.initializeViews(true);
    var input: [48]u8 = undefined;
    writeAtaTransferProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 0), zxcaml_ata_transfer_process(&arena, input[0..].ptr, views[0..], &.{0}));
    try std.testing.expectEqualSlices(u8, fixture.mint.key[0..], fixture.destination.data[token_account_mint_offset..][0..32]);
    try std.testing.expectEqualSlices(u8, fixture.authority.key[0..], fixture.destination.data[token_account_owner_offset..][0..32]);
    try std.testing.expectEqual(@as(u64, 0), tokenAmount(fixture.destination.data[0..]));
    try std.testing.expectEqual(@as(u8, 1), fixture.destination.data[token_account_state_offset]);
}

test "ata_transfer transfer moves requested token amount" {
    var arena: Arena = undefined;
    var fixture = AtaTransferTestFixture{};
    fixture.init();
    var views = fixture.transferViews(true);
    var input: [48]u8 = undefined;
    writeAtaTransferProgramInput(input[0..], fixture.program_id);
    var ix: [spl_token.transfer_instruction_data_len]u8 = undefined;
    writeAtaTransferIx(ix[0..], 15);
    try std.testing.expectEqual(@as(u64, 0), zxcaml_ata_transfer_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 25), tokenAmount(fixture.source.data[0..]));
    try std.testing.expectEqual(@as(u64, 17), tokenAmount(fixture.destination.data[0..]));
}

test "ata_transfer initialize rejects destination owner mismatch" {
    var arena: Arena = undefined;
    var fixture = AtaTransferTestFixture{};
    fixture.init();
    fixture.destination.owner = [_]u8{9} ** 32;
    var views = fixture.initializeViews(true);
    var input: [48]u8 = undefined;
    writeAtaTransferProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_ata_transfer_process(&arena, input[0..].ptr, views[0..], &.{0}));
}

test "ata_transfer transfer rejects mismatched token mints" {
    var arena: Arena = undefined;
    var fixture = AtaTransferTestFixture{};
    fixture.init();
    fixture.destination.data[token_account_mint_offset] ^= 0xff;
    var views = fixture.transferViews(true);
    var input: [48]u8 = undefined;
    writeAtaTransferProgramInput(input[0..], fixture.program_id);
    var ix: [spl_token.transfer_instruction_data_len]u8 = undefined;
    writeAtaTransferIx(ix[0..], 15);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_ata_transfer_process(&arena, input[0..].ptr, views[0..], ix[0..]));
}

test "ata_transfer transfer rejects zero amount" {
    var arena: Arena = undefined;
    var fixture = AtaTransferTestFixture{};
    fixture.init();
    var views = fixture.transferViews(true);
    var input: [48]u8 = undefined;
    writeAtaTransferProgramInput(input[0..], fixture.program_id);
    var ix: [spl_token.transfer_instruction_data_len]u8 = undefined;
    writeAtaTransferIx(ix[0..], 0);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_ata_transfer_process(&arena, input[0..].ptr, views[0..], ix[0..]));
}
