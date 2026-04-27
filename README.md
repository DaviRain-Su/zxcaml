# ZxCaml

> An **OCaml dialect** with a **Zig/BPF backend**.
> We do **not** invent a new language. Source files use the standard `.ml`
> extension. We replace the *backend*, not the *frontend*.

---

## TL;DR

```text
.ml source  →  OCaml-subset frontend  →  Typed Core IR (ANF)
                                              │
                                              ▼
                                  Lowering (arena, P1 only)
                                              │
                                              ▼
                                       Zig codegen
                                              │
                                              ▼
                                  zig build-obj -target bpfel-…
                                              │
                                              ▼
                                     Solana BPF .o
```

- Compiler host language: **Zig 0.16**
- Source language: **OCaml** (subset, growing)
- Primary target: **Solana BPF** (`bpfel-freestanding`)
- Memory model (P1): **arena, fully inferred, hidden from the user**
- Core IR shape: **ANF** (A-Normal Form), typed, layout-tagged
- CLI binary name: **`omlz`** (OCaml on Zig)

---

## Why this exists

OCaml has an elegant frontend (HM types, ADTs, pattern matching, modules)
and a battle-tested type system. What it lacks is a backend story for
**resource-constrained, deterministic** environments such as Solana BPF,
where the OCaml runtime (GC, boxed floats, exceptions) cannot run.

ZxCaml keeps the OCaml language and reuses its mental model, but routes
the program through a new pipeline that produces flat, GC-free, BPF-ready
code via Zig.

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

---

## One-line summary

> **Take OCaml's frontend. Throw away its runtime. Land on BPF via Zig.**
