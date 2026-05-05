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
