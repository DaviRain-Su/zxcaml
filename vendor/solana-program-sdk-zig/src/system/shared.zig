const std = @import("std");

pub const pubkey = @import("../pubkey/root.zig");
pub const account_mod = @import("../account/root.zig");
pub const cpi = @import("../cpi/root.zig");
pub const program_error = @import("../program_error/root.zig");
pub const instruction = @import("../instruction/root.zig");
pub const pda = @import("../pda/root.zig");

pub const Pubkey = pubkey.Pubkey;
pub const CpiAccountInfo = account_mod.CpiAccountInfo;
pub const ProgramResult = program_error.ProgramResult;
pub const MAX_SEED_LEN = pda.MAX_SEED_LEN;
pub const DISCRIMINANT_BYTES = @sizeOf(u32);
pub const U64_BYTES = @sizeOf(u64);
pub const PUBKEY_BYTES = @sizeOf(Pubkey);
pub const NONCE_STATE_SIZE: u64 = 80;

/// System Program instruction discriminants
pub const SystemInstruction = enum(u32) {
    CreateAccount = 0,
    Assign = 1,
    Transfer = 2,
    CreateAccountWithSeed = 3,
    AdvanceNonceAccount = 4,
    WithdrawNonceAccount = 5,
    InitializeNonceAccount = 6,
    AuthorizeNonceAccount = 7,
    Allocate = 8,
    AllocateWithSeed = 9,
    AssignWithSeed = 10,
    TransferWithSeed = 11,
    UpgradeNonceAccount = 12,
};

/// System Program ID (all zeros).
///
/// ⚠️ On Zig 0.16 BPF builds, module-scope const arrays can land at
/// invalid low VM addresses, so you generally must **not** take this
/// constant's address and pass it to a syscall directly. For CPI calls,
/// always derive the program ID from the System Program account that
/// the caller passed into the program's input (e.g.
/// `system_program.key()` from the parsed `CpiAccountInfo`). The
/// high-level wrappers in this module enforce that pattern.
pub const SYSTEM_PROGRAM_ID: Pubkey = .{0} ** 32;

pub const CreateAccountPayload = extern struct {
    lamports: u64,
    space: u64,
    owner: Pubkey,
};

pub const TransferPayload = extern struct {
    lamports: u64,
};

pub const AssignPayload = extern struct {
    owner: Pubkey,
};

pub const AllocatePayload = extern struct {
    space: u64,
};

pub const NonceAuthorityPayload = extern struct {
    authority: Pubkey,
};

pub fn fixedIxData(comptime discriminant: SystemInstruction, comptime Payload: type, payload: Payload) [DISCRIMINANT_BYTES + @sizeOf(Payload)]u8 {
    return instruction.comptimeInstructionData(u32, Payload).initWithDiscriminant(
        @intFromEnum(discriminant),
        payload,
    );
}

pub fn variableSeedIxCapacity(comptime fixed_bytes_without_seed: usize) usize {
    return fixed_bytes_without_seed + MAX_SEED_LEN;
}

pub fn StackIxDataWriter(comptime capacity: usize) type {
    return struct {
        buf: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub inline fn init() Self {
            return .{};
        }

        pub inline fn writeDiscriminant(self: *Self, discriminant: SystemInstruction) void {
            self.writeU32(@intFromEnum(discriminant));
        }

        pub inline fn writeU32(self: *Self, value: u32) void {
            std.mem.writeInt(u32, self.buf[self.len..][0..DISCRIMINANT_BYTES], value, .little);
            self.len += DISCRIMINANT_BYTES;
        }

        pub inline fn writeU64(self: *Self, value: u64) void {
            std.mem.writeInt(u64, self.buf[self.len..][0..U64_BYTES], value, .little);
            self.len += U64_BYTES;
        }

        pub inline fn writePubkey(self: *Self, key: *const Pubkey) void {
            self.writeBytes(key[0..PUBKEY_BYTES]);
        }

        pub inline fn writeSeed(self: *Self, seed: []const u8) void {
            self.writeU64(seed.len);
            self.writeBytes(seed);
        }

        pub inline fn writeBytes(self: *Self, bytes: []const u8) void {
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }

        pub inline fn written(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub fn discriminantOnlyData(comptime discriminant: SystemInstruction) [DISCRIMINANT_BYTES]u8 {
    return instruction.comptimeDiscriminantOnly(@as(u32, @intFromEnum(discriminant)));
}
