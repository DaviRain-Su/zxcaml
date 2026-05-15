const shared = @import("shared.zig");
const Pubkey = shared.Pubkey;
const readU16LE = shared.readU16LE;

/// View into one instruction parsed from the sysvar.
///
/// Fields point into the sysvar account's data buffer — no copies.
/// `programId()`, `accounts()`, `data()` each fold to a single
/// pointer + bounds compute.
pub const IntrospectedInstruction = struct {
    /// Raw bytes covering exactly this one instruction (`[num_accounts:u16]
    /// [account_metas][program_id][data_len:u16][data]`).
    bytes: []const u8,

    /// Number of `AccountMeta` entries in this instruction.
    pub inline fn numAccounts(self: IntrospectedInstruction) u16 {
        return readU16LE(self.bytes, 0);
    }

    /// Read the i-th account meta.
    pub inline fn account(
        self: IntrospectedInstruction,
        i: usize,
    ) IntrospectedAccountMeta {
        const off = 2 + i * (1 + 32);
        return .{
            .meta_byte = self.bytes[off],
            .pubkey = @ptrCast(self.bytes[off + 1 ..][0..32]),
        };
    }

    /// Iterate the account metas. Returns a slice-like view.
    pub fn accounts(self: IntrospectedInstruction) AccountIterator {
        return .{ .ix = self, .i = 0 };
    }

    /// Pointer to the instruction's program id (32 bytes).
    pub fn programId(self: IntrospectedInstruction) *const Pubkey {
        const k = self.numAccounts();
        const off = 2 + @as(usize, k) * (1 + 32);
        return @ptrCast(self.bytes[off..][0..32]);
    }

    /// Raw instruction data bytes.
    pub fn data(self: IntrospectedInstruction) []const u8 {
        const k = self.numAccounts();
        const off = 2 + @as(usize, k) * (1 + 32) + 32;
        const data_len = readU16LE(self.bytes, off);
        return self.bytes[off + 2 ..][0..data_len];
    }
};

/// A single account-meta entry inside an introspected instruction.
pub const IntrospectedAccountMeta = struct {
    /// Raw meta byte: `bit 0` = is_signer, `bit 1` = is_writable.
    meta_byte: u8,
    /// Pointer to the 32-byte pubkey inside the sysvar buffer.
    pubkey: *const Pubkey,

    pub inline fn isSigner(self: IntrospectedAccountMeta) bool {
        return (self.meta_byte & 0b01) != 0;
    }
    pub inline fn isWritable(self: IntrospectedAccountMeta) bool {
        return (self.meta_byte & 0b10) != 0;
    }
};

/// Lazy iterator over an introspected instruction's account metas.
pub const AccountIterator = struct {
    ix: IntrospectedInstruction,
    i: usize,

    pub fn next(self: *AccountIterator) ?IntrospectedAccountMeta {
        if (self.i >= self.ix.numAccounts()) return null;
        const m = self.ix.account(self.i);
        self.i += 1;
        return m;
    }
};
