const std = @import("std");
const vendored_sdk = @import("vendored_sdk");

test "vendored SDK adapter shell resolves committed packages" {
    const sol = vendored_sdk.solana_program_sdk;

    try std.testing.expectEqual(@as(usize, 32), sol.hash.HASH_BYTES);
    try std.testing.expectEqual(@as(usize, 32), sol.secp256k1_recover.HASH_LEN);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(sol.clock.Clock));
    try std.testing.expectEqual(@as(u8, 50), sol.rent.Rent.default_burn_percent);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), sol.compute_budget.remaining());
}
