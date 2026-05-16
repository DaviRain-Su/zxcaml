//! Runtime helper for the final cross-flow Surfpool validation program.

const std = @import("std");
const Arena = @import("../arena.zig").Arena;
const account = @import("../account.zig");
const cpi = @import("../cpi.zig");
const common = @import("common.zig");

const Pubkey = cpi.Pubkey;
const SolAccountMeta = cpi.SolAccountMeta;
const SolInstruction = cpi.SolInstruction;
const SolAccountInfo = cpi.SolAccountInfo;
const SolSignerSeed = cpi.SolSignerSeed;
const accountInfoFromView = cpi.accountInfoFromView;
const invoke = cpi.invoke;
const sol_try_find_program_address = cpi.sol_try_find_program_address;
const pubkeyEq = common.pubkeyEq;
const readU64LeSlice = common.readU64LeSlice;
const writeSystemTransferData = common.writeSystemTransferData;
const writeU64Le = common.writeU64Le;

const success: u64 = 0;
const state_len: usize = 40;
const maker_offset: usize = 0;
const count_offset: usize = 32;

pub fn zxcaml_combined_process_with_program_id(
    arena: *Arena,
    program_id: *const Pubkey,
    views: []account.AccountView,
    instruction_data: []const u8,
) u64 {
    _ = arena;
    if (views.len < 7) return 1;
    if (instruction_data.len != 1 or instruction_data[0] != 1) return 1;

    const greeting = views[3];
    const owner = views[4];
    const recipient = views[5];
    const system_program = views[6];

    if (!greeting.is_writable) return 1;
    if (!owner.is_signer or !owner.is_writable) return 1;
    if (!recipient.is_writable) return 1;
    if (!pubkeyEq(greeting.owner, program_id)) return 1;

    const system_program_id: Pubkey = [_]u8{0} ** 32;
    if (!pubkeyEq(system_program.key, &system_program_id)) return 1;
    if (greeting.data.len < state_len) return 1;

    const derived = deriveGreetingPda(owner.key, program_id) orelse return 1;
    if (!pubkeyEq(greeting.key, &derived)) return 1;

    const current = readU64LeSlice(greeting.data[count_offset..][0..8]);
    if (current == 0) {
        @memcpy(greeting.data[maker_offset..][0..32], owner.key[0..]);
    } else if (!std.mem.eql(u8, greeting.data[maker_offset..][0..32], owner.key[0..])) {
        return 1;
    }
    writeU64Le(greeting.data[count_offset..][0..8], std.math.add(u64, current, 1) catch return 1);

    var data: [12]u8 = undefined;
    writeSystemTransferData(data[0..], 1);

    var callee_program_id = system_program.key.*;
    var metas = [_]SolAccountMeta{
        .{ .pubkey = owner.key, .is_writable = 1, .is_signer = 1 },
        .{ .pubkey = recipient.key, .is_writable = 1, .is_signer = 0 },
    };
    const instruction = SolInstruction.fromSlices(&callee_program_id, metas[0..], data[0..]);
    var infos = [_]SolAccountInfo{
        accountInfoFromView(owner),
        accountInfoFromView(recipient),
    };
    return invoke(&instruction, infos[0..]);
}

fn deriveGreetingPda(owner_key: *const Pubkey, program_id: *const Pubkey) ?Pubkey {
    var greet_seed: [5]u8 = .{ 'g', 'r', 'e', 'e', 't' };
    const seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(greet_seed[0..]),
        SolSignerSeed.fromSlice(owner_key[0..]),
    };
    var address: Pubkey = undefined;
    var bump: u8 = 0;
    if (sol_try_find_program_address(seeds[0..], program_id, &address, &bump) != success) return null;
    return address;
}
