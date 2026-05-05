//! Runtime entrypoint for the hackathon_greet example.

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

/// Processes the Colosseum hackathon greeting-counter example.
///
/// The PDA fixture follows this repository's canonical bump-255 convention:
/// tests choose a maker key whose `["greet", maker]` PDA has bump 255, and
/// this helper verifies that bumped address directly instead of relying on
/// `sol_try_find_program_address` in BPF.
pub fn zxcaml_hackathon_greet_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len != 1) return 1;

    const program_id = programIdFromInput(input);
    return switch (instruction_data[0]) {
        0 => zxcamlHackathonGreetInitialize(program_id, views),
        1 => zxcamlHackathonGreet(program_id, views),
        else => 1,
    };
}

const hackathon_greet_state_len: usize = 40;
const hackathon_greet_maker_offset: usize = 0;
const hackathon_greet_count_offset: usize = 32;

fn zxcamlHackathonGreetInitialize(program_id: *const Pubkey, views: []account.AccountView) u64 {
    if (!hackathonGreetAccountsAreValid(program_id, views)) return 1;

    @memset(views[0].data[0..hackathon_greet_state_len], 0);
    return 0;
}

fn zxcamlHackathonGreet(program_id: *const Pubkey, views: []account.AccountView) u64 {
    if (!hackathonGreetAccountsAreValid(program_id, views)) return 1;

    const greeting = views[0];
    const maker = views[1];
    const current = readU64LeSlice(greeting.data[hackathon_greet_count_offset..][0..8]);
    if (current == 0) {
        @memcpy(greeting.data[hackathon_greet_maker_offset..][0..32], maker.key[0..]);
    } else if (!std.mem.eql(u8, greeting.data[hackathon_greet_maker_offset..][0..32], maker.key[0..])) {
        return 1;
    }

    const next = std.math.add(u64, current, 1) catch return 1;
    writeU64Le(greeting.data[hackathon_greet_count_offset..][0..8], next);
    return 0;
}

fn hackathonGreetAccountsAreValid(program_id: *const Pubkey, views: []account.AccountView) bool {
    if (views.len < 2) return false;

    const greeting = views[0];
    const maker = views[1];
    if (!greeting.is_writable) return false;
    if (!maker.is_signer) return false;
    if (!pubkeyEq(greeting.owner, program_id)) return false;
    if (greeting.data.len < hackathon_greet_state_len) return false;
    if (!hackathonGreetPdaMatches(greeting.key, maker.key, program_id)) return false;
    return true;
}

fn hackathonGreetPdaMatches(greeting_key: *const Pubkey, maker_key: *const Pubkey, program_id: *const Pubkey) bool {
    var greet_seed: [5]u8 = .{ 'g', 'r', 'e', 'e', 't' };
    var maker_seed = maker_key.*;
    var bump_seed: [1]u8 = .{255};
    var seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(greet_seed[0..]),
        SolSignerSeed.fromSlice(maker_seed[0..]),
        SolSignerSeed.fromSlice(bump_seed[0..]),
    };
    var expected: Pubkey = undefined;
    if (sol_create_program_address(seeds[0..], program_id, &expected) != success) return false;
    return pubkeyEq(greeting_key, &expected);
}
