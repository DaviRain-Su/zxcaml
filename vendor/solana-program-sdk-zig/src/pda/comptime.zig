const shared = @import("shared.zig");
const std = shared.std;
const pubkey = shared.pubkey;
const Pubkey = shared.Pubkey;
const MAX_SEED_LEN = shared.MAX_SEED_LEN;
const ProgramDerivedAddress = shared.ProgramDerivedAddress;

// =============================================================================
// Compile-time PDA helpers
// =============================================================================

/// Compile-time `createWithSeed`.
///
/// Computes `SHA-256(base || seed || program_id)` at build time, when
/// all three inputs are compile-time-known. Useful for fixed
/// `create_account_with_seed` derivations (e.g. nonce accounts owned
/// by a known base pubkey).
///
/// No bump search is involved — the result is unconditionally returned.
pub fn comptimeCreateWithSeed(
    comptime base: Pubkey,
    comptime seed: []const u8,
    comptime program_id: Pubkey,
) Pubkey {
    return comptime blk: {
        if (seed.len > MAX_SEED_LEN) {
            @compileError("seed exceeds MAX_SEED_LEN");
        }
        @setEvalBranchQuota(1_000_000);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&base);
        hasher.update(seed);
        hasher.update(&program_id);

        var address: Pubkey = undefined;
        hasher.final(&address);
        break :blk address;
    };
}

/// Compile-time `createProgramAddress`.
///
/// Computes the PDA at compile time from a tuple of byte-slice seeds
/// and a fixed `program_id`. Emits a `@compileError` if the derived
/// address lands on the Ed25519 curve (i.e. is not a valid PDA — pass
/// a different bump or use `comptimeFindProgramAddress`).
///
/// All seeds must be comptime-known. Typical use:
/// ```zig
/// const VAULT_PDA = pda.comptimeCreateProgramAddress(
///     .{ "vault", &[_]u8{bump} },
///     MY_PROGRAM_ID,
/// );
/// ```
pub fn comptimeCreateProgramAddress(
    comptime seeds: anytype,
    comptime program_id: Pubkey,
) Pubkey {
    return comptime blk: {
        @setEvalBranchQuota(10_000_000);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (seeds) |seed| {
            hasher.update(seed);
        }
        hasher.update(&program_id);
        hasher.update("ProgramDerivedAddress");

        var address: Pubkey = undefined;
        hasher.final(&address);

        if (pubkey.isPointOnCurve(&address)) {
            @compileError("Address is on curve, not a valid PDA");
        }

        break :blk address;
    };
}

/// Compile-time `findProgramAddress`.
///
/// Walks `bump = 255..0` until the SHA-256 of `seeds || bump ||
/// program_id || "ProgramDerivedAddress"` is off-curve, all at compile
/// time. Returns `{ address, bump_seed }` as plain constants.
///
/// This completely eliminates the `sol_try_find_program_address`
/// syscall (~1500 CU) when the PDA's seeds are statically known —
/// common for "self-owned" PDAs like a singleton vault.
///
/// All seeds must be comptime-known. Typical use:
/// ```zig
/// const VAULT = pda.comptimeFindProgramAddress(.{ "vault" }, MY_PROGRAM_ID);
/// // VAULT.address and VAULT.bump_seed are plain compile-time values.
/// ```
pub fn comptimeFindProgramAddress(
    comptime seeds: anytype,
    comptime program_id: Pubkey,
) ProgramDerivedAddress {
    return comptime blk: {
        @setEvalBranchQuota(10_000_000);
        var bump_seed: u8 = 255;
        while (true) : (bump_seed -= 1) {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            for (seeds) |seed| {
                hasher.update(seed);
            }
            hasher.update(&[_]u8{bump_seed});
            hasher.update(&program_id);
            hasher.update("ProgramDerivedAddress");

            var address: Pubkey = undefined;
            hasher.final(&address);

            if (!pubkey.isPointOnCurve(&address)) {
                break :blk ProgramDerivedAddress{
                    .address = address,
                    .bump_seed = bump_seed,
                };
            }

            if (bump_seed == 0) {
                @compileError("Failed to find valid PDA bump seed");
            }
        }
    };
}
