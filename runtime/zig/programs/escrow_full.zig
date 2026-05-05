//! Runtime entrypoint for the escrow_full example.

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
const isSystemProgramKey = common.isSystemProgramKey;
const isZeroPubkeyBytes = common.isZeroPubkeyBytes;
const programIdFromInput = common.programIdFromInput;
const pubkeyEq = common.pubkeyEq;
const readU64LeSlice = common.readU64LeSlice;
const sol_create_program_address = cpi.sol_create_program_address;
const writeSystemTransferData = common.writeSystemTransferData;
const writeU64Le = common.writeU64Le;

const success: u64 = 0;

/// Processes the zignocchio-compatible escrow make/accept/refund dispatch.
///
/// zignocchio's source creates the escrow PDA with a System Program CPI. The
/// current Mollusk fixture preallocates that canonical bump-255 PDA as a
/// program-owned account so this helper can mutate lamports and the state bytes
/// directly, matching the established mocked-account pattern used by the
/// token_vault tests.
pub fn zxcaml_escrow_full_process(arena: *Arena, input: [*]const u8, views: []account.AccountView, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len == 0) return 1;

    const program_id = programIdFromInput(input);
    return switch (instruction_data[0]) {
        0 => zxcamlEscrowMake(program_id, views, instruction_data),
        1 => zxcamlEscrowAccept(program_id, views),
        2 => zxcamlEscrowRefund(program_id, views),
        else => 1,
    };
}

const escrow_state_len: usize = 80;
const escrow_discriminator: u8 = 0xe5;
const escrow_taker_offset: usize = 33;
const escrow_amount_offset: usize = 72;
const escrow_rent_lamports: u64 = 6960;

fn zxcamlEscrowMake(program_id: *const Pubkey, views: []account.AccountView, instruction_data: []const u8) u64 {
    if (views.len < 3) return 1;
    if (instruction_data.len != 41) return 1;

    const maker = views[0];
    const escrow = views[1];
    const system_program = views[2];
    if (!maker.is_signer or !maker.is_writable) return 1;
    if (!escrow.is_writable) return 1;
    if (!isSystemProgramKey(system_program.key)) return 1;
    if (!pubkeyEq(escrow.owner, program_id)) return 1;
    if (!escrowPdaMatches(escrow.key, maker.key, program_id)) return 1;
    if (escrow.lamportsValue() != 0) return 1;
    if (escrow.data.len < escrow_state_len) return 1;

    const amount = readU64LeSlice(instruction_data[33..41]);
    if (amount == 0) return 1;
    const escrow_total = std.math.add(u64, amount, escrow_rent_lamports) catch return 1;
    if (maker.lamportsValue() < escrow_total) return 1;

    var data: [12]u8 = undefined;
    writeSystemTransferData(data[0..], escrow_total);

    var system_program_id = system_program.key.*;
    var metas = [_]SolAccountMeta{
        .{ .pubkey = maker.key, .is_writable = 1, .is_signer = 1 },
        .{ .pubkey = escrow.key, .is_writable = 1, .is_signer = 0 },
    };
    const instruction = SolInstruction.fromSlices(&system_program_id, metas[0..], data[0..]);
    var infos = [_]SolAccountInfo{
        accountInfoFromView(maker),
        accountInfoFromView(escrow),
    };
    if (invoke(&instruction, infos[0..]) != success) return 1;

    @memset(escrow.data[0..escrow_state_len], 0);
    escrow.data[0] = escrow_discriminator;
    @memcpy(escrow.data[1..33], maker.key[0..]);
    @memcpy(escrow.data[escrow_taker_offset..][0..32], instruction_data[1..33]);
    writeU64Le(escrow.data[escrow_amount_offset..][0..8], amount);
    return 0;
}

fn zxcamlEscrowAccept(program_id: *const Pubkey, views: []account.AccountView) u64 {
    if (views.len < 3) return 1;

    const taker = views[0];
    const escrow = views[1];
    const maker = views[2];
    if (!taker.is_signer or !taker.is_writable) return 1;
    if (!escrow.is_writable) return 1;
    if (!pubkeyEq(escrow.owner, program_id)) return 1;
    if (!escrowPdaMatches(escrow.key, maker.key, program_id)) return 1;
    if (!escrowStateIsInitialized(escrow.data)) return 1;

    const restricted_taker = escrow.data[escrow_taker_offset..][0..32];
    if (!isZeroPubkeyBytes(restricted_taker) and !std.mem.eql(u8, restricted_taker, taker.key[0..])) return 1;

    const amount = readU64LeSlice(escrow.data[escrow_amount_offset..][0..8]);
    if (amount == 0) return 1;
    const escrow_lamports = escrow.lamportsValue();
    if (escrow_lamports == 0) return 1;
    const taker_lamports = std.math.add(u64, taker.lamportsValue(), escrow_lamports) catch return 1;

    escrow.lamports.* = 0;
    taker.lamports.* = taker_lamports;
    escrow.data[0] = 0;
    return 0;
}

fn zxcamlEscrowRefund(program_id: *const Pubkey, views: []account.AccountView) u64 {
    if (views.len < 2) return 1;

    const maker = views[0];
    const escrow = views[1];
    if (!maker.is_signer or !maker.is_writable) return 1;
    if (!escrow.is_writable) return 1;
    if (!pubkeyEq(escrow.owner, program_id)) return 1;
    if (!escrowPdaMatches(escrow.key, maker.key, program_id)) return 1;
    if (!escrowStateIsInitialized(escrow.data)) return 1;

    const amount = readU64LeSlice(escrow.data[escrow_amount_offset..][0..8]);
    if (amount == 0) return 1;
    const escrow_lamports = escrow.lamportsValue();
    if (escrow_lamports == 0) return 1;
    const maker_lamports = std.math.add(u64, maker.lamportsValue(), escrow_lamports) catch return 1;

    escrow.lamports.* = 0;
    maker.lamports.* = maker_lamports;
    escrow.data[0] = 0;
    return 0;
}

fn escrowStateIsInitialized(data: []const u8) bool {
    return data.len >= escrow_state_len and data[0] == escrow_discriminator;
}

fn escrowPdaMatches(escrow_key: *const Pubkey, maker_key: *const Pubkey, program_id: *const Pubkey) bool {
    var escrow_seed: [6]u8 = .{ 'e', 's', 'c', 'r', 'o', 'w' };
    var maker_seed = maker_key.*;
    var bump_seed: [1]u8 = .{255};
    var seeds = [_]SolSignerSeed{
        SolSignerSeed.fromSlice(escrow_seed[0..]),
        SolSignerSeed.fromSlice(maker_seed[0..]),
        SolSignerSeed.fromSlice(bump_seed[0..]),
    };
    var expected: Pubkey = undefined;
    if (sol_create_program_address(seeds[0..], program_id, &expected) != success) return false;
    return pubkeyEq(escrow_key, &expected);
}
