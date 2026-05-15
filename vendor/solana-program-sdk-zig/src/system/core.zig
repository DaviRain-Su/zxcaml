const shared = @import("shared.zig");
const cpi = shared.cpi;
const Pubkey = shared.Pubkey;
const CpiAccountInfo = shared.CpiAccountInfo;
const ProgramResult = shared.ProgramResult;
const SystemInstruction = shared.SystemInstruction;
const TransferPayload = shared.TransferPayload;
const AssignPayload = shared.AssignPayload;
const AllocatePayload = shared.AllocatePayload;
const fixedIxData = shared.fixedIxData;

/// Transfer lamports via System Program CPI.
///
/// Accounts:
/// - `from`: signer, writable — source of lamports
/// - `to`: writable — destination for lamports
/// - `system_program`: read-only — the System Program account, parsed
///   from the program's input.
pub fn transfer(
    from: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    lamports: u64,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.Transfer, TransferPayload, .{ .lamports = lamports });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(from.key()),
        cpi.AccountMeta.writable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);

    // We construct both `account_metas` and the accounts slice inline,
    // so the bounds check in `cpi.invoke` is provably-true at compile
    // time — skip it.
    try cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ from, to, system_program });
}

/// PDA-signed variant of `transfer`.
pub fn transferSigned(
    from: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    lamports: u64,
    signers: []const cpi.Signer,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.Transfer, TransferPayload, .{ .lamports = lamports });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(from.key()),
        cpi.AccountMeta.writable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);
    try cpi.invokeSignedRaw(&ix, &[_]CpiAccountInfo{ from, to, system_program }, signers);
}

/// Single-PDA fast path for `transferSigned`.
pub inline fn transferSignedSingle(
    from: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    lamports: u64,
    signer_seeds: anytype,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.Transfer, TransferPayload, .{ .lamports = lamports });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(from.key()),
        cpi.AccountMeta.writable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);
    try cpi.invokeSignedSingle(&ix, &[_]CpiAccountInfo{ from, to, system_program }, signer_seeds);
}

/// Assign a new owner to an account.
pub fn assign(
    account: CpiAccountInfo,
    system_program: CpiAccountInfo,
    owner: *const Pubkey,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.Assign, AssignPayload, .{ .owner = owner.* });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(account.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);

    try cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ account, system_program });
}

/// PDA-signed variant of `assign`.
pub fn assignSigned(
    account: CpiAccountInfo,
    system_program: CpiAccountInfo,
    owner: *const Pubkey,
    signers: []const cpi.Signer,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.Assign, AssignPayload, .{ .owner = owner.* });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(account.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);
    try cpi.invokeSignedRaw(&ix, &[_]CpiAccountInfo{ account, system_program }, signers);
}

/// Single-PDA fast path for `assignSigned`.
pub inline fn assignSignedSingle(
    account: CpiAccountInfo,
    system_program: CpiAccountInfo,
    owner: *const Pubkey,
    signer_seeds: anytype,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.Assign, AssignPayload, .{ .owner = owner.* });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(account.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);
    try cpi.invokeSignedSingle(&ix, &[_]CpiAccountInfo{ account, system_program }, signer_seeds);
}

/// Allocate space in an account.
pub fn allocate(
    account: CpiAccountInfo,
    system_program: CpiAccountInfo,
    space: u64,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.Allocate, AllocatePayload, .{ .space = space });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(account.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);

    try cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ account, system_program });
}

/// PDA-signed variant of `allocate`.
pub fn allocateSigned(
    account: CpiAccountInfo,
    system_program: CpiAccountInfo,
    space: u64,
    signers: []const cpi.Signer,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.Allocate, AllocatePayload, .{ .space = space });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(account.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);
    try cpi.invokeSignedRaw(&ix, &[_]CpiAccountInfo{ account, system_program }, signers);
}

/// Single-PDA fast path for `allocateSigned`.
pub inline fn allocateSignedSingle(
    account: CpiAccountInfo,
    system_program: CpiAccountInfo,
    space: u64,
    signer_seeds: anytype,
) ProgramResult {
    const ix_data = fixedIxData(SystemInstruction.Allocate, AllocatePayload, .{ .space = space });

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(account.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(system_program, &account_metas, &ix_data);
    try cpi.invokeSignedSingle(&ix, &[_]CpiAccountInfo{ account, system_program }, signer_seeds);
}
