const shared = @import("shared.zig");
const std = shared.std;

// =============================================================================
// Unaligned typed reads — zero-cost deserialization helpers
// =============================================================================

/// Read a value of type `T` from `bytes` at `offset`, treating the
/// source as unaligned. Compiles to a single `ldxdw`/`ldxw`/etc.
/// instruction — identical BPF to the raw pointer-cast pattern.
///
/// **Bounds**: requires `bytes.len >= offset + @sizeOf(T)`. The check
/// is a runtime branch; if `offset` is comptime and `bytes.len` has a
/// known lower bound (e.g. the caller did `if (data.len < N) return …;`)
/// LLVM eliminates it.
///
/// Replaces the verbose:
/// ```zig
/// const amount: u64 = @as(*align(1) const u64, @ptrCast(data[1..9])).*;
/// ```
/// with:
/// ```zig
/// const amount = sol.instruction.readUnaligned(u64, data, 1);
/// ```
///
/// `T` must be a pointer-bitcast-safe type (primitive, `extern struct`
/// with `align(1)`, fixed-size array, packed struct). Verified at
/// comptime via `@sizeOf(T)`.
pub inline fn readUnaligned(comptime T: type, bytes: []const u8, comptime offset: usize) T {
    return @as(*align(1) const T, @ptrCast(bytes[offset..][0..@sizeOf(T)])).*;
}

/// Same as `readUnaligned` but takes a `[*]const u8` raw pointer.
/// Useful when you have a pointer into a larger buffer and want to
/// avoid forming a slice first.
pub inline fn readUnalignedPtr(comptime T: type, ptr: [*]const u8) T {
    return @as(*align(1) const T, @ptrCast(ptr)).*;
}

/// Bounds-checked `readUnaligned`. Returns `null` if `bytes` is too
/// short to contain a `T` starting at `offset`. Combines the two
/// always-paired statements:
/// ```zig
/// if (data.len < 9) return error.InvalidInstructionData;
/// const amount = readUnaligned(u64, data, 1);
/// ```
/// into:
/// ```zig
/// const amount = tryReadUnaligned(u64, data, 1)
///     orelse return error.InvalidInstructionData;
/// ```
///
/// Compiles to the same `ldxdw` + bounds-check as the explicit form —
/// LLVM merges the comptime-known length compare with any prior guard
/// in the caller.
pub inline fn tryReadUnaligned(comptime T: type, bytes: []const u8, comptime offset: usize) ?T {
    const end = offset + @sizeOf(T);
    if (bytes.len < end) return null;
    return @as(*align(1) const T, @ptrCast(bytes[offset..][0..@sizeOf(T)])).*;
}

/// Read the first byte(s) of `bytes` as a tag (enum) value.
/// Returns `null` if `bytes` is empty or the value doesn't correspond
/// to any variant of `Tag`. Replaces the boilerplate:
/// ```zig
/// if (data.len < 1) return error.InvalidInstructionData;
/// const tag: Ix = @enumFromInt(data[0]);  // UB if out of range!
/// ```
/// with:
/// ```zig
/// const tag = parseTag(Ix, data) orelse return error.InvalidInstructionData;
/// ```
///
/// `Tag` must be an `enum` with an integer tag type. The
/// discriminator is read from offset 0 as a comptime-sized unaligned
/// load. The validity check is an unrolled comptime switch over the
/// declared variants — no runtime table lookup.
pub inline fn parseTag(comptime Tag: type, bytes: []const u8) ?Tag {
    const info = @typeInfo(Tag);
    if (info != .@"enum") {
        @compileError("parseTag requires an enum type (got " ++ @typeName(Tag) ++ ")");
    }
    const TagInt = info.@"enum".tag_type;
    const raw = tryReadUnaligned(TagInt, bytes, 0) orelse return null;
    // Comptime-unrolled validity check against each declared variant.
    inline for (info.@"enum".fields) |field| {
        if (raw == field.value) return @enumFromInt(raw);
    }
    return null;
}

/// Faster `parseTag` variant for **exhaustive** enums whose variant
/// values span a dense `0..N-1` range. Skips the
/// `std.meta.intToEnum` bounds check (which compiles to a `switch`
/// over all variants). Caller must guarantee the source byte is
/// already in range — typically the case when the program's wire
/// protocol uses `@enumFromInt` directly anyway.
///
/// In benchmarks this saves 2-4 CU per dispatch on programs with
/// 3-4 ix variants vs. `parseTag`.
pub inline fn parseTagUnchecked(comptime Tag: type, bytes: []const u8) ?Tag {
    const info = @typeInfo(Tag);
    if (info != .@"enum") {
        @compileError("parseTagUnchecked requires an enum type");
    }
    const TagInt = info.@"enum".tag_type;
    const raw = tryReadUnaligned(TagInt, bytes, 0) orelse return null;
    return @enumFromInt(raw);
}

/// Typed reader over a `[]const u8` instruction-data buffer.
///
/// Wraps a slice and exposes typed field accessors at comptime-known
/// offsets. The discriminator byte (or u32) is treated as field 0;
/// remaining fields follow contiguously. All accessors are inline and
/// fold to single unaligned loads — identical BPF to hand-written
/// pointer casts.
///
/// Layout `Fields` must be an `extern struct` (so offsets are
/// deterministic at comptime). Field order matches the on-wire byte
/// order.
///
/// Example:
/// ```zig
/// const VaultDepositArgs = extern struct {
///     tag: u8,
///     amount: u64 align(1),
/// };
/// const args = sol.instruction.IxDataReader(VaultDepositArgs).bind(data)
///     orelse return error.InvalidInstructionData;
/// const amount = args.get(.amount); // single ldxdw, offset 1
/// ```
///
/// The `bind` constructor returns `null` if the slice is too short;
/// `bindUnchecked` skips the length check (caller asserts via prior
/// `data.len < N` guard, which LLVM then folds into a no-op).
pub fn IxDataReader(comptime Fields: type) type {
    comptime {
        const info = @typeInfo(Fields);
        if (info != .@"struct" or info.@"struct".layout != .@"extern") {
            @compileError("IxDataReader requires an extern struct (got " ++
                @typeName(Fields) ++ ")");
        }
    }

    return struct {
        const Self = @This();
        const size = @sizeOf(Fields);

        ptr: *align(1) const Fields,

        /// Bind a slice. Returns `null` if too short.
        pub inline fn bind(bytes: []const u8) ?Self {
            if (bytes.len < size) return null;
            return .{ .ptr = @ptrCast(bytes.ptr) };
        }

        /// Bind a slice without bounds check. Caller must have
        /// already verified `bytes.len >= @sizeOf(Fields)`.
        pub inline fn bindUnchecked(bytes: []const u8) Self {
            return .{ .ptr = @ptrCast(bytes.ptr) };
        }

        /// Read a single field by name. Comptime field-name → comptime
        /// offset → single unaligned load.
        pub inline fn get(self: Self, comptime field: std.meta.FieldEnum(Fields)) @FieldType(Fields, @tagName(field)) {
            return @field(self.ptr.*, @tagName(field));
        }

        /// Return a pointer to the whole struct. Useful when you want
        /// to pass the parsed args around as a single value.
        pub inline fn all(self: Self) *align(1) const Fields {
            return self.ptr;
        }
    };
}
