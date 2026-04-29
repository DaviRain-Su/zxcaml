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
- the arena model is still hidden from user OCaml, but the BPF entry arena is
  now **32 KiB** instead of the old P1/P2 1 KiB buffer;
- `no_alloc` is a conservative Core IR analysis, not a new type-system mode;
- the IDL output is ZxCaml JSON, not Anchor-compatible.

## 1. Account handling

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

`omlz idl <file.ml>` emits a single JSON document describing the discovered
program shape:

- `schema_version`;
- program name and optional program id;
- instructions with names, discriminators, accounts, and arguments;
- user record and variant types;
- structured error constants.

Example:

```sh
zig build
zig-out/bin/omlz idl tests/idl/entrypoint.ml | python3 -m json.tool
```

The schema is intentionally small and ZxCaml-specific. It is useful for smoke
tests and client-code experiments, but it is **not** Anchor-compatible yet.

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
