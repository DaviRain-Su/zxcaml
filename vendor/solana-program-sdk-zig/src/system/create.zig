const shared = @import("shared.zig");
const cpi = shared.cpi;
const Pubkey = shared.Pubkey;
const CpiAccountInfo = shared.CpiAccountInfo;
const ProgramResult = shared.ProgramResult;
const SystemInstruction = shared.SystemInstruction;
const CreateAccountPayload = shared.CreateAccountPayload;
const fixedIxData = shared.fixedIxData;

/// Create a new account via System Program CPI.
///
/// Accounts:
/// - `from`: signer, writable — pays for the new account
/// - `to`: signer, writable — the account being created
/// - `system_program`: read-only — the System Program account, parsed
///   from the program's input. Required so the syscall can resolve
///   `instruction.program_id` against a known account.
pub fn createAccount(
    from: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.CreateAccount, CreateAccountPayload, .{ .lamports = lamports, .space = space, .owner = owner.* });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(from.key()),
        cpi.AccountMeta.signerWritable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);

    // We construct both `account_metas` and the accounts slice inline,
    // so the bounds check in `cpi.invoke` is provably-true at compile
    // time — skip it.
    try cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ from, to, system_program });
}

/// Create a new account with PDA signing.
///
/// `signers_seeds` follows `cpi.invokeSigned`'s shape: one entry per PDA
/// signer, each containing the seed slices used to derive that PDA.
///
/// For maximum CU performance — typical 1-signer, 3-seed PDA case —
/// use `createAccountSignedRaw` instead and build the `Signer` array
/// at the call site. This wrapper has to stage the seeds through a
/// 128-entry scratch buffer.
pub fn createAccountSigned(
    from: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
    signers_seeds: []const []const []const u8,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.CreateAccount, CreateAccountPayload, .{ .lamports = lamports, .space = space, .owner = owner.* });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(from.key()),
        cpi.AccountMeta.signerWritable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);

    try cpi.invokeSigned(&ix, &[_]CpiAccountInfo{ from, to, system_program }, signers_seeds);
}

/// Fast-path PDA-signed CreateAccount: takes pre-built `Signer`s in
/// the runtime's C-ABI shape, skipping the seed-staging copy that
/// `createAccountSigned` performs.
///
/// ```zig
/// const bump_seed = [_]u8{bump};
/// const seeds = [_]sol.cpi.Seed{
///     .from("vault"),
///     .from(auth_key[0..]),
///     .from(&bump_seed),
/// };
/// const signer = sol.cpi.Signer.from(&seeds);
/// try sol.system.createAccountSignedRaw(
///     payer.toCpiInfo(),
///     vault.toCpiInfo(),
///     system_program.toCpiInfo(),
///     lamports,
///     space,
///     &MY_PROGRAM_ID,
///     &.{signer},
/// );
/// ```
pub fn createAccountSignedRaw(
    from: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
    signers: []const cpi.Signer,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.CreateAccount, CreateAccountPayload, .{ .lamports = lamports, .space = space, .owner = owner.* });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(from.key()),
        cpi.AccountMeta.signerWritable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);

    try cpi.invokeSignedRaw(
        &ix,
        &[_]CpiAccountInfo{ from, to, system_program },
        signers,
    );
}

/// Single-PDA fast path for CreateAccount. Accepts a comptime tuple of
/// seed values and builds the raw signer descriptors inline, so callers
/// can keep the low-CU path without spelling out `Seed.from*` and
/// `Signer.from` at the call site.
///
/// ```zig
/// const bump_seed = [_]u8{bump};
/// try sol.system.createAccountSignedSingle(
///     payer.toCpiInfo(),
///     vault.toCpiInfo(),
///     system_program.toCpiInfo(),
///     lamports,
///     space,
///     &MY_PROGRAM_ID,
///     .{ "vault", authority.key(), &bump_seed },
/// );
/// ```
pub inline fn createAccountSignedSingle(
    from: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
    signer_seeds: anytype,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.CreateAccount, CreateAccountPayload, .{ .lamports = lamports, .space = space, .owner = owner.* });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(from.key()),
        cpi.AccountMeta.signerWritable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);

    try cpi.invokeSignedSingle(
        &ix,
        &[_]CpiAccountInfo{ from, to, system_program },
        signer_seeds,
    );
}
