//! Compile-only LLVM backend placeholder.
//!
//! RESPONSIBILITIES:
//! - Keep the backend extension surface honest for future LLVM work.
//! - Compile as part of tests without participating in the default pipeline.
//! - Return `error.NotImplemented` from every operational entrypoint.
//! - F-C2 decision: keep this stub as a tiny `api.Backend` trait-shape
//!   regression target rather than deleting the documented extension point.

const std = @import("std");
const api = @import("api.zig");
const ir = @import("../core/ir.zig");

/// Placeholder LLVM backend implementation.
pub const LlvmBackend = struct {
    const vtable: api.VTable = .{
        .evalModule = api.unsupportedEvalModule,
        .emitModule = emitBackend,
    };

    /// Returns this stub behind the backend extension-point trait.
    pub fn backend(self: *LlvmBackend) api.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

fn emitBackend(_: *anyopaque, _: ir.Module) anyerror![]const u8 {
    return error.NotImplemented;
}

test "LLVM backend stub satisfies Backend trait API" {
    var backend: LlvmBackend = .{};
    const trait_backend: api.Backend = backend.backend();
    const empty_module: ir.Module = .{ .decls = &.{} };

    try std.testing.expectError(error.NotImplemented, trait_backend.evalModule(empty_module));
    try std.testing.expectError(error.NotImplemented, trait_backend.emitModule(empty_module));
}
