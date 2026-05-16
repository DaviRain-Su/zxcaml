const std = @import("std");
const vendored_sdk = @import("vendored_sdk");

test "vendored SDK adapter shell resolves committed packages" {
    const sol = vendored_sdk.solana_program_sdk;

    try std.testing.expectEqual(@as(usize, 32), sol.hash.HASH_BYTES);
    try std.testing.expectEqual(@as(usize, 32), sol.secp256k1_recover.HASH_LEN);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(sol.clock.Clock));
    try std.testing.expectEqual(@as(u8, 50), sol.rent.Rent.default_burn_percent);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), sol.compute_budget.remaining());
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(sol.account.CpiAccountInfo));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(sol.cpi.AccountMeta));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(sol.entrypoint.InstructionContext));
    try std.testing.expectEqual(@as(usize, 16), sol.pda.MAX_SEEDS);
    try std.testing.expectEqual(@as(u64, 2) << 32, sol.program_error.INVALID_ARGUMENT);

    var empty_input: [48]u8 = [_]u8{0} ** 48;
    var ctx = sol.entrypoint.InstructionContext.init(empty_input[0..].ptr);
    try std.testing.expectEqual(@as(u64, 0), ctx.remainingAccounts());
    try std.testing.expectEqual(@as(usize, 0), ctx.instructionDataUnchecked().len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 32, ctx.programIdUnchecked()[0..]);
}
