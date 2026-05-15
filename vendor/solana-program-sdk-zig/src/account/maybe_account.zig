const AccountInfo = @import("info.zig").AccountInfo;

// =========================================================================
// MaybeAccount — result of next_account (Pinocchio-style)
//
// When the Solana runtime serializes an instruction whose account list
// includes the same key more than once, occurrences after the first
// are encoded as an 8-byte "duplicate" record whose first byte holds
// the original account's index (instead of `NON_DUP_MARKER`).
//
// The lazy entrypoint's dup-aware iterators return `MaybeAccount` so
// callers can distinguish:
//   - `.account`: a non-duplicate `AccountInfo` pointing into the
//     input buffer
//   - `.duplicated`: the index of the original (earlier) account that
//     this slot duplicates — caller resolves the mapping
// =========================================================================

pub const MaybeAccount = union(enum) {
    account: AccountInfo,
    duplicated: u8,

    /// Extract the wrapped `AccountInfo`, panicking if this slot is a
    /// duplicate. Use this when you've structurally proven (or
    /// validated upstream) that duplicates can't occur.
    pub inline fn assumeAccount(self: MaybeAccount) AccountInfo {
        return switch (self) {
            .account => |a| a,
            .duplicated => @panic("MaybeAccount.assumeAccount called on duplicated account"),
        };
    }
};
