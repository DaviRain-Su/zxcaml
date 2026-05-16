# ZxCaml

> **Languages / 语言**: **English** · [简体中文](./docs/zh/README.md)

> An **OCaml dialect** with a **Zig/BPF backend**.
> We do **not** invent a new language. Source files use the standard `.ml`
> extension. We replace the *backend*, not the *frontend*.

---

## TL;DR

```text
.ml source
   │
   ▼
[ ocamlc -bin-annot ]    ◀── upstream OCaml, used as a library, never forked
   │  .cmt (Typedtree)
   ▼
[ zxc-frontend (small OCaml glue) ]
   │  .cir.sexp  (versioned wire format)
   ▼
[ omlz (Zig)  : ANF → Core IR → ArenaStrategy → Lowered IR → Zig codegen ]
   │  .zig
   ▼
[ SOLANA_ZIG (empty/unset/1 or path) ]
              defaults to `solana-zig build-lib`; `SOLANA_ZIG=0` is invalid
   ▼
[ solana-zig build-lib -target sbf-solana -fPIC -fstrip -dynamic ]    (single-step path, ADR-013 defaults to v2)
   │  .so (Solana-loadable ELF)
   ▼
Solana BPF .so
```

- Frontend: **upstream OCaml `compiler-libs`** (no fork, no
  re-implementation). See ADR-009 / ADR-010.
- Compiler host language for everything below the frontend:
  **Zig 0.16**.
- Source language: **OCaml** (subset, growing).
- Primary target: **Solana BPF/SBF** (via `solana-zig -target sbf-solana`).
- Memory model (P3): **arena, fully inferred, hidden from the user**;
  native entry programs use a 32 KiB arena, while BPF entry programs use a
  3 KiB stack-bounded arena to stay under SBF's 4 KiB frame limit.
- Core IR shape: **ANF** (A-Normal Form), typed, layout-tagged.
- CLI binary name: **`omlz`** (OCaml on Zig).
- Build driver: a single **`build.zig`** orchestrates both the
  OCaml frontend bridge and the Zig pipeline (ADR-011).
- P9 Developer Experience docs: [`docs/diagnostics.md`](./docs/diagnostics.md)
  for rustc-style diagnostics, [`docs/lsp.md`](./docs/lsp.md) for
  `omlz-lsp`, [`docs/source-map.md`](./docs/source-map.md) for source maps,
  and [`docs/wire-compat.md`](./docs/wire-compat.md) for current wire `1.5`
  compatibility.

---

## Why this exists

OCaml has an elegant frontend (HM types, ADTs, pattern matching, modules)
and a battle-tested type system. What it lacks is a backend story for
**resource-constrained, deterministic** environments such as Solana BPF,
where the OCaml runtime (GC, boxed floats, exceptions) cannot run.

ZxCaml keeps the OCaml language and reuses its mental model, but routes
the program through a new pipeline that produces flat, GC-free, BPF-ready
code via Zig.

We deliberately **do not** fork an OCaml compiler distribution (upstream
OCaml or OxCaml). Instead, we use upstream `compiler-libs` as a library
for parsing and type-checking, and we own everything from `Typedtree`
onwards. The reasoning is captured in
[`docs/alternatives-considered.md`](./docs/alternatives-considered.md)
and locked in ADR-009 / ADR-010.

---

## Native execution comes for free

Because every ZxCaml program is by construction valid OCaml
(ADR-001), and because `omlz` already requires a working OCaml
toolchain on the developer's machine (ADR-010), the **same `.ml`
file** can be compiled and run two ways:

```
one .ml file
  ├── ocaml / dune  →  native x86_64 / arm64 binary   (local testing, fuzzing, REPL)
  └── omlz          →  Solana BPF .so                 (deployment)
```

This means **ZxCaml does not need a dedicated x86 backend** to give
you native execution. Install `ocaml` (which you already have
installed for `omlz`), or install OxCaml, and run the same file
with `dune exec`. The two paths compute the same result; this is
guaranteed by the determinism invariant (ADR-008).

For the longer discussion of how OxCaml relates to this project —
and why we still don't fork it — see
[`docs/oxcaml-relationship.md`](./docs/oxcaml-relationship.md).

---

## Quickstart

For full install details and troubleshooting, see [Installing](./INSTALLING.md).
From the repository root, build `omlz` and the canonical Solana BPF example:

```sh
./init.sh && zig build && zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```

The command sequence uses the same `init.sh` setup script as CI. Expected
tooling is Zig 0.16.0, OCaml 5.2.x via opam, Rust/Cargo, and
`solana-zig` 0.16.0. For live Solana flows, also ensure Solana CLI,
`surfpool`, and `spl-token` are on `PATH`; Surfpool validation uses
`127.0.0.1:8899` for RPC and `127.0.0.1:8900` for WebSocket. `llvm-objcopy`
is optional: BPF builds still work when source-map embedding is skipped.

Useful validation commands:

```sh
zig build test --summary none
cargo test --manifest-path tests/Cargo.toml
SOLANA_BPF=1 SOLANA_RPC_PORT=8899 tests/solana/hello/invoke.sh
SOLANA_BPF=1 SOLANA_RPC_PORT=8899 tests/solana/cross_flow/run.sh
```

## Status

**P9 Developer Experience is sealed**, and the Solana runtime now uses the
vendored `solana-program-sdk-zig` adapters through the SDK-style entrypoint.
P1-P9 deliver the walking skeleton, subset expansion, Solana runtime
integration, Mollusk test infrastructure, external declarations, Anchor IDL,
functional persistent stdlib, region inference, OCaml subset expansion
(desugars, patterns, strings, expanded stdlib), and source-level compiler
optimizations: constant folding, dead code elimination, self-recursive tail call
optimization, function inlining, and P9 developer-experience surfaces for
diagnostics, LSP, wire compatibility, and source maps. Phase 19+20+21
documentation drift is sealed through `post-fmt-deepnested-baseline`.

Recent hackathon work packages that compiler state into a recordable demo:
a Surfpool localnet deploy/invoke flow, a fairness-oriented Anchor comparison,
bilingual Slidev decks, and a live Cloudflare Pages site at
[`https://zxcaml.pages.dev/`](https://zxcaml.pages.dev/). See the
[`docs/hackathon/` index](./docs/hackathon/README.md) for the storyboard,
scripts, comparison artifacts, and recording checklist.

`omlz` works end-to-end: parse/type-check OCaml with upstream
`compiler-libs` → emit sexp `1.5` → lower through Core IR with constant folding, DCE, inlining, escape
analysis → interpret, build native Zig, build Solana BPF `.so` artifacts,
or emit Anchor-compatible IDL.

MTF-1 also lands `omlz build --target=wasm` as an **experimental generic
freestanding WASM smoke target** for import-free pure logic.

MTF-2 now also lands `omlz build --target=near` as an **experimental NEAR
no-storage adapter MVP** validated with real `near-workspaces` /
`near-sandbox` acceptance. The current NEAR surface is limited to
method-style input/return/log/panic behavior; persistent storage, promises,
caller identity, broad JSON/Borsh profiles, and MTF-3 through MTF-6 remain
explicit future roadmap gates.

### Recent baselines

- `post-fmt3-baseline` sealed the expanded `omlz fmt` corpus at 20 fmt
  goldens.
- `post-fmt-fixes-baseline` sealed the formatter lex-wart fixes for
  polymorphic type variables, labelled/optional arguments, and PPX-local
  spacing.
- `post-fmt-deepnested-baseline` sealed Phase 21's generic `) word` spacing
  rule with the corpus still at 20 fmt goldens.
- Current no-regress floor: `zig build test --summary none` passes,
  `cargo test --manifest-path tests/Cargo.toml` passes across the Rust/Mollusk
  integration suite, and final Surfpool cross-flow validation passes. Future
  floor updates should record both the command and the commit that established
  it.

### Current features

- **CLI commands:** `omlz check <file>`, `omlz check --no-alloc <file>`, `omlz run <file>`, `omlz build --target=native <file> -o <out>`, `omlz build --target=bpf <file> -o <out>`, `omlz build --target=wasm [--keep-zig] <file> [-o <out.wasm>]`, `omlz build --target=near [--keep-zig] <file> -o <out.wasm>`, `omlz idl <file>`, `omlz unmap --map <file.map> --pc <addr>`, and `omlz unmap --so <file.so> --pc <addr>`
- **Formatter:** `omlz fmt` formats `.ml` sources with `--check`, `--write`, `--stdin`, JSON summaries, LSP `textDocument/formatting` / `rangeFormatting`, a 20-golden fmt corpus, and bytewise idempotency; see [`docs/16-omlz-fmt.md`](./docs/16-omlz-fmt.md)
- **Wire format:** version 1.5 (P1 `0.4`; P2 added user ADTs in `0.5`, nested/guarded patterns in `0.6`, and tuples/records in `0.7`; P3 added account/syscall references in `0.8` and CPI types/references in `0.9`; P4/P5 moved the wire through `1.0` for instruction data and external declarations; P8 moved to `1.1` for mutual-recursion groups; P9/DX2 moved to `1.2` for source-location plumbing; R8/R9 moved through typed-parameter/array surfaces; R10 moved to `1.5` for `ref-make` / `ref-get` / `ref-set` while older readers remain compatibility-only)
- **OCaml subset:** let bindings, nested let, let rec, curried functions, function application, arithmetic/comparison operators, if/then/else, user-defined ADTs, nested constructor patterns, guarded match arms, literal constant patterns, or-patterns, alias patterns, tuples, records, field access, functional record update, lists (`[]` / `::`), sequence expressions (`;`), function cases (`function |`), `while` / counted `for` loops, string operations (`^`, length, get, sub), char operations (code, chr), mutable `int` arrays (`Array.make`, `Array.get`, `Array.set`, `Array.length`, `a.(i)`, `a.(i) <- v`), `ref`/`!`/`:=` for `int` and `bool`, and pattern matching over all of those forms
- **Stdlib:** bundled `List` (`length`, `map`, `filter`, `fold_left`, `rev`, `append`, `hd`, `tl`, `nth`, `exists`, `for_all`, `find`, `sort`, `combine`, `split`), `Option` (`is_none`, `is_some`, `value`, `get`, `fold`), `Result` (`is_ok`, `is_error`, `ok`, `error`, `map`, `map_error`, `map_err`, `bind`), `Fun` (`id`, `const`, `flip`), `Map` (`empty`, `singleton`, `add`, `find`, `remove`, `mem`, `size`, `to_list`), `Set` (`empty`, `singleton`, `add`, `mem`, `remove`, `size`, `to_list`, `union`, `inter`), `String` (`length`, `get`, `sub`), `Bytes` (`length`, `get`, `sub`, `create`, `set`, `of_string`, `blit`, `fill`, `iter`, `iteri`, `fold_left`, `equal`, `compare`), `Char` (`code`, `chr`), `Account` guard/read helpers, `Fixed` / `Amount` deterministic six-decimal and bps helpers, `Format` (`int_to_string`, `hex_of_int`), `Crypto` (`sha256`, `keccak256`), and `Pubkey` (`zero`, `token_program`, `of_hex`) modules
- **Memory model:** arena-only with region inference for automatic stack allocation of non-escaping locals; native entry arena is 32 KiB, and BPF entry arena is 3 KiB to keep the loader entrypoint below SBF's 4 KiB stack-frame limit
- **Backends:** tree-walk interpreter, Zig native codegen, experimental generic freestanding WASM module output, and one-step `SOLANA_ZIG` direct `solana-zig build-lib` BPF path
- **Experimental generic WASM:** `omlz build --target=wasm` emits `.wasm`
  artifacts for import-free pure deterministic logic only; canonical acceptance
  uses Node WebAssembly with empty imports, and broader chain adapters remain
  explicitly gated in the multichain roadmap
- **Experimental NEAR no-storage adapter:** `omlz build --target=near`
  emits a `.wasm` contract with method-style export plus NEAR
  `input`/`register_len`/`read_register`/`value_return`/`log_utf8`/`panic_utf8`
  imports only; real acceptance runs through local `near-workspaces` +
  `near-sandbox`, while storage/promise/caller/JSON/Borsh expansion remains
  future-gated
- **Solana runtime:** SDK-backed adapters over the vendored `solana-program-sdk-zig` subtree cover syscalls/crypto/sysvars, CPI/PDA/return-data, SPL/ATA/codecs, account parsing/views, public API imports, and the SDK-style entrypoint
- **Solana accounts:** built-in `account` record values expose key, lamports, data, owner, and signer/writable/executable flags parsed as SDK-compatible zero-copy views; the runtime parser also tracks rent epoch and duplicate-account aliasing
- **Solana syscalls:** bindings for logging, `sol_log_64`, pubkey logging, SHA-256/Keccak/BLAKE3, secp256k1 recovery, Clock/Rent sysvars, and remaining compute units use SDK-backed Zig runtime symbols
- **Solana sysvar readers:** `Sysvar.clock_from_account`, `rent_from_account`, `instructions_header_from_account`, `instruction_at`, `stake_history_latest_from_account`, and `epoch_schedule_from_account` decode Clock, Rent, Instructions, StakeHistory, and EpochSchedule account data; see [`docs/15-sysvars.md`](./docs/15-sysvars.md)
- **Runtime crypto syscalls:** Solana-backed SHA-256, Keccak-256, BLAKE3, and `secp256k1_recover` are exposed through `Crypto`, with digest-writer and signature-recovery examples (`keccak_demo`, `blake3_demo`, `secp_recover_demo`)
- **External declarations:** `external name : type = "zig_symbol"` syntax enables direct FFI to Zig runtime functions with type safety enforced by the frontend
- **CPI and PDA helpers:** built-in `instruction` / `account_meta` records, `invoke`, `invoke_signed`, PDA helpers, and return-data syscalls mirror the Solana C ABI
- **SPL-Token:** helper support and acceptance examples cover the legacy Tokenkeg primitives transfer, init_account, burn, close_account, and revoke; the current SPL primitive examples are `spl_burn`, `spl_close_account`, and `spl_revoke`
- **no_alloc:** `omlz check --no-alloc` runs a conservative Core IR allocation proof and reports the allocation-causing node on failure
- **Static profiling reports:** `omlz check --report=cu,stack <file>` emits a deterministic, opt-in static estimate of compute units (with per-syscall breakdown) and per-function stack depth; see [docs/06-bpf-target.md](./docs/06-bpf-target.md) §7.5
- **OCaml-native tests:** `let%test_unit "name" = expr` and `let%test_prop "name" generator = fun x -> expr` bindings are discovered by `omlz test`, which runs `examples/tests/*.ml` by default, supports `--filter`, `--format=cargo|json`, `--num-cases`, and `--seed`, reports shrunk counterexamples for property failures, and powers LSP CodeLens one-test runs
- **IDL:** `omlz idl <file>` emits Anchor 0.30+ compatible JSON with SHA-256 discriminators, instruction accounts/args, account types, events, errors, and constants; `Account.is_signer` / `Account.is_writable` guard helpers feed signer/writable metadata, and `error_` constants feed the IDL error table with derived `msg` text
- **BPF closures:** hardened first-class closures — closures capturing ADT values, multi-environment captures, and nested closures are lowered without unsupported BPF code-pointer relocations and are covered by Solana closure acceptance tests
- **Solana acceptance:** Surfpool deploy + invoke validation covers canonical hello, closures, account parser/view, CPI/PDA/return-data, SPL/ATA/token, vault/order-book, and combined cross-flow harnesses
- **Region inference:** automatic escape analysis marks non-escaping local values for stack allocation, reducing arena pressure and improving BPF compute efficiency
- **Constant folding:** compile-time evaluation of arithmetic, comparison, string concatenation, boolean conditions, and known-constructor matches in Core IR
- **Dead code elimination:** removes unused let bindings (preserving side-effectful and potentially trapping operations) and unreachable if branches
- **Tail call optimization:** self-recursive tail calls are detected during ANF lowering and emitted as `while (true)` loops in generated Zig, enabling deep recursion (n > 10000) without stack overflow
- **Function inlining:** small single-expression functions (≤3 Core IR nodes) are inlined at call sites with alpha-renaming, enabling further constant folding; supports all types including String, ADT, Tuple, and Record
- **Determinism:** interpreter ≡ Zig native across the current supported examples corpus
- **CI:** GitHub Actions workflow with `macos-latest` + `ubuntu-latest` matrix runs `./init.sh`, `zig build`, `zig build test`, `cargo test` (Mollusk SVM), P3 `no_alloc` and IDL smoke checks, Mollusk tests, and an examples `omlz check` corpus loop
- **Mollusk SVM tests:** 36 Rust integration-test files (47 Rust test cases) in `tests/` using Mollusk SVM v0.12.1 (hello, demo, simple_cpi, counter, vault, external_demo, crypto_demo, hackathon_greet, mutable_state_stress, account_guard, real-world zignocchio ports, and SPL Token primitive coverage). `tests/bpf_test_support.rs` centralizes build/load helpers for these artifacts; the historical ELF post-pass has been removed (see `mission-internal/elf-patch-investigation.md`).
- **Diagnostics:** rustc-style diagnostics are the default, with `--error-format=human|json|oneline` and caret spans over source snippets; UI coverage includes common `Account.*` helper misuse cases
- **LSP:** `omlz-lsp` is installed by `zig build` and provides LSP push diagnostics over stdio JSON-RPC
- **LSP latency observability:** `make lsp-bench` rebuilds and runs `omlz lsp-bench --warmup 3 --rounds 10`, reporting p50/p99 diagnostics latency against the default 350/800 ms thresholds; see [`docs/17-lsp-latency.md`](./docs/17-lsp-latency.md)
- **Source maps:** BPF builds emit deterministic source maps, embed `.zxcaml.srcmap` when `llvm-objcopy` is available, and let `omlz unmap` resolve BPF PCs back to OCaml locations.
  Default is direct `solana-zig`; set `SOLANA_ZIG` to any custom command/path (except `0`) to override the binary.
- **Examples:** 86 programs in `examples/`, including ADT, nested/guarded pattern, tuple, record, stdlib, closure, BPF smoke, account/syscall, CPI, SPL-Token, counter, vault, external demo, crypto demo, multi-instruction, region allocation, string demo, tail recursion (TCO), hackathon greeting, zignocchio-port programs, dao_voting, ata_transfer, order_book, spl_burn, spl_close_account, spl_revoke, fixed_amm_quote, mutable_state_stress, and account_guard
- **Golden/UI tests:** Core IR/sexp snapshot, UI, and fmt golden tests run
  through `zig build test`; the current committed floor is `zig build test --summary none`
  plus the full Cargo/Mollusk suite
- **Install:** `./init.sh && zig build` (see [INSTALLING.md](./INSTALLING.md))

---

## Documents

Read in order:

| # | Doc | What it pins down |
|---|---|---|
| —  | [Installing](./INSTALLING.md) | Fresh setup, prerequisites, quickstart, and troubleshooting |
| 00 | [Overview](./docs/00-overview.md) | Vision, scope, three cold showers (anti-traps) |
| 01 | [Architecture](./docs/01-architecture.md) | Pipeline, layered IR, extension points |
| 02 | [Grammar](./docs/02-grammar.md) | Current accepted OCaml subset |
| 03 | [Core IR](./docs/03-core-ir.md) | ANF IR data model, the central contract |
| 04 | [Memory model](./docs/04-memory-model.md) | Arena-only current model, region descriptor for the future |
| 05 | [Backends](./docs/05-backends.md) | Zig codegen, tree-walk interpreter, backend trait |
| 06 | [BPF target](./docs/06-bpf-target.md) | Toolchain chain to Solana `.so` via direct `SOLANA_ZIG` build |
| 07 | [Repo layout](./docs/07-repo-layout.md) | Directory contract, who owns what |
| 08 | [Roadmap](./docs/08-roadmap.md) | P1-P9 sealed; Phase 19+20+21 drift baselines; future work preview |
| 09 | [Decisions (ADRs)](./docs/09-decisions.md) | Locked decisions, with reasons |
| 10 | [Frontend bridge](./docs/10-frontend-bridge.md) | OCaml `compiler-libs` → sexp → Zig |
| 11 | [Solana P3 guide](./docs/11-solana-p3.md) | Account layout, syscalls, CPI, SPL-Token, no_alloc, IDL, and CI coverage |
| RT | [Runtime API](./docs/runtime-api.md) | Public Zig runtime surface: Arena, Syscalls, CPI, Account, SPL Token, Bs58, and programs registry |
| P9+ | [Diagnostics](./docs/diagnostics.md) | `--error-format`, caret rendering, color, JSON schema, and wire-location notes |
| P9 | [LSP](./docs/lsp.md) | `omlz-lsp` stdio JSON-RPC, supported LSP methods, and editor setup |
| P9 | [Source maps](./docs/source-map.md) | `.map` sidecar schema, `.zxcaml.srcmap`, and `omlz unmap` |
| P9+ | [Wire compatibility](./docs/wire-compat.md) | Current wire `1.5`, prior additive bumps, and deprecated compatibility windows |
| 18 | [Fixed-point math](./docs/18-fixed-point.md) | `Fixed` / `Amount` six-decimal arithmetic and bps helpers for deterministic DeFi examples |
| 19 | [Functional multichain roadmap](./docs/19-functional-multichain-roadmap.md) | Exploratory plan for portable contract logic, WASM-chain adapters, EVM/Yul, upper syntaxes, and verified extraction |
| —  | [Hackathon assets](./docs/hackathon/README.md) | Surfpool demo, Anchor comparison, Slidev decks, recording checklist, and submission copy |
| —  | [Live site](https://zxcaml.pages.dev/) | Current public project landing page |
| —  | [Alternatives considered](./docs/alternatives-considered.md) | Why not self-write, why not fork OxCaml |
| —  | [OxCaml relationship](./docs/oxcaml-relationship.md) | What OxCaml is, four ways to "use" it, which to pick |
| —  | [zignocchio relationship](./docs/zignocchio-relationship.md) | The Zig→Solana SDK we read for ideas, what we learned, what we did not import (ADR-014) |

---

## One-line summary

> **Borrow OCaml's frontend. Throw away its runtime. Land on BPF via Zig.**
>
> Borrow ≠ fork. We call `compiler-libs` as a library; we never patch it.
