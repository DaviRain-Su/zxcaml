# 09 — Architectural Decision Records

Format: short, dated, immutable. Append new ADRs; do not edit old
ones — supersede them with a new entry.

---

## ADR-001 — ZxCaml is an OCaml dialect, not a new language

**Date:** 2026-04-27
**Status:** Accepted

### Context

Earlier drafts of this project leaned toward "a new ML-family
language with a `.zxc` extension". This was rejected by the project
owner as scope creep: the goal is not to invent a language, but to
produce a new backend for an existing one.

### Decision

- The source language is **OCaml** (a strict subset of it).
- Source files use the `.ml` extension.
- We do not introduce new keywords, operators, or syntactic forms.
- A program accepted by ZxCaml must also be accepted by the
  reference OCaml compiler (this is enforced as a CI sanity oracle
  whenever `ocaml` is installed).

### Consequences

- The frontend specification is borrowed wholesale from OCaml; we
  only document the *subset* we accept.
- Ecosystem reuse via "compile to OCaml backend" is **not** a goal,
  because reusing OCaml libraries requires reproducing the OCaml
  runtime representation, which we explicitly do not do.
- The CLI binary is named `omlz` (OCaml on Zig). The repo retains
  the name `ZxCaml`.

---

## ADR-002 — Compiler host language is Zig 0.16

**Date:** 2026-04-27
**Status:** Accepted

### Context

The compiler had to be written in something. Candidates considered:
Rust, OCaml, Zig.

### Decision

- The compiler is written in **Zig**, version **0.16**.
- The version is pinned in `build.zig.zon` via
  `minimum_zig_version = "0.16.0"`.
- 0.16's build API (`b.addExecutable` with `root_module`,
  `b.addTest` with `root_module`, `paths` in zon) is the version
  we target.

### Reasons

- The runtime helpers and code generator already need Zig.
- Using one language for compiler + runtime + generated code keeps
  the toolchain footprint minimal.
- Zig's ergonomic arena allocators map naturally onto how our
  compiler manages AST/IR memory.

### Acknowledged costs

- No mature parser-generator ecosystem in Zig; the parser is hand
  written.
- No native ADT/pattern syntax in the host; AST/IR types are
  tagged unions with manual switch dispatch.
- No `derive(Debug)`-style facilities; pretty-printers are written
  by hand.
- Standard library still evolves between Zig minor releases; we
  pin one version per phase.

---

## ADR-003 — Phase 1 ships a BPF `.o` end-to-end

**Date:** 2026-04-27
**Status:** Accepted

### Context

A safer P1 would stop at "Zig source emitted, builds natively".
That defers the riskiest part of the project (BPF target chain) to
later, but also leaves it unproven for longer.

### Decision

P1 includes the BPF target chain end-to-end:

- `omlz build --target=bpf` invokes `zig build-obj -target
  bpfel-freestanding`.
- The resulting `.o` is loadable by `solana-test-validator`.
- Acceptance criterion is a working `examples/solana_hello.ml`.

### Scope discipline

To keep this tractable, P1 covers **only**:

- the entrypoint shim,
- a return value of `0`,
- no syscalls, no account parsing, no CPI.

Everything else Solana-shaped is P3.

---

## ADR-004 — Core IR is ANF, typed, layout-tagged

**Date:** 2026-04-27
**Status:** Accepted

### Context

Choices considered for Core IR shape:

- **ANF**: simple, regular, well understood; common in production
  ML compilers.
- **CPS**: powerful for control-flow transformations and effect
  handlers; steeper learning curve, larger IR.
- **Typed tree**: smallest, but pushes optimisation duplication
  into every backend.

### Decision

Core IR is **ANF**, typed (`Ty` on every node), with `Layout`
descriptors on allocation-bearing nodes.

### Reasons

- ANF is the standard for ML-family compilers (OCaml's Lambda → Cmm
  pipeline is essentially ANF in disguise; MLton, GHC, …).
- ANF makes ABI-aware lowering straightforward: the backend sees a
  flat sequence of `let`-bound operations.
- The `Layout` field is the future-compatibility hook for region
  inference and alternative memory models (see ADR-006).

### Consequences

- Continuation-style transformations (effect handlers, advanced
  control flow) will require additional infrastructure if they
  ever land. This is acceptable because they are explicitly out
  of scope.

---

## ADR-005 — Memory model is hidden in P1, fully arena

**Date:** 2026-04-27
**Status:** Accepted

### Context

Possibilities considered:

- Hidden / fully inferred (user writes plain OCaml).
- Type-level region annotations (e.g., `'a @region`).
- Fully manual (user picks `arena` / `rc` / etc.).

### Decision

P1 hides the memory model. The user writes ordinary OCaml; the
compiler chooses arena allocation everywhere except for immediate
values and string literals.

### Reasons

- Region inference, ownership analysis, and reference counting are
  deep PL research problems; landing any of them in P1 is reckless.
- A single hidden arena trivially satisfies P1's BPF acceptance
  test.
- Future phases can refine the arena into per-region arenas without
  changing the user-visible language.

### Forward compatibility

The `Layout` descriptor on Core IR (ADR-004) is the extension
point. P4 will add new `Region` variants and an inference pass; no
shape change to Core IR is required.

---

## ADR-006 — OCaml backend removed from the main path

**Date:** 2026-04-27
**Status:** Accepted

### Context

A natural-sounding strategy would be: "compile our subset to OCaml
bytecode/native, get opam libraries for free." This was reconsidered
and rejected.

### Decision

There is **no** OCaml backend on the main path.

A compile-only stub (`src/backend/ocaml_stub.zig`) exists solely to
keep the backend trait honest. It returns `error.NotImplemented`.

### Reasons

- OCaml libraries depend on the runtime representation (tagged
  pointers, boxed floats, GC, exceptions, ctypes), not just the
  language.
- Re-implementing the OCaml runtime is "becoming OCaml", which is
  not the project's goal.
- We achieve OCaml-frontend reuse by being a strict OCaml subset
  (ADR-001), not by routing through OCaml's backend.

### Consequences

- Ecosystem reuse goes through native stdlib code (in our subset)
  and Zig FFI (P5).
- OCaml may still be used **off-line** to type-check our stdlib as
  a sanity oracle.

---

## ADR-007 — Single arena threaded through every function

**Date:** 2026-04-27
**Status:** Accepted

### Context

Allocation discipline for P1 had to be defined.

### Decision

Every emitted function takes `arena: *Arena` as an implicit first
parameter. The BPF entrypoint shim creates the arena from a
statically-sized buffer and passes it down. Allocation always uses
this arena.

### Reasons

- Trivial to reason about lifetimes: nothing escapes the program.
- Trivial to reset: drop the arena at program exit.
- Avoids global state, which is hostile to BPF and to determinism.

### Consequences

- Programs cannot allocate beyond the arena's buffer; the buffer
  size is a CLI flag (`--arena-bytes`, default 32 KiB).
- Multi-arena schemes (per region, per call) are a P4 refinement
  and do not require Core IR changes.

---

## ADR-008 — Determinism between interpreter and Zig backend is a hard invariant

**Date:** 2026-04-27
**Status:** Accepted

### Context

The interpreter and the Zig backend can diverge on subtle issues
(integer overflow, pattern-matching ordering, division semantics).
Without a check, these diverge silently.

### Decision

A property suite runs every example through the interpreter and
through the Zig backend (native build) and diffs the observable
result. Any divergence is a P0 bug.

### Reasons

- The interpreter exists precisely to act as the spec for the
  semantics; if the backend disagrees, the backend is wrong.
- This catches integer-semantics regressions immediately.

### Consequences

- Some semantic decisions (integer wrap, division semantics) are
  pinned in `05-backends.md`.
- BPF outputs cannot be diff-checked at the value level, but their
  return code can; this is the BPF acceptance test.

---

## ADR-009 — Do **not** fork OxCaml (or any OCaml compiler distribution)

**Date:** 2026-04-27
**Status:** Accepted
**Supersedes:** none. Strengthens ADR-006.

### Context

OxCaml (`oxcaml/oxcaml`, formerly `flambda-backend`) is a Jane Street
fork of the OCaml compiler. It contains a complete OCaml 5.2
compiler, a redesigned Cfg backend, the Flambda 2 optimiser, the
`mode` / `local` / `unique` system, a Layouts feature, and the
OxCaml C runtime. The repository carries ~37k commits, ~970
branches, and is ~87% OCaml + ~9% C. It is actively rebased onto
upstream OCaml.

A natural-sounding strategy for this project is: *"fork oxcaml,
add a BPF backend next to its Cfg backend, inherit all of Jane
Street's optimisations for free."* This was reconsidered carefully
and **rejected**.

### Decision

- We do **not** fork OxCaml.
- We do **not** fork upstream OCaml.
- We do **not** vendor any OCaml compiler source tree into this
  repo.

### Reasons

1. **OxCaml's optimisations assume the OCaml runtime exists.**
   Flambda 2's unboxing relies on `caml_call_gc` not running for
   the unboxed path. The Cfg backend emits calling conventions
   that match the OCaml ABI. The `local` / unique mode system
   discriminates stack-vs-GC-heap allocation, where "GC heap" is
   the OCaml GC. None of these assumptions hold on Solana BPF,
   which has no GC, no exceptions, no threads, no `caml_call_gc`,
   and no OCaml-shaped ABI. The optimisations therefore do **not**
   transfer; we would be inheriting code we cannot use and a
   maintenance burden we cannot avoid.
2. **OxCaml's own backends do not target BPF.** Adding a BPF
   target inside OxCaml would be a hostile patch from upstream's
   point of view: it would have to coexist with their Cfg backend,
   bypass `caml_call_gc`, stub out exceptions and threads, and
   ship a parallel mini-runtime. None of that is welcome upstream.
3. **Maintaining a fork of an active 37k-commit compiler is a
   full-time-team workload.** Jane Street has a team. We do not.
   A fork that does not regularly rebase becomes dead code; a fork
   that does rebase consumes most of the project's engineering
   budget on conflict resolution.
4. **The frontend reuse goal can be satisfied without a fork.**
   See ADR-010: upstream OCaml's `compiler-libs` plus
   `-bin-annot` (`.cmt`) export already provides a fully
   type-checked `Typedtree`. We consume that, no fork required.

### What we lose by not forking

- We do **not** get Flambda 2's optimisations.
  → For BPF, we trust `zig`'s LLVM-based optimiser instead.
- We do **not** get OxCaml's `mode` / `local` system.
  → Our `Layout` field on Core IR (ADR-004) is a distinct,
  smaller mechanism aligned with our region story (ADR-005).
- We do **not** get unboxed Layouts (`float64`, `bits64`, …).
  → Acceptable in P1; reconsider at P4+ if the BPF target shows
  it matters.

### What we keep open

OxCaml's design ideas (Layouts, modes, Flambda 2's IR) are
**inspirational reference material**. We may read their code and
their papers; we do not import their code.

---

## ADR-010 — Use upstream OCaml `compiler-libs` as the frontend

**Date:** 2026-04-27
**Status:** Accepted
**Supersedes:** parts of ADR-002 — the compiler is no longer
"all Zig"; it is **OCaml frontend bridge + Zig backend**.

### Context

ADR-009 rules out forking any OCaml compiler. ADR-001 commits to
OCaml syntax and semantics. We must therefore obtain a parsed,
name-resolved, type-checked representation of the user's `.ml`
file from somewhere.

Three options were considered:

- **A.** Hand-write lexer + parser + HM in Zig. Maximum
  independence; most code; risk of subset drift from real OCaml.
- **B.** Call into the upstream OCaml compiler's `compiler-libs`
  to obtain a `Typedtree`, consume that. No fork; tiny OCaml glue
  layer; perfect language fidelity within our subset.
- **C.** Fork OxCaml (rejected by ADR-009).

### Decision

We adopt **option B**: a small OCaml glue program drives
`compiler-libs` to type-check the user's `.ml` and emit a
serialised `Typedtree` (S-expression, exact format defined in
`docs/10-frontend-bridge.md`). The Zig compiler reads this
serialisation and continues from there.

### Architecture impact

```
.ml
 ↓        zxc-frontend (OCaml, ~few hundred LOC)
ocamlc -bin-annot   →   .cmt (Typedtree)   →   sexp dump
 ↓
zxc-frontend-bridge (Zig)   read sexp, build our Typed AST mirror
 ↓
ANF lowering → Core IR → ArenaStrategy → Lowered IR → Zig codegen
 ↓
zig build-obj -target bpfel-freestanding
 ↓
Solana BPF .o
```

The Core IR remains the stable contract (ADR-004 unchanged).
Everything **above** Core IR shifts: the Surface AST is now the
OCaml `Typedtree`, not a hand-written one.

### Reasons

- **No parser written, no parser to maintain.** OCaml's lexer and
  parser are the reference; we cannot drift from them by accident.
- **No type system written, no type system to maintain.** OCaml's
  HM + ADT (and modules, when we want them) come for free.
- **Subset enforcement is trivial.** The OCaml glue type-checks
  the program with the real compiler, then walks the `Typedtree`
  and rejects any node we don't yet support, with a precise
  diagnostic. No risk of accidental incompatibility.
- **Tooling reuse.** Editor support, `merlin`, `ocamlformat` all
  work on user `.ml` files unmodified.

### Consequences

- A working `ocaml` toolchain (`ocamlc`, `ocamlfind`) is a
  **build-time** requirement for `omlz`. It is **not** a
  runtime requirement of compiled BPF programs (those have no
  OCaml dependency at all).
- The compiler is now bilingual: a small OCaml frontend bridge
  plus the existing Zig pipeline. See ADR-011 for build
  orchestration.
- The `Typedtree` API is part of `compiler-libs` and is **not**
  guaranteed stable across major OCaml releases. We pin a single
  OCaml version per phase and document the upgrade path in this
  ADR's revision history.
- We lose the option of "single-binary, no-OCaml" distribution.
  Acceptable: developers building Solana programs already need
  toolchains. End-users running deployed BPF programs need
  nothing.

### Pinned versions (P1)

- OCaml: **5.2.x** (matches OxCaml's base; widely available in
  opam).
- `compiler-libs.common` from the matching distribution.
- Zig: **0.16.x** (unchanged; ADR-002 stands).

---

## ADR-011 — `build.zig` is the single build driver; no `dune`

**Date:** 2026-04-27
**Status:** Accepted

### Context

ADR-010 introduces an OCaml component to the project. The natural
build tool for OCaml code is `dune`. Adopting `dune` would mean
two coexisting build systems (`dune` for the frontend bridge,
`build.zig` for everything else) plus a coordinator on top.

### Decision

`build.zig` is the **only** build driver in this repository.

The OCaml frontend bridge is built via direct invocations of
`ocamlfind ocamlopt` from a `b.addSystemCommand` step inside
`build.zig`. No `dune-project` file is checked in.

### Reasons

- **One project, one build entry point.** `zig build` is the
  developer's contract.
- **The OCaml bridge is small.** A single executable producing
  a single binary; it does not benefit from `dune`'s
  multi-package machinery.
- **No opam dependency footprint beyond `compiler-libs`.** Adding
  `dune` would pull in a sub-toolchain we do not otherwise need.
- **CI is simpler.** One `zig build` step, period.

### Consequences

- The OCaml glue must be self-contained: no third-party `opam`
  packages beyond `compiler-libs` (which ships with the OCaml
  distribution).
- If the OCaml bridge ever grows beyond a few files, this
  decision must be revisited. It is **explicitly tied to scope**:
  if the frontend bridge becomes "real OCaml code", we will
  reconsider, but only by superseding this ADR.
- Editor / LSP setup for the OCaml bridge code may need a tiny
  `.merlin` or per-directory `dune` shim that is **not** part of
  the build. That is acceptable as long as `zig build` remains
  authoritative.

### Build flow

```
zig build
  ├─ step: ocaml-frontend
  │    invokes: ocamlfind ocamlopt -package compiler-libs.common \
  │             -linkpkg src/frontend/zxc_frontend.ml \
  │             -o build/zxc-frontend
  ├─ step: omlz (Zig executable)
  │    depends on: ocaml-frontend (binary copied/embedded)
  └─ step: install
       puts both binaries under zig-out/bin/
```

`omlz` invokes `zxc-frontend` as a subprocess at runtime when
processing `.ml` input.
