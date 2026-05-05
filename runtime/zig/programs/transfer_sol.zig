//! Runtime entrypoint for the transfer_sol example.

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
