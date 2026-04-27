# ZxCaml ↔ OxCaml — Relationship and reuse policy

> **Languages / 语言**: **English** · [简体中文](./zh/oxcaml-relationship.md)

This document exists because the question *"can we just use OxCaml
to support x86 / other targets?"* is reasonable, recurring, and
based on a few mixed-up assumptions. Pinning the answer down once
saves the project from re-litigating it.

The short version is at §6. Read §1–§5 if you want to know why.

---

## 1. What OxCaml is

`oxcaml/oxcaml` (formerly `ocaml-flambda/flambda-backend`) is a
production fork of the OCaml compiler maintained primarily by
**Jane Street**. It is *not* an experimental sandbox; it powers
Jane Street's internal trading infrastructure.

Concretely, OxCaml ships:

| Component | What it does | Upstream OCaml has it? |
|---|---|---|
| **Flambda 2** | High-level optimiser: cross-function inlining, unboxing, specialisation | No (upstream has Flambda 1, considerably weaker) |
| **Cfg backend** | Modern low-level backend: control-flow-graph IR, register allocation, instruction scheduling | No (upstream uses the older Linear IR) |
| **Modes (`local` / `global`)** | Type-level annotation: a value's escape behaviour; non-escapers can be stack allocated | No |
| **Modes (`unique` / `shared`)** | Type-level annotation: unique ownership, enabling in-place mutation | No |
| **Layouts (`value` / `float64` / `bits64` / …)** | Type-level annotation: the runtime layout of a type, enabling unboxed values | No |
| **OCaml 5 base** | Tracks upstream OCaml 5.2; rebases regularly | (upstream is the source) |

OxCaml's targets are **`x86_64-linux`, `aarch64-linux`,
`aarch64-darwin`** (and partial `x86-darwin`). It does **not**
target BPF, WASM, or anything Solana-shaped, and it has no plans
to.

## 2. Why OxCaml exists

OxCaml exists because Jane Street has a specific, measurable need:

> Make OCaml fast enough, predictable enough, and memory-tight
> enough to run a sub-millisecond trading system without GC pauses
> ruining the latency tail.

Their pain points and OxCaml's answers:

| Pain | Answer |
|---|---|
| GC pause kills latency | `local` mode → stack allocation, no GC pressure |
| Boxed floats waste memory | `float64` Layout → unboxed in registers |
| Upstream `ocamlopt` too conservative | Flambda 2 → aggressive cross-function optimiser |
| OCaml 5 multicore feels new | `unique` / `shared` modes → typed concurrency invariants |
| Old code generator | Cfg backend → modern register allocation, instruction scheduling |

So when people ask "is OxCaml faster / better than upstream
OCaml?", the honest answer is:

> **Yes, for the workloads Jane Street cares about.** The wins are
> real and measurable on x86_64 trading code. They are **not** a
> generic improvement to the OCaml language; they are a targeted
> improvement to OCaml's behaviour on a specific class of CPU on a
> specific class of program.

## 3. The misframed question

A natural question — and one this document is here to answer — is:

> "If we want ZxCaml to support x86 (or other targets), can we just
> use OxCaml as the reference / base?"

The question contains a hidden assumption that does not hold. There
is no single thing called "use OxCaml" — there are four very
different things, with very different costs.

## 4. Four ways "use OxCaml" can be interpreted

### Way A — Fork OxCaml and add a BPF backend next to its x86 / arm backend

```
fork oxcaml/oxcaml
  → add backend/bpf/ next to backend/amd64/, backend/arm64/
  → OxCaml then produces x86 + arm + BPF
```

- **Verdict: rejected, permanently.**
- This is exactly the path ADR-009 forbids.
- Costs: permanently rebasing a 37k-commit, 970-branch, actively
  developed compiler.
- "Benefits" that don't apply: Flambda 2 / Cfg / modes are all
  built around the OCaml runtime (GC, exceptions, OCaml ABI, boxed
  representations). On BPF none of those are available, so the
  optimisations do not transfer.
- Conclusion: full cost, near-zero benefit.

### Way B — Read OxCaml's source for ideas, reimplement small pieces in ZxCaml

```
read oxcaml/backend/cfg/* and middle_end/flambda2/*
  → understand the techniques (Cfg IR, regalloc, unboxing)
  → reimplement what we actually need, in ZxCaml's own pipeline
  → no fork, no vendoring, no rebase
```

- **Verdict: legitimate, recommended when (and only when) needed.**
- This is "OxCaml as reference material", not as a code source.
- Useful **post-P3** if a specific BPF-relevant optimisation is
  required and the obvious approach is not enough.
- Up to and through P3, it is **not** required. Trust `zig`'s LLVM
  optimiser; it is more than adequate for our IR shape.
- The papers and design docs around Flambda 2 are themselves a
  good entry point; reading source is rarely necessary.

### Way C — When PX activates for some other target (wasm32, x86_64-linux, …), borrow OxCaml's approach to that target

```
ZxCaml ships P1-P5 as planned (BPF only).
PX activates for, e.g., wasm32 with a real use case.
  → look at how OxCaml maps Lambda → that target's ABI
  → copy the *approach* (not the code) into ZxCaml's pipeline
```

- **Verdict: situationally useful, but smaller than it looks.**
- OxCaml's x86 / arm code generators are deeply tied to the OCaml
  ABI: `caml_call_gc` calling convention, tagged pointers,
  exception tables, boxed-float rules. **None of these apply to
  ZxCaml.**
- What we *can* learn is generic: register allocation strategy,
  instruction scheduling, basic-block layout. But these are exactly
  the things `zig`'s LLVM backend already does for us. The OxCaml
  effort here is a wash for ZxCaml.
- For non-x86 targets specifically (wasm32, riscv, …), OxCaml is
  even less helpful, because OxCaml itself does not target them.

### Way D — Use upstream OCaml (and/or OxCaml) to compile the *same* `.ml` file natively, in parallel with `omlz` compiling it to BPF

```
one .ml source file
  ├── ocaml / dune                → x86_64 / arm64 native binary
  │                                  (for fast local testing, fuzzing, REPL)
  └── omlz                         → program.so (Solana SBPF ELF)
                                     (for deployment to Solana)
```

- **Verdict: free, recommended, already implied by ADR-001.**
- Because ZxCaml is a strict subset of OCaml (ADR-001), every
  `.ml` we accept is by definition a valid OCaml program.
- Therefore the upstream OCaml compiler already produces a native
  binary for the developer's machine — for free — without ZxCaml
  needing an x86 backend at all.
- This is the cleanest answer to "I want my Solana program to also
  run on x86 for testing": **install `ocaml`** (which `omlz`
  already requires, per ADR-010) and run the same file.
- This works equally well with OxCaml installed instead of
  upstream OCaml, since OxCaml is itself a superset of OCaml 5.2.

## 5. Mapping intents to recommended paths

If your real intent is **A**, choose the path on the right.

| Real intent | Recommended path |
|---|---|
| "I want my ZxCaml program to also run on x86 for local testing" | **D** (free; install `ocaml`) |
| "I want ZxCaml's BPF output to be more aggressively optimised" | **B**, but only after P3 and only with a specific bottleneck identified |
| "I want ZxCaml to support wasm32 / x86_64-linux as a real target" | The PX phase (`08-roadmap.md` §8a). OxCaml is mostly not useful here. |
| "I want to fork OxCaml and add BPF" | **None.** ADR-009 stands. Re-read `alternatives-considered.md` §C. |
| "I just like OxCaml's papers" | Read them. They are good. They are not a basis for forking. |

## 6. The short version

- OxCaml is Jane Street's **production OCaml fork** for x86 / arm
  trading systems. It is faster and tighter than upstream **on
  those workloads**, by virtue of Flambda 2, the Cfg backend, the
  mode system, and Layouts.
- OxCaml **already** supports x86_64 and arm64; nobody needs to
  "add x86 support" to it.
- OxCaml does **not** target BPF, will not target BPF, and its
  optimisations rely on assumptions BPF does not satisfy.
- The right way to use OxCaml from ZxCaml's perspective is **as
  reference material** (Way B) and **as an optional drop-in for
  the developer's local OCaml toolchain** (Way D). Forking it
  (Way A) is rejected by ADR-009. Borrowing its target back-ends
  (Way C) is mostly irrelevant because we go through `zig`'s LLVM.
- For "I want native x86 binaries of my ZxCaml program", the
  answer is: install `ocaml` (or `oxcaml`) and run `dune exec`.
  ZxCaml does not need to grow an x86 backend to make this work.

## 7. When this document should be revisited

Open this document up and revise it when, and only when:

1. OxCaml ships a feature that *does* transfer to BPF
   (e.g., a flat-memory IR, a no-runtime mode, a freestanding
   target option). At that point, re-evaluate **Way B** in light
   of the new feature.
2. ZxCaml hits a concrete BPF performance ceiling that `zig`'s
   LLVM backend cannot remove, and the next obvious step is a
   ZxCaml-side optimiser. At that point **Way B** becomes
   actionable.
3. Some target that OxCaml supports natively becomes a real PX
   candidate (e.g., a documented use case for x86_64-linux ZxCaml
   binaries beyond developer testing). At that point re-evaluate
   **Way C** *only* for that specific target.

Forking OxCaml (Way A) is **not** a revisit case. It would require
superseding ADR-009 first, and the standing answer to that is no.
