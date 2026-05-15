//! On-chain CPI wrappers around the SPL Memo program.
//!
//! Thin syntactic sugar over `instruction.zig` + `sol.cpi.invokeRaw`.
//! Use these helpers when you're writing on-chain code that wants to
//! emit a memo via CPI; off-chain code (transaction construction)
//! should call `instruction.memo(...)` directly.

const std = @import("std");
const sol = @import("solana_program_sdk");
const instruction = @import("instruction.zig");

const CpiAccountInfo = sol.CpiAccountInfo;
const Pubkey = sol.Pubkey;
const Signer = sol.cpi.Signer;
const ProgramError = sol.ProgramError;
const ProgramResult = sol.ProgramResult;

const max_signers = 11;

fn buildMemoInstruction(
    message: []const u8,
    signers: []const CpiAccountInfo,
    meta_buf: *[max_signers]sol.cpi.AccountMeta,
    pubkey_buf: *[max_signers]*const Pubkey,
) ProgramError!sol.cpi.Instruction {
    if (signers.len > max_signers) return error.InvalidArgument;

    for (signers, 0..) |s, i| pubkey_buf[i] = s.key();
    return instruction.memoChecked(message, pubkey_buf[0..signers.len], meta_buf[0..signers.len]) catch
        return error.InvalidArgument;
}

fn stageRuntimeAccounts(
    memo_program: CpiAccountInfo,
    signers: []const CpiAccountInfo,
    infos: *[max_signers + 1]CpiAccountInfo,
) []const CpiAccountInfo {
    for (signers, 0..) |s, i| infos[i] = s;
    infos[signers.len] = memo_program;
    return infos[0 .. signers.len + 1];
}

/// Invoke the SPL Memo program with `message`.
///
/// `signers` are the runtime account views whose pubkeys must co-sign.
/// They populate the instruction's `AccountMeta` list and are forwarded
/// to the CPI runtime in the same caller order.
pub fn memo(
    message: []const u8,
    memo_program: CpiAccountInfo,
    signers: []const CpiAccountInfo,
) ProgramResult {
    var meta_buf: [max_signers]sol.cpi.AccountMeta = undefined;
    var pubkey_buf: [max_signers]*const Pubkey = undefined;
    const ix = try buildMemoInstruction(message, signers, &meta_buf, &pubkey_buf);

    var infos: [max_signers + 1]CpiAccountInfo = undefined;
    return sol.cpi.invokeRaw(&ix, stageRuntimeAccounts(memo_program, signers, &infos));
}

/// PDA-signed variant of `memo`.
///
/// Use this when one or more memo signer accounts are PDAs satisfied by
/// the current program via `invoke_signed`.
pub fn memoSigned(
    message: []const u8,
    memo_program: CpiAccountInfo,
    signers: []const CpiAccountInfo,
    pda_signers: []const Signer,
) ProgramResult {
    var meta_buf: [max_signers]sol.cpi.AccountMeta = undefined;
    var pubkey_buf: [max_signers]*const Pubkey = undefined;
    const ix = try buildMemoInstruction(message, signers, &meta_buf, &pubkey_buf);

    var infos: [max_signers + 1]CpiAccountInfo = undefined;
    return sol.cpi.invokeSignedRaw(
        &ix,
        stageRuntimeAccounts(memo_program, signers, &infos),
        pda_signers,
    );
}

/// Single-PDA fast path for `memoSigned`.
pub inline fn memoSignedSingle(
    message: []const u8,
    memo_program: CpiAccountInfo,
    signers: []const CpiAccountInfo,
    signer_seeds: anytype,
) ProgramResult {
    var meta_buf: [max_signers]sol.cpi.AccountMeta = undefined;
    var pubkey_buf: [max_signers]*const Pubkey = undefined;
    const ix = try buildMemoInstruction(message, signers, &meta_buf, &pubkey_buf);

    var infos: [max_signers + 1]CpiAccountInfo = undefined;
    return sol.cpi.invokeSignedSingle(
        &ix,
        stageRuntimeAccounts(memo_program, signers, &infos),
        signer_seeds,
    );
}

/// No-signer convenience — emit a memo without enforcing any
/// signatures. Common for "audit log" style usage.
pub fn memoNoSigners(message: []const u8, memo_program: CpiAccountInfo) ProgramResult {
    const ix = instruction.memoNoSigners(message);
    var infos = [_]CpiAccountInfo{memo_program};
    return sol.cpi.invokeRaw(&ix, &infos);
}

const TestAccount = extern struct {
    raw: sol.account.Account,
    data: [8]u8 = .{0} ** 8,
};

fn testAccount(
    key: Pubkey,
    owner: Pubkey,
    signer: bool,
    writable: bool,
    executable: bool,
) TestAccount {
    return .{
        .raw = .{
            .borrow_state = sol.account.NOT_BORROWED,
            .is_signer = @intFromBool(signer),
            .is_writable = @intFromBool(writable),
            .is_executable = @intFromBool(executable),
            ._padding = .{0} ** 4,
            .key = key,
            .owner = owner,
            .lamports = 0,
            .data_len = 8,
        },
    };
}

fn toCpiAccountInfo(backing: *TestAccount) CpiAccountInfo {
    return (sol.AccountInfo{ .raw = &backing.raw }).toCpiInfo();
}

test "public memo CPI wrapper decls exist" {
    try std.testing.expect(@hasDecl(@This(), "memo"));
    try std.testing.expect(@hasDecl(@This(), "memoSigned"));
    try std.testing.expect(@hasDecl(@This(), "memoSignedSingle"));
    try std.testing.expect(@hasDecl(@This(), "memoNoSigners"));
}

test "memo host wrappers stage successfully then return host fallback error" {
    var memo_program_account = testAccount(.{0x11} ** 32, .{0x71} ** 32, false, false, true);
    var authority_account = testAccount(.{0x12} ** 32, .{0x72} ** 32, true, false, false);

    const memo_program = toCpiAccountInfo(&memo_program_account);
    const authority = toCpiAccountInfo(&authority_account);
    const bump_seed = [_]u8{7};
    const seeds = sol.cpi.seedPack(.{ "memo", &bump_seed });
    const signer = sol.cpi.Signer.from(&seeds);

    try std.testing.expectError(error.InvalidArgument, memo("audit", memo_program, &.{authority}));
    try std.testing.expectError(error.InvalidArgument, memoSigned("audit", memo_program, &.{authority}, &.{signer}));
    try std.testing.expectError(error.InvalidArgument, memoSignedSingle("audit", memo_program, &.{authority}, .{ "memo", &bump_seed }));
    try std.testing.expectError(error.InvalidArgument, memoNoSigners("audit", memo_program));
}

test "memo rejects excessive signer counts before CPI" {
    var memo_program_account = testAccount(.{0x21} ** 32, .{0x81} ** 32, false, false, true);
    var signer_accounts: [max_signers + 1]TestAccount = undefined;
    var signers: [max_signers + 1]CpiAccountInfo = undefined;
    for (&signer_accounts, 0..) |*account, i| {
        account.* = testAccount(.{@as(u8, @intCast(i + 1))} ** 32, .{0x82} ** 32, true, false, false);
        signers[i] = toCpiAccountInfo(account);
    }

    const memo_program = toCpiAccountInfo(&memo_program_account);
    const bump_seed = [_]u8{9};

    try std.testing.expectError(error.InvalidArgument, memo("audit", memo_program, signers[0..]));
    try std.testing.expectError(error.InvalidArgument, memoSigned("audit", memo_program, signers[0..], &.{}));
    try std.testing.expectError(error.InvalidArgument, memoSignedSingle("audit", memo_program, signers[0..], .{ "memo", &bump_seed }));
}
