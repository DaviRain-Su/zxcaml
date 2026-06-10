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
const sol_create_program_address = cpi.sol_create_program_address_derive;
const writeU64Le = common.writeU64Le;

const success: u64 = 0;

/// Processes the Colosseum hackathon greeting-counter example.
///
/// The PDA fixture follows this repository's canonical bump-255 convention:
/// tests choose a maker key whose `["greet", maker]` PDA has bump 255, and
/// this helper verifies that bumped address directly instead of relying on
/// `sol_try_find_program_address` in BPF.
fn zxcaml_hackathon_greet_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    if (instruction_data.len != 1) return 1;
    return zxcaml_hackathon_greet_process_with_program_id(arena, programIdFromInput(input), views, instruction_data);
}

pub fn zxcaml_hackathon_greet_process_with_program_id(arena: *Arena, program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len != 1) return 1;

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

const GreetTestPda = struct {
    maker: Pubkey,
    greeting: Pubkey,
};

const GreetTestAccount = struct {
    key: Pubkey = [_]u8{0} ** 32,
    owner: Pubkey = [_]u8{0} ** 32,
    lamports: u64 = 0,
    rent_epoch: u64 = 0,
    data: [hackathon_greet_state_len]u8 = [_]u8{0} ** hackathon_greet_state_len,

    fn view(self: *GreetTestAccount, is_signer: bool, is_writable: bool, data_len: usize) account.AccountView {
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

const GreetTestFixture = struct {
    program_id: Pubkey = [_]u8{21} ** 32,
    greeting: GreetTestAccount = .{ .lamports = 1_000_000 },
    maker: GreetTestAccount = .{ .lamports = 1_000_000 },

    fn init() GreetTestFixture {
        var fixture = GreetTestFixture{};
        const pda = findGreetTestPda(&fixture.program_id);
        fixture.maker.key = pda.maker;
        fixture.greeting.key = pda.greeting;
        fixture.greeting.owner = fixture.program_id;
        return fixture;
    }

    fn views(self: *GreetTestFixture, greeting_writable: bool, maker_signer: bool, data_len: usize) [2]account.AccountView {
        return .{
            self.greeting.view(false, greeting_writable, data_len),
            self.maker.view(maker_signer, false, hackathon_greet_state_len),
        };
    }
};

fn findGreetTestPda(program_id: *const Pubkey) GreetTestPda {
    return findGreetTestPdaSkipping(program_id, null);
}

fn findGreetTestPdaSkipping(program_id: *const Pubkey, skip: ?*const Pubkey) GreetTestPda {
    for (0..256) |byte| {
        const maker: Pubkey = [_]u8{@intCast(byte)} ** 32;
        if (skip) |skip_key| {
            if (std.mem.eql(u8, maker[0..], skip_key[0..])) continue;
        }
        var greet_seed: [5]u8 = .{ 'g', 'r', 'e', 'e', 't' };
        var maker_seed = maker;
        var bump_seed: [1]u8 = .{255};
        var seeds = [_]SolSignerSeed{
            SolSignerSeed.fromSlice(greet_seed[0..]),
            SolSignerSeed.fromSlice(maker_seed[0..]),
            SolSignerSeed.fromSlice(bump_seed[0..]),
        };
        var greeting: Pubkey = undefined;
        if (sol_create_program_address(seeds[0..], program_id, &greeting) == success) {
            return .{ .maker = maker, .greeting = greeting };
        }
    }
    @panic("unable to find bump-255 greet PDA fixture");
}

fn writeGreetProgramInput(input: []u8, program_id: Pubkey) void {
    @memset(input, 0);
    writeU64Le(input[0..8], 0);
    writeU64Le(input[8..16], 0);
    @memcpy(input[16..48], program_id[0..]);
}

test "hackathon_greet initialize zeroes writable PDA state" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    @memset(fixture.greeting.data[0..], 0xaa);
    var views = fixture.views(true, true, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(success, zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{0}));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** hackathon_greet_state_len), fixture.greeting.data[0..]);
}

test "hackathon_greet greet records maker and increments from zero" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    var views = fixture.views(true, true, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(success, zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{1}));
    try std.testing.expectEqualSlices(u8, fixture.maker.key[0..], fixture.greeting.data[hackathon_greet_maker_offset..][0..32]);
    try std.testing.expectEqual(@as(u64, 1), readU64LeSlice(fixture.greeting.data[hackathon_greet_count_offset..][0..8]));
}

test "hackathon_greet greet increments existing maker counter" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    @memcpy(fixture.greeting.data[hackathon_greet_maker_offset..][0..32], fixture.maker.key[0..]);
    writeU64Le(fixture.greeting.data[hackathon_greet_count_offset..][0..8], 1);
    var views = fixture.views(true, true, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(success, zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{1}));
    try std.testing.expectEqual(@as(u64, 2), readU64LeSlice(fixture.greeting.data[hackathon_greet_count_offset..][0..8]));
}

test "hackathon_greet rejects instruction data with invalid length" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    var views = fixture.views(true, true, hackathon_greet_state_len);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_hackathon_greet_process(&arena, undefined, views[0..], &.{ 0, 1 }));
}

test "hackathon_greet rejects unknown instruction discriminator" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    var views = fixture.views(true, true, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{9}));
}

test "hackathon_greet initialize rejects missing maker account" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    var views = fixture.views(true, true, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..1], &.{0}));
}

test "hackathon_greet initialize rejects readonly greeting PDA" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    var views = fixture.views(false, true, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{0}));
}

test "hackathon_greet initialize rejects non-signer maker" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    var views = fixture.views(true, false, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{0}));
}

test "hackathon_greet initialize rejects greeting owner mismatch" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    fixture.greeting.owner = [_]u8{8} ** 32;
    var views = fixture.views(true, true, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{0}));
}

test "hackathon_greet initialize rejects undersized greeting state" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    var views = fixture.views(true, true, hackathon_greet_state_len - 1);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{0}));
}

test "hackathon_greet initialize rejects PDA mismatch" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    fixture.greeting.key = [_]u8{4} ** 32;
    var views = fixture.views(true, true, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{0}));
}

test "hackathon_greet greet rejects different maker after initialization" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    @memcpy(fixture.greeting.data[hackathon_greet_maker_offset..][0..32], fixture.maker.key[0..]);
    writeU64Le(fixture.greeting.data[hackathon_greet_count_offset..][0..8], 1);
    const second = findGreetTestPdaSkipping(&fixture.program_id, &fixture.maker.key);
    fixture.maker.key = second.maker;
    fixture.greeting.key = second.greeting;
    var views = fixture.views(true, true, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{1}));
}

test "hackathon_greet greet rejects counter overflow" {
    var arena: Arena = undefined;
    var fixture = GreetTestFixture.init();
    @memcpy(fixture.greeting.data[hackathon_greet_maker_offset..][0..32], fixture.maker.key[0..]);
    writeU64Le(fixture.greeting.data[hackathon_greet_count_offset..][0..8], std.math.maxInt(u64));
    var views = fixture.views(true, true, hackathon_greet_state_len);
    var input: [48]u8 = undefined;
    writeGreetProgramInput(input[0..], fixture.program_id);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_hackathon_greet_process(&arena, input[0..].ptr, views[0..], &.{1}));
}

test "hackathon_greet PDA derive cross-check uses canonical bump seed" {
    var fixture = GreetTestFixture.init();
    var greet_seed: [5]u8 = .{ 'g', 'r', 'e', 'e', 't' };
    var maker_seed = fixture.maker.key;
    var bump_seed: [1]u8 = .{255};
    var seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(greet_seed[0..]),
        SolSignerSeed.fromSlice(maker_seed[0..]),
        SolSignerSeed.fromSlice(bump_seed[0..]),
    };
    var derived: Pubkey = undefined;
    try std.testing.expectEqual(success, sol_create_program_address(seeds[0..], &fixture.program_id, &derived));
    try std.testing.expectEqualSlices(u8, fixture.greeting.key[0..], derived[0..]);
}
