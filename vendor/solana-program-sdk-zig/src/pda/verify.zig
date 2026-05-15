const shared = @import("shared.zig");
const pubkey = shared.pubkey;
const Pubkey = shared.Pubkey;
const ProgramError = shared.ProgramError;
const MAX_SEEDS = shared.MAX_SEEDS;
const createProgramAddress = @import("runtime.zig").createProgramAddress;
const findProgramAddress = @import("runtime.zig").findProgramAddress;

// =============================================================================
// PDA verification — Anchor `seeds = [...], bump` equivalent
//
// Pattern: an account was passed in claiming to be a PDA. Verify it
// by deriving the expected address from the canonical seeds and
// comparing. Two flavours:
//
//   verifyPda(account_key, seeds, bump, program_id)
//     Caller already knows the bump (typically stored inside the
//     account, e.g. `vault.bump`). One SHA-256 → ~1500 CU.
//
//   verifyPdaCanonical(account_key, seeds, program_id) -> bump
//     Walks bumps 255..0 (`sol_try_find_program_address`) to verify
//     the account is the canonical PDA, returning the bump. ~3000 CU.
//     Use only when you can't trust a stored bump.
// =============================================================================

/// Verify that `expected_key` is the PDA derived from
/// `seeds || [bump]` for `program_id`. Returns `error.InvalidSeeds` on
/// mismatch. Costs one SHA-256 (~1500 CU) — the same as Anchor's
/// `seeds = [...], bump = vault.bump` constraint.
pub fn verifyPda(
    expected_key: *const Pubkey,
    seeds: []const []const u8,
    bump: u8,
    program_id: *const Pubkey,
) ProgramError!void {
    // Append bump as the final seed.
    //
    // Tried calling sol_create_program_address directly here to skip
    // createProgramAddress's own staging copy + MAX_SEED_LEN check —
    // measured +2 CU on withdraw (the syscall setup eats the staging
    // win) AND broke host tests. Keep the cleaner shape.
    if (seeds.len + 1 > MAX_SEEDS) return ProgramError.MaxSeedLengthExceeded;
    var seeds_with_bump: [MAX_SEEDS][]const u8 = undefined;
    for (seeds, 0..) |s, i| seeds_with_bump[i] = s;
    const bump_slice: []const u8 = (&[_]u8{bump})[0..];
    seeds_with_bump[seeds.len] = bump_slice;

    const derived = try createProgramAddress(
        seeds_with_bump[0 .. seeds.len + 1],
        program_id,
    );
    if (!pubkey.pubkeyEq(&derived, expected_key)) {
        return ProgramError.InvalidSeeds;
    }
}

/// Verify that `expected_key` is the **canonical** PDA (highest valid
/// bump) for `seeds, program_id`. Returns the canonical bump on
/// success. Costs a full `findProgramAddress` (~3000-5000 CU).
///
/// Most programs should store the bump in account data and use
/// `verifyPda` instead — that saves a lot of CU.
pub fn verifyPdaCanonical(
    expected_key: *const Pubkey,
    seeds: []const []const u8,
    program_id: *const Pubkey,
) ProgramError!u8 {
    const found = try findProgramAddress(seeds, program_id);
    if (!pubkey.pubkeyEq(&found.address, expected_key)) {
        return ProgramError.InvalidSeeds;
    }
    return found.bump_seed;
}
