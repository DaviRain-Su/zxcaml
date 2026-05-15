# spl-ata (Zig)

Status: ✅ **v0.1** — released.

Zig client for the [SPL Associated Token Account](https://github.com/solana-program/associated-token-account)
program. Dual-target (on-chain CPI + off-chain ix builder), mirroring
the Rust [`spl-associated-token-account`](https://docs.rs/spl-associated-token-account)
crate.

## API

```zig
const spl_ata = @import("spl_ata");

// PDA derivation for classic SPL Token or Token-2022:
const ata = spl_ata.findAddress(&wallet, &mint, &token_program_id);

// On-chain: create the ATA via CPI
try spl_ata.cpi.createIdempotent(
    payer,
    ata_account,
    wallet,
    mint,
    sp,
    tp,
    ata_program,
);

// PDA payer / wallet fast path:
const bump_seed = [_]u8{bump};
try spl_ata.cpi.createIdempotentSignedSingle(
    payer,
    ata_account,
    wallet,
    mint,
    sp,
    tp,
    ata_program,
    .{ "payer", &bump_seed },
);

// Off-chain: build the ix bytes
var scratch: spl_ata.instruction.Scratch(spl_ata.instruction.create_idempotent_spec) = undefined;
const ix = spl_ata.instruction.createIdempotent(
    &payer_pubkey,
    &wallet_pubkey,
    &mint_pubkey,
    &sol.system_program_id,
    &token_program_id,
    &scratch,
);

// Low-CU path when the ATA address is already known:
const ix_fast = spl_ata.instruction.createIdempotentForAddress(
    &payer_pubkey,
    &ata_pubkey,
    &wallet_pubkey,
    &mint_pubkey,
    &sol.system_program_id,
    &token_program_id,
    &scratch,
);
```

## Implemented scope

- ATA PDA derivation for both classic SPL Token and Token-2022.
- `create` / `createIdempotent` / `recoverNested` instruction builders, plus
  `*ForAddress` variants that accept precomputed ATA addresses.
- On-chain CPI wrappers for ATA creation and nested-account recovery.
- PDA-signed ATA CPI helpers via `*Signed` and `*SignedSingle` variants.
- Real Mollusk integration coverage via `program-test/tests/spl_ata.rs`.
- Rust parity fixtures against `spl-associated-token-account-interface = 2.0.0`.
