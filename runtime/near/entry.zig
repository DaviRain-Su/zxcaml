//! NEAR no-storage method entry shim for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Export one NEAR-visible method-style entrypoint with no params/results.
//! - Read raw method input through NEAR registers and return bytes via `value_return`.
//! - Keep accounts absent by construction and avoid Solana/BPF/native shims.

const Arena = @import("runtime/arena.zig").Arena;
const AccountRuntime = @import("runtime/account.zig");
const host = @import("runtime/near_host.zig");
const program = @import("program.zig");

const arena_bytes = 32 * 1024;
const success_log = "omlz near entrypoint";

var near_arena_buffer: [arena_bytes]u8 align(8) = undefined;
var near_input_buffer: [host.max_input_bytes]u8 align(8) = undefined;
var near_status_buffer: [8]u8 align(8) = undefined;

export fn entrypoint() callconv(.c) void {
    const input = host.requireInput(near_input_buffer[0..]);

    var arena = Arena.fromStaticBuffer(&near_arena_buffer);
    const empty_accounts: []AccountRuntime.AccountView = &.{};
    const status = program.omlz_user_entrypoint(&arena, near_input_buffer[0..].ptr, empty_accounts, input);
    arena.reset();

    host.log(success_log);
    host.finish(host.encodeStatus(status, &near_status_buffer));
}
