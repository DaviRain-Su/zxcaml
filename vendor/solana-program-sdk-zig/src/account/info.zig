const std = @import("std");
const shared = @import("shared.zig");
const pubkey = shared.pubkey;
const program_error = shared.program_error;
const Pubkey = shared.Pubkey;
const ProgramError = shared.ProgramError;
const Account = shared.Account;
const MAX_PERMITTED_DATA_INCREASE = shared.MAX_PERMITTED_DATA_INCREASE;
const CpiAccountInfo = @import("cpi_info.zig").CpiAccountInfo;

// =========================================================================
// AccountInfo — primary account type (Pinocchio-style, 8 bytes)
//
// A single pointer into the runtime input buffer. All field access
// dereferences through it — compiles to the same BPF instructions as
// hand-written pointer arithmetic.
//
// For CPI calls, use `toCpiInfo()` to create a C-ABI-compatible view.
// =========================================================================

pub const AccountInfo = struct {
    raw: *align(8) Account,

    // --- Accessors (all inline, zero overhead) ---

    pub inline fn key(self: AccountInfo) *const Pubkey {
        return &self.raw.key;
    }

    pub inline fn owner(self: AccountInfo) *const Pubkey {
        return &self.raw.owner;
    }

    pub inline fn lamports(self: AccountInfo) u64 {
        return self.raw.lamports;
    }

    pub inline fn setLamports(self: AccountInfo, value: u64) void {
        self.raw.lamports = value;
    }

    /// Subtract lamports from this account (source of a transfer).
    /// Caller must ensure this account is writable and has sufficient balance.
    pub inline fn subLamports(self: AccountInfo, amount: u64) void {
        self.raw.lamports -= amount;
    }

    /// Add lamports to this account (destination of a transfer).
    pub inline fn addLamports(self: AccountInfo, amount: u64) void {
        self.raw.lamports += amount;
    }

    /// Subtract lamports, returning `error.ArithmeticOverflow` on
    /// underflow. Use when balance cannot be assumed to cover `amount`
    /// (typical for user-controlled withdrawal amounts).
    pub inline fn subLamportsChecked(self: AccountInfo, amount: u64) ProgramError!void {
        const new_balance, const overflow = @subWithOverflow(self.raw.lamports, amount);
        if (overflow != 0) return error.ArithmeticOverflow;
        self.raw.lamports = new_balance;
    }

    /// Add lamports, returning `error.ArithmeticOverflow` on overflow.
    /// Use when the destination balance could realistically reach
    /// `u64.max` (unusual outside of fees aggregator programs).
    pub inline fn addLamportsChecked(self: AccountInfo, amount: u64) ProgramError!void {
        const new_balance, const overflow = @addWithOverflow(self.raw.lamports, amount);
        if (overflow != 0) return error.ArithmeticOverflow;
        self.raw.lamports = new_balance;
    }

    pub inline fn dataLen(self: AccountInfo) usize {
        return @intCast(self.raw.data_len);
    }

    pub inline fn isSigner(self: AccountInfo) bool {
        return self.raw.is_signer != 0;
    }

    pub inline fn isWritable(self: AccountInfo) bool {
        return self.raw.is_writable != 0;
    }

    pub inline fn executable(self: AccountInfo) bool {
        return self.raw.is_executable != 0;
    }

    pub inline fn dataPtr(self: AccountInfo) [*]u8 {
        return @ptrFromInt(@intFromPtr(self.raw) + @sizeOf(Account));
    }

    pub inline fn data(self: AccountInfo) []u8 {
        return self.dataPtr()[0..self.dataLen()];
    }

    pub inline fn isOwnedBy(self: AccountInfo, program: *const Pubkey) bool {
        return pubkey.pubkeyEq(self.owner(), program);
    }

    /// Compare this account's owner against a compile-time-known
    /// program id. Generates four `u64`-immediate compares — no second
    /// load and no rodata reference to the expected pubkey.
    ///
    /// ```zig
    /// const MY_PROGRAM_ID = sol.pubkey.comptimeFromBase58("...");
    /// if (!account.isOwnedByComptime(MY_PROGRAM_ID)) {
    ///     return error.IncorrectProgramId;
    /// }
    /// ```
    pub inline fn isOwnedByComptime(self: AccountInfo, comptime program: Pubkey) bool {
        return pubkey.pubkeyEqComptime(self.owner(), program);
    }

    /// Like `isOwnedByComptime`, but returns
    /// `error.IncorrectProgramId` when the owner doesn't match.
    pub inline fn assertOwnerComptime(self: AccountInfo, comptime program: Pubkey) ProgramError!void {
        if (!pubkey.pubkeyEqComptime(self.owner(), program)) {
            return error.IncorrectProgramId;
        }
    }

    /// True if this account's owner matches **any** of the
    /// comptime-known program IDs. Use for programs that accept
    /// either SPL Token or Token-2022 (or any other multi-program
    /// scenario).
    ///
    /// ```zig
    /// if (!mint.isOwnedByAny(&.{
    ///     sol.spl_token_program_id,
    ///     sol.spl_token_2022_program_id,
    /// })) return error.IncorrectProgramId;
    /// ```
    pub inline fn isOwnedByAny(self: AccountInfo, comptime allowed: []const Pubkey) bool {
        return pubkey.pubkeyEqAny(self.owner(), allowed);
    }

    /// Error-returning counterpart to `isOwnedByAny`.
    pub inline fn assertOwnerAny(self: AccountInfo, comptime allowed: []const Pubkey) ProgramError!void {
        if (!pubkey.pubkeyEqAny(self.owner(), allowed)) {
            return error.IncorrectProgramId;
        }
    }

    /// Compare this account's key against a compile-time-known pubkey.
    pub inline fn keyEqComptime(self: AccountInfo, comptime expected: Pubkey) bool {
        return pubkey.pubkeyEqComptime(self.key(), expected);
    }

    /// Return `error.MissingRequiredSignature` if this account did not
    /// sign the transaction.
    pub inline fn expectSigner(self: AccountInfo) ProgramError!void {
        if (!self.isSigner()) return error.MissingRequiredSignature;
    }

    /// Return `error.ImmutableAccount` if this account is not writable.
    pub inline fn expectWritable(self: AccountInfo) ProgramError!void {
        if (!self.isWritable()) return error.ImmutableAccount;
    }

    /// Return `error.InvalidAccountData` if this account is not executable.
    /// Useful for sanity-checking that an "executable" account passed
    /// into the program really is a program account.
    pub inline fn expectExecutable(self: AccountInfo) ProgramError!void {
        if (!self.executable()) return error.InvalidAccountData;
    }

    /// Combined expectation check, mirroring `parseAccountsWith`'s
    /// `AccountExpectation` shape but applied to a single account.
    ///
    /// ```zig
    /// try authority.expect(.{ .signer = true, .writable = true });
    /// try mint.expect(.{ .owner = sol.spl_token_program_id });
    /// try sysvar.expect(.{ .key = sol.sysvar.RENT_ID });
    /// ```
    ///
    /// Each check is `comptime if`-guarded: only the requested
    /// branches generate code. Three checks compile to three branches,
    /// the unset fields disappear entirely. Same BPF as calling the
    /// individual `expectSigner` / `expectWritable` / etc. helpers
    /// in sequence — but the single-call site is easier to read and
    /// keeps related assertions together.
    pub inline fn expect(self: AccountInfo, comptime spec: anytype) ProgramError!void {
        const S = @TypeOf(spec);
        const info = @typeInfo(S);
        if (info != .@"struct") {
            @compileError("AccountInfo.expect requires a struct literal");
        }
        inline for (info.@"struct".fields) |field| {
            const name = field.name;
            if (comptime !std.mem.eql(u8, name, "signer") and
                !std.mem.eql(u8, name, "writable") and
                !std.mem.eql(u8, name, "executable") and
                !std.mem.eql(u8, name, "owner") and
                !std.mem.eql(u8, name, "owner_any") and
                !std.mem.eql(u8, name, "key") and
                !std.mem.eql(u8, name, "key_any"))
            {
                @compileError("Unknown expectation field: '" ++ name ++
                    "'. Allowed: signer, writable, executable, owner, owner_any, key, key_any.");
            }
        }
        // NOTE: we deliberately do NOT auto-fold `signer + writable`
        // into `expectSignerWritable`. Measurements showed the
        // u16-combined check helps some instructions and hurts others
        // (the wider load interacts differently with the register
        // scheduler). The user can call `expectSignerWritable` directly
        // when measurement says it wins.
        if (comptime @hasField(S, "signer") and @field(spec, "signer")) {
            try self.expectSigner();
        }
        if (comptime @hasField(S, "writable") and @field(spec, "writable")) {
            try self.expectWritable();
        }
        if (comptime @hasField(S, "executable") and @field(spec, "executable")) {
            try self.expectExecutable();
        }
        if (comptime @hasField(S, "owner")) {
            const owner_val: Pubkey = @field(spec, "owner");
            if (!pubkey.pubkeyEqComptime(self.owner(), owner_val)) {
                return program_error.fail(
                    @src(),
                    "expect:owner_mismatch",
                    error.IncorrectProgramId,
                );
            }
        }
        if (comptime @hasField(S, "owner_any")) {
            if (!pubkey.pubkeyEqAny(self.owner(), @field(spec, "owner_any"))) {
                return program_error.fail(
                    @src(),
                    "expect:owner_any_mismatch",
                    error.IncorrectProgramId,
                );
            }
        }
        if (comptime @hasField(S, "key")) {
            const key_val: Pubkey = @field(spec, "key");
            if (!pubkey.pubkeyEqComptime(self.key(), key_val)) {
                return program_error.fail(@src(), "expect:key_mismatch", error.InvalidArgument);
            }
        }
        if (comptime @hasField(S, "key_any")) {
            if (!pubkey.pubkeyEqAny(self.key(), @field(spec, "key_any"))) {
                return program_error.fail(@src(), "expect:key_any_mismatch", error.InvalidArgument);
            }
        }
    }

    /// Combined `expectSigner` + key-equality check. Common pattern
    /// for "authority signer must equal stored key" — saves the
    /// caller from writing the two-line idiom. Returns
    /// `error.MissingRequiredSignature` first (matches sequential
    /// `try expectSigner(); try keyEq(...)` ordering).
    pub inline fn expectSignerKey(
        self: AccountInfo,
        expected: *const Pubkey,
    ) ProgramError!void {
        if (!self.isSigner()) return error.MissingRequiredSignature;
        if (!pubkey.pubkeyEq(self.key(), expected)) {
            return program_error.fail(@src(), "expect:signer_key_mismatch", error.InvalidArgument);
        }
    }

    /// Comptime-key variant — folds the 32-byte compare into four
    /// u64-immediate compares.
    pub inline fn expectSignerKeyComptime(
        self: AccountInfo,
        comptime expected: Pubkey,
    ) ProgramError!void {
        if (!self.isSigner()) return error.MissingRequiredSignature;
        if (!pubkey.pubkeyEqComptime(self.key(), expected)) {
            return program_error.fail(@src(), "expect:signer_key_mismatch", error.InvalidArgument);
        }
    }

    /// Combined `expectSigner + expectWritable` — checks both flags
    /// with a single u16 load instead of two byte loads. The happy
    /// path is one compare against `0x0101` (both bytes = 1). Saves
    /// 2-3 CU vs. calling the two helpers in sequence.
    ///
    /// On failure: prefers `MissingRequiredSignature` over
    /// `ImmutableAccount`, matching the order of the equivalent
    /// hand-written `try expectSigner(); try expectWritable();`.
    pub inline fn expectSignerWritable(self: AccountInfo) ProgramError!void {
        // is_signer at offset 1, is_writable at offset 2. Both bytes
        // are 0 or 1 (never anything else). Combined u16 LE pattern
        // for "signer && writable" is 0x0101.
        const flags_ptr: *align(1) const u16 = @ptrCast(&self.raw.is_signer);
        if (flags_ptr.* != 0x0101) {
            // Fall back to individual checks to produce the right
            // error variant. Cold path — only runs when one of the
            // two flags is actually missing.
            if (!self.isSigner()) return error.MissingRequiredSignature;
            return error.ImmutableAccount;
        }
    }

    /// Read a typed value from account data at the given byte offset.
    /// Zero overhead — compiles to a single pointer dereference.
    ///
    /// ```zig
    /// const counter: u64 = account.readData(u64, 0);
    /// const flag: bool = account.readData(bool, 8);
    /// ```
    pub inline fn readData(self: AccountInfo, comptime T: type, comptime offset: usize) T {
        comptime {
            if (offset + @sizeOf(T) > 0) { // runtime check done separately
                // offset + @sizeOf(T) must fit in data
            }
        }
        const ptr: *align(1) const T = @ptrCast(@alignCast(self.dataPtr() + offset));
        return ptr.*;
    }

    /// Write a typed value to account data at the given byte offset.
    /// Zero overhead — compiles to a single pointer store.
    ///
    /// ```zig
    /// account.writeData(u64, 0, new_counter);
    /// ```
    pub inline fn writeData(self: AccountInfo, comptime T: type, comptime offset: usize, value: T) void {
        const ptr: *align(1) T = @ptrCast(@alignCast(self.dataPtr() + offset));
        ptr.* = value;
    }

    /// Typed mutable view over the account's data, starting at offset 0.
    /// Returns `*align(1) T` — no copies, no allocation, single
    /// pointer-cast. Caller is responsible for asserting the layout
    /// is correct (use `TypedAccount(T)` for discriminator-checked
    /// access).
    ///
    /// ```zig
    /// const state: *align(1) MyState = account.dataAs(MyState);
    /// state.counter += 1;  // direct write into account data
    /// ```
    pub inline fn dataAs(self: AccountInfo, comptime T: type) *align(1) T {
        return @ptrCast(@alignCast(self.dataPtr()));
    }

    /// Read-only counterpart to `dataAs`.
    pub inline fn dataAsConst(self: AccountInfo, comptime T: type) *align(1) const T {
        return @ptrCast(@alignCast(self.dataPtr()));
    }

    // ---------------------------------------------------------------
    // Resize / realloc
    //
    // The Solana runtime reserves `MAX_PERMITTED_DATA_INCREASE` (10 KiB)
    // of writable scratch after every account's data region. Inside one
    // instruction we may grow `data_len` up to `original_data_len +
    // MAX_PERMITTED_DATA_INCREASE`, where `original_data_len` is the
    // length captured at entry (stored in the 4-byte slot right before
    // `key` — corresponds to our `Account._padding`).
    //
    // Shrinking is always allowed within `[0, original_data_len +
    // MAX_PERMITTED_DATA_INCREASE]`.
    //
    // SAFETY notes:
    //   - Caller must ensure the program owns the account; the runtime
    //     enforces this at instruction-end (writes to data outside the
    //     allowed window will abort the tx).
    //   - The 10 KiB scratch is **zero-initialised at entrypoint** —
    //     calling `resize` with `zero_init=false` is safe on the first
    //     grow. If you grew, shrank, then grew again, pass `true` to
    //     wipe stale bytes (or accept that stale bytes are visible).
    // ---------------------------------------------------------------

    /// Return the data length that was captured when the runtime
    /// serialized this account for the current invocation. Resize
    /// budget = `original_data_len + MAX_PERMITTED_DATA_INCREASE`.
    pub inline fn originalDataLen(self: AccountInfo) usize {
        // `_padding[4]` is actually a `u32` little-endian length placed
        // by the runtime just before `key`. Read it through an aligned
        // pointer for a single load.
        const ptr: *align(4) const u32 = @ptrCast(&self.raw._padding);
        return @intCast(ptr.*);
    }

    /// Set the account's `data_len`. Does NOT zero or move memory —
    /// just rewrites the length header. Use the high-level `resize`
    /// helper unless you have a specific reason to skip the bounds /
    /// zero-init steps.
    inline fn writeDataLen(self: AccountInfo, new_len: u64) void {
        self.raw.data_len = new_len;
    }

    /// Resize this account's data to `new_len`.
    ///
    /// Returns `error.InvalidRealloc` if `new_len` exceeds
    /// `original_data_len + MAX_PERMITTED_DATA_INCREASE`.
    ///
    /// When `zero_init` is `true`, any bytes added by growing past the
    /// previous `data_len` are zeroed. The entrypoint-provided 10 KiB
    /// scratch is already zero on first use, so pass `false` to skip
    /// the memset if you haven't shrunk-and-regrown.
    ///
    /// This mirrors `solana_program::account_info::AccountInfo::realloc`.
    pub fn resize(
        self: AccountInfo,
        new_len: usize,
        zero_init: bool,
    ) ProgramError!void {
        const old_len = self.dataLen();
        if (new_len == old_len) return;

        const orig = self.originalDataLen();
        // `new_len.saturating_sub(orig) > MAX_PERMITTED_DATA_INCREASE`
        // — only the growth past the original is bounded; shrinking is
        // unconstrained.
        if (new_len > orig and (new_len - orig) > MAX_PERMITTED_DATA_INCREASE) {
            return error.InvalidRealloc;
        }

        self.writeDataLen(new_len);

        if (zero_init and new_len > old_len) {
            const dp = self.dataPtr();
            @memset(dp[old_len..new_len], 0);
        }
    }

    /// Trusting variant of `resize` — skips the
    /// `MAX_PERMITTED_DATA_INCREASE` check. Caller must guarantee the
    /// new length fits in the scratch window. Useful when the new
    /// length is comptime-known and provably in range.
    pub inline fn resizeUnchecked(
        self: AccountInfo,
        new_len: usize,
        zero_init: bool,
    ) void {
        const old_len = self.dataLen();
        self.writeDataLen(new_len);
        if (zero_init and new_len > old_len) {
            const dp = self.dataPtr();
            @memset(dp[old_len..new_len], 0);
        }
    }

    // ---------------------------------------------------------------
    // Owner reassignment / close
    // ---------------------------------------------------------------

    /// Reassign this account to a new owner program. The runtime
    /// enforces:
    ///   - the calling program currently owns this account, AND
    ///   - the account is empty (data_len == 0 OR all-zero on close).
    ///
    /// Direct write — no CPI required. Mirrors
    /// `solana_program::account_info::AccountInfo::assign`.
    pub inline fn assign(self: AccountInfo, new_owner: *const Pubkey) void {
        self.raw.owner = new_owner.*;
    }

    /// Comptime-key counterpart to `assign`. Generates four u64 stores
    /// against immediates instead of a `memcpy` through a runtime
    /// pointer.
    pub inline fn assignComptime(self: AccountInfo, comptime new_owner: Pubkey) void {
        self.raw.owner = new_owner;
    }

    /// Close this account by:
    ///   1. Transferring all lamports to `destination` (rent reclaim).
    ///   2. Zeroing the data buffer.
    ///   3. Shrinking `data_len` to 0.
    ///   4. Reassigning ownership to the system program (the canonical
    ///      "closed account" marker).
    ///
    /// Caller MUST verify that this program owns the account before
    /// calling — the runtime will abort the tx otherwise. The
    /// destination account must be writable. Order matters: lamports
    /// move BEFORE the owner reassignment, so the system-program
    /// rule that "only the owner can drain lamports" is satisfied.
    ///
    /// This is the Anchor `#[account(close = receiver)]` equivalent.
    pub fn close(
        self: AccountInfo,
        destination: AccountInfo,
    ) ProgramError!void {
        // 1. Drain lamports.
        const balance = self.lamports();
        // Use checked add on destination — defending against a
        // pathological "destination already at u64.max" scenario.
        try destination.addLamportsChecked(balance);
        self.setLamports(0);

        // 2. Zero the data buffer.
        const old_len = self.dataLen();
        if (old_len > 0) {
            const dp = self.dataPtr();
            @memset(dp[0..old_len], 0);
        }

        // 3. Shrink data_len to 0.
        self.writeDataLen(0);

        // 4. Reassign to system program.
        const SYSTEM_PROGRAM_ID = @import("../system/root.zig").SYSTEM_PROGRAM_ID;
        self.raw.owner = SYSTEM_PROGRAM_ID;
    }

    /// Create a C-ABI-compatible view for CPI calls.
    /// Only needed when calling `cpi.invoke`.
    pub inline fn toCpiInfo(self: AccountInfo) CpiAccountInfo {
        return CpiAccountInfo.fromPtr(self.raw);
    }
};
