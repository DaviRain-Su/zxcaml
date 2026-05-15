const shared = @import("shared.zig");
const std = shared.std;
const CpiAccountInfo = shared.CpiAccountInfo;
const Pubkey = shared.Pubkey;

/// Account metadata for CPI instructions.
///
/// Field order matches the Solana C ABI `SolAccountMeta`:
/// ```c
/// typedef struct {
///   SolPubkey *pubkey;
///   bool       is_writable;
///   bool       is_signer;
/// } SolAccountMeta;
/// ```
///
/// We use `u8` (not Zig `bool`) for the two flag fields:
///   - The C ABI specifies `bool` as a single byte but does not bound
///     non-zero values to exactly `1`. The runtime may copy these bytes
///     verbatim when re-marshalling for CPI.
///   - Zig `bool` is UB for any value other than `0` or `1`, so reading
///     a 0xFF here would be UB the moment we coerced it back to `bool`.
///
/// `@sizeOf(AccountMeta) == 16`: the trailing 6 bytes are alignment
/// padding so a `[N]AccountMeta` array keeps each `pubkey` pointer
/// 8-byte aligned. The C struct has no such padding inside a single
/// element, but its array stride is identical because `bool[2]` is
/// followed by the next struct's pointer (8-byte aligned), so the
/// effective layout on the wire matches.
pub const AccountMeta = extern struct {
    /// Public key of the account
    pubkey: *const Pubkey,
    /// Is this account writable (0 = false, non-zero = true)
    is_writable: u8,
    /// Is this account a signer (0 = false, non-zero = true)
    is_signer: u8,

    /// Convenience constructor. Prefer this over the struct literal
    /// when you already have Zig `bool`s in hand.
    pub inline fn init(key: *const Pubkey, is_writable: bool, is_signer: bool) AccountMeta {
        return .{
            .pubkey = key,
            .is_writable = @intFromBool(is_writable),
            .is_signer = @intFromBool(is_signer),
        };
    }

    /// Read-only, non-signer. Typical for sysvars / read-only program
    /// accounts passed to a CPI.
    pub inline fn readonly(key: *const Pubkey) AccountMeta {
        return .{ .pubkey = key, .is_writable = 0, .is_signer = 0 };
    }

    /// Writable but not a signer. Typical for destination accounts in
    /// a transfer.
    pub inline fn writable(key: *const Pubkey) AccountMeta {
        return .{ .pubkey = key, .is_writable = 1, .is_signer = 0 };
    }

    /// Signer but not writable. Rare — usually programs that need a
    /// signing authority but don't mutate it.
    pub inline fn signer(key: *const Pubkey) AccountMeta {
        return .{ .pubkey = key, .is_writable = 0, .is_signer = 1 };
    }

    /// Signer and writable. Typical for the payer in a CreateAccount
    /// CPI, or a token-account authority paying for a transfer.
    pub inline fn signerWritable(key: *const Pubkey) AccountMeta {
        return .{ .pubkey = key, .is_writable = 1, .is_signer = 1 };
    }
};

comptime {
    // Catch regressions in the C ABI layout at build time.
    std.debug.assert(@sizeOf(AccountMeta) == 16);
    std.debug.assert(@offsetOf(AccountMeta, "pubkey") == 0);
    std.debug.assert(@offsetOf(AccountMeta, "is_writable") == 8);
    std.debug.assert(@offsetOf(AccountMeta, "is_signer") == 9);
}

/// CPI Instruction
pub const Instruction = struct {
    /// Program ID to invoke
    program_id: *const Pubkey,
    /// Accounts required by the instruction
    accounts: []const AccountMeta,
    /// Instruction data
    data: []const u8,

    /// Construct an `Instruction` in one call — saves the 4-field
    /// struct literal at every CPI call site:
    ///
    /// ```zig
    /// const ix = sol.cpi.Instruction.init(
    ///     system_program.key(),  // program_id
    ///     &account_metas,        // accounts
    ///     &ix_data,              // raw bytes
    /// );
    /// ```
    ///
    /// `inline` so the resulting BPF is identical to the struct
    /// literal — verified by 0-CU bench regression on vault.
    pub inline fn init(
        program_id: *const Pubkey,
        accounts: []const AccountMeta,
        data: []const u8,
    ) Instruction {
        return .{
            .program_id = program_id,
            .accounts = accounts,
            .data = data,
        };
    }

    /// Same as `init` but takes a `CpiAccountInfo` for the program
    /// account (the common pattern in CPI helpers — the caller passes
    /// the program as a parsed account, and we want its `key()`).
    ///
    /// ```zig
    /// const ix = sol.cpi.Instruction.fromCpiAccount(
    ///     system_program,     // CpiAccountInfo
    ///     &account_metas,
    ///     &ix_data,
    /// );
    /// ```
    pub inline fn fromCpiAccount(
        program: CpiAccountInfo,
        accounts: []const AccountMeta,
        data: []const u8,
    ) Instruction {
        return .{
            .program_id = program.key(),
            .accounts = accounts,
            .data = data,
        };
    }
};
