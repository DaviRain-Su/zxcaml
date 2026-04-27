//! Compile-only OCaml backend placeholder.
//!
//! RESPONSIBILITIES:
//! - Keep the backend extension surface honest for future non-Zig targets.
//! - Compile as part of tests without participating in the default pipeline.
//! - Return `error.NotImplemented` from every operational entrypoint.

const std = @import("std");
const api = @import("api.zig");
const ir = @import("../core/ir.zig");

/// Placeholder OCaml backend implementation.
pub const OcamlBackend = struct {
    const vtable: api.VTable = .{
        .evalModule = api.unsupportedEvalModule,
        .emitModule = emitBackend,
    };

    /// Returns this stub behind the backend extension-point trait.
    pub fn backend(self: *OcamlBackend) api.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

fn emitBackend(_: *anyopaque, _: ir.Module) anyerror![]const u8 {
    return error.NotImplemented;
}

test "OCaml backend stub returns NotImplemented" {
    var backend: OcamlBackend = .{};
    try std.testing.expectError(error.NotImplemented, backend.backend().emitModule(.{ .decls = &.{} }));
}
