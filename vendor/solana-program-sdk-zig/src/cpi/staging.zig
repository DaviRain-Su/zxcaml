const shared = @import("shared.zig");
const std = shared.std;
const pubkey = shared.pubkey;
const CpiAccountInfo = shared.CpiAccountInfo;
const Pubkey = shared.Pubkey;
const ProgramError = shared.ProgramError;
const AccountMeta = @import("instruction.zig").AccountMeta;
const Instruction = @import("instruction.zig").Instruction;
const Seed = @import("seeds.zig").Seed;
const Signer = @import("seeds.zig").Signer;

/// Stage a fixed CPI account prefix, a runtime-sized dynamic account
/// section, and an optional trailing suffix into one contiguous runtime
/// account slice, while also extracting the dynamic accounts' pubkeys.
///
/// This is useful for multisig-style wrappers whose instruction builder
/// needs `[]const Pubkey` for the dynamic signer list, while the CPI
/// syscall needs the corresponding `[]const CpiAccountInfo` in the same
/// caller order.
///
/// The helper is policy-free: caller decides what the dynamic section
/// means and whether zero dynamic accounts is valid.
pub fn stageDynamicAccountsWithPubkeys(
    comptime fixed_len: usize,
    comptime trailing_len: usize,
    fixed_accounts: [fixed_len]CpiAccountInfo,
    dynamic_accounts: []const CpiAccountInfo,
    trailing_accounts: [trailing_len]CpiAccountInfo,
    dynamic_pubkeys_out: []Pubkey,
    accounts_out: []CpiAccountInfo,
) ProgramError!struct {
    dynamic_pubkeys: []const Pubkey,
    runtime_accounts: []const CpiAccountInfo,
} {
    if (dynamic_accounts.len > dynamic_pubkeys_out.len) {
        return error.InvalidArgument;
    }

    const total_len = fixed_len + dynamic_accounts.len + trailing_len;
    if (accounts_out.len < total_len) {
        return error.InvalidArgument;
    }

    for (fixed_accounts, 0..) |info, i| {
        accounts_out[i] = info;
    }
    for (dynamic_accounts, 0..) |info, i| {
        dynamic_pubkeys_out[i] = info.key().*;
        accounts_out[fixed_len + i] = info;
    }
    for (trailing_accounts, 0..) |info, i| {
        accounts_out[fixed_len + dynamic_accounts.len + i] = info;
    }

    return .{
        .dynamic_pubkeys = dynamic_pubkeys_out[0..dynamic_accounts.len],
        .runtime_accounts = accounts_out[0..total_len],
    };
}

/// Caller-buffer-backed CPI staging for dynamic account metas and
/// runtime account infos.
///
/// The first `accountMetas().len` entries of `accountInfos()` always
/// correspond to the same staged input accounts in the same order.
/// `appendProgram` explicitly adds a runtime-only trailing program
/// account for `invoke*` calls; it does not add a matching meta entry.
pub const CpiAccountStaging = struct {
    metas_buf: []AccountMeta,
    infos_buf: []CpiAccountInfo,
    meta_len: usize = 0,
    info_len: usize = 0,

    const Self = @This();

    pub inline fn init(
        metas_buf: []AccountMeta,
        infos_buf: []CpiAccountInfo,
    ) Self {
        return .{
            .metas_buf = metas_buf,
            .infos_buf = infos_buf,
        };
    }

    pub inline fn reset(self: *Self) void {
        self.meta_len = 0;
        self.info_len = 0;
    }

    pub inline fn accountMetas(self: *const Self) []const AccountMeta {
        return self.metas_buf[0..self.meta_len];
    }

    pub inline fn accountInfos(self: *const Self) []const CpiAccountInfo {
        return self.infos_buf[0..self.info_len];
    }

    pub inline fn appendAccount(self: *Self, info: CpiAccountInfo) ProgramError!void {
        return self.appendMetaInfoUnchecked(
            AccountMeta.init(info.key(), info.isWritable(), info.isSigner()),
            info,
        );
    }

    pub inline fn appendMetaInfo(
        self: *Self,
        meta: AccountMeta,
        info: CpiAccountInfo,
    ) ProgramError!void {
        if (!pubkey.pubkeyEq(meta.pubkey, info.key())) return error.InvalidArgument;
        if (meta.is_writable != @as(u8, @intFromBool(info.isWritable()))) return error.InvalidArgument;
        if (meta.is_signer != @as(u8, @intFromBool(info.isSigner()))) return error.InvalidArgument;
        return self.appendMetaInfoUnchecked(meta, info);
    }

    /// Capacity-checked hot path that skips meta/info consistency
    /// validation. Caller must guarantee the pubkey and flag bytes line
    /// up with the supplied runtime account.
    pub inline fn appendMetaInfoUnchecked(
        self: *Self,
        meta: AccountMeta,
        info: CpiAccountInfo,
    ) ProgramError!void {
        if (self.meta_len >= self.metas_buf.len) return error.InvalidArgument;
        if (self.info_len >= self.infos_buf.len) return error.InvalidArgument;

        self.metas_buf[self.meta_len] = meta;
        self.infos_buf[self.info_len] = info;
        self.meta_len += 1;
        self.info_len += 1;
    }

    /// Explicitly append the CPI program account (or another
    /// runtime-only trailing account) to the staged runtime slice.
    pub inline fn appendProgram(self: *Self, program: CpiAccountInfo) ProgramError!void {
        if (self.info_len >= self.infos_buf.len) return error.InvalidArgument;
        self.infos_buf[self.info_len] = program;
        self.info_len += 1;
    }

    pub inline fn instructionFromProgram(
        self: *const Self,
        program: CpiAccountInfo,
        data: []const u8,
    ) Instruction {
        return Instruction.fromCpiAccount(program, self.accountMetas(), data);
    }
};

comptime {
    // Catch ABI regressions at build time.
    std.debug.assert(@sizeOf(Seed) == 16);
    std.debug.assert(@offsetOf(Seed, "addr") == 0);
    std.debug.assert(@offsetOf(Seed, "len") == 8);
    std.debug.assert(@sizeOf(Signer) == 16);
}

// =============================================================================
// C-ABI Structures for syscalls
// =============================================================================
