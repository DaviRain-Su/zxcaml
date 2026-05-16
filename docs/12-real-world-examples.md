# 12 — Real-world examples

> **Languages / 语言**: **English** · [简体中文](./zh/12-real-world-examples.md)
>
> **Scope:** zignocchio-inspired Solana examples in `examples/*.ml`, with the
> Milestone E ports called out explicitly.
>
> **See also:** [`examples/README.md`](../examples/README.md),
> [`docs/11-solana-p3.md`](./11-solana-p3.md), and
> [`docs/zignocchio-relationship.md`](./zignocchio-relationship.md).

## 1. Position

Milestone E used `DaviRain-Su/zignocchio` as a read-only reference for a
small real-world Solana corpus. ZxCaml did **not** import zignocchio code;
it mapped the examples into ordinary `.ml` files and then used the existing
Zig runtime/codegen layer for Solana-only effects, matching the posture in
[`docs/zignocchio-relationship.md`](./zignocchio-relationship.md).

The examples are intentionally not a source-to-source translation of Zig into
OCaml. The `.ml` files keep the user-facing control flow, instruction
discriminators, account order, PDA seed shape, and payload layout visible where
that is useful, while runtime-heavy work such as CPI, account-byte mutation,
and mocked SPL Token state lives behind typed externals or codegen-recognized
witness functions. The mapping is visible in the example files, the Mollusk
tests, and the Milestone E commits (`7c59ec6`, `3f0668f`, `fb7f1cc`,
`4206a4e`, `b617117`, `07db019`, `acd2f19`, `38d8a4d`).

## 2. Mapping matrix

| ZxCaml file | zignocchio counterpart | Local verification surface | Main mapping |
|---|---|---|---|
| [`examples/noop.ml`](../examples/noop.ml) | [`examples/noop/lib.zig`](https://github.com/DaviRain-Su/zignocchio/blob/main/examples/noop/lib.zig) | [`tests/noop_test.rs`](../tests/noop_test.rs) | Minimal entrypoint succeeds with no accounts. |
| [`examples/logonly.ml`](../examples/logonly.ml) | [`examples/logonly/lib.zig`](https://github.com/DaviRain-Su/zignocchio/blob/main/examples/logonly/lib.zig) | [`tests/logonly_test.rs`](../tests/logonly_test.rs) | Solana logging through `Syscall.sol_log`, `Syscall.sol_log_64`, and `sol_log_compute_units_`. |
| [`examples/transfer_sol.ml`](../examples/transfer_sol.ml) | [`examples/transfer-sol/lib.zig`](https://github.com/DaviRain-Su/zignocchio/blob/main/examples/transfer-sol/lib.zig) | [`tests/transfer_sol_test.rs`](../tests/transfer_sol_test.rs) | System Program transfer using an eight-byte little-endian amount payload. |
| [`examples/pda_storage.ml`](../examples/pda_storage.ml) | [`examples/pda-storage/lib.zig`](https://github.com/DaviRain-Su/zignocchio/blob/main/examples/pda-storage/lib.zig) | [`tests/pda_storage_test.rs`](../tests/pda_storage_test.rs) | PDA seed `["storage", user]`, discriminator `0` initialize and `1` update, owner/value byte layout. |
| [`examples/counter_v2.ml`](../examples/counter_v2.ml) | [`examples/counter/lib.zig`](https://github.com/DaviRain-Su/zignocchio/blob/main/examples/counter/lib.zig) | [`tests/counter_v2_test.rs`](../tests/counter_v2_test.rs) | PDA-backed counter account with initialize/reset and increment discriminators. |
| [`examples/vault.ml`](../examples/vault.ml) | [`examples/vault/`](https://github.com/DaviRain-Su/zignocchio/tree/main/examples/vault) | [`tests/vault_test.rs`](../tests/vault_test.rs) | Earlier minimal lamport-vault mapping with deposit/withdraw dispatch. |
| [`examples/vault_v2.ml`](../examples/vault_v2.ml) | [`examples/vault/`](https://github.com/DaviRain-Su/zignocchio/tree/main/examples/vault) | [`tests/vault_v2_test.rs`](../tests/vault_v2_test.rs) | Milestone E zignocchio-shaped vault dispatch using canonical PDA signer seeds. |
| [`examples/token_vault.ml`](../examples/token_vault.ml) | [`examples/token-vault/`](https://github.com/DaviRain-Su/zignocchio/tree/main/examples/token-vault) | [`tests/token_vault_test.rs`](../tests/token_vault_test.rs) | Initialize/deposit/withdraw over mocked SPL Token account bytes. |
| [`examples/escrow_full.ml`](../examples/escrow_full.ml) | [`examples/escrow/`](https://github.com/DaviRain-Su/zignocchio/tree/main/examples/escrow) | [`tests/escrow_full_test.rs`](../tests/escrow_full_test.rs) | Lamport escrow make/accept/refund using a preallocated PDA fixture. |

The authoritative list of all examples, including non-zignocchio compiler
fixtures, is [`examples/README.md`](../examples/README.md).

## 3. Per-example notes

### 3.1 `noop`

`examples/noop.ml` is the direct smoke case:

```ocaml
let entrypoint _instruction_data = 0
```

The corresponding test
`tests/noop_test.rs::test_noop_executes_successfully_with_no_accounts`
loads the compiled BPF artifact and asserts that the invocation succeeds with
no accounts. This mirrors the zignocchio no-op example while exercising only
the baseline BPF entry shim documented in
[`docs/06-bpf-target.md`](./06-bpf-target.md).

### 3.2 `logonly`

`examples/logonly.ml` maps zignocchio's log-only program to the ZxCaml syscall
surface:

- `Syscall.sol_log "logonly: hello"` uses the stdlib binding in
  [`stdlib/core.ml`](../stdlib/core.ml).
- `Syscall.sol_log_64 11 22 33 44 55` uses the Solana numeric log binding in
  [`stdlib/core.ml`](../stdlib/core.ml) and `runtime/zig/syscalls.zig`.
- `external log_compute_units : unit -> unit = "sol_log_compute_units_"`
  binds an additional runtime syscall exposed by
  [`runtime/zig/syscalls.zig`](../runtime/zig/syscalls.zig).

`tests/logonly_test.rs` checks for the string log, the hex-form
`sol_log_64` output, and a compute-unit log line. This is slightly broader
than zignocchio's simplest string log, and it documents ZxCaml's current
logging coverage.

### 3.3 `transfer_sol`

`examples/transfer_sol.ml` preserves the zignocchio instruction shape: the
instruction data is exactly one little-endian `u64` amount, and the account
order is source, destination, System Program. The `.ml` helper is intentionally
a type witness:

```ocaml
let transfer_sol from_account to_account system_program instruction_data =
  (* codegen emits the actual guarded System Program CPI *)
  ...
```

The actual guarded CPI path is emitted through
`src/backend/zig_codegen/runtime_imports.zig` and implemented by
`runtime/zig/cpi.zig::zxcaml_transfer_sol_process` (added in commit
`fb7f1cc`). `tests/transfer_sol_test.rs` verifies that the source lamports
decrease and destination lamports increase by the payload amount.

### 3.4 `pda_storage`

`examples/pda_storage.ml` keeps the PDA-facing API compact in OCaml while the
runtime helper handles Solana byte mutation. The test fixture derives the PDA
with seeds `["storage", user]`, uses a canonical bump, and checks the storage
state layout: the owner pubkey lives in bytes `0..32`, and the `u64` value
lives in bytes `32..40` (`tests/pda_storage_test.rs`).

The mapping is intentionally fixture-oriented. zignocchio creates and writes
the PDA account through its SDK, while ZxCaml's Mollusk test preallocates the
program-owned PDA account and checks the same observable state transition.
The codegen hooks for this shape were added with the pda-storage port in
commit `4206a4e`.

### 3.5 `counter_v2`

`examples/counter_v2.ml` maps zignocchio's counter idea to a PDA-backed
ZxCaml account:

- the counter account is derived from `["counter", user.key]`;
- discriminator `2` initializes/resets the counter to zero;
- discriminator `0` increments the stored `u64`;
- unknown discriminators return `1`.

The upstream counter has a slightly wider command surface than this
PDA-backed variant. The tradeoff is explicit in
`examples/counter_v2.ml`: ZxCaml keeps the initialize + increment acceptance
flow that the local Mollusk test proves, while leaving decrement/default
behavior out of this example. `tests/counter_v2_test.rs` verifies initialize,
first increment, and second increment.

### 3.6 `vault` and `vault_v2`

`examples/vault.ml` is the earlier minimal lamport-vault example introduced
before Milestone E (`cd79a21`). It already used zignocchio-inspired
deposit/withdraw dispatch:

- discriminator `0` deposits an eight-byte little-endian amount;
- discriminator `1` withdraws all vault lamports;
- PDA seeds are `["vault", owner.key]`.

`examples/vault_v2.ml` is the Milestone E zignocchio-shaped pass (`07db019`).
It keeps the same two discriminators, but routes through explicit externals
`vault_v2_deposit` and `vault_v2_withdraw`, which codegen lowers to
`runtime/zig/cpi.zig::zxcaml_vault_v2_process`. The v2 runtime helper uses
the canonical bump-255 fixture pattern documented in
`tests/vault_v2_test.rs` so the withdraw path can sign with
`["vault", owner.key, bump]`.

### 3.7 `token_vault`

`examples/token_vault.ml` maps zignocchio's token-vault discriminators:

- `0` = deposit;
- `1` = withdraw;
- `2` = initialize.

The `.ml` file routes all valid discriminators to the external
`token_vault_process`, and codegen lowers that call to
`runtime/zig/cpi.zig::zxcaml_token_vault_process` (commit `acd2f19`).
The test uses mocked SPL Token account data rather than a full Tokenkeg CPI:
mint bytes start at offset `0`, owner bytes at offset `32`, amount at offset
`64`, and initialized state at offset `108` (`tests/token_vault_test.rs` and
`runtime/zig/cpi.zig`). This keeps the example deterministic under Mollusk
while still validating the account layout and token amount movement.

### 3.8 `escrow_full`

`examples/escrow_full.ml` maps zignocchio's lamport escrow:

- `make = 0`;
- `accept = 1`;
- `refund = 2`;
- PDA seeds are `["escrow", maker.key]`;
- escrow state uses discriminator `0xe5`, maker bytes, taker bytes, and an
  amount field (`tests/escrow_full_test.rs`).

The zignocchio source creates the PDA account with System Program CPI. The
ZxCaml Mollusk fixture instead preallocates the canonical bump-255 PDA as a
program-owned account, then `runtime/zig/cpi.zig::zxcaml_escrow_full_process`
mutates lamports and state bytes directly. This is the same mocked-account
tradeoff used by `token_vault`, and it is documented in both
`examples/escrow_full.ml` and `tests/escrow_full_test.rs` (commit `38d8a4d`).

## 4. Stdlib and runtime surface used by the ports

Milestone E did **not** add new pure OCaml definitions to
[`stdlib/core.ml`](../stdlib/core.ml); the relevant Solana-facing stdlib
surface already existed from earlier phases and is consumed by the new
examples. The pieces that matter for these ports are:

| Surface | File | Used by |
|---|---|---|
| `type account` with `key`, `lamports`, `data`, `owner`, signer/writable/executable flags | [`stdlib/core.ml`](../stdlib/core.ml) | every account-aware example |
| `type account_meta`, `type instruction`, `type signer_seeds` | [`stdlib/core.ml`](../stdlib/core.ml) and [`docs/11-solana-p3.md`](./11-solana-p3.md) | CPI-shaped examples and older `simple_cpi`/vault forms |
| `Syscall.sol_log`, `Syscall.sol_log_64`, `Syscall.sol_remaining_compute_units` | [`stdlib/core.ml`](../stdlib/core.ml), [`runtime/zig/syscalls.zig`](../runtime/zig/syscalls.zig) | `logonly`, plus log smoke paths in vault/counter examples |
| `Crypto.sha256`, `Crypto.keccak256`, `Pubkey.zero`, `Pubkey.token_program`, `Pubkey.of_hex` | [`stdlib/core.ml`](../stdlib/core.ml) | PDA/pubkey helpers and crypto-adjacent examples |
| `invoke`, `invoke_signed`, `create_program_address`, `try_find_program_address` | [`stdlib/core.ml`](../stdlib/core.ml), [`docs/11-solana-p3.md`](./11-solana-p3.md) | CPI/PDA surface that the real-world examples align with |
| `String`, `Char`, `Map`, `Set`, expanded `List`/`Option`/`Result` | [`stdlib/core.ml`](../stdlib/core.ml), changelog P5/P7 entries | general OCaml subset expansion used by larger examples |

Milestone E **did** add runtime/codegen recognition for example-specific
externals and witnesses. The important additions are in
[`runtime/zig/cpi.zig`](../runtime/zig/cpi.zig) and
[`src/backend/zig_codegen/runtime_imports.zig`](../src/backend/zig_codegen/runtime_imports.zig):

- `zxcaml_transfer_sol_process` for `transfer_sol` (`fb7f1cc`);
- pda-storage runtime import handling (`4206a4e`);
- `zxcaml_vault_v2_process` for `vault_v2` (`07db019`);
- `zxcaml_token_vault_process` for `token_vault` (`acd2f19`);
- `zxcaml_escrow_full_process` for `escrow_full` (`38d8a4d`);
- `sol_log_compute_units_` syscall exposure for `logonly`
  (`examples/logonly.ml`, `runtime/zig/syscalls.zig`).

## 5. Tradeoffs and known differences

### 5.1 Type witnesses instead of byte-level OCaml

Several examples define helpers such as `read_u8`, `read_u64_le`,
`write_u64_le`, and `set_account_data` whose comments say that codegen emits
the real byte operation. This is deliberate. ZxCaml currently has an OCaml
surface for `bytes`, accounts, and externals, but the BPF byte-mutation work is
owned by the generated Zig/runtime path (`examples/counter_v2.ml`,
`examples/pda_storage.ml`, `runtime/zig/cpi.zig`).

### 5.2 String formatting is lower-level than zignocchio's SDK helpers

zignocchio exposes ergonomic SDK helpers such as message and integer logging.
ZxCaml currently exposes Solana-style primitives: `sol_log_`,
`sol_log_64_`, `sol_log_compute_units_`, and related syscall wrappers
(`stdlib/core.ml`, `runtime/zig/syscalls.zig`). As a result,
`tests/logonly_test.rs` asserts Solana's raw hex-form `sol_log_64` output
rather than a higher-level formatted string.

### 5.3 Syscall coverage is targeted, not SDK-complete

The syscall surface documented in [`docs/11-solana-p3.md`](./11-solana-p3.md)
includes logging, `sol_log_64`, pubkey logging, SHA-256/Keccak, Clock/Rent
sysvars, remaining compute units, return-data helpers, PDA helpers, and CPI
entry points. It is sufficient for the checked-in examples, but it is not a
complete replacement for zignocchio's full SDK.

### 5.4 CPI-heavy tests use mocked or preallocated accounts

`token_vault` mutates mocked SPL Token account bytes instead of invoking the
full Tokenkeg program (`tests/token_vault_test.rs`). `escrow_full` preallocates
the escrow PDA instead of creating it from scratch through System Program CPI
(`tests/escrow_full_test.rs`). `pda_storage` and `vault_v2` use canonical
bump-255 fixture patterns. These choices keep Mollusk tests deterministic and
focused on observable program semantics while avoiding a much larger SDK
surface.

### 5.5 OCaml source remains the user contract

All examples remain ordinary `.ml` files, in line with ADR-001 in
[`docs/09-decisions.md`](./09-decisions.md). The mapping should therefore be
read as "OCaml program plus ZxCaml runtime externals" rather than "Zig SDK
ported line-by-line into OCaml."
