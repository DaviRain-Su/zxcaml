//! Custom program error codes — Anchor-style `#[error_code]` for Zig.
//!
//! Programs typically need a small enum of program-specific errors
//! (Overflow, Unauthorized, NotInitialized, etc.) that the runtime
//! reports via the `Custom(u32)` wire format. This module provides a
//! one-line helper that:
//!
//!   1. Lets the user declare an `enum(u32)` of error codes — the
//!      `@intFromEnum` value goes on the wire as the custom error code.
//!   2. Declares a parallel `error{...}` set so the codes are usable in
//!      `try` chains alongside `ProgramError`.
//!   3. Bridges between the two: `toError(.X)` returns the matching
//!      error variant; `toU64(.X)` returns the runtime wire form.
//!
//! Physical layout:
//! - `shared.zig` — imports plus shared `program_error` aliases/constants
//! - `typed.zig` — `ErrorCode(E, ErrSet)` validation and wire helpers
//!
//! The public API stays flattened as `sol.error_code.*`, with the
//! top-level alias `sol.ErrorCode` preserved at `src/root.zig`.

const std = @import("std");
const shared = @import("shared.zig");
const typed = @import("typed.zig");

/// Typed custom-error namespace builder.
pub const ErrorCode = typed.ErrorCode;

// =============================================================================
// Tests
// =============================================================================

const Demo = enum(u32) {
    NotInitialized = 6000,
    Overflow = 6001,
    Unauthorized = 6002,
};
const DemoErrSet = error{ NotInitialized, Overflow, Unauthorized };
const DemoErr = ErrorCode(Demo, DemoErrSet);

test "ErrorCode: toU64 passes through non-zero codes" {
    try std.testing.expectEqual(@as(u64, 6000), DemoErr.toU64(.NotInitialized));
    try std.testing.expectEqual(@as(u64, 6001), DemoErr.toU64(.Overflow));
}

test "ErrorCode: toU64 maps Custom(0) to sentinel" {
    const Zero = enum(u32) { ZeroCode = 0 };
    const ZeroErr = ErrorCode(Zero, error{ZeroCode});
    try std.testing.expectEqual(shared.CUSTOM_ZERO, ZeroErr.toU64(.ZeroCode));
}

test "ErrorCode: toError returns matching ErrorSet variant" {
    const e: DemoErr.ErrorSet = DemoErr.toError(.Unauthorized);
    try std.testing.expectEqual(error.Unauthorized, e);
}

test "ErrorCode: catchToU64 maps custom variants to their u32 code" {
    try std.testing.expectEqual(@as(u64, 6000), DemoErr.catchToU64(error.NotInitialized));
    try std.testing.expectEqual(@as(u64, 6001), DemoErr.catchToU64(error.Overflow));
    try std.testing.expectEqual(@as(u64, 6002), DemoErr.catchToU64(error.Unauthorized));
}

test "ErrorCode: catchToU64 passes through ProgramError variants" {
    try std.testing.expectEqual(
        shared.INVALID_ARGUMENT,
        DemoErr.catchToU64(error.InvalidArgument),
    );
    try std.testing.expectEqual(
        shared.MISSING_REQUIRED_SIGNATURES,
        DemoErr.catchToU64(error.MissingRequiredSignature),
    );
}

test "ErrorCode: Error union combines both halves" {
    const make = struct {
        fn custom() DemoErr.Error!void {
            return DemoErr.toError(.Overflow);
        }
        fn builtin() DemoErr.Error!void {
            return error.InvalidArgument;
        }
        fn ok() DemoErr.Error!void {}
    };

    try std.testing.expectError(error.Overflow, make.custom());
    try std.testing.expectError(error.InvalidArgument, make.builtin());
    try make.ok();
}
