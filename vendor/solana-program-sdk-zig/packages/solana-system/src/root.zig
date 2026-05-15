//! `solana_system` — shared System Program instruction builders.

const std = @import("std");
const sol = @import("solana_program_sdk");

pub const Pubkey = sol.Pubkey;
pub const AccountMeta = sol.cpi.AccountMeta;
pub const Instruction = sol.cpi.Instruction;
pub const PROGRAM_ID: Pubkey = .{0} ** sol.PUBKEY_BYTES;
pub const RECENT_BLOCKHASHES_ID: Pubkey = sol.pubkey.comptimeFromBase58("SysvarRecentB1ockHashes11111111111111111111");
pub const RENT_ID: Pubkey = sol.rent_id;
pub const MAX_SEED_LEN: usize = sol.pda.MAX_SEED_LEN;
pub const NONCE_STATE_SIZE: u64 = 80;

pub const Error = error{
    SeedTooLong,
};

pub const SystemInstruction = enum(u32) {
    create_account = 0,
    assign = 1,
    transfer = 2,
    create_account_with_seed = 3,
    advance_nonce_account = 4,
    withdraw_nonce_account = 5,
    initialize_nonce_account = 6,
    authorize_nonce_account = 7,
    allocate = 8,
    allocate_with_seed = 9,
    assign_with_seed = 10,
    transfer_with_seed = 11,
    upgrade_nonce_account = 12,
};

pub const CREATE_ACCOUNT_DATA_LEN: usize = 4 + 8 + 8 + sol.PUBKEY_BYTES;
pub const TRANSFER_DATA_LEN: usize = 4 + 8;
pub const ASSIGN_DATA_LEN: usize = 4 + sol.PUBKEY_BYTES;
pub const ALLOCATE_DATA_LEN: usize = 4 + 8;
pub const CREATE_ACCOUNT_WITH_SEED_DATA_CAPACITY: usize = 4 + sol.PUBKEY_BYTES + 8 + MAX_SEED_LEN + 8 + 8 + sol.PUBKEY_BYTES;
pub const ASSIGN_WITH_SEED_DATA_CAPACITY: usize = 4 + sol.PUBKEY_BYTES + 8 + MAX_SEED_LEN + sol.PUBKEY_BYTES;
pub const ALLOCATE_WITH_SEED_DATA_CAPACITY: usize = 4 + sol.PUBKEY_BYTES + 8 + MAX_SEED_LEN + 8 + sol.PUBKEY_BYTES;
pub const TRANSFER_WITH_SEED_DATA_CAPACITY: usize = 4 + 8 + 8 + MAX_SEED_LEN + sol.PUBKEY_BYTES;
pub const NONCE_AUTHORITY_DATA_LEN: usize = 4 + sol.PUBKEY_BYTES;
pub const DISCRIMINANT_ONLY_DATA_LEN: usize = 4;

pub const CreateAccountData = [CREATE_ACCOUNT_DATA_LEN]u8;
pub const TransferData = [TRANSFER_DATA_LEN]u8;
pub const AssignData = [ASSIGN_DATA_LEN]u8;
pub const AllocateData = [ALLOCATE_DATA_LEN]u8;
pub const CreateAccountWithSeedData = [CREATE_ACCOUNT_WITH_SEED_DATA_CAPACITY]u8;
pub const AssignWithSeedData = [ASSIGN_WITH_SEED_DATA_CAPACITY]u8;
pub const AllocateWithSeedData = [ALLOCATE_WITH_SEED_DATA_CAPACITY]u8;
pub const TransferWithSeedData = [TRANSFER_WITH_SEED_DATA_CAPACITY]u8;
pub const NonceAuthorityData = [NONCE_AUTHORITY_DATA_LEN]u8;
pub const DiscriminantOnlyData = [DISCRIMINANT_ONLY_DATA_LEN]u8;

pub fn createAccount(
    from: *const Pubkey,
    to: *const Pubkey,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
    metas: *[2]AccountMeta,
    data: *CreateAccountData,
) Instruction {
    writeDiscriminant(.create_account, data[0..]);
    std.mem.writeInt(u64, data[4..12], lamports, .little);
    std.mem.writeInt(u64, data[12..20], space, .little);
    @memcpy(data[20..52], owner);

    metas[0] = AccountMeta.signerWritable(from);
    metas[1] = AccountMeta.signerWritable(to);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = data };
}

pub fn transfer(
    from: *const Pubkey,
    to: *const Pubkey,
    lamports: u64,
    metas: *[2]AccountMeta,
    data: *TransferData,
) Instruction {
    writeDiscriminant(.transfer, data[0..]);
    std.mem.writeInt(u64, data[4..12], lamports, .little);

    metas[0] = AccountMeta.signerWritable(from);
    metas[1] = AccountMeta.writable(to);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = data };
}

pub fn assign(
    account: *const Pubkey,
    owner: *const Pubkey,
    metas: *[1]AccountMeta,
    data: *AssignData,
) Instruction {
    writeDiscriminant(.assign, data[0..]);
    @memcpy(data[4..36], owner);

    metas[0] = AccountMeta.signerWritable(account);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = data };
}

pub fn allocate(
    account: *const Pubkey,
    space: u64,
    metas: *[1]AccountMeta,
    data: *AllocateData,
) Instruction {
    writeDiscriminant(.allocate, data[0..]);
    std.mem.writeInt(u64, data[4..12], space, .little);

    metas[0] = AccountMeta.signerWritable(account);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = data };
}

pub fn createAccountWithSeed(
    from: *const Pubkey,
    to: *const Pubkey,
    base: *const Pubkey,
    seed: []const u8,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
    metas: *[2]AccountMeta,
    data: *CreateAccountWithSeedData,
) Error!Instruction {
    if (seed.len > MAX_SEED_LEN) return error.SeedTooLong;
    var cursor = Cursor.init(data);
    cursor.writeDiscriminant(.create_account_with_seed);
    cursor.writePubkey(base);
    cursor.writeSeed(seed);
    cursor.writeU64(lamports);
    cursor.writeU64(space);
    cursor.writePubkey(owner);

    metas[0] = AccountMeta.signerWritable(from);
    metas[1] = AccountMeta.writable(to);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = cursor.written() };
}

pub fn assignWithSeed(
    account: *const Pubkey,
    base: *const Pubkey,
    seed: []const u8,
    owner: *const Pubkey,
    metas: *[2]AccountMeta,
    data: *AssignWithSeedData,
) Error!Instruction {
    if (seed.len > MAX_SEED_LEN) return error.SeedTooLong;
    var cursor = Cursor.init(data);
    cursor.writeDiscriminant(.assign_with_seed);
    cursor.writePubkey(base);
    cursor.writeSeed(seed);
    cursor.writePubkey(owner);

    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.signer(base);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = cursor.written() };
}

pub fn allocateWithSeed(
    account: *const Pubkey,
    base: *const Pubkey,
    seed: []const u8,
    space: u64,
    owner: *const Pubkey,
    metas: *[2]AccountMeta,
    data: *AllocateWithSeedData,
) Error!Instruction {
    if (seed.len > MAX_SEED_LEN) return error.SeedTooLong;
    var cursor = Cursor.init(data);
    cursor.writeDiscriminant(.allocate_with_seed);
    cursor.writePubkey(base);
    cursor.writeSeed(seed);
    cursor.writeU64(space);
    cursor.writePubkey(owner);

    metas[0] = AccountMeta.writable(account);
    metas[1] = AccountMeta.signer(base);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = cursor.written() };
}

pub fn transferWithSeed(
    from: *const Pubkey,
    base: *const Pubkey,
    to: *const Pubkey,
    from_seed: []const u8,
    from_owner: *const Pubkey,
    lamports: u64,
    metas: *[3]AccountMeta,
    data: *TransferWithSeedData,
) Error!Instruction {
    if (from_seed.len > MAX_SEED_LEN) return error.SeedTooLong;
    var cursor = Cursor.init(data);
    cursor.writeDiscriminant(.transfer_with_seed);
    cursor.writeU64(lamports);
    cursor.writeSeed(from_seed);
    cursor.writePubkey(from_owner);

    metas[0] = AccountMeta.writable(from);
    metas[1] = AccountMeta.signer(base);
    metas[2] = AccountMeta.writable(to);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = cursor.written() };
}

pub fn initializeNonceAccount(
    nonce_account: *const Pubkey,
    recent_blockhashes_sysvar: *const Pubkey,
    rent_sysvar: *const Pubkey,
    authority: *const Pubkey,
    metas: *[3]AccountMeta,
    data: *NonceAuthorityData,
) Instruction {
    writeDiscriminant(.initialize_nonce_account, data[0..]);
    @memcpy(data[4..36], authority);

    metas[0] = AccountMeta.writable(nonce_account);
    metas[1] = AccountMeta.readonly(recent_blockhashes_sysvar);
    metas[2] = AccountMeta.readonly(rent_sysvar);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = data };
}

pub fn advanceNonceAccount(
    nonce_account: *const Pubkey,
    recent_blockhashes_sysvar: *const Pubkey,
    authorized: *const Pubkey,
    metas: *[3]AccountMeta,
    data: *DiscriminantOnlyData,
) Instruction {
    writeDiscriminant(.advance_nonce_account, data[0..]);

    metas[0] = AccountMeta.writable(nonce_account);
    metas[1] = AccountMeta.readonly(recent_blockhashes_sysvar);
    metas[2] = AccountMeta.signer(authorized);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = data };
}

pub fn withdrawNonceAccount(
    nonce_account: *const Pubkey,
    to: *const Pubkey,
    recent_blockhashes_sysvar: *const Pubkey,
    rent_sysvar: *const Pubkey,
    authorized: *const Pubkey,
    lamports: u64,
    metas: *[5]AccountMeta,
    data: *TransferData,
) Instruction {
    writeDiscriminant(.withdraw_nonce_account, data[0..]);
    std.mem.writeInt(u64, data[4..12], lamports, .little);

    metas[0] = AccountMeta.writable(nonce_account);
    metas[1] = AccountMeta.writable(to);
    metas[2] = AccountMeta.readonly(recent_blockhashes_sysvar);
    metas[3] = AccountMeta.readonly(rent_sysvar);
    metas[4] = AccountMeta.signer(authorized);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = data };
}

pub fn authorizeNonceAccount(
    nonce_account: *const Pubkey,
    authorized: *const Pubkey,
    new_authority: *const Pubkey,
    metas: *[2]AccountMeta,
    data: *NonceAuthorityData,
) Instruction {
    writeDiscriminant(.authorize_nonce_account, data[0..]);
    @memcpy(data[4..36], new_authority);

    metas[0] = AccountMeta.writable(nonce_account);
    metas[1] = AccountMeta.signer(authorized);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = data };
}

pub fn upgradeNonceAccount(
    nonce_account: *const Pubkey,
    metas: *[1]AccountMeta,
    data: *DiscriminantOnlyData,
) Instruction {
    writeDiscriminant(.upgrade_nonce_account, data[0..]);
    metas[0] = AccountMeta.writable(nonce_account);
    return .{ .program_id = &PROGRAM_ID, .accounts = metas, .data = data };
}

fn writeDiscriminant(tag: SystemInstruction, data: []u8) void {
    std.debug.assert(data.len >= 4);
    std.mem.writeInt(u32, data[0..4], @intFromEnum(tag), .little);
}

const Cursor = struct {
    buf: []u8,
    len: usize = 0,

    fn init(buf: []u8) Cursor {
        return .{ .buf = buf };
    }

    fn writeDiscriminant(self: *Cursor, tag: SystemInstruction) void {
        self.writeU32(@intFromEnum(tag));
    }

    fn writeU32(self: *Cursor, value: u32) void {
        std.mem.writeInt(u32, self.buf[self.len..][0..4], value, .little);
        self.len += 4;
    }

    fn writeU64(self: *Cursor, value: u64) void {
        std.mem.writeInt(u64, self.buf[self.len..][0..8], value, .little);
        self.len += 8;
    }

    fn writePubkey(self: *Cursor, key: *const Pubkey) void {
        @memcpy(self.buf[self.len..][0..sol.PUBKEY_BYTES], key);
        self.len += sol.PUBKEY_BYTES;
    }

    fn writeSeed(self: *Cursor, seed: []const u8) void {
        self.writeU64(seed.len);
        @memcpy(self.buf[self.len..][0..seed.len], seed);
        self.len += seed.len;
    }

    fn written(self: Cursor) []const u8 {
        return self.buf[0..self.len];
    }
};

test "transfer builds canonical system transfer instruction" {
    const from: Pubkey = .{1} ** sol.PUBKEY_BYTES;
    const to: Pubkey = .{2} ** sol.PUBKEY_BYTES;
    var metas: [2]AccountMeta = undefined;
    var data: TransferData = undefined;

    const ix = transfer(&from, &to, 500, &metas, &data);
    try std.testing.expectEqualSlices(u8, &PROGRAM_ID, ix.program_id);
    try std.testing.expectEqual(@as(usize, 2), ix.accounts.len);
    try std.testing.expectEqual(@as(u8, 1), ix.accounts[0].is_signer);
    try std.testing.expectEqual(@as(u8, 1), ix.accounts[0].is_writable);
    try std.testing.expectEqual(@as(u8, 0), ix.accounts[1].is_signer);
    try std.testing.expectEqual(@as(u8, 1), ix.accounts[1].is_writable);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0xf4, 0x01, 0, 0, 0, 0, 0, 0 }, ix.data);
}

test "createAccount builds canonical system create-account instruction" {
    const from: Pubkey = .{1} ** sol.PUBKEY_BYTES;
    const to: Pubkey = .{2} ** sol.PUBKEY_BYTES;
    const owner: Pubkey = .{3} ** sol.PUBKEY_BYTES;
    var metas: [2]AccountMeta = undefined;
    var data: CreateAccountData = undefined;

    const ix = createAccount(&from, &to, 1_000, 128, &owner, &metas, &data);
    try std.testing.expectEqual(@as(usize, CREATE_ACCOUNT_DATA_LEN), ix.data.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ix.data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 1_000), std.mem.readInt(u64, ix.data[4..12], .little));
    try std.testing.expectEqual(@as(u64, 128), std.mem.readInt(u64, ix.data[12..20], .little));
    try std.testing.expectEqualSlices(u8, &owner, ix.data[20..52]);
    try std.testing.expectEqual(@as(u8, 1), ix.accounts[0].is_signer);
    try std.testing.expectEqual(@as(u8, 1), ix.accounts[1].is_signer);
}

test "assign and allocate build canonical payloads" {
    const account: Pubkey = .{1} ** sol.PUBKEY_BYTES;
    const owner: Pubkey = .{9} ** sol.PUBKEY_BYTES;

    var assign_metas: [1]AccountMeta = undefined;
    var assign_data: AssignData = undefined;
    const assign_ix = assign(&account, &owner, &assign_metas, &assign_data);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, assign_ix.data[0..4], .little));
    try std.testing.expectEqualSlices(u8, &owner, assign_ix.data[4..36]);

    var allocate_metas: [1]AccountMeta = undefined;
    var allocate_data: AllocateData = undefined;
    const allocate_ix = allocate(&account, 4096, &allocate_metas, &allocate_data);
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, allocate_ix.data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 4096), std.mem.readInt(u64, allocate_ix.data[4..12], .little));
}

test "seeded builders encode variable seed payloads" {
    const from: Pubkey = .{1} ** sol.PUBKEY_BYTES;
    const to: Pubkey = .{2} ** sol.PUBKEY_BYTES;
    const base: Pubkey = .{3} ** sol.PUBKEY_BYTES;
    const owner: Pubkey = .{4} ** sol.PUBKEY_BYTES;

    var create_metas: [2]AccountMeta = undefined;
    var create_data: CreateAccountWithSeedData = undefined;
    const create_ix = try createAccountWithSeed(&from, &to, &base, "seed", 10, 20, &owner, &create_metas, &create_data);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, create_ix.data[0..4], .little));
    try std.testing.expectEqualSlices(u8, &base, create_ix.data[4..36]);
    try std.testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, create_ix.data[36..44], .little));
    try std.testing.expectEqualStrings("seed", create_ix.data[44..48]);
    try std.testing.expectEqual(@as(u64, 10), std.mem.readInt(u64, create_ix.data[48..56], .little));
    try std.testing.expectEqual(@as(u64, 20), std.mem.readInt(u64, create_ix.data[56..64], .little));
    try std.testing.expectEqualSlices(u8, &owner, create_ix.data[64..96]);
    try std.testing.expectEqual(@as(u8, 1), create_ix.accounts[0].is_signer);
    try std.testing.expectEqual(@as(u8, 0), create_ix.accounts[1].is_signer);

    var transfer_metas: [3]AccountMeta = undefined;
    var transfer_data: TransferWithSeedData = undefined;
    const transfer_ix = try transferWithSeed(&from, &base, &to, "seed", &owner, 500, &transfer_metas, &transfer_data);
    try std.testing.expectEqual(@as(u32, 11), std.mem.readInt(u32, transfer_ix.data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 500), std.mem.readInt(u64, transfer_ix.data[4..12], .little));
    try std.testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, transfer_ix.data[12..20], .little));
    try std.testing.expectEqualStrings("seed", transfer_ix.data[20..24]);
    try std.testing.expectEqualSlices(u8, &owner, transfer_ix.data[24..56]);
    try std.testing.expectEqual(@as(u8, 1), transfer_ix.accounts[1].is_signer);
}

test "seeded assign allocate reject too-long seeds" {
    const account: Pubkey = .{1} ** sol.PUBKEY_BYTES;
    const base: Pubkey = .{2} ** sol.PUBKEY_BYTES;
    const owner: Pubkey = .{3} ** sol.PUBKEY_BYTES;
    const long_seed = "abcdefghijklmnopqrstuvwxyz0123456";

    var assign_metas: [2]AccountMeta = undefined;
    var assign_data: AssignWithSeedData = undefined;
    try std.testing.expectError(
        error.SeedTooLong,
        assignWithSeed(&account, &base, long_seed, &owner, &assign_metas, &assign_data),
    );

    var allocate_metas: [2]AccountMeta = undefined;
    var allocate_data: AllocateWithSeedData = undefined;
    const allocate_ix = try allocateWithSeed(&account, &base, "seed", 64, &owner, &allocate_metas, &allocate_data);
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, allocate_ix.data[0..4], .little));
}

test "nonce builders encode canonical accounts and payloads" {
    const nonce: Pubkey = .{1} ** sol.PUBKEY_BYTES;
    const to: Pubkey = .{2} ** sol.PUBKEY_BYTES;
    const auth: Pubkey = .{3} ** sol.PUBKEY_BYTES;
    const new_auth: Pubkey = .{4} ** sol.PUBKEY_BYTES;

    var init_metas: [3]AccountMeta = undefined;
    var authority_data: NonceAuthorityData = undefined;
    const init_ix = initializeNonceAccount(&nonce, &RECENT_BLOCKHASHES_ID, &RENT_ID, &auth, &init_metas, &authority_data);
    try std.testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, init_ix.data[0..4], .little));
    try std.testing.expectEqualSlices(u8, &auth, init_ix.data[4..36]);
    try std.testing.expectEqual(@as(u8, 0), init_ix.accounts[1].is_writable);

    var withdraw_metas: [5]AccountMeta = undefined;
    var withdraw_data: TransferData = undefined;
    const withdraw_ix = withdrawNonceAccount(&nonce, &to, &RECENT_BLOCKHASHES_ID, &RENT_ID, &auth, 42, &withdraw_metas, &withdraw_data);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, withdraw_ix.data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, withdraw_ix.data[4..12], .little));
    try std.testing.expectEqual(@as(u8, 1), withdraw_ix.accounts[4].is_signer);

    var authorize_metas: [2]AccountMeta = undefined;
    var authorize_data: NonceAuthorityData = undefined;
    const authorize_ix = authorizeNonceAccount(&nonce, &auth, &new_auth, &authorize_metas, &authorize_data);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, authorize_ix.data[0..4], .little));
    try std.testing.expectEqualSlices(u8, &new_auth, authorize_ix.data[4..36]);
}

test "nonce discriminant-only builders encode canonical tags" {
    const nonce: Pubkey = .{1} ** sol.PUBKEY_BYTES;
    const auth: Pubkey = .{2} ** sol.PUBKEY_BYTES;

    var advance_metas: [3]AccountMeta = undefined;
    var advance_data: DiscriminantOnlyData = undefined;
    const advance_ix = advanceNonceAccount(&nonce, &RECENT_BLOCKHASHES_ID, &auth, &advance_metas, &advance_data);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, advance_ix.data[0..4], .little));
    try std.testing.expectEqual(@as(u8, 1), advance_ix.accounts[2].is_signer);

    var upgrade_metas: [1]AccountMeta = undefined;
    var upgrade_data: DiscriminantOnlyData = undefined;
    const upgrade_ix = upgradeNonceAccount(&nonce, &upgrade_metas, &upgrade_data);
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, upgrade_ix.data[0..4], .little));
    try std.testing.expectEqual(@as(u8, 1), upgrade_ix.accounts[0].is_writable);
}

test "public surface guards" {
    try std.testing.expect(@hasDecl(@This(), "createAccount"));
    try std.testing.expect(@hasDecl(@This(), "transfer"));
    try std.testing.expect(@hasDecl(@This(), "assign"));
    try std.testing.expect(@hasDecl(@This(), "allocate"));
    try std.testing.expect(@hasDecl(@This(), "createAccountWithSeed"));
    try std.testing.expect(@hasDecl(@This(), "initializeNonceAccount"));
    try std.testing.expect(@hasDecl(@This(), "withdrawNonceAccount"));
    try std.testing.expect(!@hasDecl(@This(), "rpc"));
    try std.testing.expect(!@hasDecl(@This(), "wallet"));
}
