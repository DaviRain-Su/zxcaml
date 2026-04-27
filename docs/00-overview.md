# 00 — Overview

## 1. What ZxCaml is

ZxCaml is a **compiler for an OCaml dialect** whose backend produces
Solana **BPF** object files via **Zig**.

Concretely:

- The **frontend** (lexer, parser, type system, module system) follows
  OCaml. We do not invent new syntax. Source files use `.ml`.
- The **backend** is new. It targets a flat, GC-free execution model
  suitable for Solana programs.
- The **glue** between them is a typed **Core IR** in **ANF**, which is
  the only stable contract between phases.

## 2. What ZxCaml is *not*

- **Not a new language.** No new keywords, no new file extension. If a
  feature is not in OCaml, it is not in ZxCaml.
- **Not an OCaml replacement.** We deliberately accept only a *subset*
  of OCaml. Effects, GADTs, first-class modules, `Obj.magic`, ctypes,
  and the official C runtime are out.
- **Not an opam consumer.** Existing opam packages will not "just
  work", because we do not reproduce the OCaml runtime
  representation. Reuse happens through:
  1. Writing a small native standard library in our subset, and
  2. **Zig FFI** for system / cryptographic primitives.
- **Not a general-purpose compiler in P1.** P1's only validated target
  is Solana BPF. Native binaries may fall out for free, but they are
  not a goal.

## 3. Project naming

| Thing | Name |
|---|---|
| Project / repo | `ZxCaml` |
| Source language | OCaml (subset) |
| Source file extension | `.ml` |
| Compiler driver binary | `omlz` (OCaml on Zig) |
| Core IR | "Core IR" (no fancy name; it's just typed ANF) |

## 4. Three cold showers (design constraints)

These are documented so that future contributors do not have to
re-discover them.

### 4.1 OCaml backend is **not** a viable ecosystem bridge

A common temptation is: *"compile our subset to OCaml's bytecode/native
backend and reuse opam libraries"*.

This fails because OCaml libraries depend on more than syntax: functor
applications, polymorphic variants, GADTs, effects, `Obj.magic`, C
stubs via ctypes, and the precise tagged-pointer / boxed-float
representation. Reproducing all of that is reproducing OCaml itself.

**Decision:** the OCaml backend is removed from the main path.
Ecosystem reuse goes through:

- a small native stdlib written in our subset, and
- **Zig FFI** for everything else.

The OCaml `ocaml` / `dune` toolchain may still be used **off-line** to
type-check our stdlib as a sanity oracle, since our subset is a true
subset.

### 4.2 Multiple backends and memory models are designed in, **not** built in P1

We design **trait-shaped** extension points (lowering strategy,
backend) so that future memory models (RC, GC, region) and future
backends do not require re-architecting. **In P1 only one of each is
implemented**: arena lowering, Zig backend, plus a tree-walk
interpreter for development.

### 4.3 "Pluggable memory model" is research-grade

Truly pluggable memory (arena / RC / GC / stack-only) interacts with
calling convention, closure representation, ADT layout, and the type
system. P1 does **one** model: **arena, fully inferred, hidden from
the user**. The Core IR carries a `Layout` field that today only
admits `Region::Arena`, but its presence is the extension point for
P4+ work on regions and ownership.

## 5. Locked Phase 1 decisions

| Decision | Value |
|---|---|
| Compiler host language | **Zig 0.16** |
| Source language | **OCaml subset** (see `02-grammar.md`) |
| Source file extension | `.ml` |
| Core IR shape | **ANF**, typed, layout-tagged |
| Memory model exposure | **Hidden**, fully inferred, arena-only |
| Primary target | **Solana BPF** (`bpfel-freestanding` via Zig) |
| P1 endpoint | A `.ml` program produces a `.o` that loads on `solana-test-validator` and returns 0 |

## 6. Out of scope (forever, or until explicitly re-opened)

- functors, first-class modules, GADTs, polymorphic variants
- effect handlers (OCaml 5.x)
- the OCaml C runtime, `Obj.magic`, ctypes
- garbage collection
- LSP, formatter, debugger
- non-BPF targets as a goal (they may incidentally work)
