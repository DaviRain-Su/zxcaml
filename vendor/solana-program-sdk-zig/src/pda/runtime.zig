const shared = @import("shared.zig");
const std = shared.std;
const pubkey = shared.pubkey;
const bpf = shared.bpf;
const Pubkey = shared.Pubkey;
const ProgramError = shared.ProgramError;
const MAX_SEEDS = shared.MAX_SEEDS;
const MAX_SEED_LEN = shared.MAX_SEED_LEN;
const ProgramDerivedAddress = shared.ProgramDerivedAddress;
const sol_create_program_address = shared.sol_create_program_address;
const sol_try_find_program_address = shared.sol_try_find_program_address;

// =============================================================================
// PDA derivation and seed-based address helpers
// =============================================================================

/// Create a program address from seeds and a program ID
///
/// Returns error.InvalidSeeds if the address is on the Curve25519 curve
/// (i.e., not a valid PDA).
pub fn createProgramAddress(
    seeds: []const []const u8,
    program_id: *const Pubkey,
) ProgramError!Pubkey {
    if (seeds.len > MAX_SEEDS) {
        return ProgramError.MaxSeedLengthExceeded;
    }
    for (seeds) |seed| {
        if (seed.len > MAX_SEED_LEN) {
            return ProgramError.MaxSeedLengthExceeded;
        }
    }

    if (bpf.is_bpf_program) {
        // `seeds.len` is runtime, so we cannot size the local array with
        // it. Use a fixed-size stack buffer of MAX_SEEDS and slice it.
        var seeds_array: [MAX_SEEDS][]const u8 = undefined;
        for (seeds, 0..) |seed, i| {
            seeds_array[i] = seed;
        }
        var address: Pubkey = undefined;

        const result = sol_create_program_address(
            seeds_array[0..seeds.len].ptr,
            seeds.len,
            program_id,
            &address,
        );
        if (result != 0) {
            return ProgramError.InvalidSeeds;
        }
        return address;
    }

    // Host implementation using SHA-256
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (seeds) |seed| {
        hasher.update(seed);
    }
    hasher.update(program_id);
    hasher.update("ProgramDerivedAddress");

    var address: Pubkey = undefined;
    hasher.final(&address);

    if (pubkey.isPointOnCurve(&address)) {
        return ProgramError.InvalidSeeds;
    }

    return address;
}

/// Find a valid program address with a bump seed
///
/// Iterates through bump seeds 255..0 to find one that produces
/// a valid PDA (not on the Curve25519 curve).
pub fn findProgramAddress(
    seeds: []const []const u8,
    program_id: *const Pubkey,
) ProgramError!ProgramDerivedAddress {
    if (bpf.is_bpf_program) {
        if (seeds.len > MAX_SEEDS) {
            return ProgramError.MaxSeedLengthExceeded;
        }
        var seeds_array: [MAX_SEEDS][]const u8 = undefined;
        for (seeds, 0..) |seed, i| {
            seeds_array[i] = seed;
        }
        var pda: ProgramDerivedAddress = undefined;

        const result = sol_try_find_program_address(
            seeds_array[0..seeds.len].ptr,
            seeds.len,
            program_id,
            &pda.address,
            &pda.bump_seed,
        );
        if (result != 0) {
            return ProgramError.InvalidSeeds;
        }
        return pda;
    }

    // Host implementation
    var bump_seed: u8 = 255;
    while (true) : (bump_seed -= 1) {
        const bump_seed_slice: []const u8 = &.{bump_seed};

        var seeds_with_bump: [16][]const u8 = undefined;
        for (seeds, 0..) |seed, i| {
            seeds_with_bump[i] = seed;
        }
        seeds_with_bump[seeds.len] = bump_seed_slice;

        const address = createProgramAddress(
            seeds_with_bump[0 .. seeds.len + 1],
            program_id,
        ) catch {
            if (bump_seed == 0) {
                return ProgramError.InvalidSeeds;
            }
            continue;
        };

        return ProgramDerivedAddress{
            .address = address,
            .bump_seed = bump_seed,
        };
    }
}

/// Create a program address with a specific seed string
pub fn createWithSeed(
    base: *const Pubkey,
    seed: []const u8,
    program_id: *const Pubkey,
) ProgramError!Pubkey {
    if (seed.len > MAX_SEED_LEN) {
        return ProgramError.MaxSeedLengthExceeded;
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(base);
    hasher.update(seed);
    hasher.update(program_id);

    var address: Pubkey = undefined;
    hasher.final(&address);

    return address;
}
