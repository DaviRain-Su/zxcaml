//! `spl-ata` — Zig client for the SPL Associated Token Account
//! program.
//!
//! Dual-target package exposing ATA PDA derivation, instruction
//! builders, and on-chain CPI wrappers.

const std = @import("std");

pub const id = @import("id.zig");
pub const derivation = @import("derivation.zig");
pub const instruction = @import("instruction.zig");
pub const cpi = @import("cpi.zig");

/// Associated Token Account program ID.
pub const PROGRAM_ID = id.PROGRAM_ID;

/// Public ATA derivation surface.
pub const ProgramDerivedAddress = derivation.ProgramDerivedAddress;
pub const findAddress = derivation.findAddress;
pub const findAddressClassic = derivation.findAddressClassic;
pub const findAddressToken2022 = derivation.findAddressToken2022;

test "@import(\"spl_ata\")-visible declarations exist" {
    try std.testing.expect(@hasDecl(@This(), "PROGRAM_ID"));
    try std.testing.expect(@hasDecl(@This(), "id"));
    try std.testing.expect(@hasDecl(@This(), "derivation"));
    try std.testing.expect(@hasDecl(@This(), "instruction"));
    try std.testing.expect(@hasDecl(@This(), "cpi"));
    try std.testing.expect(@hasDecl(@This(), "findAddress"));
}

test "PROGRAM_ID aliases id.PROGRAM_ID" {
    try std.testing.expectEqualSlices(u8, &id.PROGRAM_ID, &PROGRAM_ID);
}

test {
    std.testing.refAllDecls(@This());
}
