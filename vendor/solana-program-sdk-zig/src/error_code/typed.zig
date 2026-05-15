const shared = @import("shared.zig");

const std = shared.stdlib;
const ProgramError = shared.ProgramError;

/// Wrap a user `enum(u32)` + parallel error set so they act as a
/// typed custom-error namespace. The returned struct exposes:
///   - `Code`     — alias for the input enum.
///   - `ErrorSet` — the error set you passed.
///   - `Error`    — `ErrorSet || ProgramError`, for handler returns.
///   - `toU64(.X)` / `toError(.X)` / `catchToU64(err)`.
///
/// Validation: every field of `E` must have a same-named variant in
/// `ErrSet`, and vice-versa. Mismatches → `@compileError`.
pub fn ErrorCode(comptime E: type, comptime ErrSet: type) type {
    comptime {
        const einfo = @typeInfo(E);
        if (einfo != .@"enum") @compileError("ErrorCode(E, ErrSet): E must be an enum");
        const tag = einfo.@"enum".tag_type;
        if (tag != u32) @compileError("ErrorCode(E, ErrSet): E must be `enum(u32)` for runtime ABI compatibility");

        const sinfo = @typeInfo(ErrSet);
        if (sinfo != .error_set) @compileError("ErrorCode(E, ErrSet): ErrSet must be an error set type");
        const errs = sinfo.error_set orelse
            @compileError("ErrorCode(E, ErrSet): ErrSet must be a concrete error set, not anyerror");

        if (einfo.@"enum".fields.len != errs.len) {
            @compileError("ErrorCode(E, ErrSet): E has " ++
                std.fmt.comptimePrint("{d}", .{einfo.@"enum".fields.len}) ++
                " variants but ErrSet has " ++
                std.fmt.comptimePrint("{d}", .{errs.len}));
        }
        for (einfo.@"enum".fields) |f| {
            var found = false;
            for (errs) |e| if (std.mem.eql(u8, f.name, e.name)) {
                found = true;
                break;
            };
            if (!found) {
                @compileError("ErrorCode: enum variant `" ++ f.name ++
                    "` has no matching error in ErrSet (add `" ++
                    f.name ++ "` to your error{...})");
            }
        }
    }

    return struct {
        pub const Code = E;
        pub const ErrorSet = ErrSet;
        pub const Error = ErrSet || ProgramError;

        /// Encode an error code into the runtime's `u64` wire format.
        /// Folded to a constant at monomorphic call sites.
        pub inline fn toU64(code: E) u64 {
            return shared.customError(@intFromEnum(code));
        }

        /// Return the `ErrSet` variant whose name matches `code`'s
        /// enum tag.
        pub inline fn toError(comptime code: E) ErrSet {
            return @field(ErrSet, @tagName(code));
        }

        /// Map a caught `Error` back to its wire `u64`. Used by
        /// `lazyEntrypointTyped` / `programEntrypointTyped`.
        pub inline fn catchToU64(err: Error) u64 {
            inline for (@typeInfo(E).@"enum".fields) |f| {
                if (err == @field(ErrSet, f.name)) {
                    return shared.customError(f.value);
                }
            }
            return shared.errorToU64(@errorCast(err));
        }
    };
}
