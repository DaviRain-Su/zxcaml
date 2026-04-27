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
