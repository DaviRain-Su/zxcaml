//! Hosted native entrypoint shim for developer-convenience builds.
//!
//! RESPONSIBILITIES:
//! - Create the P1 static-buffer arena on hosted targets.
//! - Call the generated `omlz_user_entrypoint` function.
//! - Exit the native process with the user entrypoint's return value.

const std = @import("std");
const Arena = @import("runtime/arena.zig").Arena;
const AccountRuntime = @import("runtime/account.zig");
const program = @import("program.zig");

const arena_bytes = 32 * 1024;

var native_arena_buffer: [arena_bytes]u8 align(8) = undefined;
var native_empty_input: [48]u8 align(8) = [_]u8{0} ** 48;

/// Runs the generated program and exits with its returned status byte.
pub fn main() noreturn {
    var arena = Arena.fromStaticBuffer(&native_arena_buffer);
    const empty_accounts: []AccountRuntime.AccountView = &.{};
    const empty_instruction_data: []const u8 = &.{};
    const status = program.omlz_user_entrypoint(&arena, native_empty_input[0..].ptr, empty_accounts, empty_instruction_data);
    arena.reset();
    std.process.exit(@intCast(status & 0xff));
}
