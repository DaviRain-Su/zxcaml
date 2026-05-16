//! Generic freestanding WASM entry shim for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Export one minimal smoke entrypoint for generic WASM artifact generation.
//! - Create a caller-local arena and pass empty host inputs to shared generated code.
//! - Avoid Solana/BPF/native runtime adapters and host imports.

const Arena = @import("runtime/arena.zig").Arena;
const AccountRuntime = @import("runtime/account.zig");
const program = @import("program.zig");

const arena_bytes = 32 * 1024;

var wasm_arena_buffer: [arena_bytes]u8 align(8) = undefined;
var wasm_empty_input: [48]u8 align(8) = [_]u8{0} ** 48;

export fn entrypoint() callconv(.c) u64 {
    var arena = Arena.fromStaticBuffer(&wasm_arena_buffer);
    const empty_accounts: []AccountRuntime.AccountView = &.{};
    const empty_instruction_data: []const u8 = &.{};
    const status = program.omlz_user_entrypoint(&arena, wasm_empty_input[0..].ptr, empty_accounts, empty_instruction_data);
    arena.reset();
    return status;
}
