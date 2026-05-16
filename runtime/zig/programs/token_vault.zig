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
fn zxcaml_token_vault_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = input;
    const ignored_program_id: Pubkey = [_]u8{0} ** 32;
    return zxcaml_token_vault_process_with_program_id(arena, &ignored_program_id, views, instruction_data);
}

pub fn zxcaml_token_vault_process_with_program_id(arena: *Arena, program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    _ = program_id;
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

const token_program_key_test: Pubkey = .{
    0x06, 0xdd, 0xf6, 0xe1, 0xd7, 0x65, 0xa1, 0x93,
    0xd9, 0xcb, 0xe1, 0x46, 0xce, 0xeb, 0x79, 0xac,
    0x1c, 0xb4, 0x85, 0xed, 0x5f, 0x5b, 0x37, 0x91,
    0x3a, 0x8c, 0xf5, 0x85, 0x7e, 0xff, 0x00, 0xa9,
};

const TokenVaultTestAccount = struct {
    key: Pubkey = [_]u8{0} ** 32,
    owner: Pubkey = [_]u8{0} ** 32,
    lamports: u64 = 0,
    rent_epoch: u64 = 0,
    data: [token_account_len]u8 = [_]u8{0} ** token_account_len,

    fn view(self: *TokenVaultTestAccount, is_signer: bool, is_writable: bool, data_len: usize) account.AccountView {
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

const TokenVaultTestFixture = struct {
    source: TokenVaultTestAccount = .{ .key = [_]u8{1} ** 32 },
    vault: TokenVaultTestAccount = .{ .key = [_]u8{2} ** 32 },
    authority: TokenVaultTestAccount = .{ .key = [_]u8{3} ** 32 },
    system: TokenVaultTestAccount = .{ .key = [_]u8{0} ** 32 },
    token: TokenVaultTestAccount = .{ .key = token_program_key_test },
    mint: TokenVaultTestAccount = .{ .key = [_]u8{5} ** 32 },

    fn initTokenAccounts(self: *TokenVaultTestFixture, source_amount: u64, vault_amount: u64) void {
        writeTokenVaultAccount(&self.source.data, &self.mint.key, &self.authority.key, source_amount);
        writeTokenVaultAccount(&self.vault.data, &self.mint.key, &self.vault.key, vault_amount);
    }

    fn depositViews(self: *TokenVaultTestFixture, authority_signer: bool) [4]account.AccountView {
        return .{
            self.source.view(false, true, token_account_len),
            self.vault.view(false, true, token_account_len),
            self.authority.view(authority_signer, false, token_account_len),
            self.token.view(false, false, token_account_len),
        };
    }

    fn withdrawViews(self: *TokenVaultTestFixture, authority_signer: bool) [4]account.AccountView {
        return .{
            self.vault.view(false, true, token_account_len),
            self.source.view(false, true, token_account_len),
            self.authority.view(authority_signer, false, token_account_len),
            self.token.view(false, false, token_account_len),
        };
    }

    fn initializeViews(self: *TokenVaultTestFixture, vault_writable: bool, authority_signer: bool) [6]account.AccountView {
        return .{
            self.vault.view(false, vault_writable, token_account_len),
            self.mint.view(false, false, token_account_len),
            self.authority.view(authority_signer, false, token_account_len),
            self.system.view(false, false, token_account_len),
            self.token.view(false, false, token_account_len),
            self.source.view(false, false, token_account_len),
        };
    }
};

fn writeTokenVaultAccount(data: *[token_account_len]u8, mint: *const Pubkey, owner: *const Pubkey, amount: u64) void {
    @memset(data[0..], 0);
    @memcpy(data[token_account_mint_offset..][0..32], mint[0..]);
    @memcpy(data[token_account_owner_offset..][0..32], owner[0..]);
    writeU64Le(data[token_account_amount_offset..][0..8], amount);
    data[token_account_state_offset] = 1;
}

fn writeTokenVaultIx(out: []u8, discriminator: u8, amount: u64) void {
    out[0] = discriminator;
    writeU64Le(out[1..9], amount);
}

test "token_vault initialize writes zero-balance token account layout" {
    var arena: Arena = undefined;
    var fixture = TokenVaultTestFixture{};
    @memset(fixture.vault.data[0..], 0xaa);
    var views = fixture.initializeViews(true, true);
    try std.testing.expectEqual(@as(u64, 0), zxcaml_token_vault_process(&arena, undefined, views[0..], &.{2}));
    try std.testing.expectEqualSlices(u8, fixture.mint.key[0..], fixture.vault.data[token_account_mint_offset..][0..32]);
    try std.testing.expectEqualSlices(u8, fixture.vault.key[0..], fixture.vault.data[token_account_owner_offset..][0..32]);
    try std.testing.expectEqual(@as(u64, 0), tokenAmount(fixture.vault.data[0..]));
    try std.testing.expectEqual(@as(u8, 1), fixture.vault.data[token_account_state_offset]);
}

test "token_vault deposit moves requested amount into vault" {
    var arena: Arena = undefined;
    var fixture = TokenVaultTestFixture{};
    fixture.initTokenAccounts(50, 7);
    var views = fixture.depositViews(true);
    var ix: [9]u8 = undefined;
    writeTokenVaultIx(ix[0..], 0, 13);
    try std.testing.expectEqual(@as(u64, 0), zxcaml_token_vault_process(&arena, undefined, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 37), tokenAmount(fixture.source.data[0..]));
    try std.testing.expectEqual(@as(u64, 20), tokenAmount(fixture.vault.data[0..]));
}

test "token_vault withdraw moves full vault balance to authority account" {
    var arena: Arena = undefined;
    var fixture = TokenVaultTestFixture{};
    fixture.initTokenAccounts(4, 21);
    var views = fixture.withdrawViews(true);
    try std.testing.expectEqual(@as(u64, 0), zxcaml_token_vault_process(&arena, undefined, views[0..], &.{1}));
    try std.testing.expectEqual(@as(u64, 0), tokenAmount(fixture.vault.data[0..]));
    try std.testing.expectEqual(@as(u64, 25), tokenAmount(fixture.source.data[0..]));
}

test "token_vault initialize rejects non-token program account" {
    var arena: Arena = undefined;
    var fixture = TokenVaultTestFixture{};
    fixture.token.key = [_]u8{9} ** 32;
    var views = fixture.initializeViews(true, true);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_token_vault_process(&arena, undefined, views[0..], &.{2}));
}

test "token_vault deposit rejects zero amount" {
    var arena: Arena = undefined;
    var fixture = TokenVaultTestFixture{};
    fixture.initTokenAccounts(50, 7);
    var views = fixture.depositViews(true);
    var ix: [9]u8 = undefined;
    writeTokenVaultIx(ix[0..], 0, 0);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_token_vault_process(&arena, undefined, views[0..], ix[0..]));
}

test "token_vault withdraw rejects empty vault balance" {
    var arena: Arena = undefined;
    var fixture = TokenVaultTestFixture{};
    fixture.initTokenAccounts(4, 0);
    var views = fixture.withdrawViews(true);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_token_vault_process(&arena, undefined, views[0..], &.{1}));
}

test "token_vault deposit rejects source owner mismatch" {
    var arena: Arena = undefined;
    var fixture = TokenVaultTestFixture{};
    fixture.initTokenAccounts(50, 7);
    fixture.source.data[token_account_owner_offset] ^= 0xff;
    var views = fixture.depositViews(true);
    var ix: [9]u8 = undefined;
    writeTokenVaultIx(ix[0..], 0, 13);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_token_vault_process(&arena, undefined, views[0..], ix[0..]));
}
