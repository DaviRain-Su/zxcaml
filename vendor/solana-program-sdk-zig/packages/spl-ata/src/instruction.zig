//! SPL Associated Token Account instruction builders — dual-target.
//!
//! Builders construct allocation-free `sol.cpi.Instruction` values
//! using caller-owned scratch, matching the sibling SPL package
//! patterns in this repository.

const std = @import("std");
const sol = @import("solana_program_sdk");
const derivation = @import("derivation.zig");
const id = @import("id.zig");

const Pubkey = sol.Pubkey;
const AccountMeta = sol.cpi.AccountMeta;
const Instruction = sol.cpi.Instruction;

pub const AssociatedTokenAccountInstruction = enum(u8) {
    create = 0,
    create_idempotent = 1,
    recover_nested = 2,
};

pub const Spec = struct {
    disc: AssociatedTokenAccountInstruction,
    accounts_len: usize,
    data_len: usize,
};

pub const create_spec: Spec = .{
    .disc = .create,
    .accounts_len = 6,
    .data_len = 1,
};

pub const create_idempotent_spec: Spec = .{
    .disc = .create_idempotent,
    .accounts_len = 6,
    .data_len = 1,
};

pub const recover_nested_spec: Spec = .{
    .disc = .recover_nested,
    .accounts_len = 7,
    .data_len = 1,
};

pub fn metasArray(comptime spec: Spec) type {
    return [spec.accounts_len]AccountMeta;
}

pub fn dataArray(comptime spec: Spec) type {
    return [spec.data_len]u8;
}

pub fn Scratch(comptime spec: Spec) type {
    return struct {
        associated_token_account: Pubkey = undefined,
        owner_associated_token_account: Pubkey = undefined,
        destination_associated_token_account: Pubkey = undefined,
        nested_associated_token_account: Pubkey = undefined,
        metas: metasArray(spec) = undefined,
        data: dataArray(spec) = undefined,
    };
}

comptime {
    const DISC_LEN: usize = 1;
    const audits = .{
        .{ create_spec, 6 },
        .{ create_idempotent_spec, 6 },
        .{ recover_nested_spec, 7 },
    };

    for (audits) |audit| {
        const spec: Spec = audit[0];
        const want_accounts: usize = audit[1];
        if (spec.accounts_len != want_accounts) {
            @compileError(std.fmt.comptimePrint(
                "spl-ata spec drift: {s} accounts_len={d} but protocol says {d}",
                .{ @tagName(spec.disc), spec.accounts_len, want_accounts },
            ));
        }
        if (spec.data_len != DISC_LEN) {
            @compileError(std.fmt.comptimePrint(
                "spl-ata spec drift: {s} data_len={d} but protocol says 1",
                .{ @tagName(spec.disc), spec.data_len },
            ));
        }
    }
}

fn buildInstruction(
    comptime spec: Spec,
    payer: *const Pubkey,
    associated_token_account: *const Pubkey,
    wallet: *const Pubkey,
    mint: *const Pubkey,
    system_program: *const Pubkey,
    token_program: *const Pubkey,
    scratch: *Scratch(spec),
) Instruction {
    scratch.data = .{@intFromEnum(spec.disc)};
    scratch.metas[0] = AccountMeta.signerWritable(payer);
    scratch.metas[1] = AccountMeta.writable(associated_token_account);
    scratch.metas[2] = AccountMeta.readonly(wallet);
    scratch.metas[3] = AccountMeta.readonly(mint);
    scratch.metas[4] = AccountMeta.readonly(system_program);
    scratch.metas[5] = AccountMeta.readonly(token_program);
    return Instruction.init(&id.PROGRAM_ID, &scratch.metas, &scratch.data);
}

pub fn create(
    payer: *const Pubkey,
    wallet: *const Pubkey,
    mint: *const Pubkey,
    system_program: *const Pubkey,
    token_program: *const Pubkey,
    scratch: *Scratch(create_spec),
) Instruction {
    scratch.associated_token_account = derivation.findAddress(
        wallet,
        mint,
        token_program,
    ).address;
    return createForAddress(
        payer,
        &scratch.associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        scratch,
    );
}

pub fn createForAddress(
    payer: *const Pubkey,
    associated_token_account: *const Pubkey,
    wallet: *const Pubkey,
    mint: *const Pubkey,
    system_program: *const Pubkey,
    token_program: *const Pubkey,
    scratch: *Scratch(create_spec),
) Instruction {
    return buildInstruction(
        create_spec,
        payer,
        associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        scratch,
    );
}

pub fn createIdempotent(
    payer: *const Pubkey,
    wallet: *const Pubkey,
    mint: *const Pubkey,
    system_program: *const Pubkey,
    token_program: *const Pubkey,
    scratch: *Scratch(create_idempotent_spec),
) Instruction {
    scratch.associated_token_account = derivation.findAddress(
        wallet,
        mint,
        token_program,
    ).address;
    return createIdempotentForAddress(
        payer,
        &scratch.associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        scratch,
    );
}

pub fn createIdempotentForAddress(
    payer: *const Pubkey,
    associated_token_account: *const Pubkey,
    wallet: *const Pubkey,
    mint: *const Pubkey,
    system_program: *const Pubkey,
    token_program: *const Pubkey,
    scratch: *Scratch(create_idempotent_spec),
) Instruction {
    return buildInstruction(
        create_idempotent_spec,
        payer,
        associated_token_account,
        wallet,
        mint,
        system_program,
        token_program,
        scratch,
    );
}

pub fn recoverNested(
    wallet: *const Pubkey,
    owner_token_mint: *const Pubkey,
    nested_token_mint: *const Pubkey,
    token_program: *const Pubkey,
    scratch: *Scratch(recover_nested_spec),
) Instruction {
    scratch.owner_associated_token_account = derivation.findAddress(
        wallet,
        owner_token_mint,
        token_program,
    ).address;
    scratch.destination_associated_token_account = derivation.findAddress(
        wallet,
        nested_token_mint,
        token_program,
    ).address;
    scratch.nested_associated_token_account = derivation.findAddress(
        &scratch.owner_associated_token_account,
        nested_token_mint,
        token_program,
    ).address;
    return recoverNestedForAddresses(
        wallet,
        owner_token_mint,
        nested_token_mint,
        &scratch.owner_associated_token_account,
        &scratch.destination_associated_token_account,
        &scratch.nested_associated_token_account,
        token_program,
        scratch,
    );
}

pub fn recoverNestedForAddresses(
    wallet: *const Pubkey,
    owner_token_mint: *const Pubkey,
    nested_token_mint: *const Pubkey,
    owner_associated_token_account: *const Pubkey,
    destination_associated_token_account: *const Pubkey,
    nested_associated_token_account: *const Pubkey,
    token_program: *const Pubkey,
    scratch: *Scratch(recover_nested_spec),
) Instruction {
    scratch.data = .{@intFromEnum(recover_nested_spec.disc)};
    scratch.metas[0] = AccountMeta.writable(nested_associated_token_account);
    scratch.metas[1] = AccountMeta.readonly(nested_token_mint);
    scratch.metas[2] = AccountMeta.writable(destination_associated_token_account);
    scratch.metas[3] = AccountMeta.readonly(owner_associated_token_account);
    scratch.metas[4] = AccountMeta.readonly(owner_token_mint);
    scratch.metas[5] = AccountMeta.signerWritable(wallet);
    scratch.metas[6] = AccountMeta.readonly(token_program);
    return Instruction.init(&id.PROGRAM_ID, &scratch.metas, &scratch.data);
}

fn expectMeta(
    actual: AccountMeta,
    expected_key: *const Pubkey,
    expected_writable: u8,
    expected_signer: u8,
) !void {
    try std.testing.expectEqual(expected_key, actual.pubkey);
    try std.testing.expectEqual(expected_writable, actual.is_writable);
    try std.testing.expectEqual(expected_signer, actual.is_signer);
}

fn expectMetaBytes(
    actual: AccountMeta,
    expected_key: *const Pubkey,
    expected_writable: u8,
    expected_signer: u8,
) !void {
    try std.testing.expectEqualSlices(u8, expected_key, actual.pubkey);
    try std.testing.expectEqual(expected_writable, actual.is_writable);
    try std.testing.expectEqual(expected_signer, actual.is_signer);
}

test "spec helpers expose canonical ATA wire lengths" {
    try std.testing.expectEqual(@as(usize, 6), create_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 1), create_spec.data_len);
    try std.testing.expectEqual(@as(usize, 6), create_idempotent_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 1), create_idempotent_spec.data_len);
    try std.testing.expectEqual(@as(usize, 7), recover_nested_spec.accounts_len);
    try std.testing.expectEqual(@as(usize, 1), recover_nested_spec.data_len);

    const create_scratch: Scratch(create_spec) = undefined;
    const create_idempotent_scratch: Scratch(create_idempotent_spec) = undefined;
    const recover_nested_scratch: Scratch(recover_nested_spec) = undefined;
    try std.testing.expectEqual(@as(usize, 6), create_scratch.metas.len);
    try std.testing.expectEqual(@as(usize, 1), create_scratch.data.len);
    try std.testing.expectEqual(@as(usize, 6), create_idempotent_scratch.metas.len);
    try std.testing.expectEqual(@as(usize, 1), create_idempotent_scratch.data.len);
    try std.testing.expectEqual(@as(usize, 7), recover_nested_scratch.metas.len);
    try std.testing.expectEqual(@as(usize, 1), recover_nested_scratch.data.len);
}

test "create emits canonical metas, ATA callee, and [0] discriminator" {
    const payer: Pubkey = .{0x11} ** 32;
    const wallet: Pubkey = .{0x22} ** 32;
    const mint: Pubkey = .{0x33} ** 32;
    const system_program: Pubkey = sol.system_program_id;
    const token_program: Pubkey = sol.spl_token_program_id;
    const expected_ata = derivation.findAddress(&wallet, &mint, &token_program);

    var scratch: Scratch(create_spec) = undefined;
    const ix = create(
        &payer,
        &wallet,
        &mint,
        &system_program,
        &token_program,
        &scratch,
    );

    try std.testing.expectEqual(&id.PROGRAM_ID, ix.program_id);
    try std.testing.expectEqual(@as(usize, 6), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), ix.data.len);
    try std.testing.expectEqual(@as(u8, 0), ix.data[0]);

    try expectMeta(ix.accounts[0], &payer, 1, 1);
    try expectMeta(ix.accounts[1], &scratch.associated_token_account, 1, 0);
    try std.testing.expectEqualSlices(u8, &expected_ata.address, ix.accounts[1].pubkey);
    try expectMeta(ix.accounts[2], &wallet, 0, 0);
    try expectMeta(ix.accounts[3], &mint, 0, 0);
    try expectMeta(ix.accounts[4], &system_program, 0, 0);
    try expectMeta(ix.accounts[5], &token_program, 0, 0);
}

test "createIdempotent emits create metas with [1] discriminator" {
    const payer: Pubkey = .{0x44} ** 32;
    const wallet: Pubkey = .{0x55} ** 32;
    const mint: Pubkey = .{0x66} ** 32;
    const system_program: Pubkey = sol.system_program_id;
    const token_program: Pubkey = sol.spl_token_program_id;

    var create_scratch: Scratch(create_spec) = undefined;
    create_scratch.associated_token_account = payer;
    var idempotent_scratch: Scratch(create_idempotent_spec) = undefined;
    idempotent_scratch.associated_token_account = payer;

    const create_ix = create(
        &payer,
        &wallet,
        &mint,
        &system_program,
        &token_program,
        &create_scratch,
    );
    const idempotent_ix = createIdempotent(
        &payer,
        &wallet,
        &mint,
        &system_program,
        &token_program,
        &idempotent_scratch,
    );

    try std.testing.expectEqual(&id.PROGRAM_ID, idempotent_ix.program_id);
    try std.testing.expectEqual(@as(usize, 6), idempotent_ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), idempotent_ix.data.len);
    try std.testing.expectEqual(@as(u8, 1), idempotent_ix.data[0]);

    for (create_ix.accounts, idempotent_ix.accounts) |create_meta, idempotent_meta| {
        try expectMetaBytes(
            idempotent_meta,
            create_meta.pubkey,
            create_meta.is_writable,
            create_meta.is_signer,
        );
    }
}

test "precomputed address builders avoid PDA derivation scratch dependency" {
    const payer: Pubkey = .{0x41} ** 32;
    const wallet: Pubkey = .{0x42} ** 32;
    const mint: Pubkey = .{0x43} ** 32;
    const associated_token_account: Pubkey = .{0x44} ** 32;
    const system_program: Pubkey = sol.system_program_id;
    const token_program: Pubkey = sol.spl_token_program_id;
    var create_scratch: Scratch(create_spec) = undefined;
    var idempotent_scratch: Scratch(create_idempotent_spec) = undefined;

    const create_ix = createForAddress(
        &payer,
        &associated_token_account,
        &wallet,
        &mint,
        &system_program,
        &token_program,
        &create_scratch,
    );
    const idempotent_ix = createIdempotentForAddress(
        &payer,
        &associated_token_account,
        &wallet,
        &mint,
        &system_program,
        &token_program,
        &idempotent_scratch,
    );

    try expectMeta(create_ix.accounts[1], &associated_token_account, 1, 0);
    try std.testing.expectEqual(@as(u8, 0), create_ix.data[0]);
    try expectMeta(idempotent_ix.accounts[1], &associated_token_account, 1, 0);
    try std.testing.expectEqual(@as(u8, 1), idempotent_ix.data[0]);
}

test "recoverNested derives canonical nested, owner, and destination ATA metas" {
    const wallet: Pubkey = .{0x71} ** 32;
    const owner_token_mint: Pubkey = .{0x72} ** 32;
    const nested_token_mint: Pubkey = .{0x73} ** 32;
    const token_program: Pubkey = sol.spl_token_program_id;

    const owner_associated = derivation.findAddress(
        &wallet,
        &owner_token_mint,
        &token_program,
    );
    const destination_associated = derivation.findAddress(
        &wallet,
        &nested_token_mint,
        &token_program,
    );
    const nested_associated = derivation.findAddress(
        &owner_associated.address,
        &nested_token_mint,
        &token_program,
    );

    var scratch: Scratch(recover_nested_spec) = undefined;
    const ix = recoverNested(
        &wallet,
        &owner_token_mint,
        &nested_token_mint,
        &token_program,
        &scratch,
    );

    try std.testing.expectEqual(&id.PROGRAM_ID, ix.program_id);
    try std.testing.expectEqual(@as(usize, 7), ix.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), ix.data.len);
    try std.testing.expectEqual(@as(u8, 2), ix.data[0]);
    try std.testing.expectEqualSlices(u8, &owner_associated.address, &scratch.owner_associated_token_account);
    try std.testing.expectEqualSlices(u8, &destination_associated.address, &scratch.destination_associated_token_account);
    try std.testing.expectEqualSlices(u8, &nested_associated.address, &scratch.nested_associated_token_account);
    try expectMeta(ix.accounts[0], &scratch.nested_associated_token_account, 1, 0);
    try expectMeta(ix.accounts[1], &nested_token_mint, 0, 0);
    try expectMeta(ix.accounts[2], &scratch.destination_associated_token_account, 1, 0);
    try expectMeta(ix.accounts[3], &scratch.owner_associated_token_account, 0, 0);
    try expectMeta(ix.accounts[4], &owner_token_mint, 0, 0);
    try expectMeta(ix.accounts[5], &wallet, 1, 1);
    try expectMeta(ix.accounts[6], &token_program, 0, 0);
}

test "recoverNestedForAddresses uses caller-provided ATA addresses" {
    const wallet: Pubkey = .{0x81} ** 32;
    const owner_token_mint: Pubkey = .{0x82} ** 32;
    const nested_token_mint: Pubkey = .{0x83} ** 32;
    const owner_associated: Pubkey = .{0x84} ** 32;
    const destination_associated: Pubkey = .{0x85} ** 32;
    const nested_associated: Pubkey = .{0x86} ** 32;
    const token_program: Pubkey = sol.spl_token_program_id;
    var scratch: Scratch(recover_nested_spec) = undefined;

    const ix = recoverNestedForAddresses(
        &wallet,
        &owner_token_mint,
        &nested_token_mint,
        &owner_associated,
        &destination_associated,
        &nested_associated,
        &token_program,
        &scratch,
    );

    try std.testing.expectEqual(@as(u8, 2), ix.data[0]);
    try expectMeta(ix.accounts[0], &nested_associated, 1, 0);
    try expectMeta(ix.accounts[2], &destination_associated, 1, 0);
    try expectMeta(ix.accounts[3], &owner_associated, 0, 0);
    try expectMeta(ix.accounts[5], &wallet, 1, 1);
}

test "builders preserve caller-owned scratch buffers" {
    const payer: Pubkey = .{0x77} ** 32;
    const wallet: Pubkey = .{0x88} ** 32;
    const mint: Pubkey = .{0x99} ** 32;
    const system_program: Pubkey = sol.system_program_id;
    const token_program: Pubkey = sol.spl_token_program_id;

    var scratch: Scratch(create_spec) = undefined;
    const ix = create(
        &payer,
        &wallet,
        &mint,
        &system_program,
        &token_program,
        &scratch,
    );

    try std.testing.expectEqual(@intFromPtr(&scratch.metas[0]), @intFromPtr(ix.accounts.ptr));
    try std.testing.expectEqual(@intFromPtr(&scratch.data[0]), @intFromPtr(ix.data.ptr));
    try std.testing.expectEqual(&scratch.associated_token_account, ix.accounts[1].pubkey);
}

test "token program id stays caller-controlled while ATA callee stays fixed" {
    const payer: Pubkey = .{0xAA} ** 32;
    const wallet: Pubkey = .{0xBB} ** 32;
    const mint: Pubkey = .{0xCC} ** 32;
    const system_program: Pubkey = sol.system_program_id;
    const classic_token_program: Pubkey = sol.spl_token_program_id;
    const token_2022_program: Pubkey = sol.spl_token_2022_program_id;

    var classic_scratch: Scratch(create_spec) = undefined;
    var token_2022_scratch: Scratch(create_spec) = undefined;

    const classic_ix = create(
        &payer,
        &wallet,
        &mint,
        &system_program,
        &classic_token_program,
        &classic_scratch,
    );
    const token_2022_ix = create(
        &payer,
        &wallet,
        &mint,
        &system_program,
        &token_2022_program,
        &token_2022_scratch,
    );

    try std.testing.expectEqual(&id.PROGRAM_ID, classic_ix.program_id);
    try std.testing.expectEqual(&id.PROGRAM_ID, token_2022_ix.program_id);
    try expectMeta(classic_ix.accounts[5], &classic_token_program, 0, 0);
    try expectMeta(token_2022_ix.accounts[5], &token_2022_program, 0, 0);
    try std.testing.expect(
        !sol.pubkey.pubkeyEq(
            classic_ix.accounts[1].pubkey,
            token_2022_ix.accounts[1].pubkey,
        ),
    );
}
