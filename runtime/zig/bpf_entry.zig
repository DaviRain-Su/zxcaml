//! Solana BPF entrypoint shim for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Export the `entrypoint` symbol that Solana's loader discovers.
//! - Create the stack-bounded BPF static-buffer arena for each invocation.
//! - Call the generated `omlz_user_entrypoint` function with arena threading.

const std = @import("std");
const Arena = @import("runtime/arena.zig").Arena;
const AccountRuntime = @import("runtime/account.zig");
const syscalls = @import("runtime/syscalls.zig");
const vendored_sdk = @import("vendored_sdk");
const program = @import("program.zig");

comptime {
    _ = vendored_sdk.solana_program_sdk.hash.HASH_BYTES;
    _ = vendored_sdk.solana_program_sdk.secp256k1_recover.PUBKEY_LEN;
    _ = vendored_sdk.solana_program_sdk.clock.Clock;
    _ = vendored_sdk.solana_program_sdk.rent.Rent.Data;
}

// SBF stack frames are limited to 4096 bytes. Keep the entry arena below that
// ceiling so allocation-heavy array/ref programs do not overflow `entrypoint`.
const arena_bytes = 3 * 1024;
// Keep account-view scratch storage below the BPF stack-frame limit. Current
// examples need at most seven accounts (order_book fill path); oversized
// storage can overflow the entrypoint frame before the first log syscall.
const max_entrypoint_accounts = 16;

const loader_log_message_bytes = "ZxCaml entrypoint";

fn shouldEmitLoaderLog(instruction_data: []const u8) bool {
    return std.mem.eql(u8, instruction_data, loader_log_message_bytes);
}

/// Solana loader entrypoint; returns the user program's u64 status code.
export fn entrypoint(input: [*]u8) callconv(.c) u64 {
    var bpf_arena_buffer: [arena_bytes]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&bpf_arena_buffer);
    var account_storage: [max_entrypoint_accounts]AccountRuntime.AccountView = undefined;
    var accounts: []AccountRuntime.AccountView = undefined;
    AccountRuntime.parseAccountsFromPtrIntoStorage(input, account_storage[0..], &accounts) catch return 1;
    const instruction_data = AccountRuntime.parseInstructionDataFromPtr(input) catch return 1;
    if (shouldEmitLoaderLog(instruction_data)) {
        syscalls.sol_log_(loader_log_message_bytes);
    }
    const status = program.omlz_user_entrypoint(&arena, input, accounts, instruction_data);
    arena.reset();
    return status;
}
