const std = @import("std");
pub const bpf = @import("../bpf.zig");
pub const stdlib = std;

/// Host-side fallback formatter used by the logging helpers.
pub inline fn hostPrint(comptime format: []const u8, args: anytype) void {
    std.debug.print("[solana] " ++ format ++ "\n", args);
}
