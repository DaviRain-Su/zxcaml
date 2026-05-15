const std = @import("std");
const shared = @import("shared.zig");

const Pubkey = shared.Pubkey;
const Account = shared.Account;

// =========================================================================
// CpiAccountInfo — C-ABI-compatible view for CPI (SolAccountInfo layout)
//
// Only use this when passing accounts to `cpi.invoke`.
// Normal programs should use `AccountInfo` instead.
// =========================================================================

pub const CpiAccountInfo = extern struct {
    /// Raw pointer to the account's public key (32 bytes on-chain).
    /// Stored as a pointer so `CpiAccountInfo` can be passed by value
    /// while still referencing the original `Account` memory.
    key_ptr: *const Pubkey,

    /// Raw pointer to the account's lamport balance.
    /// Allows the CPI syscall to read the balance without copying.
    lamports_ptr: *u64,

    /// Length of the account's data buffer, in bytes.
    /// The actual data lives at `data_ptr`.
    data_len: u64,

    /// Pointer to the account's data buffer.
    /// Sized by `data_len`. Useful helpers: `data()` / `dataLen()`.
    data_ptr: [*]u8,

    /// Raw pointer to the account's owner program ID.
    /// Determines which program can mutate this account (besides the
    /// account itself, if it's executable).
    owner_ptr: *const Pubkey,

    /// Rent epoch (Solana's rent-collection mechanism).
    /// Always set to `0` in our CPI view — the runtime ignores this
    /// field during CPI; it only matters for top-level instructions.
    rent_epoch: u64,

    /// 1 if this account signed the transaction, 0 otherwise.
    /// Check with `isSigner()` rather than reading this field directly.
    is_signer: u8,

    /// 1 if this account was marked writable in the instruction's
    /// account list, 0 otherwise. Check with `isWritable()`.
    is_writable: u8,

    /// 1 if this account's owner is the BPF Loader (i.e., it contains
    /// executable bytecode), 0 otherwise.
    /// CPI callers rarely need to check this directly.
    is_executable: u8,

    /// Padding to reach the 56-byte `SolAccountInfo` C-ABI size.
    /// Must be zero-initialized when constructing manually.
    _abi_padding: [5]u8,

    /// Build a `CpiAccountInfo` from a pointer to our internal
    /// `Account` struct.
    ///
    /// The data pointer is computed as `ptr + @sizeOf(Account)` because
    /// in-memory layout places the variable-length data immediately
    /// after the fixed-size `Account` header.
    ///
    /// `is_signer` / `is_writable` / `is_executable` live at consecutive
    /// offsets 1, 2, 3 in `Account`. We copy them as a single `u32`
    /// load+store (4 bytes — pulling in one byte of padding on both
    /// sides, which is safe since both structures have padding there).
    /// This mirrors Pinocchio's `CpiAccount::init_from_account_view`
    /// and saves a few compute units vs. three separate byte loads +
    /// three byte stores.
    ///
    /// We intentionally do *not* do a `u64` copy (8 bytes) because the
    /// source's byte 8 is `key[0]`, which is non-zero, and would write
    /// garbage into `_abi_padding`.
    pub inline fn fromPtr(ptr: *Account) CpiAccountInfo {
        const dp: [*]u8 = @ptrFromInt(@intFromPtr(ptr) + @sizeOf(Account));
        const flags_src: *align(1) const u32 = @ptrCast(&ptr.is_signer);
        var out: CpiAccountInfo = .{
            .key_ptr = &ptr.key,
            .lamports_ptr = &ptr.lamports,
            .data_len = ptr.data_len,
            .data_ptr = dp,
            .owner_ptr = &ptr.owner,
            .rent_epoch = 0,
            .is_signer = undefined,
            .is_writable = undefined,
            .is_executable = undefined,
            ._abi_padding = undefined,
        };
        const flags_dst: *align(1) u32 = @ptrCast(&out.is_signer);
        flags_dst.* = flags_src.*;
        return out;
    }

    /// Convenience accessor: returns a pointer to the account's public key.
    pub inline fn key(self: CpiAccountInfo) *const Pubkey {
        return self.key_ptr;
    }

    /// Convenience accessor: returns a pointer to the account's owner.
    pub inline fn owner(self: CpiAccountInfo) *const Pubkey {
        return self.owner_ptr;
    }

    /// Convenience accessor: dereferences `lamports_ptr` to return the
    /// current lamport balance.
    pub inline fn lamports(self: CpiAccountInfo) u64 {
        return self.lamports_ptr.*;
    }

    /// Convenience accessor: returns the data length as a `usize`.
    pub inline fn dataLen(self: CpiAccountInfo) usize {
        return @intCast(self.data_len);
    }

    /// Returns `true` when the account signed the transaction.
    pub inline fn isSigner(self: CpiAccountInfo) bool {
        return self.is_signer != 0;
    }

    /// Returns `true` when the account is writable.
    pub inline fn isWritable(self: CpiAccountInfo) bool {
        return self.is_writable != 0;
    }

    /// Returns a slice of the account's data buffer, sized by `dataLen()`.
    /// The slice is backed by the original `Account` memory — no copy.
    pub inline fn data(self: CpiAccountInfo) []u8 {
        return self.data_ptr[0..self.dataLen()];
    }
};

comptime {
    // SolAccountInfo C ABI is 56 bytes; the syscall reads accounts at this stride.
    std.debug.assert(@sizeOf(CpiAccountInfo) == 56);
}
