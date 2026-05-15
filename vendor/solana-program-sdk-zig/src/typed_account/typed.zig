const shared = @import("shared.zig");
const std = @import("std");
const account_mod = shared.account_mod;
const discriminator = shared.discriminator;
const program_error = shared.program_error;
const AccountInfo = shared.AccountInfo;
const ProgramError = shared.ProgramError;
const DISCRIMINATOR_LEN = shared.DISCRIMINATOR_LEN;

/// Pull the `DISCRIMINATOR` decl off `T` if it has one with the right shape.
fn declaredDiscriminator(comptime T: type) ?[DISCRIMINATOR_LEN]u8 {
    if (!@hasDecl(T, "DISCRIMINATOR")) return null;
    const d = @field(T, "DISCRIMINATOR");
    const D = @TypeOf(d);
    if (D == [DISCRIMINATOR_LEN]u8) return d;
    // Allow inferred-length arrays that coerce to [8]u8.
    const info = @typeInfo(D);
    if (info == .array and info.array.len == DISCRIMINATOR_LEN and info.array.child == u8) {
        return d;
    }
    return null;
}

/// Wrap an `AccountInfo` for typed access to data shaped like `T`.
///
/// `T` should be an `extern struct`. If `T` declares a comptime
/// `pub const DISCRIMINATOR: [8]u8` the bind/initialize helpers
/// enforce it.
pub fn TypedAccount(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .@"struct") {
            @compileError("TypedAccount(T): T must be a struct");
        }
        const layout = @typeInfo(T).@"struct".layout;
        if (layout != .@"extern" and layout != .@"packed") {
            @compileError("TypedAccount(T): T must be an `extern struct` or `packed struct`");
        }
    }

    const declared = comptime declaredDiscriminator(T);

    return struct {
        info: AccountInfo,

        const Self = @This();
        pub const Inner = T;
        pub const has_discriminator: bool = declared != null;
        pub const expected_discriminator: ?[DISCRIMINATOR_LEN]u8 = declared;
        pub const size: usize = @sizeOf(T);

        /// Wrap without checking the discriminator. Use when you've
        /// already validated the account type some other way (e.g. you
        /// just created the account in this same instruction).
        pub inline fn bindUnchecked(info: AccountInfo) Self {
            return .{ .info = info };
        }

        /// Wrap an `AccountInfo`, verifying:
        ///   1. `info.dataLen() >= @sizeOf(T)` → `AccountDataTooSmall`
        ///   2. (when `T` declares `DISCRIMINATOR`) the first 8 bytes
        ///      of the account's data equal that constant → otherwise
        ///      `InvalidAccountData`.
        pub fn bind(info: AccountInfo) ProgramError!Self {
            if (info.dataLen() < size) return error.AccountDataTooSmall;
            if (comptime declared) |want| {
                const got_ptr: *align(1) const [DISCRIMINATOR_LEN]u8 =
                    @ptrCast(@alignCast(info.dataPtr()));
                if (!discriminator.eq(got_ptr, &want)) {
                    return error.InvalidAccountData;
                }
            }
            return .{ .info = info };
        }

        /// Read-only pointer to the typed payload.
        pub inline fn read(self: Self) *align(1) const T {
            return @ptrCast(@alignCast(self.info.dataPtr()));
        }

        /// Mutable pointer to the typed payload.
        ///
        /// Caller is responsible for ensuring the account is writable
        /// — typically by going through `parseAccountsWith(.{
        /// .writable = true })` upstream.
        pub inline fn write(self: Self) *align(1) T {
            return @ptrCast(@alignCast(self.info.dataPtr()));
        }

        /// Initialize a freshly-created account: writes `value` into
        /// the account data, then (if `T` declares `DISCRIMINATOR`)
        /// overwrites the first 8 bytes with the canonical
        /// discriminator. This way callers can leave the
        /// `discriminator` field of `value` as `undefined` (or any
        /// value); the canonical bytes are always written.
        pub fn initialize(info: AccountInfo, value: T) ProgramError!Self {
            if (info.dataLen() < size) return error.AccountDataTooSmall;
            const ptr: *align(1) T = @ptrCast(@alignCast(info.dataPtr()));
            // If the type has a declared discriminator: rebuild the
            // value with the disc field stamped, then single-store.
            // Measured at −3 CU vs. "store value, then stamp disc over
            // first 8 bytes" because it eliminates the redundant
            // second 8-byte store. Disassembly shows the rebuild does
            // stage through stack, but the rebuild-and-single-store
            // is still cheaper than write-twice on our 56-byte payload.
            if (comptime declared) |want| {
                var v = value;
                const v_disc: *align(1) [DISCRIMINATOR_LEN]u8 =
                    @ptrCast(@alignCast(&v));
                v_disc.* = want;
                ptr.* = v;
            } else {
                ptr.* = value;
            }
            return .{ .info = info };
        }

        /// `has_one` constraint — Anchor's
        /// `#[account(has_one = authority)]` equivalent.
        ///
        /// Asserts that the `field_name` member of the typed state
        /// equals `expected.key().*`. Returns `error.IncorrectAuthority`
        /// on mismatch (or `error.IncorrectProgramId` if you want a
        /// different variant — see `requireHasOneWith`).
        ///
        /// The field type must be `Pubkey`. Field name is comptime,
        /// so the offset is folded into a single load + 32-byte compare
        /// in BPF code.
        ///
        /// ```zig
        /// const vault = try sol.TypedAccount(VaultState).bind(a.vault);
        /// try vault.requireHasOne("authority", a.authority_signer);
        /// ```
        pub inline fn requireHasOne(
            self: Self,
            comptime field_name: []const u8,
            expected: AccountInfo,
        ) ProgramError!void {
            return self.requireHasOneWith(field_name, expected, error.IncorrectAuthority);
        }

        /// Like `requireHasOne` but lets you pick the error variant.
        /// Useful when "authority mismatch" is not the right semantic
        /// for your domain (e.g. `error.InvalidArgument` for a
        /// `delegate` field).
        pub inline fn requireHasOneWith(
            self: Self,
            comptime field_name: []const u8,
            expected: AccountInfo,
            comptime err: anytype,
        ) @TypeOf(err)!void {
            comptime {
                if (!@hasField(T, field_name)) {
                    @compileError("requireHasOne: type " ++ @typeName(T) ++
                        " has no field named `" ++ field_name ++ "`");
                }
                const FieldT = @TypeOf(@field(@as(T, undefined), field_name));
                if (FieldT != @import("../pubkey/root.zig").Pubkey) {
                    @compileError("requireHasOne: field `" ++ field_name ++
                        "` of " ++ @typeName(T) ++
                        " must be a Pubkey, got " ++ @typeName(FieldT));
                }
            }
            const stored = &@field(self.read().*, field_name);
            const pk = @import("../pubkey/root.zig");
            if (!pk.pubkeyEq(stored, expected.key())) return err;
        }

        /// Close this typed account and refund rent to `destination`.
        ///
        /// Anchor's `#[account(close = destination)]` — drains
        /// lamports, zeroes data, shrinks `data_len` to 0, reassigns
        /// to the system program. After `close()` the wrapped
        /// `AccountInfo` is no longer a valid typed view; drop the
        /// `TypedAccount` value immediately.
        ///
        /// Caller MUST ensure this program owns the account (typically
        /// by checking ownership at bind time or relying on
        /// `expect(.{ .owner = ... })` upstream).
        pub inline fn close(
            self: Self,
            destination: AccountInfo,
        ) ProgramError!void {
            return self.info.close(destination);
        }
    };
}
