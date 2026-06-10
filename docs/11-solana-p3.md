# 11 — Solana P3 guide

> **Languages / 语言**: **English** · [简体中文](./zh/11-solana-p3.md)

## TL;DR

P3 makes ZxCaml Solana-aware. Programs can receive typed account views, call
selected Solana syscalls, build cross-program invocations (CPI), encode an
SPL-Token transfer, ask `omlz` to prove a source file is allocation-free, and
emit a small JSON IDL with `omlz idl`.

The implementation remains runtime-light:

- account data is parsed in the Zig runtime as zero-copy views over the BPF
  input buffer;
- syscalls and CPI use the Solana BPF ABI directly;
- the current Solana runtime is **SDK-backed** over the vendored
  `solana-program-sdk-zig` subtree and uses the SDK-style entrypoint;
- the arena model is still hidden from user OCaml; native builds keep a
  **32 KiB** entry arena, while BPF builds use a **3 KiB** stack-bounded entry
  arena to avoid SBF's 4 KiB stack-frame ceiling;
- `no_alloc` is a conservative Core IR analysis, not a new type-system mode;
- the current IDL output is Anchor-compatible JSON, expanded after the original
  P3 smoke schema by sealed P5 work;
- local deploy/invoke validation now goes through the Surfpool harness on
  `127.0.0.1:8899` / `127.0.0.1:8900`, not a manually managed legacy validator
  session.

## 1. Account handling

### Entrypoint expectations

Every program declares a function named exactly `entrypoint`. The accepted
shapes are positional `account` parameters followed by the instruction-data
`bytes` parameter — e.g. `let entrypoint (authority : account)
(guarded : account) (instruction_data : bytes) = ...` — and the return value
must be an `int` status (`0` for success; the entry ABI maps it to the
program's exit status). Common mistakes are caught with `DX2-REGION`
diagnostics before codegen: a missing/renamed `entrypoint`, a non-function
binding, or a trailing `bool` expression where the status int belongs
(`tests/ui/entrypoint_*.ml` pin all three).

The P3 runtime parses the Solana BPF loader input into account views before user
code runs. The parser understands the loader serialization shape used by real
BPF invocations:

```text
u64 num_accounts
for each account:
  u8  dup_info
  u8  is_signer
  u8  is_writable
  u8  executable
  u32 padding
  u64 original_data_len
  [32]u8 key
  u64 lamports
  u64 data_len
  u8[data_len] data, 8-byte aligned
  [32]u8 owner
  u64 rent_epoch
```

The user-visible built-in record is:

```ocaml
type account = {
  key : bytes;
  lamports : int;
  data : bytes;
  owner : bytes;
  is_signer : bool;
  is_writable : bool;
  executable : bool;
}
```

The runtime stores `key`, `data`, and `owner` as views into the serialized input
buffer rather than copying those bytes. That keeps account access predictable on
BPF and matches the arena-only memory model.

### Account guard helper pattern

Prefer the `Account` stdlib helpers when an entrypoint validates account metas
before mutation:

```ocaml
let error_missing_signer = 1
let error_missing_writable = 2
let error_wrong_owner = 3

let entrypoint authority guarded_account instruction_data =
  let _ = instruction_data in
  if not (Account.is_signer authority) then error_missing_signer
  else if not (Account.is_writable guarded_account) then error_missing_writable
  else if not (Account.is_owned_by guarded_account (Account.key authority)) then error_wrong_owner
  else 0
```

This keeps the account order explicit (`authority`, then `guarded_account`),
returns stable custom codes instead of panicking, and lets `omlz idl` derive
`signer` / `writable` metadata from the same guard expressions. Misuse such as
`Account.is_signer 1`, `Account.data_len bytes`, or `Account.has_key account 1`
is rejected by the OCaml frontend before lowering.

### Example

`examples/log_accounts.ml` is the account/syscall smoke program. The current
backend lowers this example through the BPF account parser and logs the real
account key and lamports from the harness-provided accounts.

Run the full account logging harness locally with:

```sh
SOLANA_BPF=1 \
ZXCAML_SOLANA_SRC=examples/log_accounts.ml \
ZXCAML_SOLANA_INVOKE_ACCOUNTS=1 \
ZXCAML_EXPECT_ACCOUNT_LOGS=1 \
tests/solana/hello/invoke.sh
```

## 2. Syscalls

Solana BPF syscalls are resolved by 32-bit MurmurHash3 dispatch addresses
(seed `0`). P3 binds the syscalls needed by the account, CPI, SPL-Token, and
diagnostic examples.

| OCaml-facing helper | Runtime syscall | Hash |
|---|---|---:|
| `Syscall.sol_log` | `sol_log_` | `0x20755f21` |
| `Syscall.sol_log_64` | `sol_log_64_` | `0x5c2a3178` |
| `Syscall.sol_log_pubkey` | `sol_log_pubkey` | `0x7ef08fcb` |
| `Syscall.sol_sha256` | `sol_sha256` | `0x11f49d42` |
| `Syscall.sol_keccak256` | `sol_keccak256` | `0xd763ada3` |
| `Syscall.sol_get_clock_sysvar` | `sol_get_clock_sysvar` | `0x85532d94` |
| `Syscall.sol_get_rent_sysvar` | `sol_get_rent_sysvar` | `0x9aca9a41` |
| `Syscall.sol_remaining_compute_units` | `sol_remaining_compute_units` | `0x4e3bc231` |

`examples/syscall_test.ml` exercises hashing, Clock sysvar reads, remaining
compute-unit reads, string logging, and `sol_log_64`.

## 3. CPI patterns

P3 adds built-in CPI-shaped records:

```ocaml
type account_meta = {
  pubkey : bytes;
  is_writable : bool;
  is_signer : bool;
}

type instruction = {
  program_id : bytes;
  accounts : account_meta array;
  data : bytes;
}
```

The runtime side mirrors Solana's C ABI:

- `SolInstruction` points to a program id, account metas, and instruction data;
- `SolAccountMeta` records the public key plus signer/writable flags;
- `SolSignerSeeds` / `SolSignerSeedsC` describe PDA signer seeds;
- `sol_invoke_signed_c` performs the invocation;
- PDA helpers bind `sol_create_program_address` and
  `sol_try_find_program_address`;
- return data helpers bind `sol_set_return_data` and `sol_get_return_data`.

`invoke` is for ordinary CPI. `invoke_signed` adds signer seeds for PDA signing.
Use writable account metas only when the callee must write the account, and mark
only the authority accounts as signers.

### AccountMeta constructors

Instead of writing raw `account_meta` record literals (where the
`is_writable` / `is_signer` flags are easy to swap), use the `AccountMeta`
constructors that name the flag combination directly:

```ocaml
AccountMeta.writable p          (* { pubkey = p; is_writable = true;  is_signer = false } *)
AccountMeta.signer p            (* { pubkey = p; is_writable = false; is_signer = true  } *)
AccountMeta.writable_signer p   (* { pubkey = p; is_writable = true;  is_signer = true  } *)
AccountMeta.readonly p          (* { pubkey = p; is_writable = false; is_signer = false } *)
AccountMeta.of_account a        (* forwards a's own key + writable/signer privileges *)
```

`AccountMeta.of_account` covers the most common flow — forwarding one of the
entrypoint's accounts into a CPI with its existing privileges. The
constructors lower to plain record construction, so they behave identically
to handwritten literals everywhere (interpreter, native, BPF, `--no-alloc`
accounting). `examples/account_meta_helpers.ml` exercises all five. When a helper
function takes an `account_meta` parameter, annotate it explicitly —
`let meta_flags (m : account_meta) = ...` — and the annotation types the
helper correctly (wire 1.7 carries the annotation marker; see
`examples/account_meta_annotated.ml`). For *unannotated* params the
`pubkey`-read veto remains: reading `m.pubkey` — the field unique to
`account_meta` — keeps the parameter-typing heuristic from classifying
the param as an entrypoint `account` (see
`examples/account_meta_param.ml`).

### PDA derivation

`Pda.create_program_address seeds program_id` derives a program address from
signer seeds (`Bytes.of_string` segments built via `Array.of_list`). On BPF
the real `sol_create_program_address` syscall runs; on the interpreter and
native targets the helper returns `program_id` unchanged — the same
deterministic off-chain stub `stdlib/core.ml` defines for plain OCaml runs,
mirroring how `Cpi.invoke` stubs to `0` off-chain. The bare
`create_program_address` name remains available; `Pda.` is the discoverable
namespace. `Pda.try_find_program_address seeds program_id` returns
`Some (address, bump)` (`(bytes * int) option`): on BPF the real bump search
runs via `sol_try_find_program_address`, while the deterministic off-chain
stub yields `Some (program_id, 0)`.
`examples/pda_derive.ml` exercises both helpers end-to-end.

`examples/simple_cpi.ml` demonstrates the system-program transfer shape. The
local harness path is:

```sh
SOLANA_BPF=1 \
ZXCAML_SOLANA_SRC=examples/simple_cpi.ml \
ZXCAML_SOLANA_SIMPLE_CPI=1 \
tests/solana/hello/invoke.sh
```

## 4. SPL-Token transfer

P3 includes a small SPL-Token helper layer for the legacy Tokenkeg program:

```text
TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA
```

The transfer payload is encoded as discriminator `3` followed by the amount as
little-endian `u64`:

```text
03 amount_le_u64
```

The expected account metas are:

| Account | Writable | Signer |
|---|---:|---:|
| source token account | yes | no |
| destination token account | yes | no |
| authority | no | yes |

`examples/spl_token_transfer.ml` is the P3 SPL-Token acceptance example. The
harness creates Tokenkeg accounts, mints tokens, invokes the compiled ZxCaml
program, and checks the post-transfer balances:

```sh
SOLANA_BPF=1 \
ZXCAML_SOLANA_SRC=examples/spl_token_transfer.ml \
ZXCAML_SOLANA_SPL_TOKEN=1 \
tests/solana/hello/invoke.sh
```

## 5. `no_alloc`

`omlz check --no-alloc <file.ml>` runs a conservative Core IR pass that rejects
programs whose lowered Core graph contains arena allocation sites. The analysis
currently reports failures for allocation-bearing Core nodes such as tuple
construction, record construction, constructors with payloads, and lambda
captures.

Example:

```sh
zig build
zig-out/bin/omlz check --no-alloc examples/arith_wrap.ml
```

Expected output:

```text
no_alloc: PASS
```

On failure, the CLI prints the function name and the Core IR node kind that made
the proof fail. The pass is intentionally conservative: "cannot prove no
allocation" is reported as failure rather than silently accepting the program.

## 6. IDL emission

`omlz idl <file.ml>` emits an Anchor-compatible JSON document describing the
discovered program shape:

- program name and optional program id;
- Anchor 0.30+ instruction entries with names, discriminators, accounts, and
  arguments;
- user record and variant types;
- events, errors, and constants where the source exposes them.

Example:

```sh
zig build
zig-out/bin/omlz idl tests/idl/entrypoint.ml | python3 -m json.tool
```

The original P3 schema was intentionally small and ZxCaml-specific. The
current sealed P5/P8 toolchain emits Anchor-compatible IDL JSON while keeping
the source of truth in the `.ml` program.

R13 account helper calls also feed the IDL account metadata pass. For example,
`Account.is_signer authority` marks `authority` as `signer: true`, and
`Account.is_writable guarded_account` marks `guarded_account` as
`writable: true`; those account parameters are emitted under instruction
`accounts` instead of ordinary `args`. Prefer naming stable custom-code
constants with an `error_` prefix (for example `error_missing_signer = 1`) so
`omlz idl` can expose them in the top-level `errors` array. R14 also derives a
human-readable `msg` from that suffix (`"Missing signer"` for
`error_missing_signer`) while preserving the source-level `name` and numeric
`code`.

## 7. CI coverage

CI continues to run the cross-platform matrix on macOS and Ubuntu:

```sh
./init.sh
zig build
zig build test
```

P3 adds explicit smoke checks for:

- `omlz check --no-alloc examples/arith_wrap.ml`;
- `omlz idl tests/idl/entrypoint.ml` piped through `python3 -m json.tool`;
- the full examples `omlz check` corpus, including the P3 examples.

BPF deploy/invoke acceptance remains available through the local harnesses
above and is opt-in in CI via `SOLANA_BPF=1`.
