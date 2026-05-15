const shared = @import("shared.zig");
const model = @import("model.zig");

const std = shared.stdlib;
const AccountInfo = shared.AccountInfo;
const ProgramError = shared.ProgramError;
const sysvar = shared.sysvar;
const pubkey = shared.pubkey;
const Entry = model.Entry;
const MAX_ENTRIES = model.MAX_ENTRIES;

/// Zero-copy view over the stake-history sysvar account.
pub const StakeHistory = struct {
    /// Pointer into the sysvar account's data buffer. Entries are
    /// laid out contiguously in epoch-descending order.
    entries: []align(1) const Entry,

    /// Re-export for symmetry with the Rust API.
    pub const ID = sysvar.STAKE_HISTORY_ID;

    /// Parse the sysvar account. Returns `UnsupportedSysvar` if the
    /// account isn't the canonical stake-history sysvar, or
    /// `InvalidAccountData` if the buffer is too short / its
    /// length-prefix is inconsistent.
    pub fn fromAccount(info: AccountInfo) ProgramError!StakeHistory {
        if (!pubkey.pubkeyEqComptime(info.key(), sysvar.STAKE_HISTORY_ID)) {
            return error.UnsupportedSysvar;
        }
        const buf = info.data();
        if (buf.len < 8) return error.InvalidAccountData;
        const n = std.mem.readInt(u64, buf[0..8], .little);
        if (n > MAX_ENTRIES) return error.InvalidAccountData;
        const total = 8 + n * @sizeOf(Entry);
        if (buf.len < total) return error.InvalidAccountData;

        const entries_ptr: [*]align(1) const Entry = @ptrCast(buf[8..].ptr);
        return .{ .entries = entries_ptr[0..@intCast(n)] };
    }

    /// Look up the entry for `epoch` via binary search. Returns
    /// `null` if the epoch isn't represented in history.
    ///
    /// History is stored newest-first, so we search descending. Both
    /// `O(log n)` and stable across runtime versions.
    pub fn get(self: StakeHistory, epoch: u64) ?Entry {
        if (self.entries.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = self.entries[mid].epoch;
            if (e == epoch) return self.entries[mid];
            if (e > epoch) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Convenience: the most recent (highest-epoch) entry, or `null`
    /// if the history is empty.
    pub fn latest(self: StakeHistory) ?Entry {
        if (self.entries.len == 0) return null;
        return self.entries[0];
    }
};
