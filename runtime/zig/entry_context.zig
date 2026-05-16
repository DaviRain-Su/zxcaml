//! SDK-style entrypoint context helpers for ZxCaml runtime shims.

const std = @import("std");
const Arena = @import("arena.zig").Arena;
const AccountRuntime = @import("account.zig");
const vendored_sdk = @import("vendored_sdk").solana_program_sdk;

pub const InstructionContext = vendored_sdk.entrypoint.InstructionContext;

const SdkAccountInfo = vendored_sdk.account.AccountInfo;
const account_alignment = 8;
const max_permitted_data_increase = 10 * 1024;

/// Parses the current instruction context into ZxCaml account views while
/// preserving duplicate-account aliasing.
pub fn parseAccountViews(arena: *Arena, ctx: *InstructionContext, out: *[]AccountRuntime.AccountView) AccountRuntime.ParseError!void {
    const account_count_u64 = ctx.remainingAccounts();
    if (account_count_u64 > std.math.maxInt(usize)) return error.AccountCountOverflow;
    const account_count: usize = @intCast(account_count_u64);

    const accounts = arena.alloc(AccountRuntime.AccountView, account_count) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.AccountCountOverflow,
    };

    for (accounts, 0..) |*account_view, index| {
        account_view.* = switch (ctx.nextAccountMaybeUnchecked()) {
            .account => |resolved| accountViewFromSdkInfo(resolved),
            .duplicated => |dup_index| blk: {
                if (dup_index >= index) return error.InvalidDuplicateAccount;
                break :blk accounts[dup_index];
            },
        };
    }

    out.* = accounts;
}

fn accountViewFromSdkInfo(info: SdkAccountInfo) AccountRuntime.AccountView {
    return .{
        .is_signer = info.isSigner(),
        .is_writable = info.isWritable(),
        .executable = info.executable(),
        .key = info.key(),
        .lamports = @ptrCast(&info.raw.lamports),
        .data = info.data(),
        .owner = info.owner(),
        .rent_epoch = rentEpochPtrFromSdkInfo(info),
    };
}

fn rentEpochPtrFromSdkInfo(info: SdkAccountInfo) *align(1) const u64 {
    const data_end = @intFromPtr(info.dataPtr()) + info.dataLen() + max_permitted_data_increase;
    const aligned = std.mem.alignForward(usize, data_end, account_alignment);
    return @ptrFromInt(aligned);
}
