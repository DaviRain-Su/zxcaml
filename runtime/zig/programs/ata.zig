//! Associated Token Account program instruction builders.

const std = @import("std");
const bs58 = @import("../bs58.zig");
const cpi = @import("../cpi.zig");
const spl_token = @import("../spl_token.zig");
const sol = @import("solana_program_sdk");
const sdk_ata = @import("spl_ata_m4");

/// Canonical Associated Token Account program id as base58.
pub const program_id_base58 = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";

/// Canonical Associated Token Account program id.
pub const program_id: cpi.Pubkey = sdk_ata.PROGRAM_ID;

/// Canonical System Program id.
pub const system_program_id: cpi.Pubkey = sol.system_program_id;

/// Associated Token Account CreateIdempotent instruction discriminator.
pub const create_idempotent_discriminator: u8 = @intFromEnum(sdk_ata.create_idempotent_spec.disc);
/// CreateIdempotent instruction data length: one u8 discriminator.
pub const create_idempotent_instruction_data_len: usize = sdk_ata.create_idempotent_spec.data_len;
/// CreateIdempotent account count: funding, ATA, owner, mint, System Program, SPL Token program.
pub const create_idempotent_account_count: usize = sdk_ata.create_idempotent_spec.accounts_len;

pub const Error = error{
    InvalidInstructionDiscriminant,
    InvalidInstructionLength,
};

pub const InstructionKind = enum {
    create_idempotent,
};

pub const AssociatedTokenAddress = struct {
    address: cpi.Pubkey,
    bump_seed: u8,
};

/// Encodes Associated Token Account CreateIdempotent instruction data.
pub fn encodeCreateIdempotent() [create_idempotent_instruction_data_len]u8 {
    return .{create_idempotent_discriminator};
}

pub fn findAssociatedTokenAddress(
    owner: *const cpi.Pubkey,
    mint: *const cpi.Pubkey,
    token_program: *const cpi.Pubkey,
) AssociatedTokenAddress {
    const derived = sdk_ata.findAddress(owner, mint, token_program);
    return .{
        .address = derived.address,
        .bump_seed = derived.bump_seed,
    };
}

pub fn findAssociatedTokenAddressClassic(
    owner: *const cpi.Pubkey,
    mint: *const cpi.Pubkey,
) AssociatedTokenAddress {
    return findAssociatedTokenAddress(owner, mint, &spl_token.program_id);
}

/// Builds account metas for CreateIdempotent.
pub fn createIdempotentAccountMetas(
    funding: *const cpi.Pubkey,
    associated_token_account: *const cpi.Pubkey,
    owner: *const cpi.Pubkey,
    mint: *const cpi.Pubkey,
    system_program: *const cpi.Pubkey,
    token_program: *const cpi.Pubkey,
) [create_idempotent_account_count]cpi.SolAccountMeta {
    return .{
        .{ .pubkey = funding, .is_writable = 1, .is_signer = 1 },
        .{ .pubkey = associated_token_account, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = owner, .is_writable = 0, .is_signer = 0 },
        .{ .pubkey = mint, .is_writable = 0, .is_signer = 0 },
        .{ .pubkey = system_program, .is_writable = 0, .is_signer = 0 },
        .{ .pubkey = token_program, .is_writable = 0, .is_signer = 0 },
    };
}

/// Builds a CreateIdempotent instruction using caller-owned meta/data buffers.
pub fn createIdempotent(
    funding: *const cpi.Pubkey,
    associated_token_account: *const cpi.Pubkey,
    owner: *const cpi.Pubkey,
    mint: *const cpi.Pubkey,
    metas: *[create_idempotent_account_count]cpi.SolAccountMeta,
    data: *[create_idempotent_instruction_data_len]u8,
) cpi.SolInstruction {
    return createIdempotentWithPrograms(
        funding,
        associated_token_account,
        owner,
        mint,
        &system_program_id,
        &spl_token.program_id,
        metas,
        data,
    );
}

/// Builds a CreateIdempotent instruction with explicit System and SPL Token program account keys.
pub fn createIdempotentWithPrograms(
    funding: *const cpi.Pubkey,
    associated_token_account: *const cpi.Pubkey,
    owner: *const cpi.Pubkey,
    mint: *const cpi.Pubkey,
    system_program: *const cpi.Pubkey,
    token_program: *const cpi.Pubkey,
    metas: *[create_idempotent_account_count]cpi.SolAccountMeta,
    data: *[create_idempotent_instruction_data_len]u8,
) cpi.SolInstruction {
    var scratch: sdk_ata.Scratch(sdk_ata.create_idempotent_spec) = undefined;
    _ = sdk_ata.createIdempotentForAddress(
        funding,
        associated_token_account,
        owner,
        mint,
        system_program,
        token_program,
        &scratch,
    );
    metas.* = @bitCast(scratch.metas);
    data.* = scratch.data;
    return cpi.SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
}

pub fn validateInstructionData(data: []const u8) Error!InstructionKind {
    if (data.len != create_idempotent_instruction_data_len) return error.InvalidInstructionLength;
    if (data[0] != create_idempotent_discriminator) return error.InvalidInstructionDiscriminant;
    return .create_idempotent;
}

test "ATA program id matches canonical AToken address" {
    const encoded = try bs58.encode(std.testing.allocator, &program_id);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(program_id_base58, encoded);
}

test "ATA CreateIdempotent builder uses six canonical accounts" {
    var funding: cpi.Pubkey = [_]u8{1} ** spl_token.pubkey_len;
    var associated_token_account: cpi.Pubkey = [_]u8{2} ** spl_token.pubkey_len;
    var owner: cpi.Pubkey = [_]u8{3} ** spl_token.pubkey_len;
    var mint: cpi.Pubkey = [_]u8{4} ** spl_token.pubkey_len;
    var metas: [create_idempotent_account_count]cpi.SolAccountMeta = undefined;
    var data: [create_idempotent_instruction_data_len]u8 = undefined;

    const instruction = createIdempotent(&funding, &associated_token_account, &owner, &mint, &metas, &data);
    try std.testing.expect(instruction.program_id == &program_id);
    try std.testing.expectEqual(@as(u64, create_idempotent_account_count), instruction.account_len);
    try std.testing.expect(instruction.accounts == metas[0..].ptr);
    try std.testing.expectEqual(@as(u64, create_idempotent_instruction_data_len), instruction.data_len);
    try std.testing.expect(instruction.data == data[0..].ptr);
    try std.testing.expectEqualSlices(u8, &.{1}, instruction.data[0..@intCast(instruction.data_len)]);

    try std.testing.expect(metas[0].pubkey == &funding);
    try std.testing.expectEqual(@as(u8, 1), metas[0].is_writable);
    try std.testing.expectEqual(@as(u8, 1), metas[0].is_signer);
    try std.testing.expect(metas[1].pubkey == &associated_token_account);
    try std.testing.expectEqual(@as(u8, 1), metas[1].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[1].is_signer);
    try std.testing.expect(metas[2].pubkey == &owner);
    try std.testing.expectEqual(@as(u8, 0), metas[2].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[2].is_signer);
    try std.testing.expect(metas[3].pubkey == &mint);
    try std.testing.expectEqual(@as(u8, 0), metas[3].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[3].is_signer);
    try std.testing.expect(metas[4].pubkey == &system_program_id);
    try std.testing.expectEqual(@as(u8, 0), metas[4].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[4].is_signer);
    try std.testing.expect(metas[5].pubkey == &spl_token.program_id);
    try std.testing.expectEqual(@as(u8, 0), metas[5].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[5].is_signer);
}

test "ATA flow can reuse SPL Token InitializeAccount data" {
    const initialize_account_data = spl_token.encodeInitializeAccount();
    try std.testing.expectEqual(spl_token.initialize_account_discriminator, initialize_account_data[0]);
}

test "ATA derivation matches classic associated token address seeds" {
    const owner: cpi.Pubkey = .{0x44} ** spl_token.pubkey_len;
    const mint: cpi.Pubkey = .{0x55} ** spl_token.pubkey_len;
    const derived = findAssociatedTokenAddressClassic(&owner, &mint);
    const vendored = sdk_ata.findAddressClassic(&owner, &mint);

    try std.testing.expectEqual(vendored.bump_seed, derived.bump_seed);
    try std.testing.expectEqualSlices(u8, &vendored.address, &derived.address);
}

test "ATA CreateIdempotent explicit program metas stay readonly nonsigner" {
    var funding: cpi.Pubkey = [_]u8{1} ** spl_token.pubkey_len;
    var associated_token_account: cpi.Pubkey = [_]u8{2} ** spl_token.pubkey_len;
    var owner: cpi.Pubkey = [_]u8{3} ** spl_token.pubkey_len;
    var mint: cpi.Pubkey = [_]u8{4} ** spl_token.pubkey_len;
    var explicit_system_program: cpi.Pubkey = [_]u8{5} ** spl_token.pubkey_len;
    var explicit_token_program: cpi.Pubkey = [_]u8{6} ** spl_token.pubkey_len;
    var metas: [create_idempotent_account_count]cpi.SolAccountMeta = undefined;
    var data: [create_idempotent_instruction_data_len]u8 = undefined;

    const instruction = createIdempotentWithPrograms(
        &funding,
        &associated_token_account,
        &owner,
        &mint,
        &explicit_system_program,
        &explicit_token_program,
        &metas,
        &data,
    );

    try std.testing.expect(instruction.program_id == &program_id);
    try std.testing.expect(metas[4].pubkey == &explicit_system_program);
    try std.testing.expectEqual(@as(u8, 0), metas[4].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[4].is_signer);
    try std.testing.expect(metas[5].pubkey == &explicit_token_program);
    try std.testing.expectEqual(@as(u8, 0), metas[5].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[5].is_signer);
}

test "ATA instruction validator rejects malformed input" {
    try std.testing.expectEqual(.create_idempotent, try validateInstructionData(&.{1}));
    try std.testing.expectError(error.InvalidInstructionLength, validateInstructionData(&.{}));
    try std.testing.expectError(error.InvalidInstructionDiscriminant, validateInstructionData(&.{0}));
}
