//! secp256r1 signature-verification instruction builder + parser.
//!
//! This is the dual-target surface for Solana's native secp256r1 program:
//!
//! - **builder**: construct the transaction instruction that asks the runtime
//!   to verify one or more NIST P-256/secp256r1 signatures.
//! - **parser**: inspect that instruction later via the instructions sysvar for
//!   verify-then-act flows.
//!
//! The native secp256r1 program is a transaction-level precompile, not a normal
//! CPI target. Build these instructions off-chain (or in host-side tests), then
//! inspect them on-chain via `sysvar_instructions`.

const std = @import("std");
const pubkey = @import("../../pubkey/root.zig");
const cpi = @import("../../cpi/root.zig");
const instruction_mod = @import("../../instruction/root.zig");
const sysvar_instructions = @import("../../sysvar_instructions/root.zig");
const account_mod = @import("../../account/root.zig");

const Pubkey = pubkey.Pubkey;
const Instruction = cpi.Instruction;
const IntrospectedInstruction = sysvar_instructions.IntrospectedInstruction;
const AccountInfo = account_mod.AccountInfo;

pub const PROGRAM_ID: Pubkey = pubkey.comptimeFromBase58(
    "Secp256r1SigVerify1111111111111111111111111",
);

pub const COMPRESSED_PUBKEY_SERIALIZED_SIZE: usize = 33;
pub const SIGNATURE_SERIALIZED_SIZE: usize = 64;
pub const SIGNATURE_OFFSETS_SERIALIZED_SIZE: usize = 14;
pub const SIGNATURE_OFFSETS_START: usize = 2;
pub const DATA_START: usize = SIGNATURE_OFFSETS_START + SIGNATURE_OFFSETS_SERIALIZED_SIZE;
pub const CURRENT_INSTRUCTION_INDEX: u16 = std.math.maxInt(u16);
pub const MAX_SIGNATURES: usize = 8;

/// One serialized offset entry inside the secp256r1 instruction data.
pub const SignatureOffsets = extern struct {
    signature_offset: u16,
    signature_instruction_index: u16,
    public_key_offset: u16,
    public_key_instruction_index: u16,
    message_data_offset: u16,
    message_data_size: u16,
    message_instruction_index: u16,
};

/// Resolved signature bundle for verify-then-act flows.
pub const SignatureView = struct {
    offsets: SignatureOffsets,
    public_key: *const [COMPRESSED_PUBKEY_SERIALIZED_SIZE]u8,
    signature: []const u8,
    message: []const u8,
};

pub fn encodedLen(message_len: usize) ?usize {
    const fixed = DATA_START + COMPRESSED_PUBKEY_SERIALIZED_SIZE + SIGNATURE_SERIALIZED_SIZE;
    const total = std.math.add(usize, fixed, message_len) catch return null;
    if (total > std.math.maxInt(u16)) return null;
    if (message_len > std.math.maxInt(u16)) return null;
    return total;
}

pub fn instructionLen(num_signatures: usize, tail_len: usize) ?usize {
    if (num_signatures == 0 or num_signatures > MAX_SIGNATURES) return null;
    const header = std.math.add(usize, SIGNATURE_OFFSETS_START, num_signatures * SIGNATURE_OFFSETS_SERIALIZED_SIZE) catch return null;
    const total = std.math.add(usize, header, tail_len) catch return null;
    if (total > std.math.maxInt(u16)) return null;
    return total;
}

/// Build a raw secp256r1 verification instruction.
///
/// `offsets` describes where each signature/public-key/message triple lives.
/// `tail` is copied verbatim after the offsets table. For the common "all data
/// embedded in this instruction" case, use `verify` instead.
pub fn buildInstruction(
    offsets: []const SignatureOffsets,
    tail: []const u8,
    scratch: []u8,
) !Instruction {
    const total_len = instructionLen(offsets.len, tail.len) orelse return error.InvalidArgument;
    if (scratch.len < total_len) return error.InvalidArgument;

    const out = scratch[0..total_len];
    writeHeaderAndOffsets(out, offsets);
    @memcpy(out[SIGNATURE_OFFSETS_START + offsets.len * SIGNATURE_OFFSETS_SERIALIZED_SIZE ..], tail);

    return .{
        .program_id = &PROGRAM_ID,
        .accounts = &.{},
        .data = out,
    };
}

/// Convenience builder for the common single-signature, self-contained
/// secp256r1 instruction.
pub fn verify(
    message: []const u8,
    public_key: *const [COMPRESSED_PUBKEY_SERIALIZED_SIZE]u8,
    signature: *const [SIGNATURE_SERIALIZED_SIZE]u8,
    scratch: []u8,
) !Instruction {
    const total_len = encodedLen(message.len) orelse return error.InvalidArgument;
    if (scratch.len < total_len) return error.InvalidArgument;

    const public_key_offset: u16 = DATA_START;
    const signature_offset: u16 = public_key_offset + COMPRESSED_PUBKEY_SERIALIZED_SIZE;
    const message_offset: u16 = signature_offset + SIGNATURE_SERIALIZED_SIZE;
    const offsets = [_]SignatureOffsets{.{
        .signature_offset = signature_offset,
        .signature_instruction_index = CURRENT_INSTRUCTION_INDEX,
        .public_key_offset = public_key_offset,
        .public_key_instruction_index = CURRENT_INSTRUCTION_INDEX,
        .message_data_offset = message_offset,
        .message_data_size = @intCast(message.len),
        .message_instruction_index = CURRENT_INSTRUCTION_INDEX,
    }};

    const out = scratch[0..total_len];
    writeHeaderAndOffsets(out, &offsets);
    @memcpy(out[public_key_offset .. public_key_offset + COMPRESSED_PUBKEY_SERIALIZED_SIZE], public_key[0..COMPRESSED_PUBKEY_SERIALIZED_SIZE]);
    @memcpy(out[signature_offset .. signature_offset + SIGNATURE_SERIALIZED_SIZE], signature[0..SIGNATURE_SERIALIZED_SIZE]);
    @memcpy(out[message_offset..], message);

    return .{
        .program_id = &PROGRAM_ID,
        .accounts = &.{},
        .data = out,
    };
}

pub fn signatureCount(ix: IntrospectedInstruction) !u8 {
    const data = ix.data();
    if (data.len < SIGNATURE_OFFSETS_START) return error.InvalidInstructionData;
    const count = data[0];
    if (count == 0 or count > MAX_SIGNATURES) return error.InvalidInstructionData;

    const expected = instructionLen(count, 0) orelse return error.InvalidInstructionData;
    if (data.len < expected) return error.InvalidInstructionData;
    return count;
}

pub fn offsetsAt(ix: IntrospectedInstruction, signature_index: usize) !SignatureOffsets {
    const count = try signatureCount(ix);
    if (signature_index >= count) return error.InvalidArgument;

    const start = SIGNATURE_OFFSETS_START + signature_index * SIGNATURE_OFFSETS_SERIALIZED_SIZE;
    return instruction_mod.readUnalignedPtr(SignatureOffsets, ix.data().ptr + start);
}

/// Parse a self-contained secp256r1 instruction whose offsets all point into the
/// instruction's own data (`u16::MAX` instruction indexes).
pub fn parseSignature(
    ix: IntrospectedInstruction,
    signature_index: usize,
) !SignatureView {
    const offsets = try offsetsAtCheckedProgram(ix, signature_index);
    if (offsets.signature_instruction_index != CURRENT_INSTRUCTION_INDEX or
        offsets.public_key_instruction_index != CURRENT_INSTRUCTION_INDEX or
        offsets.message_instruction_index != CURRENT_INSTRUCTION_INDEX)
    {
        return error.InvalidInstructionData;
    }
    return resolveSignature(ix, null, offsets);
}

/// Parse a secp256r1 signature bundle, resolving referenced data from the
/// instructions sysvar when the offsets point at other instructions.
pub fn parseSignatureWithSysvar(
    ix: IntrospectedInstruction,
    signature_index: usize,
    instructions_sysvar: AccountInfo,
) !SignatureView {
    const offsets = try offsetsAtCheckedProgram(ix, signature_index);
    return resolveSignature(ix, instructions_sysvar, offsets);
}

fn offsetsAtCheckedProgram(ix: IntrospectedInstruction, signature_index: usize) !SignatureOffsets {
    if (!pubkey.pubkeyEqComptime(ix.programId(), PROGRAM_ID)) {
        return error.InvalidArgument;
    }
    return offsetsAt(ix, signature_index);
}

fn resolveSignature(
    ix: IntrospectedInstruction,
    instructions_sysvar: ?AccountInfo,
    offsets: SignatureOffsets,
) !SignatureView {
    const public_key_bytes = try getDataSlice(
        ix,
        instructions_sysvar,
        offsets.public_key_instruction_index,
        offsets.public_key_offset,
        COMPRESSED_PUBKEY_SERIALIZED_SIZE,
    );
    const signature_bytes = try getDataSlice(
        ix,
        instructions_sysvar,
        offsets.signature_instruction_index,
        offsets.signature_offset,
        SIGNATURE_SERIALIZED_SIZE,
    );
    const message_bytes = try getDataSlice(
        ix,
        instructions_sysvar,
        offsets.message_instruction_index,
        offsets.message_data_offset,
        offsets.message_data_size,
    );

    return .{
        .offsets = offsets,
        .public_key = @ptrCast(public_key_bytes.ptr),
        .signature = signature_bytes,
        .message = message_bytes,
    };
}

fn getDataSlice(
    current_ix: IntrospectedInstruction,
    instructions_sysvar: ?AccountInfo,
    instruction_index: u16,
    offset_start: u16,
    size: usize,
) ![]const u8 {
    const data = if (instruction_index == CURRENT_INSTRUCTION_INDEX)
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
    out[1] = 0;
    for (offsets, 0..) |entry, i| {
        const start = SIGNATURE_OFFSETS_START + i * SIGNATURE_OFFSETS_SERIALIZED_SIZE;
        const dst = out[start .. start + SIGNATURE_OFFSETS_SERIALIZED_SIZE];
        writeOffsets(dst, entry);
    }
}

fn writeOffsets(dst: []u8, offsets: SignatureOffsets) void {
    std.debug.assert(dst.len == SIGNATURE_OFFSETS_SERIALIZED_SIZE);
    std.mem.writeInt(u16, dst[0..2], offsets.signature_offset, .little);
    std.mem.writeInt(u16, dst[2..4], offsets.signature_instruction_index, .little);
    std.mem.writeInt(u16, dst[4..6], offsets.public_key_offset, .little);
    std.mem.writeInt(u16, dst[6..8], offsets.public_key_instruction_index, .little);
    std.mem.writeInt(u16, dst[8..10], offsets.message_data_offset, .little);
    std.mem.writeInt(u16, dst[10..12], offsets.message_data_size, .little);
    std.mem.writeInt(u16, dst[12..14], offsets.message_instruction_index, .little);
}

test "secp256r1_instruction: constants match Solana ABI" {
    try std.testing.expectEqual(@as(usize, 14), SIGNATURE_OFFSETS_SERIALIZED_SIZE);
    try std.testing.expectEqual(@as(usize, 14), @sizeOf(SignatureOffsets));
    try std.testing.expectEqual(@as(usize, 16), DATA_START);
    try std.testing.expectEqual(@as(usize, 33), COMPRESSED_PUBKEY_SERIALIZED_SIZE);
}

test "secp256r1_instruction: verify builds canonical self-contained instruction" {
    const pk = [_]u8{0x11} ** COMPRESSED_PUBKEY_SERIALIZED_SIZE;
    const sig = [_]u8{0x22} ** SIGNATURE_SERIALIZED_SIZE;
    const msg = "hello";
    var scratch: [256]u8 = undefined;

    const ix = try verify(msg, &pk, &sig, &scratch);
    try std.testing.expectEqualSlices(u8, &PROGRAM_ID, ix.program_id);
    try std.testing.expectEqual(@as(usize, 0), ix.accounts.len);
    try std.testing.expectEqual(encodedLen(msg.len).?, ix.data.len);
    try std.testing.expectEqual(@as(u8, 1), ix.data[0]);
    try std.testing.expectEqual(@as(u8, 0), ix.data[1]);

    const bytes = try buildInstructionBytes(ix.data);
    defer std.testing.allocator.free(bytes);
    const fake_ix = IntrospectedInstruction{ .bytes = bytes };
    const parsed = try parseSignature(fake_ix, 0);
    try std.testing.expectEqual(pk, parsed.public_key.*);
    try std.testing.expectEqualSlices(u8, &sig, parsed.signature);
    try std.testing.expectEqualStrings(msg, parsed.message);
}

test "secp256r1_instruction: buildInstruction requires native count range" {
    var scratch: [32]u8 = undefined;
    try std.testing.expectError(error.InvalidArgument, buildInstruction(&.{}, &.{}, &scratch));

    const offsets = [_]SignatureOffsets{.{
        .signature_offset = 0,
        .signature_instruction_index = 0,
        .public_key_offset = 0,
        .public_key_instruction_index = 0,
        .message_data_offset = 0,
        .message_data_size = 0,
        .message_instruction_index = 0,
    }} ** (MAX_SIGNATURES + 1);
    try std.testing.expectError(error.InvalidArgument, buildInstruction(&offsets, &.{}, &scratch));
}

test "secp256r1_instruction: signatureCount rejects truncated offsets table" {
    const data = [_]u8{ 1, 0, 0xaa };
    const bytes = try buildInstructionBytes(&data);
    defer std.testing.allocator.free(bytes);
    const fake_ix = IntrospectedInstruction{ .bytes = bytes };
    try std.testing.expectError(error.InvalidInstructionData, signatureCount(fake_ix));
}

test "secp256r1_instruction: signatureCount rejects invalid native counts" {
    const zero = [_]u8{ 0, 0 };
    const zero_bytes = try buildInstructionBytes(&zero);
    defer std.testing.allocator.free(zero_bytes);
    try std.testing.expectError(error.InvalidInstructionData, signatureCount(.{ .bytes = zero_bytes }));

    const too_many = [_]u8{ 9, 0 };
    const too_many_bytes = try buildInstructionBytes(&too_many);
    defer std.testing.allocator.free(too_many_bytes);
    try std.testing.expectError(error.InvalidInstructionData, signatureCount(.{ .bytes = too_many_bytes }));
}

test "secp256r1_instruction: parseSignature rejects non-self-contained layout" {
    const data = [_]u8{
        1,    0,
        49,   0,
        0,    0,
        16,   0,
        0,    0,
        113,  0,
        4,    0,
        0,    0,
        0xaa, 0xbb,
        0xcc, 0xdd,
    };
    const bytes = try buildInstructionBytes(&data);
    defer std.testing.allocator.free(bytes);
    const fake_ix = IntrospectedInstruction{ .bytes = bytes };
    try std.testing.expectError(error.InvalidInstructionData, parseSignature(fake_ix, 0));
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
