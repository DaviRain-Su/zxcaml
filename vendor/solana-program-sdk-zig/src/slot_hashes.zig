const std = @import("std");
const pubkey_mod = @import("pubkey/root.zig");
const PublicKey = pubkey_mod.Pubkey;

pub const SlotHashes = struct {
    ptr: [*]SlotHash,
    len: u64,

    pub const id = pubkey_mod.comptimeFromBase58("SysvarS1otHashes111111111111111111111111111");

    /// About 2.5 minutes to get your vote in.
    pub const max_entries = 512;
};

pub const SlotHash = extern struct {
    slot: u64,
    hash: [32]u8,

    /// View raw sysvar account data as a slice of SlotHash entries.
    /// `data` is expected to start with a little-endian u64 entry count
    /// followed by `len` packed `SlotHash` records. The returned slice
    /// has 1-byte alignment because the records sit immediately after
    /// the length prefix; access through it works for byte-level reads.
    pub fn from(data: []const u8) []align(1) const SlotHash {
        std.debug.assert(data.len >= @sizeOf(u64));
        const len = std.mem.readInt(u64, data[0..@sizeOf(u64)], .little);
        const body = data.ptr + @sizeOf(u64);
        return @as([*]align(1) const SlotHash, @ptrCast(body))[0..len];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "slot_hashes: SlotHash.from parses entry count" {
    var buf: [@sizeOf(u64) + 2 * @sizeOf(SlotHash)]u8 align(8) = undefined;
    std.mem.writeInt(u64, buf[0..8], 2, .little);
    const first = SlotHash{ .slot = 42, .hash = .{1} ** 32 };
    const second = SlotHash{ .slot = 43, .hash = .{2} ** 32 };
    @memcpy(buf[8..][0..@sizeOf(SlotHash)], std.mem.asBytes(&first));
    @memcpy(buf[8 + @sizeOf(SlotHash) ..][0..@sizeOf(SlotHash)], std.mem.asBytes(&second));

    const entries = SlotHash.from(&buf);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u64, 42), entries[0].slot);
    try std.testing.expectEqual(@as(u64, 43), entries[1].slot);
}
