//! Account memory views and helpers.
//!
//! This module is the bridge between the runtime's serialized account
//! layout and the SDK's higher-level helpers:
//!
//! - `Account` is the raw in-memory shape emitted by the loader.
//! - `AccountInfo` is the 8-byte pointer wrapper used by parse, typed-account,
//!   and CPI code.
//! - `MaybeAccount` preserves duplicate-slot information for safe parsers.
//! - `CpiAccountInfo` is the invoke-layer C-ABI view used by `sol.cpi.*`.
//!
//! Physical layout:
//! - `shared.zig` — raw runtime account layout + shared constants
//! - `info.zig` — `AccountInfo` accessors, expectations, resize, close
//! - `maybe_account.zig` — duplicate-aware parse result wrapper
//! - `cpi_info.zig` — `CpiAccountInfo` C-ABI view for invoke paths
//!
//! The public API stays flattened as `sol.account.*`, `sol.AccountInfo`,
//! `sol.CpiAccountInfo`, and `sol.MaybeAccount`.

const std = @import("std");
const shared = @import("shared.zig");
const pubkey = shared.pubkey;
const Pubkey = shared.Pubkey;
const info_mod = @import("info.zig");
const maybe_mod = @import("maybe_account.zig");
const cpi_mod = @import("cpi_info.zig");

/// Raw runtime layout constants and helpers shared with parsing / CPI staging.
pub const NON_DUP_MARKER = shared.NON_DUP_MARKER;
pub const MAX_PERMITTED_DATA_INCREASE = shared.MAX_PERMITTED_DATA_INCREASE;
pub const MAX_TX_ACCOUNTS = shared.MAX_TX_ACCOUNTS;
pub const BPF_ALIGN_OF_U128 = shared.BPF_ALIGN_OF_U128;
pub const NOT_BORROWED = shared.NOT_BORROWED;
pub const Account = shared.Account;
pub const alignPointer = shared.alignPointer;

/// High-level account views layered on top of the raw runtime layout.
pub const AccountInfo = info_mod.AccountInfo;
pub const MaybeAccount = maybe_mod.MaybeAccount;
pub const CpiAccountInfo = cpi_mod.CpiAccountInfo;

// =============================================================================
// Tests
// =============================================================================

test "account: Account size" {
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(Account));
}

test "account: AccountInfo is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(AccountInfo));
}

test "account: AccountInfo accessors" {
    var acc: Account = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{1} ** 32,
        .owner = .{2} ** 32,
        .lamports = 1000,
        .data_len = 10,
    };
    const info = AccountInfo{ .raw = &acc };

    try std.testing.expect(info.isSigner());
    try std.testing.expect(info.isWritable());
    try std.testing.expect(!info.executable());
    try std.testing.expectEqual(@as(u64, 1000), info.lamports());
    try std.testing.expectEqual(@as(usize, 10), info.dataLen());
    try std.testing.expect(pubkey.pubkeyEq(info.key(), &[_]u8{1} ** 32));
    try std.testing.expect(pubkey.pubkeyEq(info.owner(), &[_]u8{2} ** 32));
}

test "account: CpiAccountInfo from AccountInfo" {
    var acc: Account = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{1} ** 32,
        .owner = .{2} ** 32,
        .lamports = 1000,
        .data_len = 0,
    };
    const info = AccountInfo{ .raw = &acc };
    const cpi_info = info.toCpiInfo();

    try std.testing.expect(cpi_info.isSigner());
    try std.testing.expectEqual(@as(u64, 1000), cpi_info.lamports());
}

test "account: expect — happy path" {
    var acc: Account = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{42} ** 32,
        .owner = .{7} ** 32,
        .lamports = 1000,
        .data_len = 0,
    };
    const info = AccountInfo{ .raw = &acc };

    try info.expect(.{ .signer = true, .writable = true });
    try info.expect(.{ .owner = .{7} ** 32 });
    try info.expect(.{ .key = .{42} ** 32 });
    try info.expect(.{
        .signer = true,
        .writable = true,
        .owner = .{7} ** 32,
        .key = .{42} ** 32,
    });
}

test "account: expect — signer missing" {
    var acc: Account = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0} ** 32,
        .owner = .{0} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    const info = AccountInfo{ .raw = &acc };
    try std.testing.expectError(error.MissingRequiredSignature, info.expect(.{ .signer = true }));
}

test "account: expect — wrong owner" {
    var acc: Account = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0} ** 32,
        .owner = .{7} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    const info = AccountInfo{ .raw = &acc };
    try std.testing.expectError(
        error.IncorrectProgramId,
        info.expect(.{ .owner = .{99} ** 32 }),
    );
}

test "account: expect — wrong key" {
    var acc: Account = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{42} ** 32,
        .owner = .{0} ** 32,
        .lamports = 0,
        .data_len = 0,
    };
    const info = AccountInfo{ .raw = &acc };
    try std.testing.expectError(
        error.InvalidArgument,
        info.expect(.{ .key = .{99} ** 32 }),
    );
}

test "account: isOwnedByAny / assertOwnerAny" {
    const token_a: pubkey.Pubkey = .{7} ** 32;
    const token_b: pubkey.Pubkey = .{8} ** 32;

    var acc: Account = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0} ** 32,
        .owner = token_b,
        .lamports = 0,
        .data_len = 0,
    };
    const info = AccountInfo{ .raw = &acc };

    try std.testing.expect(info.isOwnedByAny(&.{ token_a, token_b }));
    try std.testing.expect(!info.isOwnedByAny(&.{token_a}));

    try info.assertOwnerAny(&.{ token_a, token_b });
    try std.testing.expectError(
        error.IncorrectProgramId,
        info.assertOwnerAny(&.{token_a}),
    );
}

test "account: expect supports owner_any / key_any" {
    const allowed_a: pubkey.Pubkey = .{10} ** 32;
    const allowed_b: pubkey.Pubkey = .{20} ** 32;

    var acc: Account = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = allowed_a,
        .owner = allowed_b,
        .lamports = 0,
        .data_len = 0,
    };
    const info = AccountInfo{ .raw = &acc };

    try info.expect(.{ .owner_any = &.{ allowed_a, allowed_b }, .key_any = &.{allowed_a} });

    try std.testing.expectError(
        error.IncorrectProgramId,
        info.expect(.{ .owner_any = &.{allowed_a} }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        info.expect(.{ .key_any = &.{allowed_b} }),
    );
}

test "account: dataAs / dataAsConst typed view" {
    const Layout = extern struct {
        a: u64 align(1),
        b: u32 align(1),
    };
    const backing: [@sizeOf(Layout)]u8 = .{0} ** @sizeOf(Layout);
    var acc: Account = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0} ** 32,
        .owner = .{0} ** 32,
        .lamports = 0,
        .data_len = @sizeOf(Layout),
    };
    // dataPtr() reads the bytes immediately after the Account header,
    // so we need a contiguous buffer. The host-side test simulates by
    // adjusting data_len and exercising dataAs via the @ptrCast — but
    // since dataPtr() is `&self.raw[1]`, we can't easily test the read
    // here without a full input layout. Instead just verify the
    // function compiles and the returned pointer type is correct.
    _ = backing;
    const info = AccountInfo{ .raw = &acc };
    const ptr_mut = info.dataAs(Layout);
    const ptr_const = info.dataAsConst(Layout);
    try std.testing.expectEqual(@TypeOf(ptr_mut), *align(1) Layout);
    try std.testing.expectEqual(@TypeOf(ptr_const), *align(1) const Layout);
}

test "account: addLamportsChecked / subLamportsChecked overflow" {
    var acc: Account = .{
        .borrow_state = NOT_BORROWED,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = .{0} ** 32,
        .owner = .{0} ** 32,
        .lamports = 100,
        .data_len = 0,
    };
    const info = AccountInfo{ .raw = &acc };

    try info.addLamportsChecked(50);
    try std.testing.expectEqual(@as(u64, 150), info.lamports());

    try info.subLamportsChecked(150);
    try std.testing.expectEqual(@as(u64, 0), info.lamports());

    try std.testing.expectError(error.ArithmeticOverflow, info.subLamportsChecked(1));
    info.setLamports(std.math.maxInt(u64));
    try std.testing.expectError(error.ArithmeticOverflow, info.addLamportsChecked(1));
}

// Synthetic backing buffer matching the runtime layout:
//   [Account header][data buffer][trailing scratch up to MAX_PERMITTED_DATA_INCREASE]
// `_padding` (offset 4..8) is the runtime's `original_data_len: u32 LE`.
const TEST_BUF_DATA = @as(usize, MAX_PERMITTED_DATA_INCREASE) + 256;
const ReallocTestBuf = struct {
    bytes: [@sizeOf(Account) + TEST_BUF_DATA]u8 align(8),

    fn init(original_len: u32, current_len: u64) ReallocTestBuf {
        var self: ReallocTestBuf = .{ .bytes = .{0} ** (@sizeOf(Account) + TEST_BUF_DATA) };
        const acc: *Account = @ptrCast(&self.bytes);
        acc.* = .{
            .borrow_state = NOT_BORROWED,
            .is_signer = 0,
            .is_writable = 1,
            .is_executable = 0,
            ._padding = .{0} ** 4,
            .key = .{0} ** 32,
            .owner = .{0xAB} ** 32,
            .lamports = 5_000_000,
            .data_len = current_len,
        };
        // Write `original_data_len` into the `_padding` slot.
        const orig_ptr: *align(4) u32 = @ptrCast(&acc._padding);
        orig_ptr.* = original_len;
        return self;
    }

    fn info(self: *ReallocTestBuf) AccountInfo {
        return .{ .raw = @ptrCast(&self.bytes) };
    }
};

test "account: originalDataLen reads u32 from _padding slot" {
    var buf = ReallocTestBuf.init(42, 42);
    try std.testing.expectEqual(@as(usize, 42), buf.info().originalDataLen());
}

test "account: resize grows within budget" {
    var buf = ReallocTestBuf.init(10, 10);
    const info = buf.info();
    // Pre-seed only a small region we care about — well within the
    // test backing buffer (TEST_BUF_DATA bytes after the header).
    @memset(info.dataPtr()[0..40], 0xCC);
    info.raw.data_len = 10;

    try info.resize(20, true);
    try std.testing.expectEqual(@as(usize, 20), info.dataLen());
    // Bytes [10..20] should now be zero.
    for (info.data()[10..20]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    // Untouched: byte at index 0 remains pre-seeded.
    try std.testing.expectEqual(@as(u8, 0xCC), info.dataPtr()[0]);
}

test "account: resize shrinks freely" {
    var buf = ReallocTestBuf.init(100, 100);
    const info = buf.info();
    try info.resize(7, false);
    try std.testing.expectEqual(@as(usize, 7), info.dataLen());
}

test "account: resize rejects > original + MAX_PERMITTED_DATA_INCREASE" {
    var buf = ReallocTestBuf.init(0, 0);
    try std.testing.expectError(
        error.InvalidRealloc,
        buf.info().resize(MAX_PERMITTED_DATA_INCREASE + 1, false),
    );
    // Boundary: exactly original + MAX is allowed.
    try buf.info().resize(MAX_PERMITTED_DATA_INCREASE, false);
}

test "account: resize no-op when new_len == old_len" {
    var buf = ReallocTestBuf.init(50, 50);
    try buf.info().resize(50, true);
    try std.testing.expectEqual(@as(usize, 50), buf.info().dataLen());
}

test "account: assign overwrites owner" {
    var buf = ReallocTestBuf.init(0, 0);
    const info = buf.info();
    const new_owner: Pubkey = .{0x33} ** 32;
    info.assign(&new_owner);
    try std.testing.expect(pubkey.pubkeyEq(info.owner(), &new_owner));
}

test "account: expectSignerKey happy path + mismatches" {
    var buf = ReallocTestBuf.init(0, 0);
    const info = buf.info();
    info.raw.is_signer = 1;
    info.raw.key = .{0x55} ** 32;

    const want: Pubkey = .{0x55} ** 32;
    const wrong: Pubkey = .{0x66} ** 32;

    try info.expectSignerKey(&want);
    try info.expectSignerKeyComptime(.{0x55} ** 32);

    try std.testing.expectError(error.InvalidArgument, info.expectSignerKey(&wrong));

    info.raw.is_signer = 0;
    try std.testing.expectError(
        error.MissingRequiredSignature,
        info.expectSignerKey(&want),
    );
}

test "account: close drains lamports, zeroes data, reassigns to system" {
    var src_buf = ReallocTestBuf.init(32, 32);
    var dst_buf = ReallocTestBuf.init(0, 0);

    const src = src_buf.info();
    const dst = dst_buf.info();
    // Seed src.data with non-zero so we can verify zeroing.
    @memset(src.data()[0..32], 0xEE);
    dst.setLamports(1_000);

    try src.close(dst);

    try std.testing.expectEqual(@as(u64, 0), src.lamports());
    try std.testing.expectEqual(@as(u64, 1_000 + 5_000_000), dst.lamports());
    try std.testing.expectEqual(@as(usize, 0), src.dataLen());
    // Owner should now be the system program (all zeros).
    const system_id = @import("../system/root.zig").SYSTEM_PROGRAM_ID;
    try std.testing.expect(pubkey.pubkeyEq(src.owner(), &system_id));
    // The bytes that used to hold data should now be zeroed (we
    // zeroed positions 0..32 inside the data buffer).
    for (src.dataPtr()[0..32]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
