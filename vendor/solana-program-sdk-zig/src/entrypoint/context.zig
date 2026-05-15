const shared = @import("shared.zig");
const std = shared.std;
const account = shared.account;
const account_cursor = shared.account_cursor;
const pubkey = shared.pubkey;
const program_error = shared.program_error;
const instruction_mod = shared.instruction_mod;
const Account = shared.Account;
const AccountInfo = shared.AccountInfo;
const AccountCursor = shared.AccountCursor;
const MaybeAccount = shared.MaybeAccount;
const Pubkey = shared.Pubkey;
const ProgramError = shared.ProgramError;
const MAX_PERMITTED_DATA_INCREASE = shared.MAX_PERMITTED_DATA_INCREASE;
const alignPointer = shared.alignPointer;
const unlikely = shared.unlikely;
const likely = shared.likely;

inline fn validateExpectedAccount(
    acc: AccountInfo,
    comptime name: []const u8,
    comptime exp: AccountExpectation,
) ProgramError!void {
    if (comptime exp.signer and exp.writable) {
        const flags_ptr: *align(1) const u16 = @ptrCast(&acc.raw.is_signer);
        if (flags_ptr.* != 0x0101) {
            if (!acc.isSigner()) {
                return program_error.fail(
                    @src(),
                    "parse:" ++ name ++ ":not_signer",
                    error.MissingRequiredSignature,
                );
            }
            return program_error.fail(
                @src(),
                "parse:" ++ name ++ ":not_writable",
                error.ImmutableAccount,
            );
        }
    } else {
        if (comptime exp.signer) {
            if (!acc.isSigner()) {
                return program_error.fail(
                    @src(),
                    "parse:" ++ name ++ ":not_signer",
                    error.MissingRequiredSignature,
                );
            }
        }
        if (comptime exp.writable) {
            if (!acc.isWritable()) {
                return program_error.fail(
                    @src(),
                    "parse:" ++ name ++ ":not_writable",
                    error.ImmutableAccount,
                );
            }
        }
    }

    if (comptime exp.executable) {
        if (!acc.executable()) {
            return program_error.fail(
                @src(),
                "parse:" ++ name ++ ":not_executable",
                error.InvalidAccountData,
            );
        }
    }
    if (comptime exp.owner != null) {
        const expected_owner = exp.owner.?;
        if (!acc.isOwnedByComptime(expected_owner)) {
            return program_error.fail(
                @src(),
                "parse:" ++ name ++ ":wrong_owner",
                error.IncorrectProgramId,
            );
        }
    }
    if (comptime exp.key != null) {
        const expected_key = exp.key.?;
        if (!pubkey.pubkeyEqComptime(acc.key(), expected_key)) {
            return program_error.fail(
                @src(),
                "parse:" ++ name ++ ":key_mismatch",
                error.InvalidArgument,
            );
        }
    }
}

// =========================================================================
// InstructionContext — on-demand input parsing (Pinocchio-style)
//
// Only 16 bytes on the stack (buffer pointer + remaining count).
// `next_account()` returns `AccountInfo` (8 bytes).
// =========================================================================

pub const InstructionContext = struct {
    buffer: [*]u8,
    remaining: u64,

    /// Create from raw input pointer.
    pub inline fn init(input: [*]u8) InstructionContext {
        const num_accounts: u64 = @as(*const u64, @ptrCast(@alignCast(input))).*;
        return .{
            .buffer = input + @sizeOf(u64),
            .remaining = num_accounts,
        };
    }

    /// Number of remaining unparsed accounts.
    pub inline fn remainingAccounts(self: InstructionContext) u64 {
        return self.remaining;
    }

    // ---------------------------------------------------------------------
    // next_account — non-dup fast path
    //
    // `nextAccount` / `nextAccountUnchecked` assume the slot is NOT a
    // duplicate (i.e. `borrow_state == NON_DUP_MARKER`). They step the
    // buffer past the full account header + data + padding.
    //
    // If the runtime ever serializes a duplicate slot, these will
    // misalign the buffer for subsequent reads. Programs that know
    // their callers may pass duplicates should use the `Maybe` variants
    // below.
    // ---------------------------------------------------------------------

    /// Parse the next account. Returns null if none remaining.
    ///
    /// Assumes the slot is not a duplicated-account marker. For
    /// duplicate-aware iteration use `nextAccountMaybe`.
    pub fn nextAccount(self: *InstructionContext) ?AccountInfo {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return self.nextAccountUnchecked();
    }

    /// Parse the next account — no bounds check, no dup check.
    /// Caller must ensure there are remaining accounts AND that the
    /// slot is not a duplicate marker.
    pub inline fn nextAccountUnchecked(self: *InstructionContext) AccountInfo {
        const account_ptr: *account.Account = @ptrCast(@alignCast(self.buffer));
        const data_len: usize = @intCast(account_ptr.data_len);
        self.buffer += @sizeOf(u64) + (@sizeOf(Account) - @sizeOf(u64)) + data_len + MAX_PERMITTED_DATA_INCREASE;
        self.buffer = @ptrFromInt(alignPointer(@intFromPtr(self.buffer)));
        self.buffer += @sizeOf(u64);
        return .{ .raw = account_ptr };
    }

    // ---------------------------------------------------------------------
    // next_account_maybe — dup-aware (matches Pinocchio `next_account`)
    //
    // Returns `MaybeAccount`, distinguishing between a freshly serialized
    // account and a duplicate slot that references an earlier account by
    // index. Buffer is advanced by the correct stride either way:
    //
    //   - non-dup:   8-byte rent_epoch + STATIC_ACCOUNT_DATA + data_len +
    //                MAX_PERMITTED_DATA_INCREASE + 8-byte alignment pad
    //   - dup:       8 bytes (1-byte index + 7 bytes padding)
    //
    // This is the only safe iteration mode for programs whose callers
    // may pass the same account in more than one slot.
    // ---------------------------------------------------------------------

    inline fn nextResolvedAccount(
        self: *InstructionContext,
        comptime seen_len: usize,
        seen: *const [seen_len]AccountInfo,
    ) ProgramError!AccountInfo {
        if (self.remaining == 0) return error.NotEnoughAccountKeys;
        self.remaining -= 1;
        return self.nextResolvedAccountUnchecked(seen_len, seen);
    }

    inline fn nextResolvedAccountUnchecked(
        self: *InstructionContext,
        comptime seen_len: usize,
        seen: *const [seen_len]AccountInfo,
    ) AccountInfo {
        const account_ptr: *account.Account = @ptrCast(@alignCast(self.buffer));

        if (account_ptr.borrow_state == account.NON_DUP_MARKER) {
            const acc: AccountInfo = .{ .raw = account_ptr };
            const data_len: usize = @intCast(account_ptr.data_len);
            self.buffer += @sizeOf(u64) + (@sizeOf(Account) - @sizeOf(u64)) + data_len + MAX_PERMITTED_DATA_INCREASE;
            self.buffer = @ptrFromInt(alignPointer(@intFromPtr(self.buffer)));
            self.buffer += @sizeOf(u64);
            return acc;
        }

        const idx = account_ptr.borrow_state;
        self.buffer += @sizeOf(u64);
        return seen[idx];
    }

    /// Dup-aware next-account. Returns `error.NotEnoughAccountKeys`
    /// when no accounts remain; otherwise returns `MaybeAccount`
    /// which the caller pattern-matches:
    ///
    /// ```zig
    /// switch (try ctx.nextAccountMaybe()) {
    ///     .account => |acc| { ... },
    ///     .duplicated => |idx| { /* same as earlier accounts[idx] */ },
    /// }
    /// ```
    pub fn nextAccountMaybe(self: *InstructionContext) ProgramError!MaybeAccount {
        if (self.remaining == 0) return error.NotEnoughAccountKeys;
        self.remaining -= 1;
        return self.nextAccountMaybeUnchecked();
    }

    /// Dup-aware next-account — no bounds check.
    /// Caller must ensure `remainingAccounts() > 0`.
    pub inline fn nextAccountMaybeUnchecked(self: *InstructionContext) MaybeAccount {
        const account_ptr: *account.Account = @ptrCast(@alignCast(self.buffer));

        if (account_ptr.borrow_state == account.NON_DUP_MARKER) {
            // Non-duplicate: advance past header (which includes the leading
            // 8-byte rent_epoch padding embedded by the runtime) + data +
            // MAX_PERMITTED_DATA_INCREASE + alignment.
            const data_len: usize = @intCast(account_ptr.data_len);
            self.buffer += @sizeOf(u64) + (@sizeOf(Account) - @sizeOf(u64)) + data_len + MAX_PERMITTED_DATA_INCREASE;
            self.buffer = @ptrFromInt(alignPointer(@intFromPtr(self.buffer)));
            self.buffer += @sizeOf(u64);
            return .{ .account = .{ .raw = account_ptr } };
        } else {
            // Duplicate slot: 1-byte index + 7 bytes padding = 8 bytes total.
            const idx = account_ptr.borrow_state;
            self.buffer += @sizeOf(u64);
            return .{ .duplicated = idx };
        }
    }

    /// Skip accounts without parsing. Dup-aware: dup slots advance by
    /// 8 bytes, non-dup slots advance by the full account stride.
    pub fn skipAccounts(self: *InstructionContext, count: u64) void {
        var i: u64 = 0;
        while (i < count and self.remaining > 0) : (i += 1) {
            _ = self.nextAccountMaybeUnchecked();
            self.remaining -= 1;
        }
    }

    /// Create an `AccountCursor` over the remaining serialized account
    /// slots. Use this on a fresh context for the full instruction
    /// account list, or after fixed parsing when duplicate references
    /// cannot target accounts outside the remaining range.
    pub inline fn accountCursor(self: *const InstructionContext) ProgramError!AccountCursor {
        return AccountCursor.initRemaining(self.buffer, self.remaining, &.{});
    }

    /// Create an `AccountCursor` over the remaining account range while
    /// seeding already-parsed earlier accounts. This lets duplicate
    /// markers in the remaining range resolve back to fixed accounts
    /// that were consumed before the cursor was created.
    pub inline fn accountCursorWithPrefix(
        self: *const InstructionContext,
        prefix: []const AccountInfo,
    ) ProgramError!AccountCursor {
        return AccountCursor.initRemaining(self.buffer, self.remaining, prefix);
    }

    /// Get instruction data. Returns an error if there are still
    /// unparsed accounts; this is the safe variant matching Pinocchio's
    /// `instruction_data`.
    ///
    /// Does NOT advance the buffer — safe to call multiple times, and
    /// safe to interleave with `programId()`. Use `instructionDataUnchecked`
    /// when you've consumed accounts via `nextAccountUnchecked` (which
    /// leaves `remaining` unchanged).
    pub inline fn instructionData(self: *const InstructionContext) ProgramError![]const u8 {
        if (self.remaining > 0) {
            return program_error.fail(
                @src(),
                "ctx:accounts_not_consumed",
                error.InvalidInstructionData,
            );
        }
        return self.instructionDataUnchecked();
    }

    /// Get instruction data without checking the remaining-accounts
    /// counter. Does not advance the buffer.
    ///
    /// Mirrors Pinocchio's `instruction_data_unchecked`.
    pub inline fn instructionDataUnchecked(self: *const InstructionContext) []const u8 {
        const data_len: usize = @intCast(@as(*const u64, @ptrCast(@alignCast(self.buffer))).*);
        return self.buffer[@sizeOf(u64) .. @sizeOf(u64) + data_len];
    }

    /// Get program ID. Returns an error if accounts are still unparsed.
    /// Mirrors Pinocchio's `program_id`. Does NOT advance the buffer.
    pub inline fn programId(self: *const InstructionContext) ProgramError!*const Pubkey {
        if (self.remaining > 0) {
            return program_error.fail(
                @src(),
                "ctx:accounts_not_consumed",
                error.InvalidInstructionData,
            );
        }
        return self.programIdUnchecked();
    }

    /// Get program ID without checks. Does not advance the buffer.
    /// Skips past the instruction-data length prefix and contents to
    /// find the program-id at the end of the input layout.
    pub inline fn programIdUnchecked(self: *const InstructionContext) *const Pubkey {
        const data_len: usize = @intCast(@as(*const u64, @ptrCast(@alignCast(self.buffer))).*);
        return @ptrCast(@alignCast(self.buffer + @sizeOf(u64) + data_len));
    }

    // =====================================================================
    // Comptime typed deserialization — no more manual pointer casting
    // =====================================================================

    /// Read a typed value from instruction data at the given byte offset.
    /// Zero overhead — compiles to a single aligned pointer dereference.
    ///
    /// ```zig
    /// const amount = ctx.readIx(u64, 0);
    /// const index = ctx.readIx(u32, 8);
    /// ```
    pub inline fn readIx(self: *InstructionContext, comptime T: type, comptime offset: usize) T {
        const ptr: *align(1) const T = @ptrCast(@alignCast(self.buffer + @sizeOf(u64) + offset));
        return ptr.*;
    }

    /// Read instruction data as a packed struct, starting at byte 0.
    /// Returns a comptime-typed value — no manual deserialization needed.
    ///
    /// ```zig
    /// const TransferIx = packed struct { amount: u64 };
    /// const ix = ctx.unpackIx(TransferIx);
    /// // ix.amount is a plain u64
    /// ```
    pub inline fn unpackIx(self: *InstructionContext, comptime T: type) T {
        const ptr: *align(1) const T = @ptrCast(@alignCast(self.buffer + @sizeOf(u64)));
        return ptr.*;
    }

    /// Read instruction data as a discriminated enum union.
    /// First reads the discriminant (default: u32 at offset 0), then returns
    /// the tagged union value. Comptime — no runtime dispatch overhead.
    ///
    /// ```zig
    /// const MyInstruction = enum(u32) {
    ///     transfer,
    ///     burn,
    /// };
    /// const tag = ctx.readIxTag(MyInstruction);
    /// switch (tag) {
    ///     .transfer => { ... },
    ///     .burn => { ... },
    /// }
    /// ```
    pub inline fn readIxTag(self: *InstructionContext, comptime Tag: type) Tag {
        comptime {
            if (@typeInfo(Tag) != .@"enum") {
                @compileError("readIxTag requires an enum type");
            }
        }
        const TagInt = comptime blk: {
            break :blk @typeInfo(Tag).@"enum".tag_type;
        };
        const raw = self.readIx(TagInt, 0);
        return @enumFromInt(raw);
    }

    /// Require at least `min_len` bytes of ix-data.
    ///
    /// Useful for fixed-layout dispatchers that want one explicit bounds
    /// check up front, then raw `readIx*` loads for the hot path.
    pub inline fn requireIxDataLen(
        self: *const InstructionContext,
        comptime min_len: usize,
    ) ProgramError!void {
        if (unlikely(self.remaining > 0)) {
            return program_error.fail(
                @src(),
                "ctx:accounts_not_consumed",
                error.InvalidInstructionData,
            );
        }
        return self.requireIxDataLenUnchecked(min_len);
    }

    /// Same as `requireIxDataLen`, but skips the `remaining == 0` check.
    pub inline fn requireIxDataLenUnchecked(
        self: *const InstructionContext,
        comptime min_len: usize,
    ) ProgramError!void {
        const data_len: usize = @intCast(@as(*const u64, @ptrCast(@alignCast(self.buffer))).*);
        if (unlikely(data_len < min_len)) {
            return error.InvalidInstructionData;
        }
    }

    /// Bind an extern-struct instruction-data view in one step.
    ///
    /// Compared to `try instructionData()` + `IxDataReader(T).bind(...)`,
    /// this folds the "accounts consumed" and "buffer large enough" checks
    /// into a single helper while still returning the same zero-copy typed view.
    pub inline fn bindIxData(
        self: *const InstructionContext,
        comptime T: type,
    ) ProgramError!instruction_mod.IxDataReader(T) {
        try self.requireIxDataLen(@sizeOf(T));
        return self.bindIxDataUnchecked(T);
    }

    /// Same as `bindIxData`, but skips the `remaining == 0` check.
    /// Caller asserts the buffer is already positioned at ix-data.
    pub inline fn bindIxDataUnchecked(
        self: *const InstructionContext,
        comptime T: type,
    ) ProgramError!instruction_mod.IxDataReader(T) {
        try self.requireIxDataLenUnchecked(@sizeOf(T));
        const bytes = self.buffer[@sizeOf(u64) .. @sizeOf(u64) + @sizeOf(T)];
        return instruction_mod.IxDataReader(T).bindUnchecked(bytes);
    }

    /// Parse a fixed set of accounts into a named struct.
    ///
    /// `names` is a comptime tuple of `[]const u8` field names. The
    /// returned struct has one `AccountInfo` field per name, in order.
    /// Returns `error.NotEnoughAccountKeys` if `ctx.remainingAccounts()`
    /// is smaller than `names.len`.
    ///
    /// ```zig
    /// const accs = try ctx.parseAccounts(.{ "from", "to", "system_program" });
    /// // accs.from, accs.to, accs.system_program are AccountInfo
    /// try sol.system.transfer(accs.from, accs.to, accs.system_program, 100);
    /// ```
    ///
    /// Zero runtime overhead vs. hand-written `nextAccount() orelse …`:
    /// the loop is fully unrolled at compile time.
    pub inline fn parseAccounts(
        self: *InstructionContext,
        comptime names: anytype,
    ) ProgramError!ParsedAccounts(names) {
        if (self.remaining < names.len) return error.NotEnoughAccountKeys;
        self.remaining -= @intCast(names.len);

        const T = ParsedAccounts(names);
        var out: T = undefined;
        // Dup-aware: walk the slot list with a single upfront account-count
        // check, then resolve duplicates against the already-seen accounts.
        var seen: [names.len]AccountInfo = undefined;
        inline for (names, 0..) |name, i| {
            const acc = self.nextResolvedAccountUnchecked(names.len, &seen);
            seen[i] = acc;
            @field(out, name) = acc;
        }
        return out;
    }

    /// Like `parseAccounts`, but skips the dup-aware tagged-union
    /// machinery entirely. Caller asserts (structurally or by upstream
    /// validation) that no two slots reference the same account.
    ///
    /// On BPF this is **~70 CU cheaper** for a 2-account parse compared
    /// to the safe `parseAccounts` — the unsafe path collapses to a
    /// straight stride-advance per slot, no `MaybeAccount` switch, no
    /// `seen[]` parallel array.
    ///
    /// Use only when:
    ///   - the program logically can't be passed the same account
    ///     twice (e.g. fixed roles like `mint`/`vault`/`recipient`), or
    ///   - the caller's transaction-builder guarantees uniqueness
    ///     (e.g. derived PDAs that are distinct by construction).
    ///
    /// If your program accepts arbitrary user-supplied account lists
    /// where dups are possible AND meaningful (token transfers,
    /// multisig signers), use the safe `parseAccounts` instead.
    pub inline fn parseAccountsUnchecked(
        self: *InstructionContext,
        comptime names: anytype,
    ) ProgramError!ParsedAccounts(names) {
        if (self.remaining < names.len) return error.NotEnoughAccountKeys;
        self.remaining -= @intCast(names.len);

        const T = ParsedAccounts(names);
        var out: T = undefined;
        inline for (names) |name| {
            @field(out, name) = self.nextAccountUnchecked();
        }
        return out;
    }

    /// Like `parseAccounts`, but with comptime-declared per-account
    /// expectations. Each entry is `.{ name, AccountExpectation{...} }`.
    /// The expectation fields:
    ///   - `signer`:     if `true`, fail with `MissingRequiredSignature`
    ///                   when the account did not sign the transaction.
    ///   - `writable`:   if `true`, fail with `ImmutableAccount`.
    ///   - `executable`: if `true`, fail with `InvalidAccountData`
    ///                   when the account is not a program.
    ///   - `owner`:      optional comptime `Pubkey`; if set, fail with
    ///                   `IncorrectProgramId` unless the account is
    ///                   owned by exactly this program id. Uses
    ///                   `pubkeyEqComptime` so the expected key is
    ///                   folded into 4 u64 immediates.
    ///
    /// All checks are unrolled at compile time — the resulting BPF
    /// code is byte-identical to hand-written `if`s, but the SDK
    /// guarantees the correct error variant for each failure (no more
    /// stray "Custom program error" surprises).
    ///
    /// ```zig
    /// const accs = try ctx.parseAccountsWith(.{
    ///     .{ "from",           .{ .signer = true, .writable = true } },
    ///     .{ "to",             .{ .writable = true } },
    ///     .{ "system_program", .{ .owner = sol.native_loader_id } },
    /// });
    /// ```
    pub inline fn parseAccountsWith(
        self: *InstructionContext,
        comptime spec: anytype,
    ) ProgramError!ParsedAccountsWith(spec) {
        if (self.remaining < spec.len) return error.NotEnoughAccountKeys;
        self.remaining -= @intCast(spec.len);

        const T = ParsedAccountsWith(spec);
        var out: T = undefined;
        // Dup-aware: see parseAccounts. Duplicates are resolved against
        // earlier slots in this same parse call, then the resolved
        // AccountInfo is still subject to the per-slot expectation
        // checks (signer/writable/owner) — because a duplicate slot in
        // an instruction's account list still has its own copy of the
        // (is_signer, is_writable) flags on the original account, so
        // re-checking those is correct.
        var seen: [spec.len]AccountInfo = undefined;
        inline for (spec, 0..) |entry, i| {
            const name = entry[0];
            const exp: AccountExpectation = entry[1];

            const acc = self.nextResolvedAccountUnchecked(spec.len, &seen);
            seen[i] = acc;

            try validateExpectedAccount(acc, name, exp);
            @field(out, name) = acc;
        }
        return out;
    }

    /// Like `parseAccountsWith`, but skips duplicate-account
    /// resolution entirely. Use this when the account roles are
    /// structurally unique yet you still want comptime-validated
    /// signer/writable/owner/key checks.
    ///
    /// This is the validated fast path: it keeps the same expectation
    /// checks as `parseAccountsWith`, but walks the input with
    /// `nextAccountUnchecked()` instead of the dup-aware
    /// `nextAccountMaybe()` tagged union.
    ///
    /// Prefer this over `parseAccountsUnchecked` + ad-hoc checks when:
    ///   - account roles are unique by construction, and
    ///   - you want the SDK to keep emitting the canonical failure
    ///     variants (`MissingRequiredSignature`, `ImmutableAccount`,
    ///     `IncorrectProgramId`, ...).
    ///
    /// If duplicate accounts are possible and semantically valid for
    /// the instruction, use the safe `parseAccountsWith` instead.
    pub inline fn parseAccountsWithUnchecked(
        self: *InstructionContext,
        comptime spec: anytype,
    ) ProgramError!ParsedAccountsWith(spec) {
        if (self.remaining < spec.len) return error.NotEnoughAccountKeys;
        self.remaining -= @intCast(spec.len);

        const T = ParsedAccountsWith(spec);
        var out: T = undefined;
        inline for (spec) |entry| {
            const name = entry[0];
            const exp: AccountExpectation = entry[1];
            const acc = self.nextAccountUnchecked();

            try validateExpectedAccount(acc, name, exp);
            @field(out, name) = acc;
        }
        return out;
    }
};

/// Per-account validation rules for `parseAccountsWith`.
///
/// Optional fields default to "no check"; set them to `true` (or a
/// `Pubkey` value) to enforce them.
pub const AccountExpectation = struct {
    signer: bool = false,
    writable: bool = false,
    executable: bool = false,
    /// Expected owner program ID (comptime constant). Comptime
    /// compare uses 4 u64-immediate cmps — no rodata lookup.
    owner: ?Pubkey = null,
    /// Expected pubkey (comptime constant). Useful for asserting an
    /// account is exactly a well-known sysvar / system program /
    /// pre-derived PDA. Same comptime-immediate compare as `owner`.
    key: ?Pubkey = null,
};

/// Generate a `ParsedAccounts`-shaped struct from a comptime spec
/// tuple of `.{ name, AccountExpectation }`. Each field has type
/// `AccountInfo`.
pub fn ParsedAccountsWith(comptime spec: anytype) type {
    var field_names: [spec.len][:0]const u8 = undefined;
    inline for (spec, 0..) |entry, i| {
        field_names[i] = entry[0] ++ "";
    }
    return @Struct(
        .auto,
        null,
        &field_names,
        &@as([spec.len]type, @splat(AccountInfo)),
        &@as(
            [spec.len]std.builtin.Type.StructField.Attributes,
            @splat(.{}),
        ),
    );
}

/// Generate a struct type from a tuple of field names. Each field is
/// of type `AccountInfo`. Used by `parseAccounts`.
///
/// Zig 0.16 replaced `@Type` with per-kind builtins; this uses
/// `@Struct(layout, backing_int, field_names, field_types, field_attrs)`.
/// See <https://ziglang.org/download/0.16.0/release-notes.html>.
pub fn ParsedAccounts(comptime names: anytype) type {
    var field_names: [names.len][:0]const u8 = undefined;
    inline for (names, 0..) |name, i| {
        field_names[i] = name ++ "";
    }
    return @Struct(
        .auto,
        null,
        &field_names,
        &@as([names.len]type, @splat(AccountInfo)),
        &@as(
            [names.len]std.builtin.Type.StructField.Attributes,
            @splat(.{}),
        ),
    );
}
