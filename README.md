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
[ zig build-obj -target bpfel-freestanding ]
   │
   ▼
Solana BPF .o
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
  └── omlz          →  Solana BPF .o                  (deployment)
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

## Status

**Spec / planning phase.** No compiler code exists yet. This repo
currently contains only design documents under [`docs/`](./docs/).

The implementation will be driven by a separate task system; this repo
is the source of truth for *what* to build.

---

## Documents

Read in order:

| # | Doc | What it pins down |
|---|---|---|
| 00 | [Overview](./docs/00-overview.md) | Vision, scope, three cold showers (anti-traps) |
| 01 | [Architecture](./docs/01-architecture.md) | Pipeline, layered IR, extension points |
| 02 | [Grammar](./docs/02-grammar.md) | OCaml subset accepted in P1 |
| 03 | [Core IR](./docs/03-core-ir.md) | ANF IR data model, the central contract |
| 04 | [Memory model](./docs/04-memory-model.md) | Arena-only in P1, region descriptor for the future |
| 05 | [Backends](./docs/05-backends.md) | Zig codegen, tree-walk interpreter, backend trait |
| 06 | [BPF target](./docs/06-bpf-target.md) | Toolchain chain to Solana `.o` |
| 07 | [Repo layout](./docs/07-repo-layout.md) | Directory contract, who owns what |
| 08 | [Roadmap](./docs/08-roadmap.md) | Phases P1–P7 and P1 internal steps |
| 09 | [Decisions (ADRs)](./docs/09-decisions.md) | Locked decisions, with reasons |
| 10 | [Frontend bridge](./docs/10-frontend-bridge.md) | OCaml `compiler-libs` → sexp → Zig |
| —  | [Alternatives considered](./docs/alternatives-considered.md) | Why not self-write, why not fork OxCaml |
| —  | [OxCaml relationship](./docs/oxcaml-relationship.md) | What OxCaml is, four ways to "use" it, which to pick |

---

## One-line summary

> **Borrow OCaml's frontend. Throw away its runtime. Land on BPF via Zig.**
>
> Borrow ≠ fork. We call `compiler-libs` as a library; we never patch it.
