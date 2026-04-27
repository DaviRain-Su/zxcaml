//! Hosted native entrypoint shim for developer-convenience builds.
//!
//! RESPONSIBILITIES:
//! - Create the P1 static-buffer arena on hosted targets.
//! - Call the generated `omlz_user_entrypoint` function.
//! - Exit the native process with the user entrypoint's return value.

const std = @import("std");
const Arena = @import("runtime/arena.zig").Arena;
const program = @import("program.zig");

const arena_bytes = 32 * 1024;

var native_arena_buffer: [arena_bytes]u8 align(8) = undefined;

/// Runs the generated program and exits with its returned status byte.
pub fn main() noreturn {
    var arena = Arena.fromStaticBuffer(&native_arena_buffer);
    const empty_input = [_]u8{};
    const status = program.omlz_user_entrypoint(&arena, empty_input[0..].ptr);
    arena.reset();
    std.process.exit(@intCast(status & 0xff));
}
