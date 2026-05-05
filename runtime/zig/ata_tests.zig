const std = @import("std");
const ata = @import("programs/ata.zig");

test "ATA program declarations compile from runtime module root" {
    std.testing.refAllDecls(ata);
}
