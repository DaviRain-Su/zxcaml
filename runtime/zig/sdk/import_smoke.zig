const std = @import("std");
const vendored_sdk = @import("vendored_sdk");

test "vendored SDK adapter shell resolves committed packages" {
    const sol = vendored_sdk.solana_program_sdk;
    const codec = vendored_sdk.solana_codec;
    const spl_token = vendored_sdk.spl_token;
    const spl_ata = vendored_sdk.spl_ata;
    const solana_system = vendored_sdk.solana_system;
    const spl_memo = vendored_sdk.spl_memo;

    try std.testing.expectEqual(@as(usize, 32), sol.PUBKEY_BYTES);

    var shortvec: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try codec.writeShortVec(7, &shortvec));
    try std.testing.expectEqualSlices(u8, &.{0x07}, shortvec[0..1]);

    const from: sol.Pubkey = .{1} ** sol.PUBKEY_BYTES;
    const to: sol.Pubkey = .{2} ** sol.PUBKEY_BYTES;
    var metas: [2]solana_system.AccountMeta = undefined;
    var data: solana_system.TransferData = undefined;
    const ix = solana_system.transfer(&from, &to, 7, &metas, &data);
    try std.testing.expectEqualSlices(u8, &solana_system.PROGRAM_ID, ix.program_id);

    try std.testing.expectEqualSlices(u8, &spl_token.PROGRAM_ID, &spl_token.id.PROGRAM_ID);
    try std.testing.expectEqualSlices(u8, &spl_ata.PROGRAM_ID, &spl_ata.id.PROGRAM_ID);
    try std.testing.expectEqualSlices(u8, &spl_memo.PROGRAM_ID, &spl_memo.id.PROGRAM_ID);
}
