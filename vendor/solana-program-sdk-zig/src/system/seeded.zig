const shared = @import("shared.zig");
const cpi = shared.cpi;
const Pubkey = shared.Pubkey;
const CpiAccountInfo = shared.CpiAccountInfo;
const ProgramResult = shared.ProgramResult;
const MAX_SEED_LEN = shared.MAX_SEED_LEN;
const DISCRIMINANT_BYTES = shared.DISCRIMINANT_BYTES;
const U64_BYTES = shared.U64_BYTES;
const PUBKEY_BYTES = shared.PUBKEY_BYTES;
const SystemInstruction = shared.SystemInstruction;
const fixedIxData = shared.fixedIxData;
const StackIxDataWriter = shared.StackIxDataWriter;
const variableSeedIxCapacity = shared.variableSeedIxCapacity;

/// Create account with seed.
///
/// The System Program encodes `base` into instruction data; there is no
/// separate base account meta for this instruction, so the CPI wrapper
/// only needs the funding account, destination account, and System
/// Program account.
pub fn createAccountWithSeed(
    from: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    base: *const Pubkey,
    seed: []const u8,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
) ProgramResult {
    if (seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + PUBKEY_BYTES + U64_BYTES + U64_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.CreateAccountWithSeed);
    ix_data.writePubkey(base);
    ix_data.writeSeed(seed);
    ix_data.writeU64(lamports);
    ix_data.writeU64(space);
    ix_data.writePubkey(owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(from.key()),
        cpi.AccountMeta.writable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    // We construct both `account_metas` and the accounts slice inline,
    // so the bounds check in `cpi.invoke` is provably-true at compile
    // time — skip it.
    try cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ from, to, system_program });
}

/// PDA-signed variant of `createAccountWithSeed`.
pub fn createAccountWithSeedSigned(
    from: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    base: *const Pubkey,
    seed: []const u8,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
    signers: []const cpi.Signer,
) ProgramResult {
    if (seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + PUBKEY_BYTES + U64_BYTES + U64_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.CreateAccountWithSeed);
    ix_data.writePubkey(base);
    ix_data.writeSeed(seed);
    ix_data.writeU64(lamports);
    ix_data.writeU64(space);
    ix_data.writePubkey(owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(from.key()),
        cpi.AccountMeta.writable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeSignedRaw(&ix, &[_]CpiAccountInfo{ from, to, system_program }, signers);
}

/// Single-PDA fast path for `createAccountWithSeedSigned`.
pub inline fn createAccountWithSeedSignedSingle(
    from: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    base: *const Pubkey,
    seed: []const u8,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
    signer_seeds: anytype,
) ProgramResult {
    if (seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + PUBKEY_BYTES + U64_BYTES + U64_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.CreateAccountWithSeed);
    ix_data.writePubkey(base);
    ix_data.writeSeed(seed);
    ix_data.writeU64(lamports);
    ix_data.writeU64(space);
    ix_data.writePubkey(owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.signerWritable(from.key()),
        cpi.AccountMeta.writable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeSignedSingle(&ix, &[_]CpiAccountInfo{ from, to, system_program }, signer_seeds);
}

/// Assign a derived account to a new owner using `(base, seed, owner)`.
pub fn assignWithSeed(
    account: CpiAccountInfo,
    base: CpiAccountInfo,
    system_program: CpiAccountInfo,
    seed: []const u8,
    owner: *const Pubkey,
) ProgramResult {
    if (seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + PUBKEY_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.AssignWithSeed);
    ix_data.writePubkey(base.key());
    ix_data.writeSeed(seed);
    ix_data.writePubkey(owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.writable(account.key()),
        cpi.AccountMeta.signer(base.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ account, base, system_program });
}

/// PDA-signed variant of `assignWithSeed` for derived `base` authorities.
pub fn assignWithSeedSigned(
    account: CpiAccountInfo,
    base: CpiAccountInfo,
    system_program: CpiAccountInfo,
    seed: []const u8,
    owner: *const Pubkey,
    signers: []const cpi.Signer,
) ProgramResult {
    if (seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + PUBKEY_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.AssignWithSeed);
    ix_data.writePubkey(base.key());
    ix_data.writeSeed(seed);
    ix_data.writePubkey(owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.writable(account.key()),
        cpi.AccountMeta.signer(base.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeSignedRaw(&ix, &[_]CpiAccountInfo{ account, base, system_program }, signers);
}

/// Single-PDA fast path for `assignWithSeedSigned`.
pub inline fn assignWithSeedSignedSingle(
    account: CpiAccountInfo,
    base: CpiAccountInfo,
    system_program: CpiAccountInfo,
    seed: []const u8,
    owner: *const Pubkey,
    signer_seeds: anytype,
) ProgramResult {
    if (seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + PUBKEY_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.AssignWithSeed);
    ix_data.writePubkey(base.key());
    ix_data.writeSeed(seed);
    ix_data.writePubkey(owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.writable(account.key()),
        cpi.AccountMeta.signer(base.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeSignedSingle(&ix, &[_]CpiAccountInfo{ account, base, system_program }, signer_seeds);
}

/// Allocate space for a derived account using `(base, seed, owner)`.
pub fn allocateWithSeed(
    account: CpiAccountInfo,
    base: CpiAccountInfo,
    system_program: CpiAccountInfo,
    seed: []const u8,
    space: u64,
    owner: *const Pubkey,
) ProgramResult {
    if (seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + PUBKEY_BYTES + U64_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.AllocateWithSeed);
    ix_data.writePubkey(base.key());
    ix_data.writeSeed(seed);
    ix_data.writeU64(space);
    ix_data.writePubkey(owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.writable(account.key()),
        cpi.AccountMeta.signer(base.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ account, base, system_program });
}

/// PDA-signed variant of `allocateWithSeed` for derived `base` authorities.
pub fn allocateWithSeedSigned(
    account: CpiAccountInfo,
    base: CpiAccountInfo,
    system_program: CpiAccountInfo,
    seed: []const u8,
    space: u64,
    owner: *const Pubkey,
    signers: []const cpi.Signer,
) ProgramResult {
    if (seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + PUBKEY_BYTES + U64_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.AllocateWithSeed);
    ix_data.writePubkey(base.key());
    ix_data.writeSeed(seed);
    ix_data.writeU64(space);
    ix_data.writePubkey(owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.writable(account.key()),
        cpi.AccountMeta.signer(base.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeSignedRaw(&ix, &[_]CpiAccountInfo{ account, base, system_program }, signers);
}

/// Single-PDA fast path for `allocateWithSeedSigned`.
pub inline fn allocateWithSeedSignedSingle(
    account: CpiAccountInfo,
    base: CpiAccountInfo,
    system_program: CpiAccountInfo,
    seed: []const u8,
    space: u64,
    owner: *const Pubkey,
    signer_seeds: anytype,
) ProgramResult {
    if (seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + PUBKEY_BYTES + U64_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.AllocateWithSeed);
    ix_data.writePubkey(base.key());
    ix_data.writeSeed(seed);
    ix_data.writeU64(space);
    ix_data.writePubkey(owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.writable(account.key()),
        cpi.AccountMeta.signer(base.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeSignedSingle(&ix, &[_]CpiAccountInfo{ account, base, system_program }, signer_seeds);
}

/// Transfer lamports from a derived system account.
pub fn transferWithSeed(
    from: CpiAccountInfo,
    base: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    from_seed: []const u8,
    from_owner: *const Pubkey,
    lamports: u64,
) ProgramResult {
    if (from_seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + U64_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.TransferWithSeed);
    ix_data.writeU64(lamports);
    ix_data.writeSeed(from_seed);
    ix_data.writePubkey(from_owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.writable(from.key()),
        cpi.AccountMeta.signer(base.key()),
        cpi.AccountMeta.writable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeRaw(&ix, &[_]CpiAccountInfo{ from, base, to, system_program });
}

/// PDA-signed variant of `transferWithSeed` for derived `base` authorities.
pub fn transferWithSeedSigned(
    from: CpiAccountInfo,
    base: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    from_seed: []const u8,
    from_owner: *const Pubkey,
    lamports: u64,
    signers: []const cpi.Signer,
) ProgramResult {
    if (from_seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + U64_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.TransferWithSeed);
    ix_data.writeU64(lamports);
    ix_data.writeSeed(from_seed);
    ix_data.writePubkey(from_owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.writable(from.key()),
        cpi.AccountMeta.signer(base.key()),
        cpi.AccountMeta.writable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeSignedRaw(&ix, &[_]CpiAccountInfo{ from, base, to, system_program }, signers);
}

/// Single-PDA fast path for `transferWithSeedSigned`.
pub inline fn transferWithSeedSignedSingle(
    from: CpiAccountInfo,
    base: CpiAccountInfo,
    to: CpiAccountInfo,
    system_program: CpiAccountInfo,
    from_seed: []const u8,
    from_owner: *const Pubkey,
    lamports: u64,
    signer_seeds: anytype,
) ProgramResult {
    if (from_seed.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;

    var ix_data = StackIxDataWriter(variableSeedIxCapacity(
        DISCRIMINANT_BYTES + U64_BYTES + U64_BYTES + PUBKEY_BYTES,
    )).init();
    ix_data.writeDiscriminant(SystemInstruction.TransferWithSeed);
    ix_data.writeU64(lamports);
    ix_data.writeSeed(from_seed);
    ix_data.writePubkey(from_owner);

    const account_metas = [_]cpi.AccountMeta{
        cpi.AccountMeta.writable(from.key()),
        cpi.AccountMeta.signer(base.key()),
        cpi.AccountMeta.writable(to.key()),
    };

    const ix = cpi.Instruction.fromCpiAccount(
        system_program,
        &account_metas,
        ix_data.written(),
    );

    try cpi.invokeSignedSingle(&ix, &[_]CpiAccountInfo{ from, base, to, system_program }, signer_seeds);
}
