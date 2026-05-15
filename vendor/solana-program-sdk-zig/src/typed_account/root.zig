//! Typed account view — zero-copy `T`-shaped access to runtime account data.
//!
//! A `TypedAccount(T)` wraps an `AccountInfo` and lets you read/write
//! fields of the user-defined `T` (an `extern struct`) **in place** in
//! the runtime input buffer. There is no allocation, no serialization,
//! no `RefCell` — every field access is a single pointer deref.
//!
//! Conventions:
//!   - `T` must be an `extern struct` (so its layout is C ABI, stable,
//!     and packed-without-padding-surprises).
//!   - If `T` declares a comptime `pub const DISCRIMINATOR: [8]u8`
//!     (typically `sol.discriminator.forAccount("MyType")`), the
//!     bind/initialize helpers enforce that the first 8 bytes of the
//!     account's data equal that constant. This matches the Anchor
//!     convention and defends against type-confusion attacks. The
//!     user is expected to reserve the first 8 bytes of `T`'s layout
//!     for this purpose (e.g. `discriminator: [8]u8 = DISCRIMINATOR`
//!     as field 0).
//!   - Without `DISCRIMINATOR`, no type check is enforced — the caller
//!     takes responsibility for type safety some other way.
//!
//! Cost: equivalent to hand-written `@ptrCast(@alignCast(data.ptr))`
//! plus (when applicable) one 64-bit compare against an immediate for
//! the discriminator check. No allocation, no copy.
//!
//! Physical layout:
//! - `shared.zig` — common imports, discriminator constants, account aliases
//! - `typed.zig` — `TypedAccount(T)` implementation
//!
//! The public API stays flattened as `sol.typed_account.*` and
//! `sol.TypedAccount(...)`.

const std = @import("std");
const shared = @import("shared.zig");
const account_mod = shared.account_mod;
const discriminator = shared.discriminator;
const AccountInfo = shared.AccountInfo;
const DISCRIMINATOR_LEN = shared.DISCRIMINATOR_LEN;

/// Zero-copy typed account binder family.
pub const TypedAccount = @import("typed.zig").TypedAccount;

// =============================================================================
// Tests
// =============================================================================

const pubkey_mod = @import("../pubkey/root.zig");
const Pubkey = pubkey_mod.Pubkey;
const Account = account_mod.Account;
const NOT_BORROWED = account_mod.NOT_BORROWED;

// A test type WITHOUT discriminator
const Simple = extern struct {
    counter: u64,
    flag: u8,
    _pad: [7]u8 = .{0} ** 7,
};

// A test type WITH discriminator
const Stateful = extern struct {
    discriminator: [DISCRIMINATOR_LEN]u8,
    counter: u64,
    owner: Pubkey,

    pub const DISCRIMINATOR = discriminator.forAccount("Stateful");
};

fn makeAccount(buf: *[256]u8, key_byte: u8) AccountInfo {
    @memset(buf, 0);
    const acc: *Account = @ptrCast(@alignCast(buf));
    acc.* = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{key_byte} ** 32,
        .owner = .{0} ** 32,
        .lamports = 0,
        .data_len = 256 - @sizeOf(Account),
    };
    return .{ .raw = acc };
}

test "TypedAccount: bind + read on non-discriminator type" {
    var buf: [256]u8 align(8) = undefined;
    const info = makeAccount(&buf, 1);

    // Write a Simple manually into account data
    const writer: *align(1) Simple = @ptrCast(@alignCast(info.dataPtr()));
    writer.* = .{ .counter = 42, .flag = 1 };

    const TA = TypedAccount(Simple);
    const ta = try TA.bind(info);
    try std.testing.expectEqual(@as(u64, 42), ta.read().counter);
    try std.testing.expectEqual(@as(u8, 1), ta.read().flag);

    ta.write().counter += 8;
    try std.testing.expectEqual(@as(u64, 50), ta.read().counter);
}

test "TypedAccount: initialize writes discriminator" {
    var buf: [256]u8 align(8) = undefined;
    const info = makeAccount(&buf, 2);

    const TA = TypedAccount(Stateful);
    const ta = try TA.initialize(info, .{
        .discriminator = undefined,
        .counter = 100,
        .owner = .{7} ** 32,
    });
    try std.testing.expectEqual(@as(u64, 100), ta.read().counter);

    // Discriminator was written
    const want = discriminator.forAccount("Stateful");
    const got_ptr: *align(1) const [DISCRIMINATOR_LEN]u8 =
        @ptrCast(@alignCast(info.dataPtr()));
    try std.testing.expectEqualSlices(u8, &want, got_ptr);
}

test "TypedAccount: bind rejects mismatching discriminator" {
    var buf: [256]u8 align(8) = undefined;
    const info = makeAccount(&buf, 3);

    // Write a wrong discriminator
    const dp = info.dataPtr();
    @memset(dp[0..DISCRIMINATOR_LEN], 0xAB);

    const TA = TypedAccount(Stateful);
    try std.testing.expectError(error.InvalidAccountData, TA.bind(info));
}

test "TypedAccount: bind accepts matching discriminator" {
    var buf: [256]u8 align(8) = undefined;
    const info = makeAccount(&buf, 4);

    // Initialize the account
    const TA = TypedAccount(Stateful);
    _ = try TA.initialize(info, .{
        .discriminator = undefined,
        .counter = 7,
        .owner = .{1} ** 32,
    });

    // Re-bind succeeds
    const ta = try TA.bind(info);
    try std.testing.expectEqual(@as(u64, 7), ta.read().counter);
}

test "TypedAccount: bind enforces minimum size" {
    // The Account header is 88 bytes; allocate a generous buffer
    // but declare a tiny `data_len` to trigger the size check.
    var small_buf: [128]u8 align(8) = undefined;
    @memset(&small_buf, 0);
    const acc: *Account = @ptrCast(@alignCast(&small_buf));
    acc.* = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{4} ** 32,
        .owner = .{0} ** 32,
        .lamports = 0,
        .data_len = 1, // too small for Stateful (sizeof ~= 48)
    };
    const info = AccountInfo{ .raw = acc };

    const TA = TypedAccount(Stateful);
    try std.testing.expectError(error.AccountDataTooSmall, TA.bind(info));
}

test "TypedAccount: has_discriminator metadata" {
    try std.testing.expect(!TypedAccount(Simple).has_discriminator);
    try std.testing.expect(TypedAccount(Stateful).has_discriminator);
}

test "TypedAccount: requireHasOne accepts matching key" {
    var vault_buf: [256]u8 align(8) = undefined;
    var auth_buf: [256]u8 align(8) = undefined;

    const auth_key: Pubkey = .{0xA1} ** 32;
    const auth_info = makeAccount(&auth_buf, 0xA1);

    const vault_info = makeAccount(&vault_buf, 1);

    const TA = TypedAccount(Stateful);
    _ = try TA.initialize(vault_info, .{
        .discriminator = undefined,
        .counter = 0,
        .owner = auth_key,
    });

    const vault = try TA.bind(vault_info);
    try vault.requireHasOne("owner", auth_info);
}

test "TypedAccount: requireHasOne rejects mismatching key" {
    var vault_buf: [256]u8 align(8) = undefined;
    var auth_buf: [256]u8 align(8) = undefined;

    const auth_info = makeAccount(&auth_buf, 0xA1); // key = 0xA1...
    const vault_info = makeAccount(&vault_buf, 1);

    const TA = TypedAccount(Stateful);
    _ = try TA.initialize(vault_info, .{
        .discriminator = undefined,
        .counter = 0,
        .owner = .{0xB2} ** 32, // different from auth.key()
    });

    const vault = try TA.bind(vault_info);
    try std.testing.expectError(
        error.IncorrectAuthority,
        vault.requireHasOne("owner", auth_info),
    );
}
