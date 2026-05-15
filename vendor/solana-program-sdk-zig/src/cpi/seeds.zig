const shared = @import("shared.zig");
const pubkey = shared.pubkey;
const Pubkey = shared.Pubkey;

/// A single PDA seed in the runtime's C-ABI shape: `{ ptr_as_u64, len }`.
///
/// Matches `SolSignerSeedC` exactly so an array of `Seed`s can be passed
/// straight to `sol_invoke_signed_c` without a staging copy. Mirrors
/// Pinocchio's `pinocchio::cpi::Seed`.
///
/// Construct with `Seed.from(slice)`. Cheaper than the
/// `[]const []const u8` shape used by `invokeSigned` because the user
/// builds the C-ABI layout inline — the CPI wrapper just hands the
/// pointer to the syscall.
pub const Seed = extern struct {
    addr: u64,
    len: u64,

    pub inline fn from(slice: []const u8) Seed {
        return .{ .addr = @intFromPtr(slice.ptr), .len = slice.len };
    }

    /// Generic seed coercion for common PDA seed shapes:
    ///
    /// - `[]const u8` / string slices
    /// - `*const Pubkey`
    /// - `*const u8`
    /// - `*const [N]u8` / `*const [N:0]u8`
    ///
    /// This is mainly used by `seedPack` / `invokeSignedSingle` /
    /// the higher-level System Program single-signer helpers so callers
    /// can write `. { "vault", authority.key(), &bump_seed }` and still
    /// hit the raw C-ABI signer fast path.
    pub inline fn fromAny(value: anytype) Seed {
        const T = @TypeOf(value);
        if (T == []const u8 or T == []u8) return from(value);
        if (T == *const Pubkey or T == *Pubkey) return fromPubkey(value);
        if (T == *const u8 or T == *u8) return fromByte(value);

        switch (@typeInfo(T)) {
            .pointer => |ptr| {
                if (ptr.size == .one and @typeInfo(ptr.child) == .array) {
                    const arr = @typeInfo(ptr.child).array;
                    if (arr.child == u8) return from(value.*[0..]);
                }
            },
            .array => |arr| {
                if (arr.child == u8) return from(value[0..]);
            },
            else => {},
        }

        @compileError("Unsupported PDA seed type for cpi.Seed.fromAny: " ++ @typeName(T));
    }

    /// Create a `Seed` over a `*const u8`, treating it as a 1-byte
    /// slice. Useful for the bump-seed pattern when you have a
    /// `u8` field on a stack variable (a stored bump on an account):
    ///
    /// ```zig
    /// const seeds = [_]Seed{
    ///     .from("vault"),
    ///     .fromPubkey(authority.key()),
    ///     .fromByte(&state.bump),     // 1-byte bump from account
    /// };
    /// ```
    ///
    /// Equivalent to wrapping the byte in a 1-element array
    /// (`const arr = [_]u8{b}; .from(&arr)`) but lets the caller
    /// reuse existing storage — useful when the bump already lives
    /// in account data or a stored struct.
    pub inline fn fromByte(byte: *const u8) Seed {
        return .{ .addr = @intFromPtr(byte), .len = 1 };
    }

    /// Create a `Seed` over a `*const Pubkey`, treating it as a
    /// 32-byte slice. Equivalent to `from(pk[0..])` but reads
    /// more naturally:
    ///
    /// ```zig
    /// .fromPubkey(authority.key())
    /// // vs.
    /// .from(authority.key()[0..])
    /// ```
    pub inline fn fromPubkey(pk: *const Pubkey) Seed {
        return .{ .addr = @intFromPtr(pk), .len = pubkey.PUBKEY_BYTES };
    }
};

/// A single PDA signer in the runtime's C-ABI shape:
/// `{ &Seed[N], seed_count }`. Mirrors `SolSignerSeedsC`.
///
/// Construct from a `[]const Seed` (typically a stack array of `Seed`s
/// the caller built inline). The `Signer` itself is also stack-friendly.
pub const Signer = extern struct {
    addr: u64,
    len: u64,

    pub inline fn from(seeds: []const Seed) Signer {
        return .{ .addr = @intFromPtr(seeds.ptr), .len = seeds.len };
    }
};

/// Build a stack `[_]Seed` array from a comptime tuple of common seed
/// value shapes. Typical usage:
///
/// ```zig
/// const bump_seed = [_]u8{bump};
/// const seeds = sol.cpi.seedPack(.{ "vault", authority.key(), &bump_seed });
/// const signer = sol.cpi.Signer.from(&seeds);
/// ```
///
/// The array length is folded at compile time, and each element is
/// coerced through `Seed.fromAny`.
pub inline fn seedPack(values: anytype) [@typeInfo(@TypeOf(values)).@"struct".fields.len]Seed {
    const len = @typeInfo(@TypeOf(values)).@"struct".fields.len;
    var out: [len]Seed = undefined;
    inline for (values, 0..) |value, i| {
        out[i] = Seed.fromAny(value);
    }
    return out;
}
