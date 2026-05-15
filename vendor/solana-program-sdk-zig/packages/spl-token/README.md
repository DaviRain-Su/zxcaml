# spl-token (Zig)

Status: ✅ **v0.3** — instruction builders + on-chain CPI helpers
for the fungible-token, authority, multisig, legacy+modern
initializers, native-SOL sync, utility/return-data helpers, custom
error-code parity, and p-token-style batch surface. The classic SPL
Token subset is validated against the real on-chain SPL Token program
inside Mollusk (see `program-test/tests/spl_token.rs`); the batch
helper is covered by Zig wire/staging tests because the bundled
classic token fixture currently rejects discriminator `255`.

Zig client for the [SPL Token](https://github.com/solana-program/token)
program.

## Overview

This package plays the same role for Zig that crates like
`pinocchio-token` play for Rust CPI users: it gives you a compact,
no-allocation way to invoke SPL Token instructions from on-chain code.

Unlike the Pinocchio helper, this package is intentionally dual-target:

- **on-chain**: CPI helpers (`spl_token.cpi.transfer(...)`)
- **off-chain**: instruction builders (`spl_token.instruction.transfer(...)`)
  returning `sol.cpi.Instruction` byte buffers ready to embed in a
  host-built transaction
- **inspection / decoding**: zero-copy state views, return-data
  decoders, UI-amount helpers, checked `COption` authority/native-reserve
  accessors over `solana_codec`, and classic `TokenError` parity helpers

Works against both **classic SPL Token** (`TokenkegQ…`) and
**Token-2022** (`TokenzQd…`) for the fungible subset — the CPI
wrappers take the token program account from the caller, so the
same call site works for either by just passing the right program.

For the current real-cluster Batch findings, see:

- [`../../scripts/devnet-batch-proof/README.md`](../../scripts/devnet-batch-proof/README.md)
- [`../../scripts/devnet-batch-proof/COST_ANALYSIS.md`](../../scripts/devnet-batch-proof/COST_ANALYSIS.md)

## Examples

### Basic transfer and checked transfer

```zig
const sol = @import("solana_program_sdk");
const spl_token = @import("spl_token");

try spl_token.cpi.transfer(
    a.token_program.toCpiInfo(),
    a.source.toCpiInfo(),
    a.destination.toCpiInfo(),
    a.authority.toCpiInfo(),
    100,
);

try spl_token.cpi.transferChecked(
    a.token_program.toCpiInfo(),
    a.source.toCpiInfo(),
    a.mint.toCpiInfo(),
    a.destination.toCpiInfo(),
    a.authority.toCpiInfo(),
    100, /* amount */
    6,   /* decimals */
);
```

### Initializer matrix

```zig
// Legacy initializers (Rent sysvar still explicit):
try spl_token.cpi.initializeMint(
    a.token_program.toCpiInfo(),
    a.mint.toCpiInfo(),
    a.rent_sysvar.toCpiInfo(),
    9,
    a.mint_authority.key(),
    a.freeze_authority.key(),
);

try spl_token.cpi.initializeAccount(
    a.token_program.toCpiInfo(),
    a.token_account.toCpiInfo(),
    a.mint.toCpiInfo(),
    a.owner.toCpiInfo(),
    a.rent_sysvar.toCpiInfo(),
);

try spl_token.cpi.initializeMultisig(
    a.token_program.toCpiInfo(),
    a.multisig.toCpiInfo(),
    a.rent_sysvar.toCpiInfo(),
    signer_infos,
    2,
);

// Modern variants (owner/authority in ix-data, no Rent sysvar):
try spl_token.cpi.initializeAccount2(
    a.token_program.toCpiInfo(),
    a.token_account.toCpiInfo(),
    a.mint.toCpiInfo(),
    a.rent_sysvar.toCpiInfo(),
    a.owner.key(),
);

try spl_token.cpi.initializeAccount3(
    a.token_program.toCpiInfo(),
    a.token_account.toCpiInfo(),
    a.mint.toCpiInfo(),
    a.owner.key(),
);

try spl_token.cpi.initializeMint2(
    a.token_program.toCpiInfo(),
    a.mint.toCpiInfo(),
    9,
    a.mint_authority.key(),
    a.freeze_authority.key(),
);

try spl_token.cpi.initializeMultisig2(
    a.token_program.toCpiInfo(),
    a.multisig.toCpiInfo(),
    signer_infos,
    2,
);
```

### Multisig and signed-authority flows

```zig
// Single-PDA fast path:
try spl_token.cpi.transferSignedSingle(
    a.token_program.toCpiInfo(),
    a.source.toCpiInfo(),
    a.destination.toCpiInfo(),
    a.authority.toCpiInfo(),
    100,
    .{ "vault", &bump_seed },
);

// Explicit multisig signer accounts:
try spl_token.cpi.approveCheckedMultisig(
    a.token_program.toCpiInfo(),
    a.source.toCpiInfo(),
    a.mint.toCpiInfo(),
    a.delegate.toCpiInfo(),
    a.multisig_authority.toCpiInfo(),
    signer_infos,
    500,
    6,
);
```

### Batch and prepared batch

```zig
var child_runtime_accounts: spl_token.cpi.batchChildRuntimeAccountsArray(
    spl_token.instruction.transfer_checked_spec,
    2,
) = .{
    source.toCpiInfo(), mint.toCpiInfo(), destination.toCpiInfo(), authority.toCpiInfo(),
    source.toCpiInfo(), mint.toCpiInfo(), destination.toCpiInfo(), authority.toCpiInfo(),
};
var invoke_accounts: spl_token.cpi.batchInvokeAccountsArray(
    spl_token.instruction.transfer_checked_spec,
    2,
) = undefined;
var batch_metas: spl_token.instruction.batchMetasArray(
    spl_token.instruction.transfer_checked_spec,
    2,
) = undefined;
var batch_data: spl_token.instruction.batchDataArray(
    spl_token.instruction.transfer_checked_spec,
    2,
) = undefined;

// High-level / ergonomic path: caller passes logical child entries plus
// the flattened child runtime accounts.
try spl_token.cpi.batch(
    a.token_program.toCpiInfo(),
    &entries,
    child_runtime_accounts[0..],
    invoke_accounts[0..],
    batch_metas[0..],
    batch_data[0..],
);

// Lower-overhead path: caller already owns the fully prepared invoke slice
// with the token program appended last.
invoke_accounts = .{
    source.toCpiInfo(), mint.toCpiInfo(), destination.toCpiInfo(), authority.toCpiInfo(),
    source.toCpiInfo(), mint.toCpiInfo(), destination.toCpiInfo(), authority.toCpiInfo(),
    a.token_program.toCpiInfo(),
};
try spl_token.cpi.batchPrepared(
    a.token_program.toCpiInfo(),
    &entries,
    invoke_accounts[0..],
    batch_metas[0..],
    batch_data[0..],
);
```

Current positioning:

- `batch*` = ergonomic, caller-friendly default
- `batchPrepared*` = lower-overhead path when the caller already has the
  exact flattened runtime-account layout and wants to skip SDK-side staging

### Utility return-data flows

```zig
try spl_token.cpi.getAccountDataSize(a.token_program.toCpiInfo(), a.mint.toCpiInfo());
var return_buf: [64]u8 = undefined;
const returned = sol.cpi.getReturnData(return_buf[0..]) orelse return error.InvalidInstructionData;
const account_size = try spl_token.return_data.parseGetAccountDataSizeReturn(returned);

try spl_token.cpi.amountToUiAmount(a.token_program.toCpiInfo(), a.mint.toCpiInfo(), 1_230_000);
const ui_returned = sol.cpi.getReturnData(return_buf[0..]) orelse return error.InvalidInstructionData;
const ui_amount = try spl_token.return_data.parseAmountToUiAmountReturn(ui_returned);

var ui_amount_ix_buf: [32]u8 = undefined;
try spl_token.cpi.uiAmountToAmount(
    a.token_program.toCpiInfo(),
    a.mint.toCpiInfo(),
    "1.23",
    ui_amount_ix_buf[0..],
);
const raw_returned = sol.cpi.getReturnData(return_buf[0..]) orelse return error.InvalidInstructionData;
const raw_amount = try spl_token.return_data.parseUiAmountToAmountReturn(raw_returned);
```

### Error decode and local helpers

```zig
// Decode classic SPL Token custom errors.
const token_err = try spl_token.parseTokenError(17);
const token_err_msg = spl_token.tokenErrorToStr(token_err);

// Local zero-allocation UI-amount formatting/parsing.
var ui_buf: [spl_token.ui_amount.MAX_FORMATTED_UI_AMOUNT_LEN]u8 = undefined;
const ui = try spl_token.ui_amount.amountToUiAmountStringTrimmed(1_230_000, 6, ui_buf[0..]);
const parsed_amount = try spl_token.ui_amount.tryUiAmountIntoAmount(ui, 6);

// Zero-copy state views / fast-path key extraction.
const mint = try spl_token.Mint.fromBytes(mint_account.data());
const balance = (try spl_token.Account.fromBytes(token_account.data())).amount;
const owner = spl_token.unpackAccountOwnerUnchecked(token_account.data());
const mint_key = spl_token.unpackAccountMintUnchecked(token_account.data());
```

### Off-chain instruction building

```zig
var metas: [3]sol.cpi.AccountMeta = undefined;
var data: [9]u8 = undefined;
const ix = spl_token.instruction.transfer(
    &source_pk,
    &dest_pk,
    &authority_pk,
    100,
    &metas,
    &data,
);
// `ix` is a `sol.cpi.Instruction` — serialise into a transaction.
```

## Module guide

- `spl_token.cpi` — on-chain CPI wrappers, including signed and
  multisig variants
- `spl_token.instruction` — off-chain / generic instruction builders
- `spl_token.state` — zero-copy `Mint`, `Account`, and `Multisig`
  layouts plus GenericTokenAccount-style fast-path helpers
- `spl_token.return_data` — decoders for utility instructions that
  answer via `sol_get_return_data`
- `spl_token.ui_amount` — local zero-allocation formatting / parsing
  for UI amount strings
- `spl_token.token_error` — classic SPL Token custom-error parity

## Scope (v0.3)

Instructions:

- `transfer` (3) / `transferChecked` (12)
- `approve` (4) / `approveChecked` (13)
- `revoke` (5)
- `setAuthority` (6)
- `mintTo` (7) / `mintToChecked` (14)
- `burn` (8) / `burnChecked` (15)
- `closeAccount` (9)
- `freezeAccount` (10) / `thawAccount` (11)
- legacy initializers:
  - `initializeMint` (0)
  - `initializeAccount` (1)
  - `initializeMultisig` (2)
- `syncNative` (17)
- `initializeAccount2` (16)
- `initializeMint2` (20) / `initializeAccount3` (18)
- `initializeMultisig2` (19)
  (modern "2"/"3" variants — no Rent sysvar, owner/freeze authority
  passed in instruction data)
- `getAccountDataSize` (21)
- `initializeImmutableOwner` (22)
- `amountToUiAmount` (23)
- `uiAmountToAmount` (24)
  (`getAccountDataSize`, `amountToUiAmount`, and `uiAmountToAmount`
  return their answers via `sol.cpi.getReturnData(...)` after CPI;
  decode them with `spl_token.return_data.*` helpers)
- local zero-allocation UI amount helpers via `spl_token.ui_amount.*`
  for formatting / parsing amounts without CPI
- `batch` (255)
  (p-token / Pinocchio-style concatenated child-instruction envelope;
  available as both `spl_token.instruction.batch(...)` and
  `spl_token.cpi.batch(...)`, plus lower-level `spl_token.cpi.batchPrepared(...)`
  / `batchPreparedSigned(...)` / `batchPreparedSignedSingle(...)` fast paths when
  the caller already controls the flattened runtime-account slice)

Authority-based operations include single-authority and explicit
multisig builders/CPI variants where the SPL Token program supports
multisig signing.

The package keeps the low-level account/data contract explicit: every
instruction documents its canonical account order, and every builder or
wrapper stays close to the upstream SPL Token interface instead of
hiding protocol details behind a large abstraction layer.

State (zero-copy `extern struct`):

- `Mint` — 82 bytes, `mint_authority` + `supply` + `decimals` +
  `is_initialized` + `freeze_authority`
- `Account` — 165 bytes, `mint` + `owner` + `amount` + `delegate` +
  `state` + `is_native` + `delegated_amount` + `close_authority`
- `Multisig` — 355 bytes, `m`, `n`, `is_initialized` + up to 11 signer keys
- `AccountState` enum (Uninitialized / Initialized / Frozen)
- `ACCOUNT_MINT_OFFSET` / `ACCOUNT_OWNER_OFFSET` fast-path offsets
- `validAccountData(...)`, `unpackAccountMintUnchecked(...)`,
  `unpackAccountOwnerUnchecked(...)` for GenericTokenAccount-style
  mint/owner inspection without full parsing
- `MIN_SIGNERS` / `MAX_SIGNERS` parity constants
- `isValidSignerIndex(...)` parity helper
- `NATIVE_MINT` constant + `isNativeMint(...)` helper for wrapped SOL flows
- `checkProgramAccount(...)` parity helper for the classic Token program ID
- `TokenError`, `TokenErrorSet`, `parseTokenError(...)`, and
  `tokenErrorToStr(...)` for classic SPL Token custom-error parity

## Not yet covered

Token-2022 extension instructions. Add when there's a concrete
consumer — these are mechanically the same patterns as above (single
comptime instruction-data builder + CPI wrapper).

## Documentation / style notes

The public surface is documented in a deliberately instruction-by-
instruction style:

- each builder documents the exact account order it encodes
- each CPI wrapper keeps runtime-account ordering explicit
- state helpers call out exact byte lengths and field offsets
- return-data and error helpers mirror the classic SPL Token interface
  naming where practical

That keeps the package close to both the upstream Token interface and
Pinocchio's "one helper per instruction" philosophy while still feeling
native in Zig.

## Notes

- The builders are **allocation-free**: every function takes a
  caller-supplied scratch buffer for the `AccountMeta` array and
  the instruction-data bytes, so the resulting `Instruction` can
  outlive the call without involving an allocator.
- For Batch specifically, prefer `batch*` when ergonomics matter and
  `batchPrepared*` when the caller already has the exact prepared invoke
  account slice. Current devnet proofs show `batchPrepared*` consistently
  saves local tens-of-CU staging cost versus `batch*`, but the larger net
  Batch penalty appears to come from token-program-side Batch internals, not
  primarily from this Zig wrapper layer.
- Use `*Checked` variants whenever the caller knows the decimals —
  it eliminates an entire class of "wrong-mint" bugs and only costs
  a single extra byte over the wire + a tiny CU bump.
- The state structs use `align(1)` on every multi-byte field so the
  byte layout matches the canonical Rust `Pack` encoding without
  trailing padding. The host-side tests assert critical offsets at
  comptime — any silent regression trips at build time, not at run
  time.
