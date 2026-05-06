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

const SplRevokeTestAccount = struct {
    key: Pubkey = [_]u8{0} ** spl_token.pubkey_len,
    owner: Pubkey = [_]u8{0} ** spl_token.pubkey_len,
    lamports: u64 = 0,
    rent_epoch: u64 = 0,
    data: [token_account_len]u8 = [_]u8{0} ** token_account_len,

    fn view(self: *SplRevokeTestAccount, is_signer: bool, is_writable: bool, data_len: usize) account.AccountView {
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

const SplRevokeTestFixture = struct {
    program_id: Pubkey = [_]u8{0xd2} ** spl_token.pubkey_len,
    source: SplRevokeTestAccount = .{ .key = [_]u8{1} ** spl_token.pubkey_len },
    authority: SplRevokeTestAccount = .{ .key = [_]u8{2} ** spl_token.pubkey_len },
    token_program: SplRevokeTestAccount = .{ .key = spl_token.program_id },

    fn init() SplRevokeTestFixture {
        var fixture = SplRevokeTestFixture{};
        fixture.source.owner = fixture.program_id;
        writeSplRevokeTokenAccount(&fixture.source.data, &fixture.authority.key);
        return fixture;
    }

    fn views(self: *SplRevokeTestFixture, authority_signer: bool) [3]account.AccountView {
        return .{
            self.source.view(false, true, token_account_len),
            self.authority.view(authority_signer, false, token_account_len),
            self.token_program.view(false, false, token_account_len),
        };
    }
};

fn writeSplRevokeProgramInput(out: []u8, program_id: Pubkey) void {
    @memset(out, 0);
    writeU64LeForTest(out[0..8], 0);
    writeU64LeForTest(out[8..16], 0);
    @memcpy(out[16..48], program_id[0..]);
}

fn writeSplRevokeTokenAccount(data: *[token_account_len]u8, owner: *const Pubkey) void {
    @memset(data[0..], 0);
    @memcpy(data[token_account_owner_offset..][0..spl_token.pubkey_len], owner[0..]);
    data[token_account_state_offset] = 1;
    data[delegate_option_offset] = 1;
    @memset(data[delegate_offset..delegate_region_end], 0x44);
    writeU64LeForTest(data[delegated_amount_offset..][0..8], 99);
}

fn writeU64LeForTest(out: []u8, value: u64) void {
    var remaining = value;
    for (out[0..8]) |*byte| {
        byte.* = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
}

test "spl_revoke clears delegate state on initialized mocked token account" {
    var arena: Arena = undefined;
    var fixture = SplRevokeTestFixture.init();
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplRevokeProgramInput(input[0..], fixture.program_id);
    const ix = spl_token.encodeRevoke();
    try std.testing.expectEqual(@as(u64, 0), zxcaml_spl_revoke_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** (delegate_region_end - delegate_option_offset)), fixture.source.data[delegate_option_offset..delegate_region_end]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** (delegated_amount_end - delegated_amount_offset)), fixture.source.data[delegated_amount_offset..delegated_amount_end]);
}

test "spl_revoke rejects uninitialized mocked token account" {
    var arena: Arena = undefined;
    var fixture = SplRevokeTestFixture.init();
    fixture.source.data[token_account_state_offset] = 0;
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplRevokeProgramInput(input[0..], fixture.program_id);
    const ix = spl_token.encodeRevoke();
    try std.testing.expectEqual(@as(u64, 1), zxcaml_spl_revoke_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u8, 1), fixture.source.data[delegate_option_offset]);
}

test "spl_revoke rejects malformed instruction data length" {
    var arena: Arena = undefined;
    var fixture = SplRevokeTestFixture.init();
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplRevokeProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_spl_revoke_process(&arena, input[0..].ptr, views[0..], &.{}));
    try std.testing.expectEqual(@as(u8, 1), fixture.source.data[delegate_option_offset]);
}

test "spl_revoke rejects token account owner mismatch" {
    var arena: Arena = undefined;
    var fixture = SplRevokeTestFixture.init();
    fixture.source.data[token_account_owner_offset] ^= 0xff;
    var views = fixture.views(true);
    var input: [48]u8 = undefined;
    writeSplRevokeProgramInput(input[0..], fixture.program_id);
    const ix = spl_token.encodeRevoke();
    try std.testing.expectEqual(@as(u64, 1), zxcaml_spl_revoke_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqual(@as(u8, 1), fixture.source.data[delegate_option_offset]);
}
