//! secp256k1 signature-verification instruction builder + parser.
//!
//! This is the dual-target surface for Solana's native secp256k1 program:
//!
//! - **builder**: construct the transaction instruction that asks the runtime
//!   to verify one or more secp256k1/Ethereum-style signatures.
//! - **parser**: inspect that instruction later via the instructions sysvar for
//!   verify-then-act flows.
//!
//! Unlike the ed25519 precompile, secp256k1 offset entries use absolute `u8`
//! instruction indexes. That means self-contained instructions must know their
//! final transaction position when being built.

const std = @import("std");
const pubkey = @import("../../pubkey/root.zig");
const cpi = @import("../../cpi/root.zig");
const hash = @import("../hash.zig");
const instruction_mod = @import("../../instruction/root.zig");
const sysvar_instructions = @import("../../sysvar_instructions/root.zig");
const account_mod = @import("../../account/root.zig");

const Pubkey = pubkey.Pubkey;
const Instruction = cpi.Instruction;
const IntrospectedInstruction = sysvar_instructions.IntrospectedInstruction;
const AccountInfo = account_mod.AccountInfo;

pub const PROGRAM_ID: Pubkey = pubkey.comptimeFromBase58(
    "KeccakSecp256k11111111111111111111111111111",
);

pub const HASHED_PUBKEY_SERIALIZED_SIZE: usize = 20;
pub const SIGNATURE_SERIALIZED_SIZE: usize = 64;
pub const RECOVERY_ID_SERIALIZED_SIZE: usize = 1;
pub const SIGNATURE_OFFSETS_SERIALIZED_SIZE: usize = 11;
pub const DATA_START: usize = 1 + SIGNATURE_OFFSETS_SERIALIZED_SIZE;

/// One decoded offset entry inside the secp256k1 instruction data.
///
/// The wire layout is 11 bytes; we decode/encode it manually because Zig's
/// natural `extern struct` layout would insert padding after the `u8` fields.
pub const SignatureOffsets = struct {
    signature_offset: u16,
    signature_instruction_index: u8,
    eth_address_offset: u16,
    eth_address_instruction_index: u8,
    message_data_offset: u16,
    message_data_size: u16,
    message_instruction_index: u8,
};

/// Resolved signature bundle for verify-then-act flows.
pub const SignatureView = struct {
    offsets: SignatureOffsets,
    signature: []const u8,
    recovery_id: u8,
    eth_address: *const [HASHED_PUBKEY_SERIALIZED_SIZE]u8,
    message: []const u8,
};

pub fn encodedLen(message_len: usize) ?usize {
    const fixed = DATA_START + HASHED_PUBKEY_SERIALIZED_SIZE + SIGNATURE_SERIALIZED_SIZE + RECOVERY_ID_SERIALIZED_SIZE;
    const total = std.math.add(usize, fixed, message_len) catch return null;
    if (total > std.math.maxInt(u16)) return null;
    if (message_len > std.math.maxInt(u16)) return null;
    return total;
}

pub fn instructionLen(num_signatures: usize, tail_len: usize) ?usize {
    if (num_signatures > std.math.maxInt(u8)) return null;
    const header = std.math.add(usize, 1, num_signatures * SIGNATURE_OFFSETS_SERIALIZED_SIZE) catch return null;
    const total = std.math.add(usize, header, tail_len) catch return null;
    if (total > std.math.maxInt(u16)) return null;
    return total;
}

/// Derive the 20-byte Ethereum address from a 64-byte uncompressed secp256k1
/// public key `(x || y)`.
pub fn constructEthAddress(pubkey64: []const u8) ![HASHED_PUBKEY_SERIALIZED_SIZE]u8 {
    if (pubkey64.len != 64) return error.InvalidArgument;
    const digest = try hash.keccak256(&.{pubkey64});
    var out: [HASHED_PUBKEY_SERIALIZED_SIZE]u8 = undefined;
    @memcpy(&out, digest.bytes[12..32]);
    return out;
}

/// Build a raw secp256k1 verification instruction.
///
/// `offsets` describes where each signature/address/message triple lives.
/// `tail` is copied verbatim after the offsets table. For the common "all data
/// embedded in this instruction" case, use `verify` or `verifyFirst`.
pub fn buildInstruction(
    offsets: []const SignatureOffsets,
    tail: []const u8,
    scratch: []u8,
) !Instruction {
    const total_len = instructionLen(offsets.len, tail.len) orelse return error.InvalidArgument;
    if (scratch.len < total_len) return error.InvalidArgument;

    const out = scratch[0..total_len];
    writeHeaderAndOffsets(out, offsets);
    @memcpy(out[1 + offsets.len * SIGNATURE_OFFSETS_SERIALIZED_SIZE ..], tail);

    return .{
        .program_id = &PROGRAM_ID,
        .accounts = &.{},
        .data = out,
    };
}

/// Convenience builder for the common single-signature, self-contained
/// secp256k1 instruction.
///
/// `instruction_index` is the absolute index this instruction will occupy in
/// the final transaction, because the native wire format stores absolute `u8`
/// indexes rather than `u16::MAX` self references.
pub fn verify(
    instruction_index: u8,
    message: []const u8,
    eth_address: *const [HASHED_PUBKEY_SERIALIZED_SIZE]u8,
    signature: *const [SIGNATURE_SERIALIZED_SIZE]u8,
    recovery_id: u8,
    scratch: []u8,
) !Instruction {
    if (recovery_id > 3) return error.InvalidArgument;
    const total_len = encodedLen(message.len) orelse return error.InvalidArgument;
    if (scratch.len < total_len) return error.InvalidArgument;

    const eth_offset: u16 = DATA_START;
    const sig_offset: u16 = eth_offset + HASHED_PUBKEY_SERIALIZED_SIZE;
    const recid_offset: u16 = sig_offset + SIGNATURE_SERIALIZED_SIZE;
    const msg_offset: u16 = recid_offset + RECOVERY_ID_SERIALIZED_SIZE;
    const offsets = [_]SignatureOffsets{.{
        .signature_offset = sig_offset,
        .signature_instruction_index = instruction_index,
        .eth_address_offset = eth_offset,
        .eth_address_instruction_index = instruction_index,
        .message_data_offset = msg_offset,
        .message_data_size = @intCast(message.len),
        .message_instruction_index = instruction_index,
    }};

    const out = scratch[0..total_len];
    writeHeaderAndOffsets(out, &offsets);
    @memcpy(out[eth_offset .. eth_offset + HASHED_PUBKEY_SERIALIZED_SIZE], eth_address[0..HASHED_PUBKEY_SERIALIZED_SIZE]);
    @memcpy(out[sig_offset .. sig_offset + SIGNATURE_SERIALIZED_SIZE], signature[0..SIGNATURE_SERIALIZED_SIZE]);
    out[recid_offset] = recovery_id;
    @memcpy(out[msg_offset..], message);

    return .{
        .program_id = &PROGRAM_ID,
        .accounts = &.{},
        .data = out,
    };
}

/// Convenience for the canonical "secp instruction is first in the tx" layout.
pub fn verifyFirst(
    message: []const u8,
    eth_address: *const [HASHED_PUBKEY_SERIALIZED_SIZE]u8,
    signature: *const [SIGNATURE_SERIALIZED_SIZE]u8,
    recovery_id: u8,
    scratch: []u8,
) !Instruction {
    return verify(0, message, eth_address, signature, recovery_id, scratch);
}

pub fn signatureCount(ix: IntrospectedInstruction) !u8 {
    const data = ix.data();
    if (data.len < 1) return error.InvalidInstructionData;
    const count = data[0];
    if (count == 0 and data.len > 1) return error.InvalidInstructionData;

    const expected = instructionLen(count, 0) orelse return error.InvalidInstructionData;
    if (data.len < expected) return error.InvalidInstructionData;
    return count;
}

pub fn offsetsAt(ix: IntrospectedInstruction, signature_index: usize) !SignatureOffsets {
    const count = try signatureCount(ix);
    if (signature_index >= count) return error.InvalidArgument;

    const start = 1 + signature_index * SIGNATURE_OFFSETS_SERIALIZED_SIZE;
    const chunk = ix.data()[start .. start + SIGNATURE_OFFSETS_SERIALIZED_SIZE];
    return .{
        .signature_offset = std.mem.readInt(u16, chunk[0..2], .little),
        .signature_instruction_index = chunk[2],
        .eth_address_offset = std.mem.readInt(u16, chunk[3..5], .little),
        .eth_address_instruction_index = chunk[5],
        .message_data_offset = std.mem.readInt(u16, chunk[6..8], .little),
        .message_data_size = std.mem.readInt(u16, chunk[8..10], .little),
        .message_instruction_index = chunk[10],
    };
}

/// Parse a self-contained secp256k1 instruction whose offsets all point into
/// the same absolute instruction index.
pub fn parseSignatureSelfContained(
    ix: IntrospectedInstruction,
    signature_index: usize,
    instruction_index: u8,
) !SignatureView {
    const offsets = try offsetsAtCheckedProgram(ix, signature_index);
    if (offsets.signature_instruction_index != instruction_index or
        offsets.eth_address_instruction_index != instruction_index or
        offsets.message_instruction_index != instruction_index)
    {
        return error.InvalidInstructionData;
    }
    return resolveSignature(ix, instruction_index, null, offsets);
}

/// Parse a secp256k1 signature bundle, resolving referenced data from the
/// instructions sysvar when the offsets point at other instructions.
pub fn parseSignatureWithSysvar(
    ix: IntrospectedInstruction,
    signature_index: usize,
    current_instruction_index: u8,
    instructions_sysvar: AccountInfo,
) !SignatureView {
    const offsets = try offsetsAtCheckedProgram(ix, signature_index);
    return resolveSignature(ix, current_instruction_index, instructions_sysvar, offsets);
}

fn offsetsAtCheckedProgram(ix: IntrospectedInstruction, signature_index: usize) !SignatureOffsets {
    if (!pubkey.pubkeyEqComptime(ix.programId(), PROGRAM_ID)) {
        return error.InvalidArgument;
    }
    return offsetsAt(ix, signature_index);
}

fn resolveSignature(
    ix: IntrospectedInstruction,
    current_instruction_index: u8,
    instructions_sysvar: ?AccountInfo,
    offsets: SignatureOffsets,
) !SignatureView {
    const signature_plus_recovery = try getDataSlice(
        ix,
        current_instruction_index,
        instructions_sysvar,
        offsets.signature_instruction_index,
        offsets.signature_offset,
        SIGNATURE_SERIALIZED_SIZE + RECOVERY_ID_SERIALIZED_SIZE,
    );
    const eth_address_bytes = try getDataSlice(
        ix,
        current_instruction_index,
        instructions_sysvar,
        offsets.eth_address_instruction_index,
        offsets.eth_address_offset,
        HASHED_PUBKEY_SERIALIZED_SIZE,
    );
    const message_bytes = try getDataSlice(
        ix,
        current_instruction_index,
        instructions_sysvar,
        offsets.message_instruction_index,
        offsets.message_data_offset,
        offsets.message_data_size,
    );

    return .{
        .offsets = offsets,
        .signature = signature_plus_recovery[0..SIGNATURE_SERIALIZED_SIZE],
        .recovery_id = signature_plus_recovery[SIGNATURE_SERIALIZED_SIZE],
        .eth_address = @ptrCast(eth_address_bytes.ptr),
        .message = message_bytes,
    };
}

fn getDataSlice(
    current_ix: IntrospectedInstruction,
    current_ix_index: u8,
    instructions_sysvar: ?AccountInfo,
    instruction_index: u8,
    offset_start: u16,
    size: usize,
) ![]const u8 {
    const data = if (instruction_index == current_ix_index)
        current_ix.data()
    else blk: {
        const info = instructions_sysvar orelse return error.InvalidInstructionData;
        break :blk (try sysvar_instructions.loadInstructionAtChecked(instruction_index, info)).data();
    };

    const start: usize = offset_start;
    const end = std.math.add(usize, start, size) catch return error.InvalidInstructionData;
    if (end > data.len) return error.InvalidInstructionData;
    return data[start..end];
}

fn writeHeaderAndOffsets(out: []u8, offsets: []const SignatureOffsets) void {
    out[0] = @intCast(offsets.len);
    for (offsets, 0..) |entry, i| {
        const start = 1 + i * SIGNATURE_OFFSETS_SERIALIZED_SIZE;
        const dst = out[start .. start + SIGNATURE_OFFSETS_SERIALIZED_SIZE];
        writeOffsets(dst, entry);
    }
}

fn writeOffsets(dst: []u8, offsets: SignatureOffsets) void {
    std.debug.assert(dst.len == SIGNATURE_OFFSETS_SERIALIZED_SIZE);
    std.mem.writeInt(u16, dst[0..2], offsets.signature_offset, .little);
    dst[2] = offsets.signature_instruction_index;
    std.mem.writeInt(u16, dst[3..5], offsets.eth_address_offset, .little);
    dst[5] = offsets.eth_address_instruction_index;
    std.mem.writeInt(u16, dst[6..8], offsets.message_data_offset, .little);
    std.mem.writeInt(u16, dst[8..10], offsets.message_data_size, .little);
    dst[10] = offsets.message_instruction_index;
}

test "secp256k1_instruction: constants match Solana ABI" {
    try std.testing.expectEqual(@as(usize, 11), SIGNATURE_OFFSETS_SERIALIZED_SIZE);
    try std.testing.expectEqual(@as(usize, 12), DATA_START);
}

test "secp256k1_instruction: verifyFirst builds canonical self-contained instruction" {
    const eth = [_]u8{0x11} ** HASHED_PUBKEY_SERIALIZED_SIZE;
    const sig = [_]u8{0x22} ** SIGNATURE_SERIALIZED_SIZE;
    const msg = "hello";
    var scratch: [256]u8 = undefined;

    const ix = try verifyFirst(msg, &eth, &sig, 1, &scratch);
    try std.testing.expectEqualSlices(u8, &PROGRAM_ID, ix.program_id);
    try std.testing.expectEqual(@as(usize, 0), ix.accounts.len);
    try std.testing.expectEqual(encodedLen(msg.len).?, ix.data.len);
    try std.testing.expectEqual(@as(u8, 1), ix.data[0]);

    const bytes = try buildInstructionBytes(ix.data);
    defer std.testing.allocator.free(bytes);
    const fake_ix = IntrospectedInstruction{ .bytes = bytes };
    const parsed = try parseSignatureSelfContained(fake_ix, 0, 0);
    try std.testing.expectEqual(eth, parsed.eth_address.*);
    try std.testing.expectEqualSlices(u8, &sig, parsed.signature);
    try std.testing.expectEqual(@as(u8, 1), parsed.recovery_id);
    try std.testing.expectEqualStrings(msg, parsed.message);
}

test "secp256k1_instruction: verify rejects bad recovery id" {
    const eth = [_]u8{0x11} ** HASHED_PUBKEY_SERIALIZED_SIZE;
    const sig = [_]u8{0x22} ** SIGNATURE_SERIALIZED_SIZE;
    var scratch: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidArgument, verifyFirst("x", &eth, &sig, 4, &scratch));
}

test "secp256k1_instruction: signatureCount rejects truncated offsets table" {
    const data = [_]u8{ 1, 0xaa };
    const bytes = try buildInstructionBytes(&data);
    defer std.testing.allocator.free(bytes);
    const fake_ix = IntrospectedInstruction{ .bytes = bytes };
    try std.testing.expectError(error.InvalidInstructionData, signatureCount(fake_ix));
}

test "secp256k1_instruction: parseSignatureSelfContained rejects mismatched instruction index" {
    const eth = [_]u8{0x11} ** HASHED_PUBKEY_SERIALIZED_SIZE;
    const sig = [_]u8{0x22} ** SIGNATURE_SERIALIZED_SIZE;
    var scratch: [256]u8 = undefined;
    const ix = try verify(2, "hello", &eth, &sig, 0, &scratch);
    const bytes = try buildInstructionBytes(ix.data);
    defer std.testing.allocator.free(bytes);
    const fake_ix = IntrospectedInstruction{ .bytes = bytes };
    try std.testing.expectError(error.InvalidInstructionData, parseSignatureSelfContained(fake_ix, 0, 0));
}

test "secp256k1_instruction: constructEthAddress validates length" {
    try std.testing.expectError(error.InvalidArgument, constructEthAddress(&[_]u8{0} ** 63));
}

fn buildInstructionBytes(data: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, 2 + 32 + 2 + data.len);
    bytes[0] = 0;
    bytes[1] = 0;
    @memcpy(bytes[2..34], &PROGRAM_ID);
    std.mem.writeInt(u16, bytes[34..36], @intCast(data.len), .little);
    @memcpy(bytes[36..], data);
    return bytes;
}
