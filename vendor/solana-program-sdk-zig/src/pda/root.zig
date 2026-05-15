//! Program Derived Address (PDA) computation.
//!
//! This module groups the SDK's PDA derivation helpers across three use cases:
//!
//! - runtime PDA creation / bump search via syscalls or host-side SHA-256
//! - compile-time PDA / `create_with_seed` derivation for fixed seeds
//! - PDA verification helpers for stored-bump and canonical-bump flows
//!
//! Physical layout:
//! - `shared.zig` — common imports, limits, result type, runtime syscalls
//! - `runtime.zig` — runtime PDA derivation and `createWithSeed`
//! - `comptime.zig` — compile-time PDA and seed-address derivation
//! - `verify.zig` — stored-bump and canonical-bump verification helpers
//!
//! The public API stays flattened as `sol.pda.*`, with root aliases
//! `sol.verifyPda(...)` and `sol.verifyPdaCanonical(...)` preserved at
//! `src/root.zig`.

const std = @import("std");
const shared = @import("shared.zig");
const pubkey = shared.pubkey;
const Pubkey = shared.Pubkey;
const ProgramError = shared.ProgramError;
const runtime_mod = @import("runtime.zig");
const comptime_mod = @import("comptime.zig");
const verify_mod = @import("verify.zig");

/// PDA size / derivation limits and result model.
pub const MAX_SEEDS = shared.MAX_SEEDS;
pub const MAX_SEED_LEN = shared.MAX_SEED_LEN;
pub const ProgramDerivedAddress = shared.ProgramDerivedAddress;

/// Runtime PDA derivation and seed-address helpers.
pub const createProgramAddress = runtime_mod.createProgramAddress;
pub const findProgramAddress = runtime_mod.findProgramAddress;
pub const createWithSeed = runtime_mod.createWithSeed;

/// Compile-time PDA / seed-address derivation helpers.
pub const comptimeCreateWithSeed = comptime_mod.comptimeCreateWithSeed;
pub const comptimeCreateProgramAddress = comptime_mod.comptimeCreateProgramAddress;
pub const comptimeFindProgramAddress = comptime_mod.comptimeFindProgramAddress;

/// PDA verification helpers.
pub const verifyPda = verify_mod.verifyPda;
pub const verifyPdaCanonical = verify_mod.verifyPdaCanonical;

// =============================================================================
// Tests
// =============================================================================

test "pda: create program address" {
    const program_id = pubkey.comptimeFromBase58("11111111111111111111111111111111");
    const address = try createProgramAddress(&.{
        "hello",
        &.{255},
    }, &program_id);
    _ = address;
}

test "pda: find program address" {
    const program_id = pubkey.comptimeFromBase58("11111111111111111111111111111111");
    const pda = try findProgramAddress(&.{"hello"}, &program_id);
    _ = pda;
}

test "pda: create with seed" {
    const base = pubkey.comptimeFromBase58("11111111111111111111111111111111");
    const program_id = pubkey.comptimeFromBase58("11111111111111111111111111111111");
    const address = try createWithSeed(&base, "seed", &program_id);
    _ = address;
}

test "pda: comptime find matches runtime find" {
    const program_id: Pubkey = .{0} ** 32; // System Program
    const ct = comptimeFindProgramAddress(.{"vault"}, program_id);
    const rt = try findProgramAddress(&.{"vault"}, &program_id);
    try std.testing.expectEqualSlices(u8, &ct.address, &rt.address);
    try std.testing.expectEqual(rt.bump_seed, ct.bump_seed);
}

test "pda: comptime find produces known address (cross-check)" {
    // Cross-verified against `python -m hashlib` and Solana's
    // Pubkey::find_program_address: for seed "vault" against the
    // System Program ID, the canonical PDA has bump = 254 and address
    // 3d467e29e4663a956c3aa851857d888f6032c4d7606825a4ab75f2e0a932a0d2.
    const program_id: Pubkey = .{0} ** 32;
    const pda = comptimeFindProgramAddress(.{"vault"}, program_id);

    try std.testing.expectEqual(@as(u8, 254), pda.bump_seed);
    const expected_hex = "3d467e29e4663a956c3aa851857d888f6032c4d7606825a4ab75f2e0a932a0d2";
    var expected: Pubkey = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    try std.testing.expectEqualSlices(u8, &expected, &pda.address);
}

test "pda: comptime createWithSeed matches runtime" {
    const base: Pubkey = .{1} ** 32;
    const program_id: Pubkey = .{2} ** 32;
    const seed = "nonce";

    const ct = comptimeCreateWithSeed(base, seed, program_id);
    const rt = try createWithSeed(&base, seed, &program_id);
    try std.testing.expectEqualSlices(u8, &ct, &rt);
}

test "pda: comptime create matches runtime create" {
    const program_id: Pubkey = .{0} ** 32;
    const seeds = .{ "vault", &[_]u8{254} };

    const ct = comptimeCreateProgramAddress(seeds, program_id);
    const rt = try createProgramAddress(
        &.{ "vault", &[_]u8{254} },
        &program_id,
    );
    try std.testing.expectEqualSlices(u8, &ct, &rt);
}

test "pda: verifyPda accepts canonical address" {
    const program_id: Pubkey = .{0} ** 32;
    const found = try findProgramAddress(&.{"vault"}, &program_id);

    try verifyPda(&found.address, &.{"vault"}, found.bump_seed, &program_id);
}

test "pda: verifyPda rejects wrong key" {
    const program_id: Pubkey = .{0} ** 32;
    const wrong: Pubkey = .{0xAB} ** 32;

    try std.testing.expectError(
        ProgramError.InvalidSeeds,
        verifyPda(&wrong, &.{"vault"}, 254, &program_id),
    );
}

test "pda: verifyPda rejects wrong bump" {
    const program_id: Pubkey = .{0} ** 32;
    const found = try findProgramAddress(&.{"vault"}, &program_id);

    // off-by-one bump produces a different address (or InvalidSeeds)
    const wrong_bump: u8 = found.bump_seed -% 1;
    try std.testing.expectError(
        ProgramError.InvalidSeeds,
        verifyPda(&found.address, &.{"vault"}, wrong_bump, &program_id),
    );
}

test "pda: verifyPdaCanonical returns canonical bump" {
    const program_id: Pubkey = .{0} ** 32;
    const found = try findProgramAddress(&.{"vault"}, &program_id);

    const bump = try verifyPdaCanonical(&found.address, &.{"vault"}, &program_id);
    try std.testing.expectEqual(found.bump_seed, bump);
}
