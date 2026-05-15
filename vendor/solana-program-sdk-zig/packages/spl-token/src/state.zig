//! SPL Token on-chain state structs — zero-copy views over the token program's
//! account data buffers.
//!
//! This module mirrors the canonical Rust layouts for `Mint`, `Account`, and
//! `Multisig`, but it also exposes the smaller "just give me the mint/owner"
//! helpers that router-style programs often want.
//!
//! Layouts mirror the canonical Rust `Mint` (82 B) and `Account` (165 B)
//! bincode-style encodings exactly: `Pubkey` is 32 raw bytes, `COption<T>` is
//! a 4-byte little-endian tag followed by `T`'s bytes (whether or not the
//! option is `Some`). Padding fields are kept explicit so a
//! `@bitCast`/pointer-cast from the runtime account-data slice lands on the
//! right bytes regardless of host alignment rules.
//!
//! Use the `from*` constructors below to validate a slice's length and obtain a
//! typed pointer in one step — they're the only supported way to materialise
//! these structs.

const std = @import("std");
const sol = @import("solana_program_sdk");
const codec = @import("solana_codec");

const Pubkey = sol.Pubkey;

/// Size of the encoded `Mint` account — match the canonical Rust
/// `spl_token::state::Mint::LEN`.
pub const MINT_LEN: usize = 82;

/// Size of the encoded token `Account` — match the canonical Rust
/// `spl_token::state::Account::LEN`.
pub const ACCOUNT_LEN: usize = 165;

/// Maximum number of signer pubkeys stored in a canonical SPL Token
/// multisig account.
pub const MULTISIG_SIGNER_MAX: usize = 11;

/// Raw-byte offsets for the two most commonly inspected account fields.
pub const ACCOUNT_MINT_OFFSET: usize = 0;
pub const ACCOUNT_OWNER_OFFSET: usize = 32;

/// Size of the encoded `Multisig` account — match the canonical
/// Rust `spl_token::state::Multisig::LEN`.
pub const MULTISIG_LEN: usize = 3 + (@sizeOf(Pubkey) * MULTISIG_SIGNER_MAX);

/// `COption<T>` discriminator tag — 4 little-endian bytes preceding
/// the optional payload. Matches Rust's bincode encoding.
pub const COPTION_SOME: u32 = 1;
pub const COPTION_NONE: u32 = 0;

/// Token account "state" byte (`Account::state`):
///   0 = Uninitialized
///   1 = Initialized
///   2 = Frozen
pub const AccountState = enum(u8) {
    uninitialized = 0,
    initialized = 1,
    frozen = 2,
    _,
};

/// Mint account — zero-copy view over `MINT_LEN` bytes.
///
/// Use `Mint.fromBytes(slice)` to obtain a typed pointer after the
/// runtime has handed you an `AccountInfo`'s `data` slice.
pub const Mint = extern struct {
    /// `COption<Pubkey>` — 4-byte tag + 32-byte pubkey. When the tag
    /// is `COPTION_NONE`, the pubkey bytes are zero-padding and
    /// must not be read.
    mint_authority_tag: u32 align(1),
    mint_authority: Pubkey align(1),

    /// Total supply currently in circulation (raw u64, no decimals
    /// adjustment).
    supply: u64 align(1),

    /// Number of decimal places — the on-chain `Amount` is
    /// `ui_amount * 10^decimals`.
    decimals: u8,

    /// 1 = `is_initialized`. Anything else means the buffer hasn't
    /// been initialised by the token program yet.
    is_initialized: u8,

    /// Optional freeze authority — same `COption` layout as
    /// `mint_authority` above.
    freeze_authority_tag: u32 align(1),
    freeze_authority: Pubkey align(1),

    pub inline fn isInitialized(self: *const Mint) bool {
        return self.is_initialized != 0;
    }

    pub inline fn mintAuthority(self: *const Mint) ?*const Pubkey {
        return if (self.mint_authority_tag == COPTION_SOME) &self.mint_authority else null;
    }

    pub inline fn freezeAuthority(self: *const Mint) ?*const Pubkey {
        return if (self.freeze_authority_tag == COPTION_SOME) &self.freeze_authority else null;
    }

    /// Validated variant of `mintAuthority`: rejects malformed `COption` tags
    /// through the shared `solana_codec` SPL bincode decoder.
    pub inline fn mintAuthorityChecked(self: *const Mint) sol.ProgramError!?Pubkey {
        return readCOptionPubkeyValue(self.mint_authority_tag, &self.mint_authority);
    }

    /// Validated variant of `freezeAuthority`: rejects malformed `COption`
    /// tags through the shared `solana_codec` SPL bincode decoder.
    pub inline fn freezeAuthorityChecked(self: *const Mint) sol.ProgramError!?Pubkey {
        return readCOptionPubkeyValue(self.freeze_authority_tag, &self.freeze_authority);
    }

    /// Parse a runtime data slice into a typed pointer. Returns an
    /// error if `bytes.len != MINT_LEN`.
    pub inline fn fromBytes(bytes: []const u8) sol.ProgramError!*const Mint {
        if (bytes.len != MINT_LEN) {
            return sol.program_error.fail(
                @src(),
                "mint:wrong_size",
                error.InvalidAccountData,
            );
        }
        return @ptrCast(@alignCast(bytes.ptr));
    }

    /// Mutable variant — same length check, returns a writable
    /// pointer so a program that owns the account (typically the
    /// token program itself; this helper is mainly for tests and
    /// account inspection inside test harnesses) can mutate the
    /// fields in place.
    pub inline fn fromBytesMut(bytes: []u8) sol.ProgramError!*Mint {
        if (bytes.len != MINT_LEN) {
            return sol.program_error.fail(
                @src(),
                "mint:wrong_size",
                error.InvalidAccountData,
            );
        }
        return @ptrCast(@alignCast(bytes.ptr));
    }
};

/// Token `Account` — zero-copy view over `ACCOUNT_LEN` bytes.
pub const Account = extern struct {
    mint: Pubkey align(1),
    owner: Pubkey align(1),
    amount: u64 align(1),

    delegate_tag: u32 align(1),
    delegate: Pubkey align(1),

    state: u8,

    is_native_tag: u32 align(1),
    is_native_rent_exempt_reserve: u64 align(1),

    delegated_amount: u64 align(1),

    close_authority_tag: u32 align(1),
    close_authority: Pubkey align(1),

    pub inline fn accountState(self: *const Account) AccountState {
        return @enumFromInt(self.state);
    }

    pub inline fn isFrozen(self: *const Account) bool {
        return self.state == @intFromEnum(AccountState.frozen);
    }

    pub inline fn isInitialized(self: *const Account) bool {
        return self.state != @intFromEnum(AccountState.uninitialized);
    }

    pub inline fn delegateKey(self: *const Account) ?*const Pubkey {
        return if (self.delegate_tag == COPTION_SOME) &self.delegate else null;
    }

    pub inline fn closeAuthority(self: *const Account) ?*const Pubkey {
        return if (self.close_authority_tag == COPTION_SOME) &self.close_authority else null;
    }

    /// Validated variant of `delegateKey`: rejects malformed `COption` tags
    /// through the shared `solana_codec` SPL bincode decoder.
    pub inline fn delegateKeyChecked(self: *const Account) sol.ProgramError!?Pubkey {
        return readCOptionPubkeyValue(self.delegate_tag, &self.delegate);
    }

    /// Validated variant of `closeAuthority`: rejects malformed `COption`
    /// tags through the shared `solana_codec` SPL bincode decoder.
    pub inline fn closeAuthorityChecked(self: *const Account) sol.ProgramError!?Pubkey {
        return readCOptionPubkeyValue(self.close_authority_tag, &self.close_authority);
    }

    /// `true` if the token-account owner is the System Program or the
    /// incinerator, mirroring the upstream SPL Token interface helper.
    pub inline fn isOwnedBySystemProgramOrIncinerator(self: *const Account) bool {
        return sol.pubkey.pubkeyEqComptime(&self.owner, sol.system_program_id) or
            sol.pubkey.pubkeyEqComptime(&self.owner, sol.incinerator_id);
    }

    /// `true` if the account is a wrapped-SOL holder. The token
    /// program uses the `is_native` `COption` to flag this and the
    /// inner `u64` carries the rent-exempt reserve.
    pub inline fn isNative(self: *const Account) bool {
        return self.is_native_tag == COPTION_SOME;
    }

    /// Validated wrapped-SOL rent reserve. `null` means the account is not
    /// native; malformed `COption` tags are rejected as invalid account data.
    pub inline fn nativeRentExemptReserveChecked(self: *const Account) sol.ProgramError!?u64 {
        return readCOptionU64Value(self.is_native_tag, self.is_native_rent_exempt_reserve);
    }

    pub inline fn fromBytes(bytes: []const u8) sol.ProgramError!*const Account {
        if (bytes.len != ACCOUNT_LEN) {
            return sol.program_error.fail(
                @src(),
                "token_account:wrong_size",
                error.InvalidAccountData,
            );
        }
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub inline fn fromBytesMut(bytes: []u8) sol.ProgramError!*Account {
        if (bytes.len != ACCOUNT_LEN) {
            return sol.program_error.fail(
                @src(),
                "token_account:wrong_size",
                error.InvalidAccountData,
            );
        }
        return @ptrCast(@alignCast(bytes.ptr));
    }

    /// Fast length-only validation for callers that only need selected raw
    /// fields and want to avoid materializing the full `Account` view.
    pub inline fn validAccountData(account_data: []const u8) bool {
        return account_data.len == ACCOUNT_LEN;
    }

    /// Unpack a pubkey at a known offset after length has already been checked.
    ///
    /// Upstream SPL Token exposes these via `GenericTokenAccount`; Zig keeps
    /// them as account-type helpers so on-chain routers and adapters can read
    /// mint/owner straight from the account bytes without parsing the rest of
    /// the struct.
    pub inline fn unpackPubkeyUnchecked(account_data: []const u8, comptime offset: usize) *const Pubkey {
        comptime std.debug.assert(offset + @sizeOf(Pubkey) <= ACCOUNT_LEN);
        return @ptrCast(account_data.ptr + offset);
    }

    /// Fast-path unpack for the token-account mint pubkey.
    pub inline fn unpackMintUnchecked(account_data: []const u8) *const Pubkey {
        return unpackPubkeyUnchecked(account_data, ACCOUNT_MINT_OFFSET);
    }

    /// Fast-path unpack for the token-account owner pubkey.
    pub inline fn unpackOwnerUnchecked(account_data: []const u8) *const Pubkey {
        return unpackPubkeyUnchecked(account_data, ACCOUNT_OWNER_OFFSET);
    }
};

/// `true` when `account_data` has the canonical SPL Token account length.
pub inline fn validAccountData(account_data: []const u8) bool {
    return Account.validAccountData(account_data);
}

/// Unpack the token-account mint pubkey after length has been validated.
pub inline fn unpackAccountMintUnchecked(account_data: []const u8) *const Pubkey {
    return Account.unpackMintUnchecked(account_data);
}

/// Unpack the token-account owner pubkey after length has been validated.
pub inline fn unpackAccountOwnerUnchecked(account_data: []const u8) *const Pubkey {
    return Account.unpackOwnerUnchecked(account_data);
}

/// Unpack a token-account pubkey at the supplied fixed offset after length has
/// been validated.
pub inline fn unpackAccountPubkeyUnchecked(account_data: []const u8, comptime offset: usize) *const Pubkey {
    return Account.unpackPubkeyUnchecked(account_data, offset);
}

/// Token `Multisig` — zero-copy view over `MULTISIG_LEN` bytes.
pub const Multisig = extern struct {
    /// Threshold number of signer approvals required.
    m: u8,
    /// Number of configured signer pubkeys.
    n: u8,
    /// 1 when the multisig has been initialized.
    is_initialized: u8,
    /// Canonical 11 pubkey slots, zero-padded when `n < 11`.
    signers: [MULTISIG_SIGNER_MAX]Pubkey align(1),

    pub inline fn isInitialized(self: *const Multisig) bool {
        return self.is_initialized != 0;
    }

    pub inline fn signerCount(self: *const Multisig) usize {
        return @min(@as(usize, self.n), MULTISIG_SIGNER_MAX);
    }

    pub inline fn signerPubkeys(self: *const Multisig) []const Pubkey {
        return self.signers[0..self.signerCount()];
    }

    pub inline fn fromBytes(bytes: []const u8) sol.ProgramError!*const Multisig {
        if (bytes.len != MULTISIG_LEN) {
            return sol.program_error.fail(
                @src(),
                "multisig:wrong_size",
                error.InvalidAccountData,
            );
        }
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub inline fn fromBytesMut(bytes: []u8) sol.ProgramError!*Multisig {
        if (bytes.len != MULTISIG_LEN) {
            return sol.program_error.fail(
                @src(),
                "multisig:wrong_size",
                error.InvalidAccountData,
            );
        }
        return @ptrCast(@alignCast(bytes.ptr));
    }
};

fn readCOptionPubkeyValue(tag: u32, payload: *const Pubkey) sol.ProgramError!?Pubkey {
    const decoded = codec.readCOptionPubkeyParts(tag, payload) catch {
        return sol.program_error.fail(
            @src(),
            "token_state:invalid_coption_pubkey",
            error.InvalidAccountData,
        );
    };
    return decoded.value;
}

fn readCOptionU64Value(tag: u32, payload: u64) sol.ProgramError!?u64 {
    const decoded = codec.readCOptionU64Parts(tag, payload) catch {
        return sol.program_error.fail(
            @src(),
            "token_state:invalid_coption_u64",
            error.InvalidAccountData,
        );
    };
    return decoded.value;
}

// =============================================================================
// Tests
// =============================================================================

comptime {
    std.debug.assert(@sizeOf(Mint) == MINT_LEN);
    std.debug.assert(@sizeOf(Account) == ACCOUNT_LEN);
    std.debug.assert(@sizeOf(Multisig) == MULTISIG_LEN);

    // Spot-check critical field offsets so any silent regression
    // (e.g. someone removes an `align(1)`) trips at build time.
    std.debug.assert(@offsetOf(Mint, "mint_authority_tag") == 0);
    std.debug.assert(@offsetOf(Mint, "supply") == 36);
    std.debug.assert(@offsetOf(Mint, "decimals") == 44);
    std.debug.assert(@offsetOf(Mint, "is_initialized") == 45);
    std.debug.assert(@offsetOf(Mint, "freeze_authority_tag") == 46);

    std.debug.assert(@offsetOf(Account, "mint") == 0);
    std.debug.assert(@offsetOf(Account, "owner") == 32);
    std.debug.assert(@offsetOf(Account, "amount") == 64);
    std.debug.assert(@offsetOf(Account, "delegate_tag") == 72);
    std.debug.assert(@offsetOf(Account, "state") == 108);
    std.debug.assert(@offsetOf(Account, "is_native_tag") == 109);
    std.debug.assert(@offsetOf(Account, "delegated_amount") == 121);
    std.debug.assert(@offsetOf(Account, "close_authority_tag") == 129);

    std.debug.assert(@offsetOf(Multisig, "m") == 0);
    std.debug.assert(@offsetOf(Multisig, "n") == 1);
    std.debug.assert(@offsetOf(Multisig, "is_initialized") == 2);
    std.debug.assert(@offsetOf(Multisig, "signers") == 3);
}

test "mint: fromBytes rejects wrong length" {
    const buf = [_]u8{0} ** (MINT_LEN - 1);
    try std.testing.expectError(error.InvalidAccountData, Mint.fromBytes(&buf));
}

test "mint: round-trip authority decoding" {
    var buf: [MINT_LEN]u8 = [_]u8{0} ** MINT_LEN;
    // mint_authority = Some(0x01..01), freeze_authority = None
    std.mem.writeInt(u32, buf[0..4], COPTION_SOME, .little);
    @memset(buf[4..36], 0x01);
    std.mem.writeInt(u64, buf[36..44], 1_000_000_000, .little);
    buf[44] = 9; // decimals
    buf[45] = 1; // is_initialized
    std.mem.writeInt(u32, buf[46..50], COPTION_NONE, .little);

    const mint = try Mint.fromBytes(&buf);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), mint.supply);
    try std.testing.expectEqual(@as(u8, 9), mint.decimals);
    try std.testing.expect(mint.isInitialized());
    try std.testing.expect(mint.mintAuthority() != null);
    try std.testing.expect(mint.freezeAuthority() == null);
    const expected: Pubkey = .{0x01} ** 32;
    try std.testing.expectEqualSlices(u8, &expected, mint.mintAuthority().?);
    try std.testing.expectEqualSlices(u8, &expected, &(try mint.mintAuthorityChecked()).?);
    try std.testing.expect((try mint.freezeAuthorityChecked()) == null);

    std.mem.writeInt(u32, buf[0..4], 9, .little);
    const invalid_mint = try Mint.fromBytes(&buf);
    try std.testing.expectError(error.InvalidAccountData, invalid_mint.mintAuthorityChecked());
}

test "account: fromBytes rejects wrong length" {
    const buf = [_]u8{0} ** (ACCOUNT_LEN + 1);
    try std.testing.expectError(error.InvalidAccountData, Account.fromBytes(&buf));
}

test "account: state + isNative round-trip" {
    var buf: [ACCOUNT_LEN]u8 = [_]u8{0} ** ACCOUNT_LEN;
    @memset(buf[0..32], 0xAA); // mint
    @memset(buf[32..64], 0xBB); // owner
    std.mem.writeInt(u64, buf[64..72], 42, .little); // amount
    std.mem.writeInt(u32, buf[72..76], COPTION_NONE, .little); // delegate
    buf[108] = @intFromEnum(AccountState.frozen);
    std.mem.writeInt(u32, buf[109..113], COPTION_SOME, .little);
    std.mem.writeInt(u64, buf[113..121], 2_039_280, .little); // wSOL rent reserve

    const acc = try Account.fromBytes(&buf);
    try std.testing.expectEqual(@as(u64, 42), acc.amount);
    try std.testing.expect(acc.isFrozen());
    try std.testing.expect(acc.isInitialized());
    try std.testing.expect(acc.isNative());
    try std.testing.expectEqual(@as(u64, 2_039_280), acc.is_native_rent_exempt_reserve);
    try std.testing.expect(acc.delegateKey() == null);
    try std.testing.expect((try acc.delegateKeyChecked()) == null);
    try std.testing.expectEqual(@as(?u64, 2_039_280), try acc.nativeRentExemptReserveChecked());
    try std.testing.expect(!acc.isOwnedBySystemProgramOrIncinerator());

    std.mem.writeInt(u32, buf[109..113], 9, .little);
    const invalid_acc = try Account.fromBytes(&buf);
    try std.testing.expectError(error.InvalidAccountData, invalid_acc.nativeRentExemptReserveChecked());
}

test "account: fast-path pubkey helpers match canonical offsets" {
    var buf: [ACCOUNT_LEN]u8 = [_]u8{0} ** ACCOUNT_LEN;
    @memset(buf[ACCOUNT_MINT_OFFSET .. ACCOUNT_MINT_OFFSET + sol.PUBKEY_BYTES], 0x44);
    @memset(buf[ACCOUNT_OWNER_OFFSET .. ACCOUNT_OWNER_OFFSET + sol.PUBKEY_BYTES], 0x55);

    try std.testing.expect(validAccountData(buf[0..]));
    try std.testing.expect(!validAccountData(buf[0 .. ACCOUNT_LEN - 1]));
    try std.testing.expectEqualSlices(u8, &([_]u8{0x44} ** 32), unpackAccountMintUnchecked(buf[0..])[0..]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x55} ** 32), unpackAccountOwnerUnchecked(buf[0..])[0..]);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0x55} ** 32),
        unpackAccountPubkeyUnchecked(buf[0..], ACCOUNT_OWNER_OFFSET)[0..],
    );
}

test "account: owner helper recognizes system program and incinerator" {
    var system_buf: [ACCOUNT_LEN]u8 = [_]u8{0} ** ACCOUNT_LEN;
    @memcpy(system_buf[ACCOUNT_OWNER_OFFSET .. ACCOUNT_OWNER_OFFSET + sol.PUBKEY_BYTES], sol.system_program_id[0..]);
    const system_account = try Account.fromBytes(&system_buf);
    try std.testing.expect(system_account.isOwnedBySystemProgramOrIncinerator());

    var incinerator_buf: [ACCOUNT_LEN]u8 = [_]u8{0} ** ACCOUNT_LEN;
    @memcpy(incinerator_buf[ACCOUNT_OWNER_OFFSET .. ACCOUNT_OWNER_OFFSET + sol.PUBKEY_BYTES], sol.incinerator_id[0..]);
    const incinerator_account = try Account.fromBytes(&incinerator_buf);
    try std.testing.expect(incinerator_account.isOwnedBySystemProgramOrIncinerator());
}

test "multisig: fromBytes rejects wrong length" {
    const buf = [_]u8{0} ** (MULTISIG_LEN - 1);
    try std.testing.expectError(error.InvalidAccountData, Multisig.fromBytes(&buf));
}

test "multisig: threshold, signer count, initialized flag, and signer pubkeys round-trip" {
    var buf: [MULTISIG_LEN]u8 = [_]u8{0} ** MULTISIG_LEN;
    buf[0] = 2; // m
    buf[1] = 3; // n
    buf[2] = 1; // is_initialized
    @memset(buf[3..35], 0x11);
    @memset(buf[35..67], 0x22);
    @memset(buf[67..99], 0x33);

    const multisig = try Multisig.fromBytes(&buf);
    try std.testing.expectEqual(@as(u8, 2), multisig.m);
    try std.testing.expectEqual(@as(u8, 3), multisig.n);
    try std.testing.expect(multisig.isInitialized());
    try std.testing.expectEqual(@as(usize, 3), multisig.signerCount());

    const signers = multisig.signerPubkeys();
    try std.testing.expectEqual(@as(usize, 3), signers.len);

    const signer0: Pubkey = .{0x11} ** 32;
    const signer1: Pubkey = .{0x22} ** 32;
    const signer2: Pubkey = .{0x33} ** 32;
    try std.testing.expectEqualSlices(u8, &signer0, &signers[0]);
    try std.testing.expectEqualSlices(u8, &signer1, &signers[1]);
    try std.testing.expectEqualSlices(u8, &signer2, &signers[2]);
}
