//! SPL Token runtime helpers for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Encode SPL Token Transfer instruction data without heap allocation.
//! - Parse canonical SPL Token account state into zero-copy pubkey views.
//! - Provide the canonical SPL Token program id and Transfer account metas.

const std = @import("std");
const Arena = @import("arena.zig").Arena;
const bs58 = @import("bs58.zig");
const cpi = @import("cpi.zig");
const sdk_spl_token = @import("spl_token_m4");

/// 32-byte Solana public key.
pub const Pubkey = cpi.Pubkey;

/// Length of a Solana public key in bytes.
pub const pubkey_len: usize = @sizeOf(Pubkey);
/// SPL Token Transfer instruction discriminator.
pub const transfer_discriminator: u8 = @intFromEnum(sdk_spl_token.TokenInstruction.transfer);
/// SPL Token Transfer instruction data length: one u8 discriminator plus u64 amount.
pub const transfer_instruction_data_len: usize = sdk_spl_token.transfer_spec.data_len;
/// SPL Token InitializeAccount instruction discriminator.
pub const initialize_account_discriminator: u8 = @intFromEnum(sdk_spl_token.TokenInstruction.initialize_account);
/// SPL Token InitializeAccount instruction data length: one u8 discriminator.
pub const initialize_account_instruction_data_len: usize = sdk_spl_token.initialize_account_spec.data_len;
/// SPL Token InitializeAccount account count: account, mint, owner, rent sysvar.
pub const initialize_account_account_count: usize = sdk_spl_token.initialize_account_spec.accounts_len;
/// SPL Token Burn instruction discriminator.
pub const burn_discriminator: u8 = @intFromEnum(sdk_spl_token.TokenInstruction.burn);
/// SPL Token Burn instruction data length: one u8 discriminator plus u64 amount.
pub const burn_instruction_data_len: usize = sdk_spl_token.burn_spec.data_len;
/// SPL Token Burn account count: account, mint, authority.
pub const burn_account_count: usize = sdk_spl_token.burn_spec.accounts_len;
/// SPL Token CloseAccount instruction discriminator.
pub const close_account_discriminator: u8 = @intFromEnum(sdk_spl_token.TokenInstruction.close_account);
/// SPL Token CloseAccount instruction data length: one u8 discriminator.
pub const close_account_instruction_data_len: usize = sdk_spl_token.close_account_spec.data_len;
/// SPL Token CloseAccount account count: account, destination, authority.
pub const close_account_account_count: usize = sdk_spl_token.close_account_spec.accounts_len;
/// SPL Token Revoke instruction discriminator.
pub const revoke_discriminator: u8 = @intFromEnum(sdk_spl_token.TokenInstruction.revoke);
/// SPL Token Revoke instruction data length: one u8 discriminator.
pub const revoke_instruction_data_len: usize = sdk_spl_token.revoke_spec.data_len;
/// SPL Token Revoke account count: source, authority.
pub const revoke_account_count: usize = sdk_spl_token.revoke_spec.accounts_len;
/// Canonical packed SPL Token account length.
pub const token_account_len: usize = sdk_spl_token.ACCOUNT_LEN;
/// Canonical packed SPL Mint account length.
pub const mint_len: usize = sdk_spl_token.MINT_LEN;
const max_cpi_account_infos: usize = 4;
const pre_original_data_len_padding: usize = 4;
const max_permitted_data_increase: usize = 10 * 1024;
const account_alignment: usize = 8;
const transfer_account_count: usize = 3;

/// Canonical SPL Token program id as base58 for diagnostics and tests.
pub const program_id_base58 = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";

/// Canonical SPL Token program id.
pub const program_id: Pubkey = sdk_spl_token.PROGRAM_ID;

/// Errors returned by SPL Token runtime helpers.
pub const Error = error{
    OutputTooShort,
    TruncatedInput,
    InvalidOptionTag,
    InvalidInstructionDiscriminant,
    InvalidInstructionLength,
};

/// Zero-copy view over the canonical SPL Token account state.
pub const TokenAccountView = struct {
    mint: *const Pubkey,
    owner: *const Pubkey,
    amount: u64,
    delegate: ?*const Pubkey,
    state: u8,
    is_native: ?u64,
    delegated_amount: u64,
    close_authority: ?*const Pubkey,
};

/// Zero-copy view over the canonical SPL Mint account state.
pub const MintView = struct {
    mint_authority: ?*const Pubkey,
    supply: u64,
    decimals: u8,
    is_initialized: u8,
    freeze_authority: ?*const Pubkey,
};

pub const InstructionKind = enum {
    transfer,
    initialize_account,
    burn,
    close_account,
    revoke,
};

/// Writes the canonical SPL Token program id into a caller-owned stack or arena buffer.
pub inline fn writeProgramId(out: *Pubkey) void {
    out.* = program_id;
}

/// Writes an SPL Token program id from either raw bytes or the canonical base58 text.
pub fn writeProgramIdFromBytes(out: *Pubkey, bytes: []const u8) bool {
    if (bytes.len == pubkey_len and std.mem.eql(u8, bytes, &program_id)) {
        writeProgramId(out);
        return true;
    }
    if (bytes.len == program_id_base58.len and std.mem.eql(u8, bytes, program_id_base58)) {
        writeProgramId(out);
        return true;
    }
    return false;
}

/// Encodes SPL Token Transfer instruction data into a fixed-size array.
pub fn encodeTransfer(amount: u64) [transfer_instruction_data_len]u8 {
    var out: [transfer_instruction_data_len]u8 = undefined;
    _ = encodeTransferInto(out[0..], amount) catch unreachable;
    return out;
}

/// Encodes SPL Token Transfer instruction data into `out` and returns the written prefix.
pub fn encodeTransferInto(out: []u8, amount: u64) Error![]const u8 {
    if (out.len < transfer_instruction_data_len) return error.OutputTooShort;
    out[0] = transfer_discriminator;
    writeU64Le(out[1..transfer_instruction_data_len], amount);
    return out[0..transfer_instruction_data_len];
}

/// Encodes SPL Token InitializeAccount instruction data into a fixed-size array.
pub fn encodeInitializeAccount() [initialize_account_instruction_data_len]u8 {
    return .{initialize_account_discriminator};
}

/// Encodes SPL Token InitializeAccount instruction data into `out` and returns the written prefix.
pub fn encodeInitializeAccountInto(out: []u8) Error![]const u8 {
    if (out.len < initialize_account_instruction_data_len) return error.OutputTooShort;
    out[0] = initialize_account_discriminator;
    return out[0..initialize_account_instruction_data_len];
}

/// Builds account metas for Transfer: source writable, destination writable, authority signer.
pub fn transferAccountMetas(source: *const Pubkey, destination: *const Pubkey, authority: *const Pubkey) [3]cpi.SolAccountMeta {
    return .{
        .{ .pubkey = source, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = destination, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = authority, .is_writable = 0, .is_signer = 1 },
    };
}

/// Builds account metas for InitializeAccount: account writable, mint readonly, owner readonly, rent sysvar readonly.
pub fn initializeAccountMetas(account_pubkey: *const Pubkey, mint: *const Pubkey, owner: *const Pubkey, rent_sysvar: *const Pubkey) [initialize_account_account_count]cpi.SolAccountMeta {
    return .{
        .{ .pubkey = account_pubkey, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = mint, .is_writable = 0, .is_signer = 0 },
        .{ .pubkey = owner, .is_writable = 0, .is_signer = 0 },
        .{ .pubkey = rent_sysvar, .is_writable = 0, .is_signer = 0 },
    };
}

/// Builds an SPL Token InitializeAccount instruction using caller-owned meta/data buffers.
pub fn initializeAccountInstruction(
    account_pubkey: *const Pubkey,
    mint: *const Pubkey,
    owner: *const Pubkey,
    rent_sysvar: *const Pubkey,
    metas: *[initialize_account_account_count]cpi.SolAccountMeta,
    data: *[initialize_account_instruction_data_len]u8,
) cpi.SolInstruction {
    _ = rent_sysvar;
    _ = sdk_spl_token.initializeAccount(
        account_pubkey,
        mint,
        owner,
        @ptrCast(metas),
        data,
    );
    return cpi.SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
}

/// Encodes SPL Token Burn instruction data into a fixed-size array.
pub fn encodeBurn(amount: u64) [burn_instruction_data_len]u8 {
    var out: [burn_instruction_data_len]u8 = undefined;
    _ = encodeBurnInto(out[0..], amount) catch unreachable;
    return out;
}

/// Encodes SPL Token Burn instruction data into `out` and returns the written prefix.
pub fn encodeBurnInto(out: []u8, amount: u64) Error![]const u8 {
    if (out.len < burn_instruction_data_len) return error.OutputTooShort;
    out[0] = burn_discriminator;
    writeU64Le(out[1..burn_instruction_data_len], amount);
    return out[0..burn_instruction_data_len];
}

/// Encodes SPL Token CloseAccount instruction data into a fixed-size array.
pub fn encodeCloseAccount() [close_account_instruction_data_len]u8 {
    return .{close_account_discriminator};
}

/// Encodes SPL Token CloseAccount instruction data into `out` and returns the written prefix.
pub fn encodeCloseAccountInto(out: []u8) Error![]const u8 {
    if (out.len < close_account_instruction_data_len) return error.OutputTooShort;
    out[0] = close_account_discriminator;
    return out[0..close_account_instruction_data_len];
}

/// Encodes SPL Token Revoke instruction data into a fixed-size array.
pub fn encodeRevoke() [revoke_instruction_data_len]u8 {
    return .{revoke_discriminator};
}

/// Encodes SPL Token Revoke instruction data into `out` and returns the written prefix.
pub fn encodeRevokeInto(out: []u8) Error![]const u8 {
    if (out.len < revoke_instruction_data_len) return error.OutputTooShort;
    out[0] = revoke_discriminator;
    return out[0..revoke_instruction_data_len];
}

/// Builds account metas for Burn: account writable, mint writable, authority signer.
pub fn burnAccountMetas(account_pubkey: *const Pubkey, mint: *const Pubkey, authority: *const Pubkey) [burn_account_count]cpi.SolAccountMeta {
    return .{
        .{ .pubkey = account_pubkey, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = mint, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = authority, .is_writable = 0, .is_signer = 1 },
    };
}

/// Builds an SPL Token Burn instruction using caller-owned meta/data buffers.
pub fn burnInstruction(
    account_pubkey: *const Pubkey,
    mint: *const Pubkey,
    authority: *const Pubkey,
    amount: u64,
    metas: *[burn_account_count]cpi.SolAccountMeta,
    data: *[burn_instruction_data_len]u8,
) cpi.SolInstruction {
    _ = sdk_spl_token.burn(
        account_pubkey,
        mint,
        authority,
        amount,
        @ptrCast(metas),
        data,
    );
    return cpi.SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
}

/// Builds account metas for CloseAccount: account writable, destination writable, authority signer.
pub fn closeAccountAccountMetas(account_pubkey: *const Pubkey, destination: *const Pubkey, authority: *const Pubkey) [close_account_account_count]cpi.SolAccountMeta {
    return .{
        .{ .pubkey = account_pubkey, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = destination, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = authority, .is_writable = 0, .is_signer = 1 },
    };
}

/// Builds an SPL Token CloseAccount instruction using caller-owned meta/data buffers.
pub fn closeAccountInstruction(
    account_pubkey: *const Pubkey,
    destination: *const Pubkey,
    authority: *const Pubkey,
    metas: *[close_account_account_count]cpi.SolAccountMeta,
    data: *[close_account_instruction_data_len]u8,
) cpi.SolInstruction {
    _ = sdk_spl_token.closeAccount(
        account_pubkey,
        destination,
        authority,
        @ptrCast(metas),
        data,
    );
    return cpi.SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
}

/// Builds account metas for Revoke: source writable, authority signer.
pub fn revokeAccountMetas(source: *const Pubkey, authority: *const Pubkey) [revoke_account_count]cpi.SolAccountMeta {
    return .{
        .{ .pubkey = source, .is_writable = 1, .is_signer = 0 },
        .{ .pubkey = authority, .is_writable = 0, .is_signer = 1 },
    };
}

/// Builds an SPL Token Revoke instruction using caller-owned meta/data buffers.
pub fn revokeInstruction(
    source: *const Pubkey,
    authority: *const Pubkey,
    metas: *[revoke_account_count]cpi.SolAccountMeta,
    data: *[revoke_instruction_data_len]u8,
) cpi.SolInstruction {
    _ = sdk_spl_token.revoke(
        source,
        authority,
        @ptrCast(metas),
        data,
    );
    return cpi.SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
}

/// Parses the first three input accounts and invokes SPL Token Transfer for one token.
pub inline fn zxcaml_transfer_one(arena: *Arena, input: [*]const u8) u64 {
    _ = arena;
    const input_mut: [*]u8 = @constCast(input);
    var cursor: usize = 0;
    const account_count = readU64Raw(input_mut, &cursor);
    if (account_count < 3) return 1;

    var infos: [max_cpi_account_infos]cpi.SolAccountInfo = undefined;
    const info_count: usize = @min(@as(usize, @intCast(account_count)), infos.len);
    for (infos[0..info_count]) |*info| {
        parseAccountInfoNoGrowth(input_mut, &cursor, info);
    }
    var token_program_id: Pubkey = undefined;
    writeProgramId(&token_program_id);
    var source_key = infos[0].key.*;
    var destination_key = infos[1].key.*;
    var authority_key = infos[2].key.*;
    var metas = transferAccountMetas(&source_key, &destination_key, &authority_key);
    var data = encodeTransfer(1);
    const instruction = cpi.SolInstruction.fromSlices(&token_program_id, metas[0..], data[0..]);
    var empty_seed_groups: [1]cpi.SolSignerSeedsC = undefined;
    return cpi.sol_invoke_signed_c(&instruction, infos[0..info_count], empty_seed_groups[0..0]);
}

/// Parses canonical packed SPL Token account data.
pub fn parseTokenAccount(data: []const u8) Error!TokenAccountView {
    if (data.len < token_account_len) return error.TruncatedInput;
    const account_state = sdk_spl_token.Account.fromBytes(data[0..token_account_len]) catch {
        return error.TruncatedInput;
    };
    _ = account_state.delegateKeyChecked() catch return error.InvalidOptionTag;
    const is_native = account_state.nativeRentExemptReserveChecked() catch return error.InvalidOptionTag;
    _ = account_state.closeAuthorityChecked() catch return error.InvalidOptionTag;

    return .{
        .mint = &account_state.mint,
        .owner = &account_state.owner,
        .amount = account_state.amount,
        .delegate = account_state.delegateKey(),
        .state = account_state.state,
        .is_native = is_native,
        .delegated_amount = account_state.delegated_amount,
        .close_authority = account_state.closeAuthority(),
    };
}

pub fn parseMint(data: []const u8) Error!MintView {
    if (data.len < mint_len) return error.TruncatedInput;
    const mint_state = sdk_spl_token.Mint.fromBytes(data[0..mint_len]) catch {
        return error.TruncatedInput;
    };
    _ = mint_state.mintAuthorityChecked() catch return error.InvalidOptionTag;
    _ = mint_state.freezeAuthorityChecked() catch return error.InvalidOptionTag;

    return .{
        .mint_authority = mint_state.mintAuthority(),
        .supply = mint_state.supply,
        .decimals = mint_state.decimals,
        .is_initialized = mint_state.is_initialized,
        .freeze_authority = mint_state.freezeAuthority(),
    };
}

pub fn validateInstructionData(data: []const u8) Error!InstructionKind {
    if (data.len == 0) return error.InvalidInstructionLength;
    return switch (data[0]) {
        transfer_discriminator => if (data.len == transfer_instruction_data_len) .transfer else error.InvalidInstructionLength,
        initialize_account_discriminator => if (data.len == initialize_account_instruction_data_len) .initialize_account else error.InvalidInstructionLength,
        burn_discriminator => if (data.len == burn_instruction_data_len) .burn else error.InvalidInstructionLength,
        close_account_discriminator => if (data.len == close_account_instruction_data_len) .close_account else error.InvalidInstructionLength,
        revoke_discriminator => if (data.len == revoke_instruction_data_len) .revoke else error.InvalidInstructionLength,
        else => error.InvalidInstructionDiscriminant,
    };
}

fn readPubkeyPtr(data: []const u8, cursor: *usize) Error!*const Pubkey {
    if (data.len -| cursor.* < pubkey_len) return error.TruncatedInput;
    const ptr: *const Pubkey = @ptrCast(data.ptr + cursor.*);
    cursor.* += pubkey_len;
    return ptr;
}

inline fn parseAccountInfoNoGrowth(input: [*]u8, cursor: *usize, out: *cpi.SolAccountInfo) void {
    _ = input[cursor.*];
    cursor.* += 1;
    const is_signer = input[cursor.*];
    cursor.* += 1;
    const is_writable = input[cursor.*];
    cursor.* += 1;
    const executable = input[cursor.*];
    cursor.* += 1;
    cursor.* += pre_original_data_len_padding;
    const key: *const Pubkey = @ptrCast(input + cursor.*);
    cursor.* += pubkey_len;
    const owner: *const Pubkey = @ptrCast(input + cursor.*);
    cursor.* += pubkey_len;
    const lamports: *align(1) u64 = @ptrCast(input + cursor.*);
    cursor.* += @sizeOf(u64);
    const data_len = readU64Raw(input, cursor);
    const data = (input + cursor.*)[0..@intCast(data_len)];
    cursor.* += @intCast(data_len);
    cursor.* += max_permitted_data_increase;
    cursor.* = std.mem.alignForward(usize, cursor.*, account_alignment);
    const rent_epoch: *align(1) u64 = @ptrCast(input + cursor.*);
    cursor.* += @sizeOf(u64);

    out.* = .{
        .key = key,
        .lamports = lamports,
        .data_len = data.len,
        .data = data.ptr,
        .owner = owner,
        .rent_epoch = rent_epoch.*,
        .is_signer = is_signer,
        .is_writable = is_writable,
        .executable = executable,
    };
}

inline fn readU64Raw(input: [*]const u8, cursor: *usize) u64 {
    const start = cursor.*;
    cursor.* += 8;
    return @as(u64, input[start]) |
        (@as(u64, input[start + 1]) << 8) |
        (@as(u64, input[start + 2]) << 16) |
        (@as(u64, input[start + 3]) << 24) |
        (@as(u64, input[start + 4]) << 32) |
        (@as(u64, input[start + 5]) << 40) |
        (@as(u64, input[start + 6]) << 48) |
        (@as(u64, input[start + 7]) << 56);
}

fn readPubkeyOption(data: []const u8, cursor: *usize) Error!?*const Pubkey {
    const tag = try readU32(data, cursor);
    const value = try readPubkeyPtr(data, cursor);
    return switch (tag) {
        0 => null,
        1 => value,
        else => error.InvalidOptionTag,
    };
}

fn readU64Option(data: []const u8, cursor: *usize) Error!?u64 {
    const tag = try readU32(data, cursor);
    const value = try readU64(data, cursor);
    return switch (tag) {
        0 => null,
        1 => value,
        else => error.InvalidOptionTag,
    };
}

fn readU32(data: []const u8, cursor: *usize) Error!u32 {
    if (data.len -| cursor.* < @sizeOf(u32)) return error.TruncatedInput;
    const bytes = data[cursor.*..][0..@sizeOf(u32)];
    cursor.* += @sizeOf(u32);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readU64(data: []const u8, cursor: *usize) Error!u64 {
    if (data.len -| cursor.* < @sizeOf(u64)) return error.TruncatedInput;
    const bytes = data[cursor.*..][0..@sizeOf(u64)];
    cursor.* += @sizeOf(u64);
    return readU64Le(bytes);
}

fn readU64Le(bytes: []const u8) u64 {
    var out: u64 = 0;
    for (bytes[0..@sizeOf(u64)], 0..) |byte, shift_index| {
        out |= @as(u64, byte) << @intCast(shift_index * 8);
    }
    return out;
}

fn writeU64Le(out: []u8, value: u64) void {
    var remaining = value;
    for (out[0..@sizeOf(u64)]) |*byte| {
        byte.* = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
}

fn writeU32Le(out: []u8, value: u32) void {
    var remaining = value;
    for (out[0..@sizeOf(u32)]) |*byte| {
        byte.* = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
}

test "SPL Token program id matches Tokenkeg bytes" {
    try std.testing.expectEqualStrings(program_id_base58, "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
    try std.testing.expectEqual(@as(usize, pubkey_len), program_id.len);

    const encoded = try bs58.encode(std.testing.allocator, &program_id);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(program_id_base58, encoded);

    var copied: Pubkey = undefined;
    writeProgramId(&copied);
    try std.testing.expectEqualSlices(u8, &program_id, &copied);

    var from_base58: Pubkey = undefined;
    try std.testing.expect(writeProgramIdFromBytes(&from_base58, program_id_base58));
    try std.testing.expectEqualSlices(u8, &program_id, &from_base58);
    try std.testing.expect(writeProgramIdFromBytes(&from_base58, &program_id));
    try std.testing.expectEqualSlices(u8, &program_id, &from_base58);
    const random_pubkey = [_]u8{0x55} ** pubkey_len;
    try std.testing.expect(!writeProgramIdFromBytes(&from_base58, &random_pubkey));
    try std.testing.expect(!writeProgramIdFromBytes(&from_base58, "not-token"));
}

test "SPL Token Transfer instruction encoding is discriminator plus u64 little endian" {
    const encoded = encodeTransfer(0x0102_0304_0506_0708);
    try std.testing.expectEqual(@as(usize, 9), encoded.len);
    try std.testing.expectEqualSlices(u8, &.{ 3, 8, 7, 6, 5, 4, 3, 2, 1 }, &encoded);

    var out: [9]u8 = undefined;
    const written = try encodeTransferInto(out[0..], 500);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0xf4, 0x01, 0, 0, 0, 0, 0, 0 }, written);
    try std.testing.expectError(error.OutputTooShort, encodeTransferInto(out[0..8], 1));
}

test "SPL Token Transfer account metas use source destination authority flags" {
    var source: Pubkey = [_]u8{1} ** pubkey_len;
    var destination: Pubkey = [_]u8{2} ** pubkey_len;
    var authority: Pubkey = [_]u8{3} ** pubkey_len;

    const metas = transferAccountMetas(&source, &destination, &authority);
    try std.testing.expectEqual(@as(usize, 3), metas.len);
    try std.testing.expect(metas[0].pubkey == &source);
    try std.testing.expectEqual(@as(u8, 1), metas[0].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[0].is_signer);
    try std.testing.expect(metas[1].pubkey == &destination);
    try std.testing.expectEqual(@as(u8, 1), metas[1].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[1].is_signer);
    try std.testing.expect(metas[2].pubkey == &authority);
    try std.testing.expectEqual(@as(u8, 0), metas[2].is_writable);
    try std.testing.expectEqual(@as(u8, 1), metas[2].is_signer);
}

test "SPL Token InitializeAccount instruction encoding is discriminator only" {
    const encoded = encodeInitializeAccount();
    try std.testing.expectEqual(@as(usize, 1), encoded.len);
    try std.testing.expectEqualSlices(u8, &.{1}, &encoded);

    var out: [1]u8 = undefined;
    const written = try encodeInitializeAccountInto(out[0..]);
    try std.testing.expectEqualSlices(u8, &.{1}, written);
    try std.testing.expectError(error.OutputTooShort, encodeInitializeAccountInto(out[0..0]));
}

test "SPL Token InitializeAccount builder uses canonical metas and data" {
    var account_pubkey: Pubkey = [_]u8{1} ** pubkey_len;
    var mint: Pubkey = [_]u8{2} ** pubkey_len;
    var owner: Pubkey = [_]u8{3} ** pubkey_len;
    var rent_sysvar: Pubkey = [_]u8{4} ** pubkey_len;
    var metas: [initialize_account_account_count]cpi.SolAccountMeta = undefined;
    var data: [initialize_account_instruction_data_len]u8 = undefined;

    const instruction = initializeAccountInstruction(&account_pubkey, &mint, &owner, &rent_sysvar, &metas, &data);
    try std.testing.expect(instruction.program_id == &program_id);
    try std.testing.expectEqual(@as(u64, initialize_account_account_count), instruction.account_len);
    try std.testing.expect(instruction.accounts == metas[0..].ptr);
    try std.testing.expectEqual(@as(u64, initialize_account_instruction_data_len), instruction.data_len);
    try std.testing.expect(instruction.data == data[0..].ptr);
    try std.testing.expectEqualSlices(u8, &.{1}, instruction.data[0..@intCast(instruction.data_len)]);

    try std.testing.expect(metas[0].pubkey == &account_pubkey);
    try std.testing.expectEqual(@as(u8, 1), metas[0].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[0].is_signer);
    try std.testing.expect(metas[1].pubkey == &mint);
    try std.testing.expectEqual(@as(u8, 0), metas[1].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[1].is_signer);
    try std.testing.expect(metas[2].pubkey == &owner);
    try std.testing.expectEqual(@as(u8, 0), metas[2].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[2].is_signer);
    try std.testing.expect(metas[3].pubkey == &@import("solana_program_sdk").rent_id);
    try std.testing.expectEqual(@as(u8, 0), metas[3].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[3].is_signer);
}

test "SPL Token Burn instruction encoding is discriminator plus u64 little endian" {
    const encoded = encodeBurn(0x0102_0304_0506_0708);
    try std.testing.expectEqual(@as(usize, burn_instruction_data_len), encoded.len);
    try std.testing.expectEqualSlices(u8, &.{ 8, 8, 7, 6, 5, 4, 3, 2, 1 }, &encoded);

    var out: [burn_instruction_data_len]u8 = undefined;
    const written = try encodeBurnInto(out[0..], 500);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0xf4, 0x01, 0, 0, 0, 0, 0, 0 }, written);
    try std.testing.expectError(error.OutputTooShort, encodeBurnInto(out[0 .. burn_instruction_data_len - 1], 1));
}

test "SPL Token CloseAccount instruction encoding is discriminator only" {
    const encoded = encodeCloseAccount();
    try std.testing.expectEqual(@as(usize, close_account_instruction_data_len), encoded.len);
    try std.testing.expectEqualSlices(u8, &.{9}, &encoded);

    var out: [close_account_instruction_data_len]u8 = undefined;
    const written = try encodeCloseAccountInto(out[0..]);
    try std.testing.expectEqualSlices(u8, &.{9}, written);
    try std.testing.expectError(error.OutputTooShort, encodeCloseAccountInto(out[0..0]));
}

test "SPL Token Revoke instruction encoding is discriminator only" {
    const encoded = encodeRevoke();
    try std.testing.expectEqual(@as(usize, revoke_instruction_data_len), encoded.len);
    try std.testing.expectEqualSlices(u8, &.{5}, &encoded);

    var out: [revoke_instruction_data_len]u8 = undefined;
    const written = try encodeRevokeInto(out[0..]);
    try std.testing.expectEqualSlices(u8, &.{5}, written);
    try std.testing.expectError(error.OutputTooShort, encodeRevokeInto(out[0..0]));
}

test "SPL Token Burn account metas use account mint authority flags" {
    var account_pubkey: Pubkey = [_]u8{1} ** pubkey_len;
    var mint: Pubkey = [_]u8{2} ** pubkey_len;
    var authority: Pubkey = [_]u8{3} ** pubkey_len;

    const metas = burnAccountMetas(&account_pubkey, &mint, &authority);
    try std.testing.expectEqual(@as(usize, burn_account_count), metas.len);
    try std.testing.expect(metas[0].pubkey == &account_pubkey);
    try std.testing.expectEqual(@as(u8, 1), metas[0].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[0].is_signer);
    try std.testing.expect(metas[1].pubkey == &mint);
    try std.testing.expectEqual(@as(u8, 1), metas[1].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[1].is_signer);
    try std.testing.expect(metas[2].pubkey == &authority);
    try std.testing.expectEqual(@as(u8, 0), metas[2].is_writable);
    try std.testing.expectEqual(@as(u8, 1), metas[2].is_signer);
}

test "SPL Token CloseAccount account metas use account destination authority flags" {
    var account_pubkey: Pubkey = [_]u8{1} ** pubkey_len;
    var destination: Pubkey = [_]u8{2} ** pubkey_len;
    var authority: Pubkey = [_]u8{3} ** pubkey_len;

    const metas = closeAccountAccountMetas(&account_pubkey, &destination, &authority);
    try std.testing.expectEqual(@as(usize, close_account_account_count), metas.len);
    try std.testing.expect(metas[0].pubkey == &account_pubkey);
    try std.testing.expectEqual(@as(u8, 1), metas[0].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[0].is_signer);
    try std.testing.expect(metas[1].pubkey == &destination);
    try std.testing.expectEqual(@as(u8, 1), metas[1].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[1].is_signer);
    try std.testing.expect(metas[2].pubkey == &authority);
    try std.testing.expectEqual(@as(u8, 0), metas[2].is_writable);
    try std.testing.expectEqual(@as(u8, 1), metas[2].is_signer);
}

test "SPL Token Revoke account metas use source authority flags" {
    var source: Pubkey = [_]u8{1} ** pubkey_len;
    var authority: Pubkey = [_]u8{2} ** pubkey_len;

    const metas = revokeAccountMetas(&source, &authority);
    try std.testing.expectEqual(@as(usize, revoke_account_count), metas.len);
    try std.testing.expect(metas[0].pubkey == &source);
    try std.testing.expectEqual(@as(u8, 1), metas[0].is_writable);
    try std.testing.expectEqual(@as(u8, 0), metas[0].is_signer);
    try std.testing.expect(metas[1].pubkey == &authority);
    try std.testing.expectEqual(@as(u8, 0), metas[1].is_writable);
    try std.testing.expectEqual(@as(u8, 1), metas[1].is_signer);
}

test "SPL Token Burn CloseAccount and Revoke builders use canonical program id" {
    var account_pubkey: Pubkey = [_]u8{1} ** pubkey_len;
    var mint: Pubkey = [_]u8{2} ** pubkey_len;
    var destination: Pubkey = [_]u8{3} ** pubkey_len;
    var authority: Pubkey = [_]u8{4} ** pubkey_len;

    var burn_metas: [burn_account_count]cpi.SolAccountMeta = undefined;
    var burn_data: [burn_instruction_data_len]u8 = undefined;
    const burn_ix = burnInstruction(&account_pubkey, &mint, &authority, 7, &burn_metas, &burn_data);
    try std.testing.expect(burn_ix.program_id == &program_id);
    try std.testing.expectEqual(@as(u64, burn_account_count), burn_ix.account_len);
    try std.testing.expectEqual(@as(u64, burn_instruction_data_len), burn_ix.data_len);
    try std.testing.expectEqualSlices(u8, &.{ 8, 7, 0, 0, 0, 0, 0, 0, 0 }, burn_ix.data[0..@intCast(burn_ix.data_len)]);

    var close_metas: [close_account_account_count]cpi.SolAccountMeta = undefined;
    var close_data: [close_account_instruction_data_len]u8 = undefined;
    const close_ix = closeAccountInstruction(&account_pubkey, &destination, &authority, &close_metas, &close_data);
    try std.testing.expect(close_ix.program_id == &program_id);
    try std.testing.expectEqual(@as(u64, close_account_account_count), close_ix.account_len);
    try std.testing.expectEqual(@as(u64, close_account_instruction_data_len), close_ix.data_len);
    try std.testing.expectEqualSlices(u8, &.{9}, close_ix.data[0..@intCast(close_ix.data_len)]);

    var revoke_metas: [revoke_account_count]cpi.SolAccountMeta = undefined;
    var revoke_data: [revoke_instruction_data_len]u8 = undefined;
    const revoke_ix = revokeInstruction(&account_pubkey, &authority, &revoke_metas, &revoke_data);
    try std.testing.expect(revoke_ix.program_id == &program_id);
    try std.testing.expectEqual(@as(u64, revoke_account_count), revoke_ix.account_len);
    try std.testing.expectEqual(@as(u64, revoke_instruction_data_len), revoke_ix.data_len);
    try std.testing.expectEqualSlices(u8, &.{5}, revoke_ix.data[0..@intCast(revoke_ix.data_len)]);
}

test "SPL Token account parser extracts mint owner amount and options" {
    var data = [_]u8{0} ** token_account_len;
    var cursor: usize = 0;
    for (data[cursor..][0..pubkey_len], 0..) |*byte, index| byte.* = @intCast(0x10 + index);
    const mint_offset = cursor;
    cursor += pubkey_len;
    for (data[cursor..][0..pubkey_len], 0..) |*byte, index| byte.* = @intCast(0x80 + index);
    const owner_offset = cursor;
    cursor += pubkey_len;
    writeU64Le(data[cursor..][0..@sizeOf(u64)], 123_456);
    cursor += @sizeOf(u64);
    writeU32Le(data[cursor..][0..@sizeOf(u32)], 1);
    cursor += @sizeOf(u32);
    for (data[cursor..][0..pubkey_len]) |*byte| byte.* = 0xaa;
    const delegate_offset = cursor;
    cursor += pubkey_len;
    data[cursor] = 1;
    cursor += 1;
    writeU32Le(data[cursor..][0..@sizeOf(u32)], 1);
    cursor += @sizeOf(u32);
    writeU64Le(data[cursor..][0..@sizeOf(u64)], 2_039_280);
    cursor += @sizeOf(u64);
    writeU64Le(data[cursor..][0..@sizeOf(u64)], 77);
    cursor += @sizeOf(u64);
    writeU32Le(data[cursor..][0..@sizeOf(u32)], 1);
    cursor += @sizeOf(u32);
    for (data[cursor..][0..pubkey_len]) |*byte| byte.* = 0xbb;
    const close_authority_offset = cursor;

    const parsed = try parseTokenAccount(data[0..]);
    try std.testing.expectEqual(@as(usize, mint_offset), @intFromPtr(parsed.mint) - @intFromPtr(&data));
    try std.testing.expectEqual(@as(usize, owner_offset), @intFromPtr(parsed.owner) - @intFromPtr(&data));
    try std.testing.expectEqual(@as(u64, 123_456), parsed.amount);
    try std.testing.expectEqual(@as(u8, 0x10), parsed.mint[0]);
    try std.testing.expectEqual(@as(u8, 0x9f), parsed.owner[31]);
    try std.testing.expect(parsed.delegate != null);
    try std.testing.expectEqual(@as(usize, delegate_offset), @intFromPtr(parsed.delegate.?) - @intFromPtr(&data));
    try std.testing.expectEqual(@as(u8, 1), parsed.state);
    try std.testing.expectEqual(@as(u64, 2_039_280), parsed.is_native.?);
    try std.testing.expectEqual(@as(u64, 77), parsed.delegated_amount);
    try std.testing.expect(parsed.close_authority != null);
    try std.testing.expectEqual(@as(usize, close_authority_offset), @intFromPtr(parsed.close_authority.?) - @intFromPtr(&data));
}

test "SPL Token account parser rejects malformed buffers" {
    var short = [_]u8{0} ** (token_account_len - 1);
    try std.testing.expectError(error.TruncatedInput, parseTokenAccount(short[0..]));

    var invalid_option = [_]u8{0} ** token_account_len;
    const cursor: usize = pubkey_len + pubkey_len + @sizeOf(u64);
    writeU32Le(invalid_option[cursor..][0..@sizeOf(u32)], 2);
    try std.testing.expectError(error.InvalidOptionTag, parseTokenAccount(invalid_option[0..]));
}

test "SPL Mint parser extracts authorities supply decimals and init flag" {
    var data = [_]u8{0} ** mint_len;
    writeU32Le(data[0..4], 1);
    @memset(data[4..36], 0x33);
    writeU64Le(data[36..44], 999);
    data[44] = 6;
    data[45] = 1;
    writeU32Le(data[46..50], 1);
    @memset(data[50..82], 0x77);

    const parsed = try parseMint(data[0..]);
    try std.testing.expect(parsed.mint_authority != null);
    try std.testing.expectEqual(@as(u8, 0x33), parsed.mint_authority.?[0]);
    try std.testing.expectEqual(@as(u64, 999), parsed.supply);
    try std.testing.expectEqual(@as(u8, 6), parsed.decimals);
    try std.testing.expectEqual(@as(u8, 1), parsed.is_initialized);
    try std.testing.expect(parsed.freeze_authority != null);
    try std.testing.expectEqual(@as(u8, 0x77), parsed.freeze_authority.?[0]);
}

test "SPL Mint parser rejects malformed option tags" {
    var short = [_]u8{0} ** (mint_len - 1);
    try std.testing.expectError(error.TruncatedInput, parseMint(short[0..]));

    var invalid_option = [_]u8{0} ** mint_len;
    writeU32Le(invalid_option[0..4], 2);
    try std.testing.expectError(error.InvalidOptionTag, parseMint(invalid_option[0..]));
}

test "SPL Token instruction validator rejects malformed lengths and discriminants" {
    try std.testing.expectEqual(.transfer, try validateInstructionData(&.{ 3, 1, 0, 0, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(.initialize_account, try validateInstructionData(&.{1}));
    try std.testing.expectEqual(.burn, try validateInstructionData(&.{ 8, 1, 0, 0, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(.close_account, try validateInstructionData(&.{9}));
    try std.testing.expectEqual(.revoke, try validateInstructionData(&.{5}));
    try std.testing.expectError(error.InvalidInstructionLength, validateInstructionData(&.{3}));
    try std.testing.expectError(error.InvalidInstructionLength, validateInstructionData(&.{ 1, 0 }));
    try std.testing.expectError(error.InvalidInstructionDiscriminant, validateInstructionData(&.{0xff}));
}
