const shared = @import("shared.zig");
const cpi = shared.cpi;
const Pubkey = shared.Pubkey;
const CpiAccountInfo = shared.CpiAccountInfo;
const ProgramResult = shared.ProgramResult;
const create = @import("create.zig");

// Note: there is no System Program `Realloc` instruction. Accounts that
// the program owns can be resized in-place (within
// `MAX_PERMITTED_DATA_INCREASE`) by writing directly to the runtime's
// `data_len` slot — no CPI is required. We intentionally do not expose
// a `system.realloc` wrapper to avoid suggesting otherwise.

/// Rent-exempt-aware account creation helper.
///
/// Computes the rent-exempt minimum balance at runtime via the Rent
/// sysvar and forwards to `createAccount` / `createAccountSigned`.
///
/// `space` is `u64` (not `comptime`) so dynamic sizes work; pass a
/// comptime-known constant to let LLVM fold the surrounding arithmetic.
///
/// Usage (non-PDA new account):
/// ```zig
/// try sol.system.createRentExempt(.{
///     .payer = a.payer,
///     .new_account = a.vault,
///     .system_program = a.system_program,
///     .space = @sizeOf(VaultState),
///     .owner = &MY_PROGRAM_ID,
/// });
/// ```
///
/// Usage (PDA new account — `new_account` must be a PDA):
/// ```zig
/// const bump_seed = [_]u8{bump};
/// try sol.system.createRentExempt(.{
///     .payer = a.payer,
///     .new_account = a.vault,
///     .system_program = a.system_program,
///     .space = @sizeOf(VaultState),
///     .owner = &MY_PROGRAM_ID,
///     .signer_seeds = &.{ &.{ "vault", a.payer.key().*[0..], &bump_seed } },
/// });
/// ```
pub const CreateRentExemptArgs = struct {
    payer: CpiAccountInfo,
    new_account: CpiAccountInfo,
    system_program: CpiAccountInfo,
    space: u64,
    owner: *const Pubkey,
    /// Optional PDA signer seeds. Pass `null` if the new account is a
    /// fresh keypair signed by the user; pass seeds when the new
    /// account is a PDA whose signature must come from this program.
    signer_seeds: ?[]const []const []const u8 = null,
};

pub fn createRentExempt(args: CreateRentExemptArgs) ProgramResult {
    const rent_mod = @import("../rent.zig");
    const rent_data = rent_mod.Rent.get() catch return error.UnsupportedSysvar;
    const lamports = rent_data.getMinimumBalance(args.space);

    if (args.signer_seeds) |seeds| {
        return create.createAccountSigned(
            args.payer,
            args.new_account,
            args.system_program,
            lamports,
            args.space,
            args.owner,
            seeds,
        );
    }

    return create.createAccount(
        args.payer,
        args.new_account,
        args.system_program,
        lamports,
        args.space,
        args.owner,
    );
}

inline fn comptimeRentExemptLamports(comptime space: u64) u64 {
    const rent_mod = @import("../rent.zig");
    return comptime blk: {
        const total: u64 = rent_mod.Rent.account_storage_overhead + space;
        break :blk total * rent_mod.Rent.default_lamports_per_byte_year * 2;
    };
}

/// Comptime rent-exempt account creation with no PDA signers.
///
/// Same comptime rent-folding win as `createRentExemptComptimeRaw` /
/// `createRentExemptComptimeSingle`, but for the common plain-keypair
/// account-creation case.
///
/// ```zig
/// try sol.system.createRentExemptComptime(.{
///     .payer = a.payer,
///     .new_account = a.vault,
///     .system_program = a.system_program,
///     .owner = &MY_PROGRAM_ID,
/// }, @sizeOf(VaultState));
/// ```
pub fn createRentExemptComptime(
    args: struct {
        payer: CpiAccountInfo,
        new_account: CpiAccountInfo,
        system_program: CpiAccountInfo,
        owner: *const Pubkey,
    },
    comptime space: u64,
) ProgramResult {
    return create.createAccount(
        args.payer,
        args.new_account,
        args.system_program,
        comptimeRentExemptLamports(space),
        space,
        args.owner,
    );
}

/// Comptime rent-exempt account creation with pre-built PDA signers.
///
/// `space` is a `comptime` parameter so the rent-exempt minimum
/// balance is computed at build time and baked into the binary as a
/// single u64 immediate — no `sol_get_rent_sysvar` syscall (~85 CU)
/// runs at execution time.
///
/// This assumes the cluster's rent parameters never change from the
/// canonical values (lamports_per_byte_year = 3480,
/// exemption_threshold = 2.0). They've been stable since genesis and
/// changing them would require a feature gate, so for >99.99% of
/// programs this is a free win. If you genuinely need to read live
/// rent params (e.g. you're writing tooling that has to handle
/// future cluster changes), use `createRentExemptRaw` instead.
///
/// ```zig
/// const seeds = [_]sol.cpi.Seed{ .from("vault"), .from(auth_key[0..]), .from(&bump_seed) };
/// const signer = sol.cpi.Signer.from(&seeds);
/// try sol.system.createRentExemptComptimeRaw(
///     .{ .payer = ..., .new_account = ..., .system_program = ..., .owner = &PROGRAM_ID },
///     @sizeOf(VaultState),
///     &.{signer},
/// );
/// ```
pub fn createRentExemptComptimeRaw(
    args: struct {
        payer: CpiAccountInfo,
        new_account: CpiAccountInfo,
        system_program: CpiAccountInfo,
        owner: *const Pubkey,
    },
    comptime space: u64,
    signers: []const cpi.Signer,
) ProgramResult {
    return create.createAccountSignedRaw(
        args.payer,
        args.new_account,
        args.system_program,
        comptimeRentExemptLamports(space),
        space,
        args.owner,
        signers,
    );
}

/// Single-PDA fast path for comptime rent-exempt account creation.
///
/// Same win profile as `createRentExemptComptimeRaw`, but accepts a
/// comptime tuple of seed values for the common 1-signer PDA case.
///
/// ```zig
/// const bump_seed = [_]u8{bump};
/// try sol.system.createRentExemptComptimeSingle(.{
///     .payer = a.payer,
///     .new_account = a.vault,
///     .system_program = a.system_program,
///     .owner = &MY_PROGRAM_ID,
/// }, @sizeOf(VaultState), .{ "vault", authority.key(), &bump_seed });
/// ```
pub inline fn createRentExemptComptimeSingle(
    args: struct {
        payer: CpiAccountInfo,
        new_account: CpiAccountInfo,
        system_program: CpiAccountInfo,
        owner: *const Pubkey,
    },
    comptime space: u64,
    signer_seeds: anytype,
) ProgramResult {
    return create.createAccountSignedSingle(
        args.payer,
        args.new_account,
        args.system_program,
        comptimeRentExemptLamports(space),
        space,
        args.owner,
        signer_seeds,
    );
}

/// Fast-path rent-exempt account creation with pre-built PDA signers.
///
/// Saves ~80-120 CU vs. `createRentExempt` on the common PDA case
/// by handing the runtime the C-ABI signer descriptors directly,
/// skipping the `[]const []const []const u8` → C-ABI staging copy.
///
/// ```zig
/// const bump_seed = [_]u8{bump};
/// const seeds = [_]sol.cpi.Seed{
///     .from("vault"),
///     .from(auth_key[0..]),
///     .from(&bump_seed),
/// };
/// const signer = sol.cpi.Signer.from(&seeds);
/// try sol.system.createRentExemptRaw(.{
///     .payer = a.payer,
///     .new_account = a.vault,
///     .system_program = a.system_program,
///     .space = @sizeOf(VaultState),
///     .owner = &MY_PROGRAM_ID,
/// }, &.{signer});
/// ```
pub fn createRentExemptRaw(
    args: CreateRentExemptArgs,
    signers: []const cpi.Signer,
) ProgramResult {
    const rent_mod = @import("../rent.zig");
    const rent_data = rent_mod.Rent.get() catch return error.UnsupportedSysvar;
    const lamports = rent_data.getMinimumBalance(args.space);

    return create.createAccountSignedRaw(
        args.payer,
        args.new_account,
        args.system_program,
        lamports,
        args.space,
        args.owner,
        signers,
    );
}
