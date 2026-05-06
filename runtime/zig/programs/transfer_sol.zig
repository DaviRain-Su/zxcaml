//! Runtime entrypoint for the transfer_sol example.

const std = @import("std");
const Arena = @import("../arena.zig").Arena;
const cpi = @import("../cpi.zig");
const common = @import("common.zig");

const Pubkey = cpi.Pubkey;
const SolAccountMeta = cpi.SolAccountMeta;
const SolInstruction = cpi.SolInstruction;
const SolAccountInfo = cpi.SolAccountInfo;
const invoke = cpi.invoke;
const parseAccountInfoUnchecked = common.parseAccountInfoUnchecked;
const pubkeyEq = common.pubkeyEq;
const readU64LeSlice = common.readU64LeSlice;
const readU64Raw = common.readU64Raw;
const writeSystemTransferData = common.writeSystemTransferData;

/// Processes the transfer_sol example's u64 amount payload via System Program CPI.
pub fn zxcaml_transfer_sol_process(arena: *Arena, input: [*]const u8, instruction_data: []const u8) u64 {
    _ = arena;
    if (instruction_data.len != 8) return 1;

    const input_mut: [*]u8 = @constCast(input);
    var cursor: usize = 0;
    const account_count = readU64Raw(input_mut, &cursor);
    if (account_count < 3) return 1;

    var infos: [3]SolAccountInfo = undefined;
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[0]);
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[1]);
    parseAccountInfoUnchecked(input_mut, &cursor, &infos[2]);
    if (infos[0].is_signer == 0) return 1;
    if (infos[0].is_writable == 0) return 1;
    if (infos[1].is_writable == 0) return 1;

    const system_program_id: Pubkey = [_]u8{0} ** 32;
    if (!pubkeyEq(infos[2].key, &system_program_id)) return 1;

    const amount = readU64LeSlice(instruction_data[0..8]);
    if (amount == 0) return 1;

    var data: [12]u8 = undefined;
    writeSystemTransferData(data[0..], amount);

    var program_id = infos[2].key.*;
    var metas = [_]SolAccountMeta{
        .{ .pubkey = infos[0].key, .is_writable = 1, .is_signer = 1 },
        .{ .pubkey = infos[1].key, .is_writable = 1, .is_signer = 0 },
    };
    const instruction = SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
    return invoke(&instruction, infos[0..]);
}

const transfer_test_account_len: usize = 1 + 1 + 1 + 1 + 4 + 32 + 32 + 8 + 8 + (10 * 1024) + 8;
const transfer_test_input_len: usize = 8 + (3 * transfer_test_account_len);

fn writeU64LeTest(out: []u8, value: u64) void {
    var remaining = value;
    for (out[0..8]) |*byte| {
        byte.* = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
}

fn writeTransferTestAccount(input: []u8, cursor: *usize, key: Pubkey, owner: Pubkey, is_signer: u8, is_writable: u8) void {
    input[cursor.*] = 0xff;
    cursor.* += 1;
    input[cursor.*] = is_signer;
    cursor.* += 1;
    input[cursor.*] = is_writable;
    cursor.* += 1;
    input[cursor.*] = 0;
    cursor.* += 1;
    @memset(input[cursor.*..][0..4], 0);
    cursor.* += 4;
    @memcpy(input[cursor.*..][0..32], key[0..]);
    cursor.* += 32;
    @memcpy(input[cursor.*..][0..32], owner[0..]);
    cursor.* += 32;
    writeU64LeTest(input[cursor.*..][0..8], 10_000);
    cursor.* += 8;
    writeU64LeTest(input[cursor.*..][0..8], 0);
    cursor.* += 8;
    @memset(input[cursor.*..][0 .. 10 * 1024], 0);
    cursor.* += 10 * 1024;
    cursor.* = std.mem.alignForward(usize, cursor.*, 8);
    writeU64LeTest(input[cursor.*..][0..8], 0);
    cursor.* += 8;
}

fn writeTransferTestInput(input: []u8, source_signer: bool, source_writable: bool, destination_writable: bool, system_program_key: Pubkey) void {
    @memset(input, 0);
    var cursor: usize = 0;
    writeU64LeTest(input[cursor..][0..8], 3);
    cursor += 8;
    const source_key: Pubkey = [_]u8{1} ** 32;
    const destination_key: Pubkey = [_]u8{2} ** 32;
    const owner_key: Pubkey = [_]u8{9} ** 32;
    writeTransferTestAccount(input, &cursor, source_key, owner_key, @intFromBool(source_signer), @intFromBool(source_writable));
    writeTransferTestAccount(input, &cursor, destination_key, owner_key, 0, @intFromBool(destination_writable));
    writeTransferTestAccount(input, &cursor, system_program_key, system_program_key, 0, 0);
}

test "transfer_sol rejects instruction data with non-u64 amount length" {
    var arena: Arena = undefined;
    var input: [8]u8 = undefined;
    writeU64LeTest(input[0..], 0);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_transfer_sol_process(&arena, input[0..].ptr, &.{ 1, 2, 3 }));
}

test "transfer_sol rejects fewer than three serialized accounts" {
    var arena: Arena = undefined;
    var input: [8]u8 = undefined;
    writeU64LeTest(input[0..], 2);
    var amount: [8]u8 = undefined;
    writeU64LeTest(amount[0..], 1);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_transfer_sol_process(&arena, input[0..].ptr, amount[0..]));
}

test "transfer_sol rejects non-signer source account before CPI" {
    var arena: Arena = undefined;
    var input: [transfer_test_input_len]u8 = undefined;
    const system_program_key: Pubkey = [_]u8{0} ** 32;
    writeTransferTestInput(input[0..], false, true, true, system_program_key);
    var amount: [8]u8 = undefined;
    writeU64LeTest(amount[0..], 1);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_transfer_sol_process(&arena, input[0..].ptr, amount[0..]));
}

test "transfer_sol rejects readonly source account before CPI" {
    var arena: Arena = undefined;
    var input: [transfer_test_input_len]u8 = undefined;
    const system_program_key: Pubkey = [_]u8{0} ** 32;
    writeTransferTestInput(input[0..], true, false, true, system_program_key);
    var amount: [8]u8 = undefined;
    writeU64LeTest(amount[0..], 1);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_transfer_sol_process(&arena, input[0..].ptr, amount[0..]));
}

test "transfer_sol rejects readonly destination account before CPI" {
    var arena: Arena = undefined;
    var input: [transfer_test_input_len]u8 = undefined;
    const system_program_key: Pubkey = [_]u8{0} ** 32;
    writeTransferTestInput(input[0..], true, true, false, system_program_key);
    var amount: [8]u8 = undefined;
    writeU64LeTest(amount[0..], 1);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_transfer_sol_process(&arena, input[0..].ptr, amount[0..]));
}

test "transfer_sol rejects non-system program account before CPI" {
    var arena: Arena = undefined;
    var input: [transfer_test_input_len]u8 = undefined;
    const not_system_program_key: Pubkey = [_]u8{7} ** 32;
    writeTransferTestInput(input[0..], true, true, true, not_system_program_key);
    var amount: [8]u8 = undefined;
    writeU64LeTest(amount[0..], 1);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_transfer_sol_process(&arena, input[0..].ptr, amount[0..]));
}

test "transfer_sol rejects zero lamport amount before CPI" {
    var arena: Arena = undefined;
    var input: [transfer_test_input_len]u8 = undefined;
    const system_program_key: Pubkey = [_]u8{0} ** 32;
    writeTransferTestInput(input[0..], true, true, true, system_program_key);
    var amount: [8]u8 = undefined;
    writeU64LeTest(amount[0..], 0);
    try std.testing.expectEqual(@as(u64, 1), zxcaml_transfer_sol_process(&arena, input[0..].ptr, amount[0..]));
}
