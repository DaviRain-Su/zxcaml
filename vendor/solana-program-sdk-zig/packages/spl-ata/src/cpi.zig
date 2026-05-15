//! On-chain CPI wrappers around the SPL Associated Token Account
//! program.
//!
//! Thin syntactic sugar over `instruction.zig` + `sol.cpi.invokeRaw`.
//! The wrappers stack-allocate the builder scratch, reuse the
//! instruction builders for meta/data encoding, and then rebrand the
//! resulting instruction's `program_id` from the caller-provided ATA
//! program account so the CPI callee comes from runtime account input
//! rather than a rodata constant.

const std = @import("std");
const sol = @import("solana_program_sdk");
const instruction = @import("instruction.zig");

const Pubkey = sol.Pubkey;
const CpiAccountInfo = sol.CpiAccountInfo;
const Instruction = sol.cpi.Instruction;
const Signer = sol.cpi.Signer;
const ProgramResult = sol.ProgramResult;

inline fn rebrand(ix: Instruction, program_id: *const Pubkey) Instruction {
    return .{
        .program_id = program_id,
        .accounts = ix.accounts,
        .data = ix.data,
    };
}

fn buildCreateInstruction(
    comptime spec: instruction.Spec,
    payer: CpiAccountInfo,
    wallet: CpiAccountInfo,
    mint: CpiAccountInfo,
    system_program: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
    scratch: *instruction.Scratch(spec),
) Instruction {
    const built = switch (spec.disc) {
        .create => instruction.create(
            payer.key(),
            wallet.key(),
            mint.key(),
            system_program.key(),
            token_program.key(),
            scratch,
        ),
        .create_idempotent => instruction.createIdempotent(
            payer.key(),
            wallet.key(),
            mint.key(),
            system_program.key(),
            token_program.key(),
            scratch,
        ),
        else => unreachable,
    };

    return rebrand(built, associated_token_program.key());
}

inline fn runtimeAccounts(
    payer: CpiAccountInfo,
    associated_token_account: CpiAccountInfo,
    wallet: CpiAccountInfo,
    mint: CpiAccountInfo,
    system_program: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
) [7]CpiAccountInfo {
    return .{
        payer,
        associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
    };
}

fn buildRecoverNestedInstruction(
    nested_token_mint: CpiAccountInfo,
    owner_token_mint: CpiAccountInfo,
    wallet: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
    scratch: *instruction.Scratch(instruction.recover_nested_spec),
) Instruction {
    const built = instruction.recoverNested(
        wallet.key(),
        owner_token_mint.key(),
        nested_token_mint.key(),
        token_program.key(),
        scratch,
    );
    return rebrand(built, associated_token_program.key());
}

inline fn recoverNestedRuntimeAccounts(
    nested_associated_token_account: CpiAccountInfo,
    nested_token_mint: CpiAccountInfo,
    destination_associated_token_account: CpiAccountInfo,
    owner_associated_token_account: CpiAccountInfo,
    owner_token_mint: CpiAccountInfo,
    wallet: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
) [8]CpiAccountInfo {
    return .{
        nested_associated_token_account,
        nested_token_mint,
        destination_associated_token_account,
        owner_associated_token_account,
        owner_token_mint,
        wallet,
        token_program,
        associated_token_program,
    };
}

/// Create an ATA via CPI.
pub fn create(
    payer: CpiAccountInfo,
    associated_token_account: CpiAccountInfo,
    wallet: CpiAccountInfo,
    mint: CpiAccountInfo,
    system_program: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
) ProgramResult {
    var scratch: instruction.Scratch(instruction.create_spec) = undefined;
    const ix = buildCreateInstruction(
        instruction.create_spec,
        payer,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = runtimeAccounts(
        payer,
        associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
    );
    return sol.cpi.invokeRaw(&ix, &infos);
}

/// PDA-signed variant of `create`.
pub fn createSigned(
    payer: CpiAccountInfo,
    associated_token_account: CpiAccountInfo,
    wallet: CpiAccountInfo,
    mint: CpiAccountInfo,
    system_program: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
    signers: []const Signer,
) ProgramResult {
    var scratch: instruction.Scratch(instruction.create_spec) = undefined;
    const ix = buildCreateInstruction(
        instruction.create_spec,
        payer,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = runtimeAccounts(
        payer,
        associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
    );
    return sol.cpi.invokeSignedRaw(&ix, &infos, signers);
}

/// Single-PDA fast path for `createSigned`.
pub inline fn createSignedSingle(
    payer: CpiAccountInfo,
    associated_token_account: CpiAccountInfo,
    wallet: CpiAccountInfo,
    mint: CpiAccountInfo,
    system_program: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
    signer_seeds: anytype,
) ProgramResult {
    var scratch: instruction.Scratch(instruction.create_spec) = undefined;
    const ix = buildCreateInstruction(
        instruction.create_spec,
        payer,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = runtimeAccounts(
        payer,
        associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
    );
    return sol.cpi.invokeSignedSingle(&ix, &infos, signer_seeds);
}

/// Create an ATA via idempotent CPI.
pub fn createIdempotent(
    payer: CpiAccountInfo,
    associated_token_account: CpiAccountInfo,
    wallet: CpiAccountInfo,
    mint: CpiAccountInfo,
    system_program: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
) ProgramResult {
    var scratch: instruction.Scratch(instruction.create_idempotent_spec) = undefined;
    const ix = buildCreateInstruction(
        instruction.create_idempotent_spec,
        payer,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = runtimeAccounts(
        payer,
        associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
    );
    return sol.cpi.invokeRaw(&ix, &infos);
}

/// PDA-signed variant of `createIdempotent`.
pub fn createIdempotentSigned(
    payer: CpiAccountInfo,
    associated_token_account: CpiAccountInfo,
    wallet: CpiAccountInfo,
    mint: CpiAccountInfo,
    system_program: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
    signers: []const Signer,
) ProgramResult {
    var scratch: instruction.Scratch(instruction.create_idempotent_spec) = undefined;
    const ix = buildCreateInstruction(
        instruction.create_idempotent_spec,
        payer,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = runtimeAccounts(
        payer,
        associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
    );
    return sol.cpi.invokeSignedRaw(&ix, &infos, signers);
}

/// Single-PDA fast path for `createIdempotentSigned`.
pub inline fn createIdempotentSignedSingle(
    payer: CpiAccountInfo,
    associated_token_account: CpiAccountInfo,
    wallet: CpiAccountInfo,
    mint: CpiAccountInfo,
    system_program: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
    signer_seeds: anytype,
) ProgramResult {
    var scratch: instruction.Scratch(instruction.create_idempotent_spec) = undefined;
    const ix = buildCreateInstruction(
        instruction.create_idempotent_spec,
        payer,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = runtimeAccounts(
        payer,
        associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
    );
    return sol.cpi.invokeSignedSingle(&ix, &infos, signer_seeds);
}

/// Recover a nested ATA via CPI.
pub fn recoverNested(
    nested_associated_token_account: CpiAccountInfo,
    nested_token_mint: CpiAccountInfo,
    destination_associated_token_account: CpiAccountInfo,
    owner_associated_token_account: CpiAccountInfo,
    owner_token_mint: CpiAccountInfo,
    wallet: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
) ProgramResult {
    var scratch: instruction.Scratch(instruction.recover_nested_spec) = undefined;
    const ix = buildRecoverNestedInstruction(
        nested_token_mint,
        owner_token_mint,
        wallet,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = recoverNestedRuntimeAccounts(
        nested_associated_token_account,
        nested_token_mint,
        destination_associated_token_account,
        owner_associated_token_account,
        owner_token_mint,
        wallet,
        token_program,
        associated_token_program,
    );
    return sol.cpi.invokeRaw(&ix, &infos);
}

/// PDA-signed variant of `recoverNested`.
pub fn recoverNestedSigned(
    nested_associated_token_account: CpiAccountInfo,
    nested_token_mint: CpiAccountInfo,
    destination_associated_token_account: CpiAccountInfo,
    owner_associated_token_account: CpiAccountInfo,
    owner_token_mint: CpiAccountInfo,
    wallet: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
    signers: []const Signer,
) ProgramResult {
    var scratch: instruction.Scratch(instruction.recover_nested_spec) = undefined;
    const ix = buildRecoverNestedInstruction(
        nested_token_mint,
        owner_token_mint,
        wallet,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = recoverNestedRuntimeAccounts(
        nested_associated_token_account,
        nested_token_mint,
        destination_associated_token_account,
        owner_associated_token_account,
        owner_token_mint,
        wallet,
        token_program,
        associated_token_program,
    );
    return sol.cpi.invokeSignedRaw(&ix, &infos, signers);
}

/// Single-PDA fast path for `recoverNestedSigned`.
pub inline fn recoverNestedSignedSingle(
    nested_associated_token_account: CpiAccountInfo,
    nested_token_mint: CpiAccountInfo,
    destination_associated_token_account: CpiAccountInfo,
    owner_associated_token_account: CpiAccountInfo,
    owner_token_mint: CpiAccountInfo,
    wallet: CpiAccountInfo,
    token_program: CpiAccountInfo,
    associated_token_program: CpiAccountInfo,
    signer_seeds: anytype,
) ProgramResult {
    var scratch: instruction.Scratch(instruction.recover_nested_spec) = undefined;
    const ix = buildRecoverNestedInstruction(
        nested_token_mint,
        owner_token_mint,
        wallet,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = recoverNestedRuntimeAccounts(
        nested_associated_token_account,
        nested_token_mint,
        destination_associated_token_account,
        owner_associated_token_account,
        owner_token_mint,
        wallet,
        token_program,
        associated_token_program,
    );
    return sol.cpi.invokeSignedSingle(&ix, &infos, signer_seeds);
}

const TestAccount = extern struct {
    raw: sol.account.Account,
    data: [8]u8 = .{0} ** 8,
};

fn testAccount(
    key: Pubkey,
    owner: Pubkey,
    signer: bool,
    writable: bool,
    executable: bool,
) TestAccount {
    return .{
        .raw = .{
            .borrow_state = sol.account.NOT_BORROWED,
            .is_signer = @intFromBool(signer),
            .is_writable = @intFromBool(writable),
            .is_executable = @intFromBool(executable),
            ._padding = .{0} ** 4,
            .key = key,
            .owner = owner,
            .lamports = 0,
            .data_len = 8,
        },
    };
}

fn toCpiAccountInfo(backing: *TestAccount) CpiAccountInfo {
    return (sol.AccountInfo{ .raw = &backing.raw }).toCpiInfo();
}

test "public CPI wrapper decls exist" {
    try std.testing.expect(@hasDecl(@This(), "create"));
    try std.testing.expect(@hasDecl(@This(), "createSigned"));
    try std.testing.expect(@hasDecl(@This(), "createSignedSingle"));
    try std.testing.expect(@hasDecl(@This(), "createIdempotent"));
    try std.testing.expect(@hasDecl(@This(), "createIdempotentSigned"));
    try std.testing.expect(@hasDecl(@This(), "createIdempotentSignedSingle"));
    try std.testing.expect(@hasDecl(@This(), "recoverNested"));
    try std.testing.expect(@hasDecl(@This(), "recoverNestedSigned"));
    try std.testing.expect(@hasDecl(@This(), "recoverNestedSignedSingle"));
}

test "create rebrands ATA callee and preserves canonical runtime account order" {
    var payer_account = testAccount(.{0x11} ** 32, sol.system_program_id, true, true, false);
    var associated_token_account = testAccount(.{0x22} ** 32, .{0x90} ** 32, false, true, false);
    var wallet_account = testAccount(.{0x33} ** 32, .{0x91} ** 32, false, false, false);
    var mint_account = testAccount(.{0x44} ** 32, .{0x92} ** 32, false, false, false);
    var system_program_account = testAccount(sol.system_program_id, .{0x93} ** 32, false, false, true);
    var token_program_account = testAccount(.{0x55} ** 32, .{0x94} ** 32, false, false, true);
    var ata_program_account = testAccount(.{0x66} ** 32, .{0x95} ** 32, false, false, true);

    const payer = toCpiAccountInfo(&payer_account);
    const ata = toCpiAccountInfo(&associated_token_account);
    const wallet = toCpiAccountInfo(&wallet_account);
    const mint = toCpiAccountInfo(&mint_account);
    const system_program = toCpiAccountInfo(&system_program_account);
    const token_program = toCpiAccountInfo(&token_program_account);
    const associated_token_program = toCpiAccountInfo(&ata_program_account);

    var scratch: instruction.Scratch(instruction.create_spec) = undefined;
    const ix = buildCreateInstruction(
        instruction.create_spec,
        payer,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = runtimeAccounts(
        payer,
        ata,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
    );
    const expected_ata = instruction.create(
        payer.key(),
        wallet.key(),
        mint.key(),
        system_program.key(),
        token_program.key(),
        &scratch,
    );

    try std.testing.expectEqual(associated_token_program.key(), ix.program_id);
    try std.testing.expectEqual(@as(usize, 6), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), ix.data.len);
    try std.testing.expectEqual(@as(u8, 0), ix.data[0]);
    try std.testing.expectEqualSlices(u8, expected_ata.accounts[1].pubkey, ix.accounts[1].pubkey);
    try std.testing.expect(!sol.pubkey.pubkeyEq(ix.accounts[1].pubkey, infos[1].key()));
    try std.testing.expectEqualSlices(u8, payer.key(), infos[0].key());
    try std.testing.expectEqualSlices(u8, ata.key(), infos[1].key());
    try std.testing.expectEqualSlices(u8, wallet.key(), infos[2].key());
    try std.testing.expectEqualSlices(u8, mint.key(), infos[3].key());
    try std.testing.expectEqualSlices(u8, system_program.key(), infos[4].key());
    try std.testing.expectEqualSlices(u8, token_program.key(), infos[5].key());
    try std.testing.expectEqualSlices(u8, associated_token_program.key(), infos[6].key());
}

test "createIdempotent keeps builder metas/data and caller-selected token plus ATA programs" {
    var payer_account = testAccount(.{0x71} ** 32, sol.system_program_id, true, true, false);
    var associated_token_account = testAccount(.{0x72} ** 32, .{0x96} ** 32, false, true, false);
    var wallet_account = testAccount(.{0x73} ** 32, .{0x97} ** 32, false, false, false);
    var mint_account = testAccount(.{0x74} ** 32, .{0x98} ** 32, false, false, false);
    var system_program_account = testAccount(sol.system_program_id, .{0x99} ** 32, false, false, true);
    var token_program_account = testAccount(sol.spl_token_2022_program_id, .{0x9A} ** 32, false, false, true);
    var ata_program_account = testAccount(.{0x75} ** 32, .{0x9B} ** 32, false, false, true);

    const payer = toCpiAccountInfo(&payer_account);
    const ata = toCpiAccountInfo(&associated_token_account);
    const wallet = toCpiAccountInfo(&wallet_account);
    const mint = toCpiAccountInfo(&mint_account);
    const system_program = toCpiAccountInfo(&system_program_account);
    const token_program = toCpiAccountInfo(&token_program_account);
    const associated_token_program = toCpiAccountInfo(&ata_program_account);

    var scratch: instruction.Scratch(instruction.create_idempotent_spec) = undefined;
    const ix = buildCreateInstruction(
        instruction.create_idempotent_spec,
        payer,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = runtimeAccounts(
        payer,
        ata,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
    );

    try std.testing.expectEqual(associated_token_program.key(), ix.program_id);
    try std.testing.expectEqual(@as(u8, 1), ix.data[0]);
    try std.testing.expectEqualSlices(u8, token_program.key(), ix.accounts[5].pubkey);
    try std.testing.expectEqualSlices(u8, ata.key(), infos[1].key());
    try std.testing.expectEqualSlices(u8, associated_token_program.key(), infos[6].key());
}

test "create signed fast paths keep canonical runtime account order" {
    var payer_account = testAccount(.{0x61} ** 32, sol.system_program_id, false, true, false);
    var associated_token_account = testAccount(.{0x62} ** 32, .{0x86} ** 32, false, true, false);
    var wallet_account = testAccount(.{0x63} ** 32, .{0x87} ** 32, false, false, false);
    var mint_account = testAccount(.{0x64} ** 32, .{0x88} ** 32, false, false, false);
    var system_program_account = testAccount(sol.system_program_id, .{0x89} ** 32, false, false, true);
    var token_program_account = testAccount(.{0x65} ** 32, .{0x8A} ** 32, false, false, true);
    var ata_program_account = testAccount(.{0x66} ** 32, .{0x8B} ** 32, false, false, true);

    const payer = toCpiAccountInfo(&payer_account);
    const ata = toCpiAccountInfo(&associated_token_account);
    const wallet = toCpiAccountInfo(&wallet_account);
    const mint = toCpiAccountInfo(&mint_account);
    const system_program = toCpiAccountInfo(&system_program_account);
    const token_program = toCpiAccountInfo(&token_program_account);
    const associated_token_program = toCpiAccountInfo(&ata_program_account);

    var scratch: instruction.Scratch(instruction.create_spec) = undefined;
    const ix = buildCreateInstruction(
        instruction.create_spec,
        payer,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = runtimeAccounts(
        payer,
        ata,
        wallet,
        mint,
        system_program,
        token_program,
        associated_token_program,
    );
    const bump_seed = [_]u8{7};
    const seeds = sol.cpi.seedPack(.{ "payer", &bump_seed });
    const signer = sol.cpi.Signer.from(&seeds);

    try std.testing.expectError(
        error.InvalidArgument,
        createSigned(payer, ata, wallet, mint, system_program, token_program, associated_token_program, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        createSignedSingle(payer, ata, wallet, mint, system_program, token_program, associated_token_program, .{ "payer", &bump_seed }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        createIdempotentSigned(payer, ata, wallet, mint, system_program, token_program, associated_token_program, &.{signer}),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        createIdempotentSignedSingle(payer, ata, wallet, mint, system_program, token_program, associated_token_program, .{ "payer", &bump_seed }),
    );
    try std.testing.expectEqual(associated_token_program.key(), ix.program_id);
    try std.testing.expectEqualSlices(u8, payer.key(), infos[0].key());
    try std.testing.expectEqualSlices(u8, ata.key(), infos[1].key());
    try std.testing.expectEqualSlices(u8, associated_token_program.key(), infos[6].key());
}

test "recoverNested rebrands ATA callee and preserves nested recovery runtime order" {
    var nested_associated_token_account = testAccount(.{0x81} ** 32, .{0xA1} ** 32, false, true, false);
    var nested_token_mint_account = testAccount(.{0x82} ** 32, .{0xA2} ** 32, false, false, false);
    var destination_associated_token_account = testAccount(.{0x83} ** 32, .{0xA3} ** 32, false, true, false);
    var owner_associated_token_account = testAccount(.{0x84} ** 32, .{0xA4} ** 32, false, false, false);
    var owner_token_mint_account = testAccount(.{0x85} ** 32, .{0xA5} ** 32, false, false, false);
    var wallet_account = testAccount(.{0x86} ** 32, .{0xA6} ** 32, true, true, false);
    var token_program_account = testAccount(sol.spl_token_program_id, .{0xA7} ** 32, false, false, true);
    var ata_program_account = testAccount(.{0x87} ** 32, .{0xA8} ** 32, false, false, true);

    const nested_ata = toCpiAccountInfo(&nested_associated_token_account);
    const nested_mint = toCpiAccountInfo(&nested_token_mint_account);
    const destination_ata = toCpiAccountInfo(&destination_associated_token_account);
    const owner_ata = toCpiAccountInfo(&owner_associated_token_account);
    const owner_mint = toCpiAccountInfo(&owner_token_mint_account);
    const wallet = toCpiAccountInfo(&wallet_account);
    const token_program = toCpiAccountInfo(&token_program_account);
    const associated_token_program = toCpiAccountInfo(&ata_program_account);

    var scratch: instruction.Scratch(instruction.recover_nested_spec) = undefined;
    const ix = buildRecoverNestedInstruction(
        nested_mint,
        owner_mint,
        wallet,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = recoverNestedRuntimeAccounts(
        nested_ata,
        nested_mint,
        destination_ata,
        owner_ata,
        owner_mint,
        wallet,
        token_program,
        associated_token_program,
    );

    try std.testing.expectEqual(associated_token_program.key(), ix.program_id);
    try std.testing.expectEqual(@as(usize, 7), ix.accounts.len);
    try std.testing.expectEqual(@as(u8, 2), ix.data[0]);
    try std.testing.expectEqualSlices(u8, nested_ata.key(), infos[0].key());
    try std.testing.expectEqualSlices(u8, nested_mint.key(), infos[1].key());
    try std.testing.expectEqualSlices(u8, destination_ata.key(), infos[2].key());
    try std.testing.expectEqualSlices(u8, owner_ata.key(), infos[3].key());
    try std.testing.expectEqualSlices(u8, owner_mint.key(), infos[4].key());
    try std.testing.expectEqualSlices(u8, wallet.key(), infos[5].key());
    try std.testing.expectEqualSlices(u8, token_program.key(), infos[6].key());
    try std.testing.expectEqualSlices(u8, associated_token_program.key(), infos[7].key());
}

test "recoverNested signed fast paths preserve runtime order" {
    var nested_associated_token_account = testAccount(.{0x91} ** 32, .{0xB1} ** 32, false, true, false);
    var nested_token_mint_account = testAccount(.{0x92} ** 32, .{0xB2} ** 32, false, false, false);
    var destination_associated_token_account = testAccount(.{0x93} ** 32, .{0xB3} ** 32, false, true, false);
    var owner_associated_token_account = testAccount(.{0x94} ** 32, .{0xB4} ** 32, false, false, false);
    var owner_token_mint_account = testAccount(.{0x95} ** 32, .{0xB5} ** 32, false, false, false);
    var wallet_account = testAccount(.{0x96} ** 32, .{0xB6} ** 32, false, true, false);
    var token_program_account = testAccount(sol.spl_token_program_id, .{0xB7} ** 32, false, false, true);
    var ata_program_account = testAccount(.{0x97} ** 32, .{0xB8} ** 32, false, false, true);

    const nested_ata = toCpiAccountInfo(&nested_associated_token_account);
    const nested_mint = toCpiAccountInfo(&nested_token_mint_account);
    const destination_ata = toCpiAccountInfo(&destination_associated_token_account);
    const owner_ata = toCpiAccountInfo(&owner_associated_token_account);
    const owner_mint = toCpiAccountInfo(&owner_token_mint_account);
    const wallet = toCpiAccountInfo(&wallet_account);
    const token_program = toCpiAccountInfo(&token_program_account);
    const associated_token_program = toCpiAccountInfo(&ata_program_account);

    var scratch: instruction.Scratch(instruction.recover_nested_spec) = undefined;
    const ix = buildRecoverNestedInstruction(
        nested_mint,
        owner_mint,
        wallet,
        token_program,
        associated_token_program,
        &scratch,
    );
    const infos = recoverNestedRuntimeAccounts(
        nested_ata,
        nested_mint,
        destination_ata,
        owner_ata,
        owner_mint,
        wallet,
        token_program,
        associated_token_program,
    );
    const bump_seed = [_]u8{9};
    const seeds = sol.cpi.seedPack(.{ "wallet", &bump_seed });
    const signer = sol.cpi.Signer.from(&seeds);

    try std.testing.expectError(
        error.InvalidArgument,
        recoverNestedSigned(
            nested_ata,
            nested_mint,
            destination_ata,
            owner_ata,
            owner_mint,
            wallet,
            token_program,
            associated_token_program,
            &.{signer},
        ),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        recoverNestedSignedSingle(
            nested_ata,
            nested_mint,
            destination_ata,
            owner_ata,
            owner_mint,
            wallet,
            token_program,
            associated_token_program,
            .{ "wallet", &bump_seed },
        ),
    );
    try std.testing.expectEqual(associated_token_program.key(), ix.program_id);
    try std.testing.expectEqualSlices(u8, nested_ata.key(), infos[0].key());
    try std.testing.expectEqualSlices(u8, wallet.key(), infos[5].key());
    try std.testing.expectEqualSlices(u8, associated_token_program.key(), infos[7].key());
}
