//! Runtime entrypoint for the dao_voting example.

const std = @import("std");
const Arena = @import("../arena.zig").Arena;
const account = @import("../account.zig");
const cpi = @import("../cpi.zig");
const common = @import("common.zig");

const Pubkey = cpi.Pubkey;
const SolSignerSeed = cpi.SolSignerSeed;
const programIdFromInput = common.programIdFromInput;
const pubkeyEq = common.pubkeyEq;
const readU64LeSlice = common.readU64LeSlice;
const sol_create_program_address = cpi.sol_create_program_address;
const writeU64Le = common.writeU64Le;

const success: u64 = 0;
const proposal_state_len: usize = 56;
const proposal_title_offset: usize = 0;
const proposal_yes_offset: usize = 32;
const proposal_no_offset: usize = 40;
const proposal_deadline_offset: usize = 48;
const vote_record_state_len: usize = 1;

/// Processes the ZxCaml-original DAO yes/no proposal example.
///
/// The PDA fixture follows this repository's canonical bump-255 convention:
/// tests choose a proposal id and voter whose PDAs have bump 255, and this
/// helper verifies the bumped address directly instead of relying on
/// `sol_try_find_program_address` inside BPF.
pub fn zxcaml_dao_voting_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len == 0) return 1;

    const program_id = programIdFromInput(input);
    return switch (instruction_data[0]) {
        0x01 => createProposal(program_id, views, instruction_data),
        0x02 => vote(program_id, views, instruction_data),
        0x03 => closeProposal(program_id, views),
        else => 1,
    };
}

fn createProposal(program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    if (instruction_data.len != 49) return 1;
    if (views.len < 1) return 1;

    const proposal = views[0];
    if (!proposal.is_writable) return 1;
    if (!pubkeyEq(proposal.owner, program_id)) return 1;
    if (proposal.data.len < proposal_state_len) return 1;

    var proposal_id_seed: [8]u8 = undefined;
    @memcpy(proposal_id_seed[0..], instruction_data[1..9]);
    if (!proposalPdaMatches(proposal.key, &proposal_id_seed, program_id)) return 1;

    @memcpy(proposal.data[proposal_title_offset..][0..32], instruction_data[17..49]);
    writeU64Le(proposal.data[proposal_yes_offset..][0..8], 0);
    writeU64Le(proposal.data[proposal_no_offset..][0..8], 0);
    @memcpy(proposal.data[proposal_deadline_offset..][0..8], instruction_data[9..17]);
    return 0;
}

fn vote(program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    if (instruction_data.len != 2) return 1;
    if (views.len < 3) return 1;

    const proposal = views[0];
    const vote_record = views[1];
    const voter = views[2];
    if (!proposal.is_writable) return 1;
    if (!vote_record.is_writable) return 1;
    if (!voter.is_signer) return 1;
    if (!pubkeyEq(proposal.owner, program_id)) return 1;
    if (!pubkeyEq(vote_record.owner, program_id)) return 1;
    if (proposal.data.len < proposal_state_len) return 1;
    if (vote_record.data.len < vote_record_state_len) return 1;
    if (!voteRecordPdaMatches(vote_record.key, proposal.key, voter.key, program_id)) return 1;

    // VoteRecord existence guard: this program-owned fixture treats voted=1 as
    // the initialized VoteRecord state. A second vote observes that state and
    // returns an error before touching proposal counters.
    if (vote_record.data[0] != 0) return 1;

    const yes_flag = instruction_data[1];
    if (yes_flag == 1) {
        const yes = readU64LeSlice(proposal.data[proposal_yes_offset..][0..8]);
        const next_yes = std.math.add(u64, yes, 1) catch return 1;
        writeU64Le(proposal.data[proposal_yes_offset..][0..8], next_yes);
    } else if (yes_flag == 0) {
        const no = readU64LeSlice(proposal.data[proposal_no_offset..][0..8]);
        const next_no = std.math.add(u64, no, 1) catch return 1;
        writeU64Le(proposal.data[proposal_no_offset..][0..8], next_no);
    } else {
        return 1;
    }

    vote_record.data[0] = 1;
    return 0;
}

fn closeProposal(program_id: *const Pubkey, views: []account.AccountView) u64 {
    if (views.len < 1) return 1;

    const proposal = views[0];
    if (!proposal.is_writable) return 1;
    if (!pubkeyEq(proposal.owner, program_id)) return 1;
    if (proposal.data.len < proposal_state_len) return 1;

    @memset(proposal.data[0..proposal_state_len], 0);
    return 0;
}

fn proposalPdaMatches(proposal_key: *const Pubkey, proposal_id_seed: *const [8]u8, program_id: *const Pubkey) bool {
    var proposal_seed: [8]u8 = .{ 'p', 'r', 'o', 'p', 'o', 's', 'a', 'l' };
    var id_seed = proposal_id_seed.*;
    var bump_seed: [1]u8 = .{255};
    var seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(proposal_seed[0..]),
        SolSignerSeed.fromSlice(id_seed[0..]),
        SolSignerSeed.fromSlice(bump_seed[0..]),
    };
    var expected: Pubkey = undefined;
    if (sol_create_program_address(seeds[0..], program_id, &expected) != success) return false;
    return pubkeyEq(proposal_key, &expected);
}

fn voteRecordPdaMatches(vote_record_key: *const Pubkey, proposal_key: *const Pubkey, voter_key: *const Pubkey, program_id: *const Pubkey) bool {
    var vote_seed: [4]u8 = .{ 'v', 'o', 't', 'e' };
    var proposal_seed = proposal_key.*;
    var voter_seed = voter_key.*;
    var bump_seed: [1]u8 = .{255};
    var seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(vote_seed[0..]),
        SolSignerSeed.fromSlice(proposal_seed[0..]),
        SolSignerSeed.fromSlice(voter_seed[0..]),
        SolSignerSeed.fromSlice(bump_seed[0..]),
    };
    var expected: Pubkey = undefined;
    if (sol_create_program_address(seeds[0..], program_id, &expected) != success) return false;
    return pubkeyEq(vote_record_key, &expected);
}

const DaoProposalPda = struct {
    proposal_id: [8]u8,
    proposal: Pubkey,
};

const DaoVotePda = struct {
    voter: Pubkey,
    vote_record: Pubkey,
};

const DaoVotingTestAccount = struct {
    key: Pubkey = [_]u8{0} ** 32,
    owner: Pubkey = [_]u8{0} ** 32,
    lamports: u64 = 0,
    rent_epoch: u64 = 0,
    data: [proposal_state_len]u8 = [_]u8{0} ** proposal_state_len,

    fn view(self: *DaoVotingTestAccount, is_signer: bool, is_writable: bool, data_len: usize) account.AccountView {
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

const DaoVotingTestFixture = struct {
    program_id: Pubkey = [_]u8{31} ** 32,
    proposal_id: [8]u8 = [_]u8{0} ** 8,
    proposal: DaoVotingTestAccount = .{ .lamports = 1_000 },
    vote_record: DaoVotingTestAccount = .{ .lamports = 1_000 },
    voter: DaoVotingTestAccount = .{ .lamports = 1_000 },

    fn init() DaoVotingTestFixture {
        var fixture = DaoVotingTestFixture{};
        const proposal_pda = findDaoProposalPda(&fixture.program_id);
        fixture.proposal_id = proposal_pda.proposal_id;
        fixture.proposal.key = proposal_pda.proposal;
        fixture.proposal.owner = fixture.program_id;
        const vote_pda = findDaoVotePda(&fixture.proposal.key, &fixture.program_id);
        fixture.voter.key = vote_pda.voter;
        fixture.vote_record.key = vote_pda.vote_record;
        fixture.vote_record.owner = fixture.program_id;
        return fixture;
    }

    fn createViews(self: *DaoVotingTestFixture, proposal_writable: bool, data_len: usize) [1]account.AccountView {
        return .{self.proposal.view(false, proposal_writable, data_len)};
    }

    fn voteViews(self: *DaoVotingTestFixture, vote_record_writable: bool, voter_signer: bool) [3]account.AccountView {
        return .{
            self.proposal.view(false, true, proposal_state_len),
            self.vote_record.view(false, vote_record_writable, vote_record_state_len),
            self.voter.view(voter_signer, false, proposal_state_len),
        };
    }

    fn closeViews(self: *DaoVotingTestFixture, proposal_writable: bool) [1]account.AccountView {
        return .{self.proposal.view(false, proposal_writable, proposal_state_len)};
    }
};

fn findDaoProposalPda(program_id: *const Pubkey) DaoProposalPda {
    for (0..256) |byte| {
        const proposal_id: [8]u8 = [_]u8{@intCast(byte)} ** 8;
        var proposal_seed: [8]u8 = .{ 'p', 'r', 'o', 'p', 'o', 's', 'a', 'l' };
        var id_seed = proposal_id;
        var bump_seed: [1]u8 = .{255};
        var seeds = [_]SolSignerSeed{
            SolSignerSeed.fromSlice(proposal_seed[0..]),
            SolSignerSeed.fromSlice(id_seed[0..]),
            SolSignerSeed.fromSlice(bump_seed[0..]),
        };
        var proposal: Pubkey = undefined;
        if (sol_create_program_address(seeds[0..], program_id, &proposal) == success) {
            return .{ .proposal_id = proposal_id, .proposal = proposal };
        }
    }
    @panic("unable to find bump-255 dao proposal PDA fixture");
}

fn findDaoVotePda(proposal_key: *const Pubkey, program_id: *const Pubkey) DaoVotePda {
    for (0..256) |byte| {
        const voter: Pubkey = [_]u8{@intCast(byte)} ** 32;
        var vote_seed: [4]u8 = .{ 'v', 'o', 't', 'e' };
        var proposal_seed = proposal_key.*;
        var voter_seed = voter;
        var bump_seed: [1]u8 = .{255};
        var seeds = [_]SolSignerSeed{
            SolSignerSeed.fromSlice(vote_seed[0..]),
            SolSignerSeed.fromSlice(proposal_seed[0..]),
            SolSignerSeed.fromSlice(voter_seed[0..]),
            SolSignerSeed.fromSlice(bump_seed[0..]),
        };
        var vote_record: Pubkey = undefined;
        if (sol_create_program_address(seeds[0..], program_id, &vote_record) == success) {
            return .{ .voter = voter, .vote_record = vote_record };
        }
    }
    @panic("unable to find bump-255 dao vote-record PDA fixture");
}

fn writeDaoProgramInput(input: []u8, program_id: Pubkey) void {
    @memset(input, 0);
    writeU64Le(input[0..8], 0);
    writeU64Le(input[8..16], 0);
    @memcpy(input[16..48], program_id[0..]);
}

fn writeDaoCreateIx(out: []u8, proposal_id: [8]u8, deadline: u64, title: *const [32]u8) void {
    out[0] = 0x01;
    @memcpy(out[1..9], proposal_id[0..]);
    writeU64Le(out[9..17], deadline);
    @memcpy(out[17..49], title[0..]);
}

test "dao_voting create writes proposal title counters and deadline" {
    var arena: Arena = undefined;
    var fixture = DaoVotingTestFixture.init();
    @memset(fixture.proposal.data[0..], 0xaa);
    var views = fixture.createViews(true, proposal_state_len);
    var input: [48]u8 = undefined;
    writeDaoProgramInput(input[0..], fixture.program_id);
    const title: [32]u8 = "proposal title bytes fixture!!!!".*;
    var ix: [49]u8 = undefined;
    writeDaoCreateIx(ix[0..], fixture.proposal_id, 123_456, &title);
    try std.testing.expectEqual(success, zxcaml_dao_voting_process(&arena, input[0..].ptr, views[0..], ix[0..]));
    try std.testing.expectEqualSlices(u8, title[0..], fixture.proposal.data[proposal_title_offset..][0..32]);
    try std.testing.expectEqual(@as(u64, 0), readU64LeSlice(fixture.proposal.data[proposal_yes_offset..][0..8]));
    try std.testing.expectEqual(@as(u64, 0), readU64LeSlice(fixture.proposal.data[proposal_no_offset..][0..8]));
    try std.testing.expectEqual(@as(u64, 123_456), readU64LeSlice(fixture.proposal.data[proposal_deadline_offset..][0..8]));
}

test "dao_voting vote yes increments yes counter and records vote" {
    var arena: Arena = undefined;
    var fixture = DaoVotingTestFixture.init();
    var views = fixture.voteViews(true, true);
    var input: [48]u8 = undefined;
    writeDaoProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(success, zxcaml_dao_voting_process(&arena, input[0..].ptr, views[0..], &.{ 0x02, 1 }));
    try std.testing.expectEqual(@as(u64, 1), readU64LeSlice(fixture.proposal.data[proposal_yes_offset..][0..8]));
    try std.testing.expectEqual(@as(u64, 0), readU64LeSlice(fixture.proposal.data[proposal_no_offset..][0..8]));
    try std.testing.expectEqual(@as(u8, 1), fixture.vote_record.data[0]);
}

test "dao_voting vote no increments no counter and records vote" {
    var arena: Arena = undefined;
    var fixture = DaoVotingTestFixture.init();
    var views = fixture.voteViews(true, true);
    var input: [48]u8 = undefined;
    writeDaoProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(success, zxcaml_dao_voting_process(&arena, input[0..].ptr, views[0..], &.{ 0x02, 0 }));
    try std.testing.expectEqual(@as(u64, 0), readU64LeSlice(fixture.proposal.data[proposal_yes_offset..][0..8]));
    try std.testing.expectEqual(@as(u64, 1), readU64LeSlice(fixture.proposal.data[proposal_no_offset..][0..8]));
    try std.testing.expectEqual(@as(u8, 1), fixture.vote_record.data[0]);
}

test "dao_voting close zeroes proposal state" {
    var arena: Arena = undefined;
    var fixture = DaoVotingTestFixture.init();
    @memset(fixture.proposal.data[0..], 0xbb);
    var views = fixture.closeViews(true);
    var input: [48]u8 = undefined;
    writeDaoProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(success, zxcaml_dao_voting_process(&arena, input[0..].ptr, views[0..], &.{0x03}));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** proposal_state_len), fixture.proposal.data[0..]);
}

test "dao_voting rejects double vote without changing counters" {
    var arena: Arena = undefined;
    var fixture = DaoVotingTestFixture.init();
    fixture.vote_record.data[0] = 1;
    writeU64Le(fixture.proposal.data[proposal_yes_offset..][0..8], 7);
    var views = fixture.voteViews(true, true);
    var input: [48]u8 = undefined;
    writeDaoProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_dao_voting_process(&arena, input[0..].ptr, views[0..], &.{ 0x02, 1 }));
    try std.testing.expectEqual(@as(u64, 7), readU64LeSlice(fixture.proposal.data[proposal_yes_offset..][0..8]));
}

test "dao_voting rejects invalid yes flag" {
    var arena: Arena = undefined;
    var fixture = DaoVotingTestFixture.init();
    var views = fixture.voteViews(true, true);
    var input: [48]u8 = undefined;
    writeDaoProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_dao_voting_process(&arena, input[0..].ptr, views[0..], &.{ 0x02, 2 }));
    try std.testing.expectEqual(@as(u64, 0), readU64LeSlice(fixture.proposal.data[proposal_yes_offset..][0..8]));
    try std.testing.expectEqual(@as(u64, 0), readU64LeSlice(fixture.proposal.data[proposal_no_offset..][0..8]));
    try std.testing.expectEqual(@as(u8, 0), fixture.vote_record.data[0]);
}

test "dao_voting create rejects proposal PDA mismatch" {
    var arena: Arena = undefined;
    var fixture = DaoVotingTestFixture.init();
    fixture.proposal.key = [_]u8{9} ** 32;
    var views = fixture.createViews(true, proposal_state_len);
    var input: [48]u8 = undefined;
    writeDaoProgramInput(input[0..], fixture.program_id);
    const title: [32]u8 = [_]u8{0x34} ** 32;
    var ix: [49]u8 = undefined;
    writeDaoCreateIx(ix[0..], fixture.proposal_id, 123_456, &title);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_dao_voting_process(&arena, input[0..].ptr, views[0..], ix[0..]));
}
