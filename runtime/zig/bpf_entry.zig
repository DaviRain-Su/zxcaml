//! Solana BPF entrypoint shim for generated ZxCaml programs.
//!
//! RESPONSIBILITIES:
//! - Export the `entrypoint` symbol that Solana's loader discovers.
//! - Create the P1 32 KiB static-buffer arena for each invocation.
//! - Call the generated `omlz_user_entrypoint` function with arena threading.

const Arena = @import("runtime/arena.zig").Arena;
const AccountRuntime = @import("runtime/account.zig");
const syscalls = @import("runtime/syscalls.zig");
const program = @import("program.zig");

const arena_bytes = 32 * 1024;

const loader_log_message linksection(".rodata") = "ZxCaml entrypoint".*;

/// Solana loader entrypoint; returns the user program's u64 status code.
export fn entrypoint(input: [*]const u8) callconv(.c) u64 {
    // Minimal `return 0` programs can otherwise link to a section-only ELF that
    // `solana program deploy` rejects. A tiny log syscall keeps the dynamic
    // relocation/program-header shape expected by Solana's BPF loader.
    syscalls.sol_log_(loader_log_message[0..]);

    var bpf_arena_buffer: [arena_bytes]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&bpf_arena_buffer);
    const status = program.omlz_user_entrypoint(&arena, input);
    arena.reset();
    return status;
}
