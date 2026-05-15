//! Solana program entrypoint — `InstructionContext` (Pinocchio-style)
//!
//! This module owns the runtime input parser and the SDK's entrypoint-wrapper
//! family:
//!
//! - `InstructionContext` walks the loader-provided input buffer lazily.
//! - `parseAccounts*` / `parseAccountsWith*` provide named account binding.
//! - `readIx*` / `bindIxData*` provide zero-copy instruction-data access.
//! - `lazyEntrypoint*` / `programEntrypoint*` wrap a user handler as the
//!   exported `entrypoint` symbol.
//!
//! Accounts are returned as `AccountInfo` (an 8-byte pointer wrapper), so the
//! happy path stays zero-copy and allocation-free.
//!
//! Physical layout:
//! - `shared.zig` — common imports, heap constants, branch-hint helpers
//! - `context.zig` — `InstructionContext`, parse helpers, typed ix-data binding
//! - `entry.zig` — exported entrypoint wrapper families
//!
//! The public API stays flattened as `sol.entrypoint.*`, plus the root alias
//! `sol.InstructionContext`.

const std = @import("std");
const shared = @import("shared.zig");
const account = shared.account;
const account_cursor = shared.account_cursor;
const pubkey = shared.pubkey;
const program_error = shared.program_error;
const error_code = shared.error_code;
const instruction_mod = shared.instruction_mod;
const Account = shared.Account;
const AccountInfo = shared.AccountInfo;
const AccountCursor = shared.AccountCursor;
const MaybeAccount = shared.MaybeAccount;
const Pubkey = shared.Pubkey;
const ProgramResult = shared.ProgramResult;
const ProgramError = shared.ProgramError;
const SUCCESS = shared.SUCCESS;
const MAX_PERMITTED_DATA_INCREASE = shared.MAX_PERMITTED_DATA_INCREASE;
const context_mod = @import("context.zig");
const entry_mod = @import("entry.zig");

/// Loader heap constants re-exported for custom allocators / diagnostics.
pub const HEAP_START_ADDRESS = shared.HEAP_START_ADDRESS;
pub const HEAP_LENGTH = shared.HEAP_LENGTH;

/// Lazy account / instruction-data parser surface.
pub const InstructionContext = context_mod.InstructionContext;
pub const AccountExpectation = context_mod.AccountExpectation;
pub const ParsedAccountsWith = context_mod.ParsedAccountsWith;
pub const ParsedAccounts = context_mod.ParsedAccounts;
pub const unlikely = shared.unlikely;
pub const likely = shared.likely;

/// Entrypoint wrapper families.
pub const lazyEntrypoint = entry_mod.lazyEntrypoint;
pub const programEntrypoint = entry_mod.programEntrypoint;
pub const lazyEntrypointRaw = entry_mod.lazyEntrypointRaw;
pub const lazyEntrypointTyped = entry_mod.lazyEntrypointTyped;
pub const programEntrypointTyped = entry_mod.programEntrypointTyped;

// =========================================================================
// Tests
// =========================================================================

fn makePubkey(v: u8) Pubkey {
    var pk: Pubkey = undefined;
    @memset(&pk, v);
    return pk;
}

test "entrypoint: InstructionContext size is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(InstructionContext));
}

test "entrypoint: AccountInfo size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(AccountInfo));
}

test "entrypoint: ErrorCode catch path emits correct wire codes" {
    const Demo = enum(u32) { First = 6000, Second = 6042 };
    const DemoErr = error_code.ErrorCode(Demo, error{ First, Second });

    try std.testing.expectEqual(@as(u64, 6042), DemoErr.catchToU64(error.Second));
    try std.testing.expectEqual(@as(u64, 6000), DemoErr.catchToU64(error.First));
    try std.testing.expectEqual(
        program_error.errorToU64(error.InvalidArgument),
        DemoErr.catchToU64(error.InvalidArgument),
    );
}

test "entrypoint: parse accounts and instruction data" {
    var input align(8) = [_]u8{0} ** 32768;
    var ptr: [*]u8 = &input;

    // num_accounts = 2
    std.mem.writeInt(u64, ptr[0..8], 2, .little);
    ptr += 8;

    // Account 0
    const acc0: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(1),
        .owner = makePubkey(2),
        .lamports = 1000,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc0));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    // Account 1
    const acc1: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(3),
        .owner = makePubkey(2),
        .lamports = 500,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc1));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    // instruction data
    std.mem.writeInt(u64, ptr[0..8], 4, .little);
    ptr += 8;
    @memcpy(ptr[0..4], "test");

    var ctx = InstructionContext.init(&input);

    try std.testing.expectEqual(@as(u64, 2), ctx.remainingAccounts());

    const a0 = ctx.nextAccount().?;
    try std.testing.expect(a0.isSigner());
    try std.testing.expect(a0.isWritable());
    try std.testing.expectEqual(@as(u64, 1000), a0.lamports());
    try std.testing.expect(pubkey.pubkeyEq(a0.key(), &makePubkey(1)));

    const a1 = ctx.nextAccount().?;
    try std.testing.expect(!a1.isSigner());
    try std.testing.expectEqual(@as(u64, 500), a1.lamports());
    try std.testing.expect(pubkey.pubkeyEq(a1.key(), &makePubkey(3)));

    try std.testing.expectEqual(@as(u64, 0), ctx.remainingAccounts());
    try std.testing.expect(ctx.nextAccount() == null);

    const ix_data = try ctx.instructionData();
    try std.testing.expectEqualStrings("test", ix_data);
}

test "entrypoint: parseAccounts builds named struct" {
    var input align(8) = [_]u8{0} ** 32768;
    var ptr: [*]u8 = &input;

    std.mem.writeInt(u64, ptr[0..8], 2, .little);
    ptr += 8;

    const acc0: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(7),
        .owner = makePubkey(8),
        .lamports = 100,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc0));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    const acc1: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(9),
        .owner = makePubkey(8),
        .lamports = 200,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc1));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    std.mem.writeInt(u64, ptr[0..8], 0, .little);

    var ctx = InstructionContext.init(&input);
    const accs = try ctx.parseAccounts(.{ "from", "to" });

    try std.testing.expectEqual(@as(u64, 100), accs.from.lamports());
    try std.testing.expectEqual(@as(u64, 200), accs.to.lamports());
    try std.testing.expect(accs.from.isSigner());
    try std.testing.expect(!accs.to.isSigner());
}

test "entrypoint: parseAccounts errors when too few accounts" {
    var input align(8) = [_]u8{0} ** 256;
    std.mem.writeInt(u64, input[0..8], 0, .little);
    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.NotEnoughAccountKeys,
        ctx.parseAccounts(.{"only_one"}),
    );
}

test "entrypoint: parseAccountsUnchecked — happy path advances remaining" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 1, 1, makePubkey(99), 0, 1);

    var ctx = InstructionContext.init(&input);
    const accs = try ctx.parseAccountsUnchecked(.{ "first", "second" });
    try std.testing.expectEqual(@as(u8, 1), accs.first.key()[0]);
    try std.testing.expectEqual(@as(u8, 2), accs.second.key()[0]);
    try std.testing.expectEqual(@as(u64, 0), ctx.remaining);
    // After consuming both slots, instructionData() must accept.
    const ix = try ctx.instructionData();
    try std.testing.expectEqual(@as(usize, 0), ix.len);
}

test "entrypoint: parseAccountsUnchecked errors when too few accounts" {
    var input align(8) = [_]u8{0} ** 256;
    std.mem.writeInt(u64, input[0..8], 0, .little);
    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.NotEnoughAccountKeys,
        ctx.parseAccountsUnchecked(.{ "a", "b" }),
    );
}

// Helper that builds an input buffer with two accounts whose
// signer/writable flags are set by the caller.
fn buildTwoAccountInput(
    buf: *[32768]u8,
    acc0_signer: u8,
    acc0_writable: u8,
    acc0_owner: Pubkey,
    acc1_signer: u8,
    acc1_writable: u8,
) void {
    @memset(buf, 0);
    var ptr: [*]u8 = buf;

    std.mem.writeInt(u64, ptr[0..8], 2, .little);
    ptr += 8;

    const acc0: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = acc0_signer,
        .is_writable = acc0_writable,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(1),
        .owner = acc0_owner,
        .lamports = 100,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc0));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    const acc1: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = acc1_signer,
        .is_writable = acc1_writable,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(2),
        .owner = makePubkey(3),
        .lamports = 100,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc1));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    std.mem.writeInt(u64, ptr[0..8], 0, .little);
}

test "entrypoint: parseAccountsWith — happy path" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 1, 1, makePubkey(99), 0, 1);

    var ctx = InstructionContext.init(&input);
    const accs = try ctx.parseAccountsWith(.{
        .{ "from", AccountExpectation{ .signer = true, .writable = true } },
        .{ "to", AccountExpectation{ .writable = true } },
    });
    try std.testing.expect(accs.from.isSigner());
    try std.testing.expect(accs.to.isWritable());
}

test "entrypoint: parseAccountsWith — missing signer" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 0, 1, makePubkey(99), 0, 1); // acc0 not signing

    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.MissingRequiredSignature,
        ctx.parseAccountsWith(.{
            .{ "from", AccountExpectation{ .signer = true } },
            .{ "to", AccountExpectation{} },
        }),
    );
}

test "entrypoint: parseAccountsWith — not writable" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 1, 0, makePubkey(99), 0, 1); // acc0 not writable

    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.ImmutableAccount,
        ctx.parseAccountsWith(.{
            .{ "from", AccountExpectation{ .writable = true } },
            .{ "to", AccountExpectation{} },
        }),
    );
}

test "entrypoint: parseAccountsWith — wrong owner" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 0, 0, makePubkey(1), 0, 0); // owner=1, not 99

    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.IncorrectProgramId,
        ctx.parseAccountsWith(.{
            .{ "from", AccountExpectation{ .owner = comptime makePubkey(99) } },
            .{ "to", AccountExpectation{} },
        }),
    );
}

test "entrypoint: parseAccountsWith — owner match passes" {
    const expected_owner = comptime makePubkey(42);
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 0, 0, expected_owner, 0, 0);

    var ctx = InstructionContext.init(&input);
    const accs = try ctx.parseAccountsWith(.{
        .{ "from", AccountExpectation{ .owner = comptime makePubkey(42) } },
        .{ "to", AccountExpectation{} },
    });
    _ = accs;
}

test "entrypoint: parseAccountsWith — key match passes" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 0, 0, makePubkey(3), 0, 0);

    var ctx = InstructionContext.init(&input);
    // acc0.key = makePubkey(1) per buildTwoAccountInput.
    const accs = try ctx.parseAccountsWith(.{
        .{ "from", AccountExpectation{ .key = comptime makePubkey(1) } },
        .{ "to", AccountExpectation{} },
    });
    _ = accs;
}

test "entrypoint: parseAccountsWith — key mismatch fails" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 0, 0, makePubkey(3), 0, 0);

    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.InvalidArgument,
        ctx.parseAccountsWith(.{
            .{ "from", AccountExpectation{ .key = comptime makePubkey(99) } },
            .{ "to", AccountExpectation{} },
        }),
    );
}

test "entrypoint: requireIxDataLen validates minimum ix-data length" {
    var input align(8) = [_]u8{0} ** 128;
    std.mem.writeInt(u64, input[0..8], 0, .little); // num_accounts
    std.mem.writeInt(u64, input[8..16], 12, .little); // ix_data_len

    var ctx = InstructionContext.init(&input);
    try ctx.requireIxDataLen(12);
    try std.testing.expectError(error.InvalidInstructionData, ctx.requireIxDataLen(13));
}

test "entrypoint: requireIxDataLen rejects unconsumed accounts" {
    var input align(8) = [_]u8{0} ** 128;
    std.mem.writeInt(u64, input[0..8], 1, .little); // num_accounts
    std.mem.writeInt(u64, input[8..16], 12, .little); // ix_data_len

    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(error.InvalidInstructionData, ctx.requireIxDataLen(12));
}

test "entrypoint: bindIxData returns typed ix reader" {
    var input align(8) = [_]u8{0} ** 128;
    std.mem.writeInt(u64, input[0..8], 0, .little); // num_accounts
    std.mem.writeInt(u64, input[8..16], 16, .little); // ix_data_len
    std.mem.writeInt(u32, input[16..20], 7, .little);
    std.mem.writeInt(u64, input[20..28], 42, .little);

    const Args = extern struct {
        tag: u32 align(1),
        amount: u64 align(1),
    };

    var ctx = InstructionContext.init(&input);
    const args = try ctx.bindIxData(Args);
    try std.testing.expectEqual(@as(u32, 7), args.get(.tag));
    try std.testing.expectEqual(@as(u64, 42), args.get(.amount));

    std.mem.writeInt(u64, input[8..16], 4, .little);
    var short_ctx = InstructionContext.init(&input);
    try std.testing.expectError(error.InvalidInstructionData, short_ctx.bindIxData(Args));
}

test "entrypoint: bindIxData rejects unconsumed accounts" {
    var input align(8) = [_]u8{0} ** 128;
    std.mem.writeInt(u64, input[0..8], 1, .little); // num_accounts
    std.mem.writeInt(u64, input[8..16], 16, .little); // ix_data_len

    const Args = extern struct {
        tag: u32 align(1),
        amount: u64 align(1),
    };

    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(error.InvalidInstructionData, ctx.bindIxData(Args));
}

test "entrypoint: parseAccountsWithUnchecked — happy path" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 1, 1, makePubkey(99), 0, 1);

    var ctx = InstructionContext.init(&input);
    const accs = try ctx.parseAccountsWithUnchecked(.{
        .{ "from", AccountExpectation{ .signer = true, .writable = true } },
        .{ "to", AccountExpectation{ .writable = true } },
    });
    try std.testing.expect(accs.from.isSigner());
    try std.testing.expect(accs.to.isWritable());
    try std.testing.expectEqual(@as(u64, 0), ctx.remaining);
    const ix = try ctx.instructionData();
    try std.testing.expectEqual(@as(usize, 0), ix.len);
}

test "entrypoint: parseAccountsWithUnchecked errors when too few accounts" {
    var input align(8) = [_]u8{0} ** 256;
    std.mem.writeInt(u64, input[0..8], 0, .little);
    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.NotEnoughAccountKeys,
        ctx.parseAccountsWithUnchecked(.{
            .{ "a", AccountExpectation{} },
            .{ "b", AccountExpectation{} },
        }),
    );
}

test "entrypoint: parseAccountsWithUnchecked — missing signer" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 0, 1, makePubkey(99), 0, 1);

    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.MissingRequiredSignature,
        ctx.parseAccountsWithUnchecked(.{
            .{ "from", AccountExpectation{ .signer = true } },
            .{ "to", AccountExpectation{} },
        }),
    );
}

test "entrypoint: parseAccountsWithUnchecked — not writable" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 1, 0, makePubkey(99), 0, 1);

    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.ImmutableAccount,
        ctx.parseAccountsWithUnchecked(.{
            .{ "from", AccountExpectation{ .writable = true } },
            .{ "to", AccountExpectation{} },
        }),
    );
}

test "entrypoint: parseAccountsWithUnchecked — wrong owner" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 0, 0, makePubkey(1), 0, 0);

    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.IncorrectProgramId,
        ctx.parseAccountsWithUnchecked(.{
            .{ "from", AccountExpectation{ .owner = comptime makePubkey(99) } },
            .{ "to", AccountExpectation{} },
        }),
    );
}

test "entrypoint: parseAccountsWithUnchecked — key mismatch fails" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 0, 0, makePubkey(3), 0, 0);

    var ctx = InstructionContext.init(&input);
    try std.testing.expectError(
        error.InvalidArgument,
        ctx.parseAccountsWithUnchecked(.{
            .{ "from", AccountExpectation{ .key = comptime makePubkey(99) } },
            .{ "to", AccountExpectation{} },
        }),
    );
}

// =========================================================================
// Duplicate-account handling tests
//
// Build an input buffer where slot 1 is a duplicate of slot 0
// (encoded as 1 byte index = 0, then 7 bytes padding = 8 bytes total).
// =========================================================================

fn buildInputWithDup(buf: *[32768]u8) void {
    @memset(buf, 0);
    var ptr: [*]u8 = buf;

    // num_accounts = 3 (one real, one dup-of-0, one real)
    std.mem.writeInt(u64, ptr[0..8], 3, .little);
    ptr += 8;

    // slot 0: real account
    const acc0: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(0xAA),
        .owner = makePubkey(0xBB),
        .lamports = 777,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc0));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    // slot 1: duplicate marker pointing back to slot 0
    // (8 bytes: index byte + 7 zero pad)
    ptr[0] = 0; // dup-of index = 0
    ptr += 8;

    // slot 2: another real account
    const acc2: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(0xCC),
        .owner = makePubkey(0xDD),
        .lamports = 333,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc2));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    // instruction data: empty
    std.mem.writeInt(u64, ptr[0..8], 0, .little);
}

fn buildInputWithNonAdjacentDup(buf: *[32768]u8) void {
    @memset(buf, 0);
    var ptr: [*]u8 = buf;

    std.mem.writeInt(u64, ptr[0..8], 4, .little);
    ptr += 8;

    const acc0: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(0x11),
        .owner = makePubkey(0x21),
        .lamports = 11,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc0));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    const acc1: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 0,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(0x12),
        .owner = makePubkey(0x22),
        .lamports = 22,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc1));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    ptr[0] = 0;
    ptr += 8;

    const acc3: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(0x13),
        .owner = makePubkey(0x23),
        .lamports = 33,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc3));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    std.mem.writeInt(u64, ptr[0..8], 0, .little);
}

test "entrypoint: nextAccountMaybe handles dup marker" {
    var input: [32768]u8 align(8) = undefined;
    buildInputWithDup(&input);

    var ctx = InstructionContext.init(&input);
    try std.testing.expectEqual(@as(u64, 3), ctx.remainingAccounts());

    const s0 = try ctx.nextAccountMaybe();
    switch (s0) {
        .account => |a| try std.testing.expectEqual(@as(u64, 777), a.lamports()),
        .duplicated => return error.TestUnexpectedDup,
    }

    const s1 = try ctx.nextAccountMaybe();
    switch (s1) {
        .account => return error.TestExpectedDup,
        .duplicated => |idx| try std.testing.expectEqual(@as(u8, 0), idx),
    }

    const s2 = try ctx.nextAccountMaybe();
    switch (s2) {
        .account => |a| try std.testing.expectEqual(@as(u64, 333), a.lamports()),
        .duplicated => return error.TestUnexpectedDup,
    }

    try std.testing.expectEqual(@as(u64, 0), ctx.remainingAccounts());
}

test "entrypoint: parseAccounts resolves dup back to original" {
    var input: [32768]u8 align(8) = undefined;
    buildInputWithDup(&input);

    var ctx = InstructionContext.init(&input);
    const accs = try ctx.parseAccounts(.{ "owner", "owner_again", "other" });

    // owner and owner_again must refer to the same backing record.
    try std.testing.expectEqual(@intFromPtr(accs.owner.raw), @intFromPtr(accs.owner_again.raw));
    try std.testing.expectEqual(@as(u64, 777), accs.owner_again.lamports());
    try std.testing.expectEqual(@as(u64, 333), accs.other.lamports());
}

test "entrypoint: parseAccountsWith resolves dup and re-applies checks" {
    var input: [32768]u8 align(8) = undefined;
    buildInputWithDup(&input);

    var ctx = InstructionContext.init(&input);
    const accs = try ctx.parseAccountsWith(.{
        .{ "owner", AccountExpectation{ .signer = true, .writable = true } },
        .{ "owner_again", AccountExpectation{ .signer = true, .writable = true } },
        .{ "other", AccountExpectation{} },
    });
    try std.testing.expectEqual(@intFromPtr(accs.owner.raw), @intFromPtr(accs.owner_again.raw));
    try std.testing.expect(accs.owner_again.isSigner());
}

test "entrypoint: skipAccounts is dup-aware" {
    var input: [32768]u8 align(8) = undefined;
    buildInputWithDup(&input);

    var ctx = InstructionContext.init(&input);
    ctx.skipAccounts(2); // skip slot 0 (real) + slot 1 (dup)
    try std.testing.expectEqual(@as(u64, 1), ctx.remainingAccounts());

    const last = ctx.nextAccount().?;
    try std.testing.expectEqual(@as(u64, 333), last.lamports());
}

// =========================================================================
// AccountCursor tests
// =========================================================================

test "entrypoint: accountCursor supports full and remaining sources" {
    var input: [32768]u8 align(8) = undefined;
    buildInputWithDup(&input);

    var full_ctx = InstructionContext.init(&input);
    var full_cursor = try full_ctx.accountCursor();
    try std.testing.expectEqual(@as(usize, 0), full_cursor.nextIndex());
    try std.testing.expectEqual(@as(u64, 3), full_cursor.remainingAccounts());

    const first = try full_cursor.takeOne();
    try std.testing.expectEqual(@as(u64, 777), first.lamports());
    try std.testing.expectEqual(@as(usize, 1), full_cursor.nextIndex());

    const full_peek = try full_cursor.peek();
    try std.testing.expectEqual(@intFromPtr(first.raw), @intFromPtr(full_peek.raw));
    try std.testing.expectEqual(@as(u64, 2), full_cursor.remainingAccounts());

    var remaining_ctx = InstructionContext.init(&input);
    const fixed = try remaining_ctx.parseAccounts(.{"authority"});
    var remaining_cursor = try remaining_ctx.accountCursorWithPrefix(&.{fixed.authority});
    try std.testing.expectEqual(@as(usize, 1), remaining_cursor.nextIndex());
    try std.testing.expectEqual(@as(u64, 2), remaining_cursor.remainingAccounts());

    const remaining_peek = try remaining_cursor.peek();
    try std.testing.expectEqual(
        @intFromPtr(fixed.authority.raw),
        @intFromPtr(remaining_peek.raw),
    );

    const window = try remaining_cursor.takeWindow(2);
    try std.testing.expectEqual(@as(usize, 2), window.len());
    try std.testing.expectEqual(@intFromPtr(fixed.authority.raw), @intFromPtr(window.at(0).raw));
    try std.testing.expectEqual(@as(u64, 333), window.at(1).lamports());
    try std.testing.expectEqual(@as(u64, 0), remaining_cursor.remainingAccounts());
}

test "entrypoint: accountCursor takeOne peek and skip are all-or-nothing" {
    var input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&input, 1, 1, makePubkey(9), 0, 1);

    var ctx = InstructionContext.init(&input);
    var cursor = try ctx.accountCursor();

    const first = try cursor.takeOne();
    try std.testing.expectEqual(@as(u8, 1), first.key()[0]);
    try std.testing.expectEqual(@as(u64, 1), cursor.remainingAccounts());

    const peek_a = try cursor.peek();
    const peek_b = try cursor.peek();
    const peek_c = try cursor.peek();
    try std.testing.expectEqual(@intFromPtr(peek_a.raw), @intFromPtr(peek_b.raw));
    try std.testing.expectEqual(@intFromPtr(peek_a.raw), @intFromPtr(peek_c.raw));
    try std.testing.expectEqual(@as(u64, 1), cursor.remainingAccounts());

    try std.testing.expectError(error.NotEnoughAccountKeys, cursor.skip(2));
    try std.testing.expectEqual(@as(u64, 1), cursor.remainingAccounts());

    const second = try cursor.takeOne();
    try std.testing.expectEqual(@intFromPtr(peek_a.raw), @intFromPtr(second.raw));
    try std.testing.expectEqual(@as(u64, 0), cursor.remainingAccounts());
    try std.testing.expectError(error.NotEnoughAccountKeys, cursor.takeOne());
    try std.testing.expectError(error.NotEnoughAccountKeys, cursor.peek());
}

test "entrypoint: accountCursor windows stay ordered and stable after parent advances" {
    var input: [32768]u8 align(8) = undefined;
    buildInputWithDup(&input);

    var ctx = InstructionContext.init(&input);
    var cursor = try ctx.accountCursor();

    const empty = try cursor.takeWindow(0);
    try std.testing.expectEqual(@as(usize, 0), empty.len());
    try std.testing.expectEqual(@as(u64, 3), cursor.remainingAccounts());

    const window = try cursor.takeWindow(2);
    try std.testing.expectEqual(@as(usize, 2), window.len());
    try std.testing.expectEqual(@as(u64, 777), window.at(0).lamports());
    try std.testing.expectEqual(@as(u64, 777), window.at(1).lamports());

    const tail = try cursor.takeOne();
    try std.testing.expectEqual(@as(u64, 333), tail.lamports());
    try std.testing.expectEqual(@as(usize, 2), window.len());
    try std.testing.expectEqual(@as(u64, 777), window.at(0).lamports());
    try std.testing.expectEqual(@as(u64, 777), window.at(1).lamports());

    var count: usize = 0;
    var sum: u64 = 0;
    var it = window.iterator();
    while (it.next()) |acc| {
        count += 1;
        sum += acc.lamports();
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u64, 1_554), sum);
}

test "entrypoint: accountCursor duplicate policies and assume-unique path behave as specified" {
    var dup_input: [32768]u8 align(8) = undefined;
    buildInputWithDup(&dup_input);

    var dup_ctx = InstructionContext.init(&dup_input);
    var dup_cursor = try dup_ctx.accountCursor();
    try std.testing.expectError(
        error.InvalidArgument,
        dup_cursor.takeWindowWithPolicy(2, .reject),
    );
    try std.testing.expectEqual(@as(u64, 3), dup_cursor.remainingAccounts());
    try std.testing.expectEqual(@as(u64, 777), (try dup_cursor.takeOne()).lamports());

    var unique_input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&unique_input, 1, 1, makePubkey(9), 0, 1);

    var safe_ctx = InstructionContext.init(&unique_input);
    var safe_cursor = try safe_ctx.accountCursor();
    const safe_window = try safe_cursor.takeWindow(2);

    var unique_ctx = InstructionContext.init(&unique_input);
    var unique_cursor = try unique_ctx.accountCursor();
    const unique_window = try unique_cursor.takeWindowAssumeUnique(2);

    try std.testing.expectEqual(@as(usize, safe_window.len()), unique_window.len());
    inline for (0..2) |i| {
        try std.testing.expectEqual(
            @intFromPtr(safe_window.at(i).raw),
            @intFromPtr(unique_window.at(i).raw),
        );
    }
    try std.testing.expectEqual(safe_cursor.nextIndex(), unique_cursor.nextIndex());
    try std.testing.expectEqual(safe_cursor.remainingAccounts(), unique_cursor.remainingAccounts());
}

test "entrypoint: accountCursor safe skip and reject duplicate windows stay aligned" {
    var adjacent_input: [32768]u8 align(8) = undefined;
    buildInputWithDup(&adjacent_input);

    var adjacent_ctx = InstructionContext.init(&adjacent_input);
    var adjacent_cursor = try adjacent_ctx.accountCursor();
    try adjacent_cursor.skip(2);
    try std.testing.expectEqual(@as(u64, 1), adjacent_cursor.remainingAccounts());
    try std.testing.expectEqual(@as(u64, 333), (try adjacent_cursor.takeOne()).lamports());

    var spaced_input: [32768]u8 align(8) = undefined;
    buildInputWithNonAdjacentDup(&spaced_input);

    var reject_ctx = InstructionContext.init(&spaced_input);
    var reject_cursor = try reject_ctx.accountCursor();
    try std.testing.expectError(
        error.InvalidArgument,
        reject_cursor.takeWindowWithPolicy(3, .reject),
    );
    try std.testing.expectEqual(@as(u64, 4), reject_cursor.remainingAccounts());

    var allow_ctx = InstructionContext.init(&spaced_input);
    var allow_cursor = try allow_ctx.accountCursor();
    const allow_window = try allow_cursor.takeWindow(3);
    try std.testing.expectEqual(@as(usize, 3), allow_window.len());
    try std.testing.expectEqual(@intFromPtr(allow_window.at(0).raw), @intFromPtr(allow_window.at(2).raw));
    try std.testing.expectEqual(@as(u64, 1), allow_cursor.remainingAccounts());
    try std.testing.expectEqual(@as(u64, 33), (try allow_cursor.takeOne()).lamports());
}

test "entrypoint: accountCursor validation maps canonical errors and rolls back" {
    var signer_input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&signer_input, 0, 1, makePubkey(9), 1, 1);
    var signer_ctx = InstructionContext.init(&signer_input);
    var signer_cursor = try signer_ctx.accountCursor();
    try std.testing.expectError(
        error.MissingRequiredSignature,
        signer_cursor.takeWindowValidated(1, .allow, .{ .writable = true, .signer = true }),
    );
    try std.testing.expectEqual(@as(u64, 2), signer_cursor.remainingAccounts());
    try std.testing.expectEqual(@as(u8, 1), (try signer_cursor.takeOne()).key()[0]);

    var writable_input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&writable_input, 1, 0, makePubkey(9), 1, 1);
    var writable_ctx = InstructionContext.init(&writable_input);
    var writable_cursor = try writable_ctx.accountCursor();
    try std.testing.expectError(
        error.ImmutableAccount,
        writable_cursor.takeWindowValidated(1, .allow, .{ .signer = true, .writable = true }),
    );

    var executable_input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&executable_input, 1, 1, makePubkey(9), 1, 1);
    var executable_ctx = InstructionContext.init(&executable_input);
    var executable_cursor = try executable_ctx.accountCursor();
    try std.testing.expectError(
        error.InvalidAccountData,
        executable_cursor.takeWindowValidated(1, .allow, .{ .executable = true }),
    );

    var owner_input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&owner_input, 1, 1, makePubkey(9), 1, 1);
    var owner_ctx = InstructionContext.init(&owner_input);
    var owner_cursor = try owner_ctx.accountCursor();
    try std.testing.expectError(
        error.IncorrectProgramId,
        owner_cursor.takeWindowValidated(1, .allow, .{ .owner = comptime makePubkey(77) }),
    );

    var key_input: [32768]u8 align(8) = undefined;
    buildTwoAccountInput(&key_input, 1, 1, makePubkey(9), 1, 1);
    var key_ctx = InstructionContext.init(&key_input);
    var key_cursor = try key_ctx.accountCursor();
    try std.testing.expectError(
        error.InvalidArgument,
        key_cursor.takeWindowValidated(1, .allow, .{ .key = comptime makePubkey(77) }),
    );
}

// =========================================================================
// programEntrypoint tests
// =========================================================================
//
// We exercise programEntrypoint directly by constructing a serialized
// input buffer (same shape the runtime hands the BPF program) and
// calling the closure it returns. Since we're on the host, the test
// runs in plain native code — there's no BPF runtime emulation here.

// A scratch buffer for the test process function to record what it saw.
var test_observed_count: usize = 0;
var test_observed_lamports: [4]u64 = .{ 0, 0, 0, 0 };
var test_observed_data: [16]u8 = .{0} ** 16;
var test_observed_data_len: usize = 0;

fn testProcess2(
    accounts: *const [2]AccountInfo,
    data: []const u8,
    _: *const Pubkey,
) ProgramResult {
    test_observed_count = 2;
    test_observed_lamports[0] = accounts[0].lamports();
    test_observed_lamports[1] = accounts[1].lamports();
    test_observed_data_len = data.len;
    @memcpy(test_observed_data[0..data.len], data);
    return;
}

test "entrypoint: programEntrypoint parses 2 accounts + ix data" {
    var input align(8) = [_]u8{0} ** 32768;
    var ptr: [*]u8 = &input;

    std.mem.writeInt(u64, ptr[0..8], 2, .little);
    ptr += 8;

    const acc0: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 1,
        .is_writable = 1,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(1),
        .owner = makePubkey(2),
        .lamports = 12345,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc0));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    const acc1: Account = .{
        .borrow_state = account.NON_DUP_MARKER,
        .is_signer = 0,
        .is_writable = 0,
        .is_executable = 0,
        ._padding = .{0} ** 4,
        .key = makePubkey(3),
        .owner = makePubkey(2),
        .lamports = 67890,
        .data_len = 0,
    };
    @memcpy(ptr[0..@sizeOf(Account)], std.mem.asBytes(&acc1));
    ptr += @sizeOf(Account) + MAX_PERMITTED_DATA_INCREASE + 8;

    // instruction data: "hello" (5 bytes)
    std.mem.writeInt(u64, ptr[0..8], 5, .little);
    ptr += 8;
    @memcpy(ptr[0..5], "hello");
    ptr += 5;
    // program id (just zeros; we don't inspect it)
    ptr += @sizeOf(Pubkey);

    test_observed_count = 0;
    test_observed_data_len = 0;

    const entry = programEntrypoint(2, testProcess2);
    const result = entry(&input);

    try std.testing.expectEqual(SUCCESS, result);
    try std.testing.expectEqual(@as(usize, 2), test_observed_count);
    try std.testing.expectEqual(@as(u64, 12345), test_observed_lamports[0]);
    try std.testing.expectEqual(@as(u64, 67890), test_observed_lamports[1]);
    try std.testing.expectEqualStrings("hello", test_observed_data[0..test_observed_data_len]);
}

fn testProcess3Noop(
    _: *const [3]AccountInfo,
    _: []const u8,
    _: *const Pubkey,
) ProgramResult {
    return;
}

test "entrypoint: programEntrypoint errors on too-few accounts" {
    var input align(8) = [_]u8{0} ** 32768;
    // num_accounts = 1, but we request 3
    std.mem.writeInt(u64, input[0..8], 1, .little);
    const entry = programEntrypoint(3, testProcess3Noop);
    const result = entry(&input);
    // NotEnoughAccountKeys
    try std.testing.expect(result != SUCCESS);
}
