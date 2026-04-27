//! Solana BPF entrypoint shim for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Export the `entrypoint` symbol that Solana's loader discovers.
//! - Create the P1 32 KiB static-buffer arena for each invocation.
//! - Call the generated `omlz_user_entrypoint` function with arena threading.

const Arena = @import("runtime/arena.zig").Arena;
const program = @import("program.zig");

const arena_bytes = 32 * 1024;

var bpf_arena_buffer: [arena_bytes]u8 align(8) = undefined;

/// Solana loader entrypoint; returns the user program's u64 status code.
export fn entrypoint(input: [*]const u8) callconv(.c) u64 {
    var arena = Arena.fromStaticBuffer(&bpf_arena_buffer);
    const status = program.omlz_user_entrypoint(&arena, input);
    arena.reset();
    return status;
}
