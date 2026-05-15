/// Maximum number of entries the runtime keeps. After this, oldest
/// entries are truncated.
pub const MAX_ENTRIES: usize = 512;

/// On-chain stake-history entry. `repr(C)` matches the runtime's
/// serialized form exactly — `extern struct` in Zig gives the same
/// guarantees.
pub const Entry = extern struct {
    epoch: u64,
    effective: u64,
    activating: u64,
    deactivating: u64,

    pub fn isZero(self: Entry) bool {
        return self.effective == 0 and self.activating == 0 and self.deactivating == 0;
    }
};
