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
const syscalls = @import("../syscalls.zig");
const common = @import("common.zig");

const Pubkey = cpi.Pubkey;
const isTokenProgramKey = common.isTokenProgramKey;
const isToken2022ProgramKey = common.isToken2022ProgramKey;
const programIdFromInput = common.programIdFromInput;
const pubkeyEq = common.pubkeyEq;
const readU64LeSlice = common.readU64LeSlice;
const writeU64Le = common.writeU64Le;

const token_account_len: usize = spl_token.token_account_len;
const token_account_mint_offset: usize = 0;
const token_account_owner_offset: usize = 32;
const token_account_amount_offset: usize = 64;
const token_account_state_offset: usize = 108;
const mint_len: usize = spl_token.mint_len;
const mint_supply_offset: usize = 36;

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
    if (isToken2022ProgramKey(token_program.key)) {
        syscalls.sol_log_("Token-2022 unsupported: spl_burn only supports classic Tokenkeg helpers");
        return 1;
    }
    if (!isTokenProgramKey(token_program.key)) return 1;
    if (!tokenAccountInitialized(account_to_burn.data)) return 1;
    if (!tokenAccountOwnerEquals(account_to_burn.data, authority.key)) return 1;
    if (!tokenAccountMintEquals(account_to_burn.data, mint.key)) return 1;
    if (mint.data.len < mint_len) return 1;

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
    const current_supply = mintSupply(mint.data);
    if (current_amount < amount) return 1;
    if (current_supply < amount) return 1;
    writeTokenAmount(account_to_burn.data, current_amount - amount);
    writeMintSupply(mint.data, current_supply - amount);
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

fn mintSupply(data: []const u8) u64 {
    return readU64LeSlice(data[mint_supply_offset..][0..8]);
}

fn writeMintSupply(data: []u8, amount: u64) void {
    writeU64Le(data[mint_supply_offset..][0..8], amount);
}

const SplBurnTestAccount = struct {
    key: Pubkey = [_]u8{0} ** spl_token.pubkey_len,
    owner: Pubkey = [_]u8{0} ** spl_token.pubkey_len,
    lamports: u64 = 0,
    rent_epoch: u64 = 0,
    data: [token_account_len]u8 = [_]u8{0} ** token_account_len,

    fn view(self: *SplBurnTestAccount, is_signer: bool, is_writable: bool, data_len: usize) account.AccountView {
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

const SplBurnTestFixture = struct {
    program_id: Pubkey = [_]u8{0xb0} ** spl_token.pubkey_len,
    account_to_burn: SplBurnTestAccount = .{ .key = [_]u8{1} ** spl_token.pubkey_len },
    mint: SplBurnTestAccount = .{ .key = [_]u8{2} ** spl_token.pubkey_len },
    authority: SplBurnTestAccount = .{ .key = [_]u8{3} ** spl_token.pubkey_len },
    token_program: SplBurnTestAccount = .{ .key = spl_token.program_id },

    fn init(amount: u64) SplBurnTestFixture {
        var fixture = SplBurnTestFixture{};
        fixture.account_to_burn.owner = fixture.program_id;
        writeSplBurnTokenAccount(&fixture.account_to_burn.data, &fixture.mint.key, &fixture.authority.key, amount);
        writeMintSupply(fixture.mint.data[0..], amount + 60);
        return fixture;
    }

    fn views(self: *SplBurnTestFixture, authority_signer: bool) [4]account.AccountView {
        return .{
            self.account_to_burn.view(false, true, token_account_len),
            self.mint.view(false, true, token_account_len),
            self.authority.view(authority_signer, false, token_account_len),
            self.token_program.view(false, false, token_account_len),
        };
    }
};

fn writeSplBurnProgramInput(out: []u8, program_id: Pubkey) void {
    @memset(out, 0);
    writeU64Le(out[0..8], 0);
    writeU64Le(out[8..16], 0);
    @memcpy(out[16..48], program_id[0..]);
}

fn writeSplBurnTokenAccount(data: *[token_account_len]u8, mint: *const Pubkey, owner: *const Pubkey, amount: u64) void {
    @memset(data[0..], 0);
    @memcpy(data[token_account_mint_offset..][0..spl_token.pubkey_len], mint[0..]);
    @memcpy(data[token_account_owner_offset..][0..spl_token.pubkey_len], owner[0..]);
    writeTokenAmount(data[0..], amount);
    data[token_account_state_offset] = 1;
}

test "spl_burn burns requested amount from initialized mocked token account and mint supply" {
    var arena: Arena = undefined;
    var fixture = SplBurnTestFixture.init(40);
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplBurnProgramInput(input[0..], fixture.program_id);
    const ix = spl_token.encodeBurn(15);
    try std.testing.expectEqual(@as(u64, 0), zxcaml_spl_burn_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 25), tokenAmount(fixture.account_to_burn.data[0..]));
    try std.testing.expectEqual(@as(u64, 85), mintSupply(fixture.mint.data[0..]));
}

test "spl_burn rejects uninitialized mocked token account" {
    var arena: Arena = undefined;
    var fixture = SplBurnTestFixture.init(40);
    fixture.account_to_burn.data[token_account_state_offset] = 0;
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplBurnProgramInput(input[0..], fixture.program_id);
    const ix = spl_token.encodeBurn(15);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_spl_burn_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 40), tokenAmount(fixture.account_to_burn.data[0..]));
}

test "spl_burn rejects token account mint mismatch" {
    var arena: Arena = undefined;
    var fixture = SplBurnTestFixture.init(40);
    fixture.account_to_burn.data[token_account_mint_offset] ^= 0xff;
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplBurnProgramInput(input[0..], fixture.program_id);
    const ix = spl_token.encodeBurn(15);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_spl_burn_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 40), tokenAmount(fixture.account_to_burn.data[0..]));
}

test "spl_burn rejects malformed instruction data length" {
    var arena: Arena = undefined;
    var fixture = SplBurnTestFixture.init(40);
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplBurnProgramInput(input[0..], fixture.program_id);
    const ix = spl_token.encodeBurn(15);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_spl_burn_process(&arena, input[0..].ptr, views[0..], ix[0 .. ix.len - 1]));
    try std.testing.expectEqual(@as(u64, 40), tokenAmount(fixture.account_to_burn.data[0..]));
}
