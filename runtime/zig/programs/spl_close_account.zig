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
fn zxcaml_spl_close_account_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    return zxcaml_spl_close_account_process_with_program_id(arena, programIdFromInput(input), views, instruction_data);
}

pub fn zxcaml_spl_close_account_process_with_program_id(arena: *Arena, program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len != spl_token.close_account_instruction_data_len) return 1;
    if (views.len < 4) return 1;

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

const SplCloseAccountTestAccount = struct {
    key: Pubkey = [_]u8{0} ** spl_token.pubkey_len,
    owner: Pubkey = [_]u8{0} ** spl_token.pubkey_len,
    lamports: u64 = 0,
    rent_epoch: u64 = 0,
    data: [token_account_len]u8 = [_]u8{0} ** token_account_len,

    fn view(self: *SplCloseAccountTestAccount, is_signer: bool, is_writable: bool, data_len: usize) account.AccountView {
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

const SplCloseAccountTestFixture = struct {
    program_id: Pubkey = [_]u8{0xc1} ** spl_token.pubkey_len,
    account_to_close: SplCloseAccountTestAccount = .{
        .key = [_]u8{1} ** spl_token.pubkey_len,
        .lamports = 7,
    },
    destination: SplCloseAccountTestAccount = .{
        .key = [_]u8{2} ** spl_token.pubkey_len,
        .lamports = 11,
    },
    authority: SplCloseAccountTestAccount = .{ .key = [_]u8{3} ** spl_token.pubkey_len },
    token_program: SplCloseAccountTestAccount = .{ .key = spl_token.program_id },

    fn init() SplCloseAccountTestFixture {
        var fixture = SplCloseAccountTestFixture{};
        fixture.account_to_close.owner = fixture.program_id;
        writeSplCloseTokenAccount(&fixture.account_to_close.data, &fixture.authority.key, 0);
        return fixture;
    }

    fn views(self: *SplCloseAccountTestFixture, authority_signer: bool) [4]account.AccountView {
        return .{
            self.account_to_close.view(false, true, token_account_len),
            self.destination.view(false, true, token_account_len),
            self.authority.view(authority_signer, false, token_account_len),
            self.token_program.view(false, false, token_account_len),
        };
    }
};

fn writeSplCloseAccountProgramInput(out: []u8, program_id: Pubkey) void {
    @memset(out, 0);
    writeU64LeForTest(out[0..8], 0);
    writeU64LeForTest(out[8..16], 0);
    @memcpy(out[16..48], program_id[0..]);
}

fn writeSplCloseTokenAccount(data: *[token_account_len]u8, owner: *const Pubkey, amount: u64) void {
    @memset(data[0..], 0);
    @memcpy(data[token_account_owner_offset..][0..spl_token.pubkey_len], owner[0..]);
    writeU64LeForTest(data[token_account_amount_offset..][0..8], amount);
    data[token_account_state_offset] = 1;
}

fn writeU64LeForTest(out: []u8, value: u64) void {
    var remaining = value;
    for (out[0..8]) |*byte| {
        byte.* = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
}

test "spl_close_account transfers lamports and clears mocked token account" {
    var arena: Arena = undefined;
    var fixture = SplCloseAccountTestFixture.init();
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplCloseAccountProgramInput(input[0..], fixture.program_id);
    const ix = spl_token.encodeCloseAccount();
    try std.testing.expectEqual(@as(u64, 0), zxcaml_spl_close_account_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 0), fixture.account_to_close.lamports);
    try std.testing.expectEqual(@as(u64, 18), fixture.destination.lamports);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** token_account_len), fixture.account_to_close.data[0..]);
}

test "spl_close_account rejects authority owner mismatch" {
    var arena: Arena = undefined;
    var fixture = SplCloseAccountTestFixture.init();
    fixture.account_to_close.data[token_account_owner_offset] ^= 0xff;
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplCloseAccountProgramInput(input[0..], fixture.program_id);
    const ix = spl_token.encodeCloseAccount();
    try std.testing.expectEqual(@as(u64, 1), zxcaml_spl_close_account_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 7), fixture.account_to_close.lamports);
    try std.testing.expectEqual(@as(u64, 11), fixture.destination.lamports);
}

test "spl_close_account rejects malformed instruction data length" {
    var arena: Arena = undefined;
    var fixture = SplCloseAccountTestFixture.init();
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplCloseAccountProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_spl_close_account_process(&arena, input[0..].ptr, views[0..], &.{}));
    try std.testing.expectEqual(@as(u64, 7), fixture.account_to_close.lamports);
    try std.testing.expectEqual(@as(u64, 11), fixture.destination.lamports);
}

test "spl_close_account rejects destination lamport overflow" {
    var arena: Arena = undefined;
    var fixture = SplCloseAccountTestFixture.init();
    fixture.account_to_close.lamports = 1;
    fixture.destination.lamports = std.math.maxInt(u64);
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplCloseAccountProgramInput(input[0..], fixture.program_id);
    const ix = spl_token.encodeCloseAccount();
    try std.testing.expectEqual(@as(u64, 1), zxcaml_spl_close_account_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u64, 1), fixture.account_to_close.lamports);
    try std.testing.expectEqual(std.math.maxInt(u64), fixture.destination.lamports);
}
