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
[ zig build-lib -target bpfel-freestanding -femit-llvm-bc ]
   │  .bc (LLVM bitcode)
   ▼
[ sbpf-linker --cpu v2 --export entrypoint ]    ◀── v3 opt-in (ADR-013)
   │
   ▼
Solana BPF .so
```

- Frontend: **upstream OCaml `compiler-libs`** (no fork, no
  re-implementation). See ADR-009 / ADR-010.
- Compiler host language for everything below the frontend:
  **Zig 0.16**.
- Source language: **OCaml** (subset, growing).
- Primary target: **Solana BPF** (`bpfel-freestanding`).
- Memory model (P3): **arena, fully inferred, hidden from the user**;
  BPF entry programs use a 32 KiB arena.
- Core IR shape: **ANF** (A-Normal Form), typed, layout-tagged.
- CLI binary name: **`omlz`** (OCaml on Zig).
- Build driver: a single **`build.zig`** orchestrates both the
  OCaml frontend bridge and the Zig pipeline (ADR-011).

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

The command sequence uses the same `init.sh` setup script as CI.

## Status

**P7 OCaml Subset Expansion is implemented.** P1-P6 deliver the walking skeleton,
subset expansion, Solana runtime integration, Mollusk test infrastructure,
external declarations, Anchor IDL, functional persistent stdlib, and region
inference. P7 expands the OCaml language subset with trivial desugars (sequence,
if-then, function cases), pattern extensions (literal/or/alias patterns), string
and char operations, and expanded stdlib (List/Option/Result/Fun).

`omlz` works end-to-end: parse/type-check OCaml with upstream
`compiler-libs` → emit sexp `1.0` → lower through Core IR with escape
analysis → interpret, build native Zig, build Solana BPF `.so` artifacts,
or emit Anchor-compatible IDL.

### Current features

- **CLI commands:** `omlz check <file>`, `omlz check --no-alloc <file>`, `omlz run <file>`, `omlz build --target=native <file> -o <out>`, `omlz build --target=bpf <file> -o <out>`, `omlz idl <file>`
- **Wire format:** version 1.0 (P1 `0.4`; P2 added user ADTs in `0.5`, nested/guarded patterns in `0.6`, and tuples/records in `0.7`; P3 added account/syscall references in `0.8` and CPI types/references in `0.9`; P4 added instruction_data; P5 added external declarations; P6 added escape analysis annotations)
- **OCaml subset:** let bindings, nested let, let rec, curried functions, function application, arithmetic/comparison operators, if/then/else, user-defined ADTs, nested constructor patterns, guarded match arms, literal constant patterns, or-patterns, alias patterns, tuples, records, field access, functional record update, lists (`[]` / `::`), sequence expressions (`;`), function cases (`function |`), string operations (`^`, length, get, sub), char operations (code, chr), and pattern matching over all of those forms
- **Stdlib:** bundled `List` (`length`, `map`, `filter`, `fold_left`, `rev`, `append`, `hd`, `tl`, `nth`, `exists`, `for_all`, `find`, `sort`, `combine`, `split`), `Option` (`is_none`, `is_some`, `value`, `get`, `fold`), `Result` (`is_ok`, `is_error`, `ok`, `error`, `map`, `bind`), `Fun` (`id`, `const`, `flip`), `Map` (`empty`, `singleton`, `add`, `find`, `remove`, `mem`, `size`, `to_list`), `Set` (`empty`, `singleton`, `add`, `mem`, `remove`, `size`, `to_list`, `union`, `inter`), `String` (`length`, `get`, `sub`), `Char` (`code`, `chr`), `Crypto` (`sha256`, `keccak256`), and `Pubkey` (`zero`, `token_program`, `of_hex`) modules
- **Memory model:** arena-only with region inference for automatic stack allocation of non-escaping locals; BPF entry arena is 32 KiB
- **Backends:** tree-walk interpreter, Zig native codegen, BPF codegen via `sbpf-linker --cpu v2`
- **Solana accounts:** built-in `account` record values expose key, lamports, data, owner, and signer/writable/executable flags parsed from the BPF input buffer as zero-copy views; the runtime parser also tracks rent epoch
- **Solana syscalls:** bindings for logging, `sol_log_64`, pubkey logging, SHA-256/Keccak, Clock/Rent sysvars, and remaining compute units use `external` declarations to bind directly to Zig runtime symbols
- **External declarations:** `external name : type = "zig_symbol"` syntax enables direct FFI to Zig runtime functions with type safety enforced by the frontend
- **CPI and PDA helpers:** built-in `instruction` / `account_meta` records, `invoke`, `invoke_signed`, PDA helpers, and return-data syscalls mirror the Solana C ABI
- **SPL-Token:** helper support and an acceptance example encode legacy Tokenkeg Transfer instructions with source/destination/authority metas
- **no_alloc:** `omlz check --no-alloc` runs a conservative Core IR allocation proof and reports the allocation-causing node on failure
- **IDL:** `omlz idl <file>` emits Anchor 0.30+ compatible JSON with SHA-256 discriminators, instruction accounts/args, account types, events, errors, and constants
- **BPF closures:** hardened first-class closures — closures capturing ADT values, multi-environment captures, and nested closures are lowered without unsupported BPF code-pointer relocations and are covered by Solana closure acceptance tests
- **Solana acceptance:** deploy + invoke against `solana-test-validator` works for the canonical hello harness, closure harness, account/syscall harness, simple CPI harness, and SPL-Token transfer harness
- **Region inference:** automatic escape analysis marks non-escaping local values for stack allocation, reducing arena pressure and improving BPF compute efficiency
- **Determinism:** interpreter ≡ Zig native across the P1 + P2 + P3 + P4 + P5 + P6 examples corpus
- **CI:** GitHub Actions workflow with `macos-latest` + `ubuntu-latest` matrix runs `./init.sh`, `zig build`, `zig build test`, `cargo test` (Mollusk SVM), P3 `no_alloc` and IDL smoke checks, and an examples `omlz check` corpus loop
- **Mollusk SVM tests:** 7 integration tests in `tests/` using Mollusk SVM v0.12.1 (hello, demo, simple_cpi, counter, vault, external_demo, crypto_demo)
- **Diagnostics:** human-friendly `path:line:col: severity: message` rendering
- **Examples:** 41 programs in `examples/`, including ADT, nested/guarded pattern, tuple, record, stdlib, closure, BPF smoke, account/syscall, CPI, SPL-Token, counter, vault, external demo, crypto demo, multi-instruction, region allocation, and string demo programs
- **Golden/UI tests:** Core IR/sexp snapshot and UI tests run through `zig build test`
- **Install:** `./init.sh && zig build` (see [INSTALLING.md](./INSTALLING.md))

---

## Documents

Read in order:

| # | Doc | What it pins down |
|---|---|---|
| —  | [Installing](./INSTALLING.md) | Fresh setup, prerequisites, quickstart, and troubleshooting |
| 00 | [Overview](./docs/00-overview.md) | Vision, scope, three cold showers (anti-traps) |
| 01 | [Architecture](./docs/01-architecture.md) | Pipeline, layered IR, extension points |
| 02 | [Grammar](./docs/02-grammar.md) | OCaml subset accepted through P2 |
| 03 | [Core IR](./docs/03-core-ir.md) | ANF IR data model, the central contract |
| 04 | [Memory model](./docs/04-memory-model.md) | Arena-only current model, region descriptor for the future |
| 05 | [Backends](./docs/05-backends.md) | Zig codegen, tree-walk interpreter, backend trait |
| 06 | [BPF target](./docs/06-bpf-target.md) | Toolchain chain to Solana `.so` (zig + sbpf-linker) |
| 07 | [Repo layout](./docs/07-repo-layout.md) | Directory contract, who owns what |
| 08 | [Roadmap](./docs/08-roadmap.md) | Phases P1–P7, with P1/P2 release notes |
| 09 | [Decisions (ADRs)](./docs/09-decisions.md) | Locked decisions, with reasons |
| 10 | [Frontend bridge](./docs/10-frontend-bridge.md) | OCaml `compiler-libs` → sexp → Zig |
| 11 | [Solana P3 guide](./docs/11-solana-p3.md) | Account layout, syscalls, CPI, SPL-Token, no_alloc, IDL, and CI coverage |
| —  | [Alternatives considered](./docs/alternatives-considered.md) | Why not self-write, why not fork OxCaml |
| —  | [OxCaml relationship](./docs/oxcaml-relationship.md) | What OxCaml is, four ways to "use" it, which to pick |
| —  | [zignocchio relationship](./docs/zignocchio-relationship.md) | The Zig→Solana SDK we read for ideas, what we learned, what we did not import (ADR-014) |

---

## One-line summary

> **Borrow OCaml's frontend. Throw away its runtime. Land on BPF via Zig.**
>
> Borrow ≠ fork. We call `compiler-libs` as a library; we never patch it.
