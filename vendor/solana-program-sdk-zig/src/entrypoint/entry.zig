const shared = @import("shared.zig");
const account = shared.account;
const program_error = shared.program_error;
const error_code = shared.error_code;
const Account = shared.Account;
const AccountInfo = shared.AccountInfo;
const Pubkey = shared.Pubkey;
const ProgramResult = shared.ProgramResult;
const SUCCESS = shared.SUCCESS;
const MAX_PERMITTED_DATA_INCREASE = shared.MAX_PERMITTED_DATA_INCREASE;
const alignPointer = shared.alignPointer;
const InstructionContext = @import("context.zig").InstructionContext;

// =========================================================================
// Entrypoint helpers
// =========================================================================

// =========================================================================
// lazyEntrypoint — the ONLY entrypoint macro (Pinocchio: lazy_program_entrypoint!)
//
/// Usage:
/// ```zig
/// fn process(ctx: *sol.entrypoint.InstructionContext) sol.ProgramResult {
///     const source = ctx.nextAccount() orelse return error.NotEnoughAccountKeys;
///     const dest = ctx.nextAccount() orelse return error.NotEnoughAccountKeys;
///     const ix_data = ctx.instructionData();
///     // ...
/// }
///
/// export fn entrypoint(input: [*]u8) u64 {
///     return sol.entrypoint.lazyEntrypoint(process)(input);
/// }
/// ```
pub fn lazyEntrypoint(
    comptime process: *const fn (*InstructionContext) ProgramResult,
) fn ([*]u8) callconv(.c) u64 {
    return struct {
        fn entry(input: [*]u8) callconv(.c) u64 {
            var context = InstructionContext.init(input);
            process(&context) catch |err| {
                return program_error.errorToU64(err);
            };
            return SUCCESS;
        }
    }.entry;
}

// =========================================================================
// programEntrypoint — eager-parse entrypoint (ergonomic alternative)
//
// Pre-parses a comptime-known account count and instruction data into
// a flat array, then hands everything to user `process` in one call.
//
// Performance: **measurably tied with lazyEntrypoint** under
// ReleaseFast. The benchmark `program_entry_1` vs `program_entry_lazy_1`
// shows a 1-CU difference (in either direction depending on the body).
// LLVM aggressively optimizes the lazy path so there's no real
// throughput win here — pick this entrypoint for **ergonomic
// reasons** (positional `accounts[0]` access, no InstructionContext
// indirection, account count enforced at the entrypoint level so
// per-handler bounds checks are unnecessary), not for CU savings.
//
// Trade-offs vs. lazyEntrypoint:
//   + Account count enforced at the entry boundary — handlers can
//     index `accounts[i]` without bounds checks.
//   + No `try ctx.parseAccountsUnchecked(...)` boilerplate at the
//     top of `process`.
//   + Cleaner signature: `(accounts, data, program_id)`.
//   - Requires the account count to be known at compile time. For
//     dispatch patterns where account count varies between
//     instructions, use `lazyEntrypoint` and `parseAccountsUnchecked`.
//
// All accounts MUST be non-duplicate slots (i.e. distinct positions
// in the transaction). If your program may receive duplicate accounts,
// use lazyEntrypoint + `nextAccountMaybe`.
// =========================================================================

/// Parse exactly `account_count` non-duplicate accounts plus the
/// instruction data and program id, then call
/// `process(accounts, data, program_id)`.
///
/// CU cost is essentially identical to `lazyEntrypoint` +
/// `parseAccountsUnchecked` — choose based on style preference, not
/// performance. (Measured 1-CU swing in the
/// `benchmark_program_entry_*` micro-benches.)
///
/// Usage:
/// ```zig
/// fn process(
///     accounts: *const [3]sol.AccountInfo,
///     data: []const u8,
///     _: *const sol.Pubkey,
/// ) sol.ProgramResult {
///     try accounts[0].expectSigner();
///     // ...
/// }
///
/// export fn entrypoint(input: [*]u8) u64 {
///     return sol.entrypoint.programEntrypoint(3, process)(input);
/// }
/// ```
///
/// Returns `error.NotEnoughAccountKeys` if the runtime serialized
/// fewer accounts than `account_count`. Programs whose account count
/// differs across instructions should use `lazyEntrypoint` instead.
pub fn programEntrypoint(
    comptime account_count: usize,
    comptime process: *const fn (
        accounts: *const [account_count]AccountInfo,
        data: []const u8,
        program_id: *const Pubkey,
    ) ProgramResult,
) fn ([*]u8) callconv(.c) u64 {
    return struct {
        fn entry(input: [*]u8) callconv(.c) u64 {
            // First 8 bytes: num_accounts (u64 LE).
            const num_accounts: u64 = @as(*const u64, @ptrCast(@alignCast(input))).*;
            if (num_accounts < account_count) {
                return program_error.errorToU64(error.NotEnoughAccountKeys);
            }

            var accounts: [account_count]AccountInfo = undefined;
            var buf: [*]u8 = input + @sizeOf(u64);

            // Unrolled at comptime — the loop body is straight-line BPF
            // assembly with `i` baked into the array store index.
            inline for (0..account_count) |i| {
                const account_ptr: *Account = @ptrCast(@alignCast(buf));
                const data_len: usize = @intCast(account_ptr.data_len);
                buf += @sizeOf(u64) + (@sizeOf(Account) - @sizeOf(u64)) + data_len + MAX_PERMITTED_DATA_INCREASE;
                buf = @ptrFromInt(alignPointer(@intFromPtr(buf)));
                buf += @sizeOf(u64);
                accounts[i] = .{ .raw = account_ptr };
            }

            // After `account_count` accounts the buffer points at the
            // instruction-data length prefix.
            const data_len: usize = @intCast(@as(*const u64, @ptrCast(@alignCast(buf))).*);
            const data: []const u8 = buf[@sizeOf(u64) .. @sizeOf(u64) + data_len];
            const program_id: *const Pubkey = @ptrCast(@alignCast(buf + @sizeOf(u64) + data_len));

            process(&accounts, data, program_id) catch |err| {
                return program_error.errorToU64(err);
            };
            return SUCCESS;
        }
    }.entry;
}

/// Raw entrypoint — returns u64 directly, no error union overhead.
/// Use for maximum performance when you don't need ProgramResult.
pub fn lazyEntrypointRaw(
    comptime process: *const fn (*InstructionContext) u64,
) fn ([*]u8) callconv(.c) u64 {
    return struct {
        fn entry(input: [*]u8) callconv(.c) u64 {
            var context = InstructionContext.init(input);
            return process(&context);
        }
    }.entry;
}

/// `lazyEntrypoint` variant for handlers that return `ErrCode.Error!void`.
///
/// Use this when you have an `ErrorCode(MyEnum)` and want to preserve
/// the custom u32 discriminator on the wire while keeping `try`
/// ergonomics:
///
/// ```zig
/// const VaultErr = sol.ErrorCode(enum(u32) { Unauthorized = 6000, Overflow });
///
/// fn process(ctx: *InstructionContext) VaultErr.Error!void {
///     try sol.system.transfer(...);                       // ProgramError
///     if (bad) return VaultErr.toError(.Unauthorized);    // custom code
/// }
///
/// export fn entrypoint(input: [*]u8) u64 {
///     return sol.entrypoint.lazyEntrypointTyped(VaultErr, process)(input);
/// }
/// ```
///
/// Why not mutable globals: the SBPFv2 loader rejects `.bss` /
/// `.data`, so we can't stash a `u32` discriminator alongside a
/// generic `error.Custom`. Instead `ErrorCode(E)` synthesises a
/// unique error name per enum variant; the entrypoint's `catch`
/// dispatches on the name to recover the `u32` code.
///
/// Cost: zero CU on the happy path. The error-path dispatch is an
/// `inline for` over the variants (cold).
pub fn lazyEntrypointTyped(
    comptime ErrCode: type,
    comptime process: *const fn (*InstructionContext) ErrCode.Error!void,
) fn ([*]u8) callconv(.c) u64 {
    return struct {
        fn entry(input: [*]u8) callconv(.c) u64 {
            var context = InstructionContext.init(input);
            process(&context) catch |err| return ErrCode.catchToU64(err);
            return SUCCESS;
        }
    }.entry;
}

/// `programEntrypoint` variant for handlers that return `ErrCode.Error!void`.
/// See `lazyEntrypointTyped` for the rationale.
pub fn programEntrypointTyped(
    comptime account_count: usize,
    comptime ErrCode: type,
    comptime process: *const fn (
        accounts: *const [account_count]AccountInfo,
        data: []const u8,
        program_id: *const Pubkey,
    ) ErrCode.Error!void,
) fn ([*]u8) callconv(.c) u64 {
    return struct {
        fn entry(input: [*]u8) callconv(.c) u64 {
            const num_accounts: u64 = @as(*const u64, @ptrCast(@alignCast(input))).*;
            if (num_accounts < account_count) {
                return program_error.errorToU64(error.NotEnoughAccountKeys);
            }

            var accounts: [account_count]AccountInfo = undefined;
            var buf: [*]u8 = input + @sizeOf(u64);

            inline for (0..account_count) |i| {
                const account_ptr: *Account = @ptrCast(@alignCast(buf));
                const data_len: usize = @intCast(account_ptr.data_len);
                buf += @sizeOf(u64) + (@sizeOf(Account) - @sizeOf(u64)) + data_len + MAX_PERMITTED_DATA_INCREASE;
                buf = @ptrFromInt(alignPointer(@intFromPtr(buf)));
                buf += @sizeOf(u64);
                accounts[i] = .{ .raw = account_ptr };
            }

            const data_len: usize = @intCast(@as(*const u64, @ptrCast(@alignCast(buf))).*);
            const data: []const u8 = buf[@sizeOf(u64) .. @sizeOf(u64) + data_len];
            const program_id: *const Pubkey = @ptrCast(@alignCast(buf + @sizeOf(u64) + data_len));

            process(&accounts, data, program_id) catch |err| return ErrCode.catchToU64(err);
            return SUCCESS;
        }
    }.entry;
}
