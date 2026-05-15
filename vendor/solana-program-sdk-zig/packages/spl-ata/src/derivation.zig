//! Public ATA derivation surface.
//!
//! ATA addresses are PDAs over canonical seeds:
//! `wallet || token_program_id || mint`, derived under the ATA
//! program id. Separate helpers are exposed for classic SPL Token and
//! Token-2022, plus a generic form that accepts any token program id.

const std = @import("std");
const sol = @import("solana_program_sdk");
const id = @import("id.zig");

const Pubkey = sol.Pubkey;

pub const ProgramDerivedAddress = sol.pda.ProgramDerivedAddress;

pub fn findAddress(
    wallet: *const Pubkey,
    mint: *const Pubkey,
    token_program_id: *const Pubkey,
) ProgramDerivedAddress {
    return sol.pda.findProgramAddress(
        &.{ wallet, token_program_id, mint },
        &id.PROGRAM_ID,
    ) catch unreachable;
}

pub fn findAddressClassic(
    wallet: *const Pubkey,
    mint: *const Pubkey,
) ProgramDerivedAddress {
    return findAddress(wallet, mint, &sol.spl_token_program_id);
}

pub fn findAddressToken2022(
    wallet: *const Pubkey,
    mint: *const Pubkey,
) ProgramDerivedAddress {
    return findAddress(wallet, mint, &sol.spl_token_2022_program_id);
}

const fixture_wallet = sol.pubkey.comptimeFromBase58(
    "SysvarC1ock11111111111111111111111111111111",
);
const fixture_mint = sol.pubkey.comptimeFromBase58(
    "So11111111111111111111111111111111111111112",
);
const fixture_classic_address = sol.pubkey.comptimeFromBase58(
    "286pxd3rnNYaQAtfxZqFrH6aW6QBJ5k8KzoBFt94rT9D",
);
const fixture_token2022_address = sol.pubkey.comptimeFromBase58(
    "3W3NGpd7orbruigyrt7Bsh3zzyiuDhXxZxLqemr8ZXNF",
);

fn canonicalFindAddress(
    wallet: *const Pubkey,
    mint: *const Pubkey,
    token_program_id: *const Pubkey,
) !ProgramDerivedAddress {
    return try sol.pda.findProgramAddress(
        &.{ wallet, token_program_id, mint },
        &id.PROGRAM_ID,
    );
}

test "findAddress accepts explicit token program id and matches canonical ATA seeds" {
    const expected_classic = try canonicalFindAddress(
        &fixture_wallet,
        &fixture_mint,
        &sol.spl_token_program_id,
    );
    const expected_token2022 = try canonicalFindAddress(
        &fixture_wallet,
        &fixture_mint,
        &sol.spl_token_2022_program_id,
    );

    const actual_classic = findAddress(
        &fixture_wallet,
        &fixture_mint,
        &sol.spl_token_program_id,
    );
    const actual_token2022 = findAddress(
        &fixture_wallet,
        &fixture_mint,
        &sol.spl_token_2022_program_id,
    );

    try std.testing.expectEqual(expected_classic.bump_seed, actual_classic.bump_seed);
    try std.testing.expectEqualSlices(u8, &expected_classic.address, &actual_classic.address);
    try std.testing.expectEqual(expected_token2022.bump_seed, actual_token2022.bump_seed);
    try std.testing.expectEqualSlices(u8, &expected_token2022.address, &actual_token2022.address);
    try std.testing.expect(
        !sol.pubkey.pubkeyEq(&actual_classic.address, &actual_token2022.address),
    );
}

test "classic helper matches generic derivation fixture" {
    const generic = findAddress(
        &fixture_wallet,
        &fixture_mint,
        &sol.spl_token_program_id,
    );
    const actual = findAddressClassic(&fixture_wallet, &fixture_mint);

    try std.testing.expectEqual(@as(u8, 255), actual.bump_seed);
    try std.testing.expectEqualSlices(u8, &fixture_classic_address, &actual.address);
    try std.testing.expectEqual(generic.bump_seed, actual.bump_seed);
    try std.testing.expectEqualSlices(u8, &generic.address, &actual.address);
}

test "token2022 helper matches generic derivation fixture and differs from classic" {
    const classic = findAddressClassic(&fixture_wallet, &fixture_mint);
    const generic = findAddress(
        &fixture_wallet,
        &fixture_mint,
        &sol.spl_token_2022_program_id,
    );
    const actual = findAddressToken2022(&fixture_wallet, &fixture_mint);

    try std.testing.expectEqual(@as(u8, 253), actual.bump_seed);
    try std.testing.expectEqualSlices(u8, &fixture_token2022_address, &actual.address);
    try std.testing.expectEqual(generic.bump_seed, actual.bump_seed);
    try std.testing.expectEqualSlices(u8, &generic.address, &actual.address);
    try std.testing.expect(
        !sol.pubkey.pubkeyEq(&classic.address, &actual.address),
    );
}

test "derivation supports PDA wallet owners" {
    const wallet_owner = try sol.pda.findProgramAddress(
        &.{"wallet-owner"},
        &sol.spl_memo_program_id,
    );
    const expected = try canonicalFindAddress(
        &wallet_owner.address,
        &fixture_mint,
        &sol.spl_token_program_id,
    );

    const actual = findAddress(
        &wallet_owner.address,
        &fixture_mint,
        &sol.spl_token_program_id,
    );

    try std.testing.expectEqual(expected.bump_seed, actual.bump_seed);
    try std.testing.expectEqualSlices(u8, &expected.address, &actual.address);
}
