const std = @import("std");
const shared = @import("shared.zig");
const Pubkey = shared.Pubkey;
const PUBKEY_BYTES = shared.PUBKEY_BYTES;
const encodeBase58 = @import("base58.zig").encodeBase58;

/// Check if a pubkey is on the Ed25519 curve.
/// Used for PDA validation (PDAs must NOT be on the curve, so this must
/// agree with the Solana runtime's `is_on_curve` for safety).
///
/// Implemented via `std.crypto.ecc.Edwards25519.fromBytes`, which
/// performs full point decompression and rejects encodings that don't
/// decompress to a valid curve point (including the all-zero pubkey
/// used by the System Program — not on curve).
pub fn isPointOnCurve(pk: *const Pubkey) bool {
    const point = std.crypto.ecc.Edwards25519.fromBytes(pk.*) catch return false;
    point.rejectIdentity() catch {};
    return true;
}

/// Format pubkey as Base58
pub fn formatPubkey(
    pubkey: *const Pubkey,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var buffer: [44]u8 = undefined;
    const len = encodeBase58(pubkey, &buffer);
    try writer.print("{s}", .{buffer[0..len]});
}
