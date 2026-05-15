const shared = @import("shared.zig");
const bpf = shared.bpf;
const program_error = shared.program_error;
const CpiAccountInfo = shared.CpiAccountInfo;
const Pubkey = shared.Pubkey;
const ProgramResult = shared.ProgramResult;
const SUCCESS = shared.SUCCESS;
const AccountMeta = @import("instruction.zig").AccountMeta;
const Instruction = @import("instruction.zig").Instruction;
const Seed = @import("seeds.zig").Seed;
const Signer = @import("seeds.zig").Signer;
const seedPack = @import("seeds.zig").seedPack;

/// C-ABI instruction format (SolInstruction in sol/cpi.h)
const SolInstruction = extern struct {
    program_id: *const Pubkey,
    accounts: [*]const AccountMeta,
    account_len: u64,
    data: [*]const u8,
    data_len: u64,
};

/// `Seed` and `Signer` (declared above) are the public C-ABI types;
/// they match the layout of `SolSignerSeedC` / `SolSignerSeedsC` exactly.
/// We use them directly in the syscall signature so callers can pass
/// stack-built `Signer` arrays without a copy.
extern fn sol_invoke_signed_c(
    instruction: *const SolInstruction,
    account_infos: [*]const CpiAccountInfo,
    account_infos_len: u64,
    signers_seeds: [*]const Signer,
    signers_seeds_len: u64,
) callconv(.c) u64;

extern fn sol_set_return_data(data: [*]const u8, len: u64) callconv(.c) void;
extern fn sol_get_return_data(data: [*]u8, len: u64, program_id: *Pubkey) callconv(.c) u64;

// =============================================================================
// CPI Functions
// =============================================================================

/// Maximum number of PDA signers per CPI call.
pub const MAX_CPI_SIGNERS: usize = 8;
/// Maximum seeds per signer (matches Solana runtime limit).
pub const MAX_CPI_SEEDS_PER_SIGNER: usize = 16;

/// Invoke another program (no PDA signers).
///
/// Fast path: skips the seed-staging loop entirely. Use this whenever
/// the called program does not require a PDA signature — saves a few
/// CU vs. `invokeSigned` with an empty `signers_seeds`.
///
/// ZERO-COPY: `CpiAccountInfo` layout matches `SolCpiAccountInfo` C ABI,
/// so accounts can be passed directly without conversion.
pub fn invoke(
    instruction: *const Instruction,
    accounts: []const CpiAccountInfo,
) ProgramResult {
    if (!bpf.is_bpf_program) {
        return error.InvalidArgument;
    }

    if (instruction.accounts.len > accounts.len) {
        return error.NotEnoughAccountKeys;
    }

    return invokeRaw(instruction, accounts);
}

/// Invoke another program with no bounds check.
///
/// Identical to `invoke` but skips the
/// `instruction.accounts.len > accounts.len` runtime check. Callers
/// must ensure they're passing the right slice (every `system.*`
/// helper does this by construction since it builds both arrays
/// inline). Saves ~2-4 CU per CPI.
pub fn invokeRaw(
    instruction: *const Instruction,
    accounts: []const CpiAccountInfo,
) ProgramResult {
    if (!bpf.is_bpf_program) {
        return error.InvalidArgument;
    }

    const sol_instruction = SolInstruction{
        .program_id = instruction.program_id,
        .accounts = instruction.accounts.ptr,
        .account_len = instruction.accounts.len,
        .data = instruction.data.ptr,
        .data_len = instruction.data.len,
    };

    const result = sol_invoke_signed_c(
        &sol_instruction,
        accounts.ptr,
        accounts.len,
        @ptrFromInt(@alignOf(Signer)), // unused when len = 0
        0,
    );

    if (result != SUCCESS) {
        return program_error.u64ToError(result);
    }
}

/// Invoke another program with program derived address signatures.
///
/// `signers_seeds` is a slice of signer entries; each entry is itself a
/// slice of byte slices (the seeds used to derive that signer's PDA).
/// For a single PDA signer with seeds `["vault", bump]`, pass
/// `&.{ &.{ "vault", &.{bump} } }`.
///
/// If you don't need PDA signing, call `invoke` directly — it skips
/// the seed-staging loop.
///
/// ZERO-COPY: `CpiAccountInfo` layout matches `SolCpiAccountInfo` C ABI,
/// so accounts can be passed directly without conversion.
pub fn invokeSigned(
    instruction: *const Instruction,
    accounts: []const CpiAccountInfo,
    signers_seeds: []const []const []const u8,
) ProgramResult {
    if (!bpf.is_bpf_program) {
        return error.InvalidArgument;
    }

    if (signers_seeds.len == 0) {
        return invoke(instruction, accounts);
    }

    if (signers_seeds.len > MAX_CPI_SIGNERS) {
        return program_error.fail(@src(), "cpi:too_many_signers", error.InvalidArgument);
    }

    // Build the C-ABI signer descriptors on the stack.
    //
    // Layout: one Signer per signer, each pointing to a contiguous run
    // of Seed entries inside `seed_pool`. We size the pool exactly to
    // `MAX_CPI_SEEDS_PER_SIGNER * signers_seeds.len` via a per-signer
    // bound check, avoiding the 128-entry over-allocation the previous
    // implementation used.
    var seed_pool: [MAX_CPI_SIGNERS * MAX_CPI_SEEDS_PER_SIGNER]Seed = undefined;
    var signers_buf: [MAX_CPI_SIGNERS]Signer = undefined;

    var pool_cursor: usize = 0;
    for (signers_seeds, 0..) |seeds, i| {
        if (seeds.len > MAX_CPI_SEEDS_PER_SIGNER) {
            return program_error.fail(@src(), "cpi:too_many_seeds", error.InvalidArgument);
        }
        const start = pool_cursor;
        for (seeds) |seed| {
            seed_pool[pool_cursor] = .{
                .addr = @intFromPtr(seed.ptr),
                .len = seed.len,
            };
            pool_cursor += 1;
        }
        signers_buf[i] = .{
            .addr = @intFromPtr(&seed_pool[start]),
            .len = seeds.len,
        };
    }

    return invokeSignedRaw(instruction, accounts, signers_buf[0..signers_seeds.len]);
}

/// Fast-path PDA-signed CPI: takes pre-built `Signer`s in the runtime's
/// C-ABI shape, skipping the seed-pool staging copy `invokeSigned`
/// performs.
///
/// Mirrors Pinocchio's `invoke_signed_unchecked` path. Use this when
/// you already know the seed layout at the call site, which is the
/// common case (`["seed", key, &[bump]]`):
///
/// ```zig
/// const bump_seed = [_]u8{bump};
/// const seeds = [_]sol.cpi.Seed{
///     .from("vault"),
///     .from(authority.key()[0..]),
///     .from(&bump_seed),
/// };
/// const signer = sol.cpi.Signer.from(&seeds);
/// try sol.cpi.invokeSignedRaw(&ix, &accounts, &.{signer});
/// ```
///
/// Saves ~80-120 CU vs. `invokeSigned` on the typical 1-signer,
/// 3-seed PDA case by skipping a 128-entry stack scratch buffer +
/// nested loop with bounds checks. The caller is responsible for
/// keeping the seed slices and the `Seed` array alive across the
/// CPI call — both must outlive `sol_invoke_signed_c`.
pub fn invokeSignedRaw(
    instruction: *const Instruction,
    accounts: []const CpiAccountInfo,
    signers: []const Signer,
) ProgramResult {
    if (!bpf.is_bpf_program) {
        return error.InvalidArgument;
    }

    const sol_instruction = SolInstruction{
        .program_id = instruction.program_id,
        .accounts = instruction.accounts.ptr,
        .account_len = instruction.accounts.len,
        .data = instruction.data.ptr,
        .data_len = instruction.data.len,
    };

    const result = sol_invoke_signed_c(
        &sol_instruction,
        accounts.ptr,
        accounts.len,
        signers.ptr,
        signers.len,
    );

    if (result != SUCCESS) {
        return program_error.u64ToError(result);
    }
}

/// Single-PDA fast path: build one raw `Signer` inline from a comptime
/// tuple of seed values, then forward to `invokeSignedRaw`.
///
/// Typical usage:
///
/// ```zig
/// const bump_seed = [_]u8{bump};
/// try sol.cpi.invokeSignedSingle(&ix, &accounts, .{
///     "vault",
///     authority.key(),
///     &bump_seed,
/// });
/// ```
///
/// This keeps the raw fast path while removing most of the call-site
/// boilerplate (`Seed.from*` per element + `Signer.from`).
pub inline fn invokeSignedSingle(
    instruction: *const Instruction,
    accounts: []const CpiAccountInfo,
    signer_seeds: anytype,
) ProgramResult {
    const seeds = seedPack(signer_seeds);
    const signer = Signer.from(&seeds);
    return invokeSignedRaw(instruction, accounts, &.{signer});
}
