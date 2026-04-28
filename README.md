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
- Memory model (P1): **arena, fully inferred, hidden from the user**.
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

**P2 subset expansion is implemented.** The P1 walking skeleton remains the
baseline, and P2 adds user-defined ADTs, nested and guarded pattern matching,
decision-tree match compilation, tuples, records, an expanded stdlib, and
first-class closure support on the BPF path.

`omlz` works end-to-end: parse/type-check OCaml with upstream
`compiler-libs` → emit sexp `0.7` → lower through Core IR → interpret,
build native Zig, or build Solana BPF `.so` artifacts.

### Current features

- **CLI commands:** `omlz check <file>`, `omlz run <file>`, `omlz build --target=native <file> -o <out>`, `omlz build --target=bpf <file> -o <out>`
- **Wire format:** version 0.7 (P1 `0.4`; P2 added user ADTs in `0.5`, nested/guarded patterns in `0.6`, and tuples/records in `0.7`)
- **OCaml subset:** let bindings, nested let, let rec, curried functions, function application, arithmetic/comparison operators, if/then/else, user-defined ADTs, nested constructor patterns, guarded match arms, tuples, records, field access, functional record update, lists (`[]` / `::`), and pattern matching over all of those forms
- **Stdlib:** bundled `Option`, `Result`, and `List` modules with common combinators such as `map`, `bind`, `value`, `length`, `filter`, `fold_left`, `rev`, and `append`
- **Memory model:** arena-only, fully inferred, hidden from the user
- **Backends:** tree-walk interpreter, Zig native codegen, BPF codegen via `sbpf-linker --cpu v2`
- **BPF closures:** first-class closures with captured environments are lowered without unsupported BPF code-pointer relocations and are covered by Solana closure acceptance tests
- **Solana acceptance:** deploy + invoke against `solana-test-validator` works for the canonical hello harness, with closure acceptance available under `tests/solana/closures/`
- **Determinism:** interpreter ≡ Zig native across the P1 + P2 examples corpus
- **CI:** GitHub Actions workflow with `macos-latest` + `ubuntu-latest` matrix runs `./init.sh`, `zig build`, `zig build test`, and an examples `omlz check` corpus loop
- **Diagnostics:** human-friendly `path:line:col: severity: message` rendering
- **Examples:** 29 programs in `examples/`, including ADT, nested/guarded pattern, tuple, record, stdlib, closure, and BPF smoke programs
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
| —  | [Alternatives considered](./docs/alternatives-considered.md) | Why not self-write, why not fork OxCaml |
| —  | [OxCaml relationship](./docs/oxcaml-relationship.md) | What OxCaml is, four ways to "use" it, which to pick |
| —  | [zignocchio relationship](./docs/zignocchio-relationship.md) | The Zig→Solana SDK we read for ideas, what we learned, what we did not import (ADR-014) |

---

## One-line summary

> **Borrow OCaml's frontend. Throw away its runtime. Land on BPF via Zig.**
>
> Borrow ≠ fork. We call `compiler-libs` as a library; we never patch it.
