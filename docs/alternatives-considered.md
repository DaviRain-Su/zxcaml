# Alternatives Considered — Frontend strategy

> **Languages / 语言**: **English** · [简体中文](./zh/alternatives-considered.md)

This is a snapshot of the three options considered for ZxCaml's
frontend, the reasoning behind picking option B, and what each
rejected option would have entailed. It exists so that future
contributors do not re-litigate the decision without first
reading why it was made.

The decision itself is recorded in **ADR-009** (no fork) and
**ADR-010** (use upstream `compiler-libs`). This file is the
*context* those ADRs reference.

---

## Option A — Hand-write everything in Zig

```text
.ml  →  Zig lexer  →  Zig parser  →  Zig HM/ADT  →  Zig Typed AST
        →  ANF  →  Core IR  →  Lowered IR  →  Zig codegen
        →  zig build-lib + sbpf-linker  →  program.so
```

### Pros
- Zero OCaml toolchain dependency at build time.
- Single language across the whole compiler.
- Total control over diagnostics and IR shape.

### Cons
- ~3–5 kloc of additional Zig: lexer, parser, HM with let-poly,
  ADT inference, exhaustiveness checking, error reporting.
- Constant risk of *subset drift* — a program our parser accepts
  but real OCaml rejects (or vice versa). Catching this requires
  a continuous oracle test against `ocaml`, which means the
  toolchain dependency comes back through the back door.
- Hand-written HM error messages are notoriously hard to make
  good. OCaml has decades of polish here; we would never catch
  up.

### Why rejected (for now)
The cost is real and recurring; the benefit is independence we do
not need. Our acceptance criterion is BPF output, not
toolchain-free distribution of the *compiler*. End-users running
a deployed BPF program never see OCaml; only developers building
ZxCaml programs do, and they already have toolchains.

We keep this option open as a fallback if `compiler-libs`
stability becomes a chronic problem.

---

## Option B — Upstream OCaml `compiler-libs` as the frontend ★ chosen

```text
.ml  →  ocamlc -bin-annot  →  .cmt
        →  zxc-frontend (OCaml, ~few hundred LOC)
        →  .cir.sexp
        →  Zig frontend bridge
        →  ANF  →  Core IR  →  Lowered IR  →  Zig codegen
        →  zig build-lib + sbpf-linker  →  program.so
```

### Pros
- **No parser, no HM written by us.** Both come from OCaml itself.
- **No subset drift possible.** `zxc-frontend` literally walks the
  real `Typedtree`; if we accept a node, OCaml accepts the same
  program.
- **Editor support out of the box.** `merlin`, `ocamlformat`,
  VSCode OCaml extension, etc. all work on user `.ml` files
  unmodified.
- Tiny OCaml footprint: a few hundred lines, only depends on
  `compiler-libs.common` (ships with the OCaml distribution).
- Compiler is **bilingual but small** in each language; each side
  does what it is good at.

### Cons
- Build-time dependency on a working OCaml toolchain
  (`ocamlc`, `ocamlfind`).
- `compiler-libs` `Typedtree` shape is not formally stable across
  major OCaml releases; we pin one version per phase.
- A small OCaml subprocess must be invoked per compilation. The
  cost is negligible (`< 100 ms` typical).

### Mitigations
- ADR-011 keeps the build single-driver (`build.zig`) so the
  bilingual nature is invisible to anyone running `zig build`.
- The `.cir.sexp` wire format is versioned (see
  `10-frontend-bridge.md` §3.2). Major bumps update both sides
  in one PR.
- A "single OCaml version per phase" policy is documented in
  ADR-010 and cross-referenced from `08-roadmap.md`.

### Why chosen
This is the only option that gives us OCaml's frontend without
inheriting OCaml's runtime. It matches every locked decision we
have made (ADR-001, -004, -005, -006, -009) and adds the smallest
possible new surface to maintain.

---

## Option C — Fork OxCaml (or upstream OCaml)

```text
oxcaml/oxcaml fork
  add: backend/bpf_codegen.ml
  add: runtime/bpf/*  (parallel to existing C runtime)
  patch: drop caml_call_gc on BPF target
  patch: stub exceptions on BPF target
  patch: stub threads on BPF target
  rebase: weekly on oxcaml/main (37k commits, very active)
```

### Pros (theoretical)
- Inherit Flambda 2 optimisations.
- Inherit Cfg backend infrastructure.
- Inherit OxCaml's `mode` / `local` / `unique` analysis.

### Cons (actual)
- **Optimisations do not transfer to BPF.** Flambda 2 unboxes
  around the OCaml ABI and the OCaml GC; both are absent on BPF.
  Cfg lowers for x86 / arm64; BPF needs a separate lowering.
  The `local` mode discriminates GC heap vs stack; on BPF there
  is no GC heap. None of the optimisations *target* BPF; they
  target what BPF lacks.
- **OxCaml is ~37k commits, ~970 branches, ~87% OCaml + ~9% C,
  and rebases onto upstream OCaml regularly.** Maintaining a
  fork at this scale is a full-time team workload. We are not a
  team. A fork that does not rebase is dead code; one that does
  rebase consumes most of the project's engineering budget.
- **Adding a BPF target inside OxCaml is hostile to upstream.**
  It would coexist with their Cfg backend, bypass `caml_call_gc`,
  stub exceptions and threads, and ship a parallel mini-runtime.
  None of that is welcome in their tree, so the fork divergence
  grows monotonically.
- **The OCaml C runtime is the very thing we want to discard.**
  Forking the compiler that ships that runtime puts us
  permanently in the position of "carrying everything we want to
  remove".

### Why rejected
Forking a 37k-commit active OCaml compiler to add a backend whose
defining feature is "no OCaml runtime" is the wrong shape of
project for this team. Every benefit of the fork either does not
apply to BPF or can be obtained more cheaply.

OxCaml's design ideas remain valuable as **reference material**,
not as imported code. We may read their papers, study their IR,
borrow their terminology; we do not import their source tree.

---

## Decision summary

| Criterion | A: self-write | B: compiler-libs ★ | C: fork OxCaml |
|---|---|---|---|
| Lines of code we write | high | low | catastrophic (rebase) |
| OCaml fidelity | best-effort | exact | exact |
| Build-time deps | none | OCaml + Zig | Jane Street build chain |
| Long-term maintenance | parser drift | minor `compiler-libs` API churn | permanent rebase war |
| Optimisations gained | none specific | none specific | many — but **all** assume OCaml runtime |
| Fits our ADRs | partly | fully | violates ADR-001/006/009 |

**Picked: B.** Documented in ADR-010 and the new pipeline lives
in `10-frontend-bridge.md`.

---

## When to revisit

This decision should be revisited if any of the following
becomes true:

1. `compiler-libs` introduces a breaking change every minor
   release for two consecutive releases. → consider option A.
2. The OCaml frontend bridge grows past ~1500 lines of OCaml.
   → consider splitting it into a `dune` project (revise
   ADR-011).
3. A specific BPF optimisation requires control over OCaml's
   `Lambda` or `Cmm` IR that `Typedtree` cannot express.
   → consider switching the cut from `Typedtree` to `Lambda`
   (still option B-shaped, just deeper).

Forking OxCaml does not appear in this revisit list. If a future
maintainer believes it should, they must first answer in writing:

- How do you keep current with 37k commits?
- Which Flambda 2 optimisation, specifically, transfers to BPF?
- Why is that optimisation cheaper to inherit-and-maintain than
  to write from scratch over our Core IR?

If those answers exist and are convincing, supersede ADR-009 and
this file.
