# 09 — Architectural Decision Records

> **Languages / 语言**: **English** · [简体中文](./zh/09-decisions.md)

Format: short, dated, immutable. Append new ADRs; do not edit old
ones — supersede them with a new entry.

> **Current-status note (2026-05-17).** This file preserves historical ADR
> text exactly where possible, but several early Solana build/runtime entries
> below are now **historical/superseded context only**. The current BPF build
> path is the direct `SOLANA_ZIG` / `solana-zig build-lib -target sbf-solana`
> route, which emits the final Solana-loadable `.so` **without**
> `sbpf-linker`. The current Solana runtime state is SDK-backed through the
> vendored `solana-program-sdk-zig` adapters and is validated through the
> Surfpool harness (`127.0.0.1:8899` / `127.0.0.1:8900`). Unless a newer
> addendum says otherwise, references below to `sbpf-linker`,
> `bpfel-freestanding`, or `solana-test-validator` should be read as
> historical background rather than current required setup.

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

> **Current-status note (2026-05-17).** The toolchain details in this ADR are
> preserved as historical P1 context. Current `omlz build --target=bpf` no
> longer runs the `bpfel-freestanding` + `sbpf-linker` chain; it uses the
> direct `SOLANA_ZIG` / `solana-zig build-lib` path and current local
> validation flows go through Surfpool rather than `solana-test-validator`.

### Context

A safer P1 would stop at "Zig source emitted, builds natively".
That defers the riskiest part of the project (BPF target chain) to
later, but also leaves it unproven for longer.

### Decision

P1 includes the BPF target chain end-to-end:

- `omlz build --target=bpf` invokes `zig build-lib -target
  bpfel-freestanding -femit-llvm-bc=…` followed by
  `sbpf-linker --cpu v2 --export entrypoint` (default; `v3` is an
  opt-in per ADR-013 Revised 2026-04-27).
- The resulting `.so` is loadable by `solana-test-validator`.
- Acceptance criterion is a working `examples/solana_hello.ml`.

> **Revised 2026-04-27** to reflect the actual toolchain shape
> validated against `DaviRain-Su/zignocchio`. The earlier wording
> ("`zig build-obj`", "`.o`") was a planning approximation; the
> chain that actually works is documented in `06-bpf-target.md` §2
> and locked in by ADR-012 / ADR-013 / ADR-014.

### Scope discipline

To keep this tractable, P1 covers **only**:

- the entrypoint shim,
- a return value of `0`,
- no syscalls, no account parsing, no CPI.

Everything else Solana-shaped is P3.


### Revised 2026-04-28 — P1 outcome and reproducibility

P1 completed the endpoint described above using the revised `.so` chain:
`examples/solana_hello.ml` builds with `omlz build --target=bpf`, deploys
through the Solana acceptance harness, and invokes successfully with the
minimal return-0 entrypoint. The G13 reproducibility check also passed for
that artifact: two consecutive BPF builds of `examples/solana_hello.ml`
were byte-identical (`diff_exit=0`).

This does **not** expand the BPF acceptance surface beyond the minimal
entrypoint. First-class closure code pointers, syscall bindings, account
input decoding, and richer Solana APIs remain outside P1.

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

No `OCamlBackend` is shipped, even as a stub. The earlier compile-only
placeholder under `src/backend/` was removed; reintroduce one only when
a real OCaml backend is scheduled.

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

- Programs cannot allocate beyond the arena's buffer. Native entry programs
  use a 32 KiB buffer; BPF entry programs use a 3 KiB stack-bounded buffer so
  the loader entrypoint stays below SBF's 4 KiB stack-frame limit.
- Multi-arena schemes (per region, per call) are a P4 refinement
  and do not require Core IR changes.


### Revised 2026-04-28 — as-built arena and closure boundary

The P1 runtime arena is the caller-owned static-buffer bump allocator in
`runtime/zig/arena.zig`: `fromStaticBuffer`, aligned checked `alloc`, and
`reset`. It does not own memory and has no free list or per-object lifetime.

Recursion lowered into two practical shapes during P1: top-level and
non-escaping recursive helpers use direct arena-threaded functions, while
escaping first-class closures use arena-allocated closure records for the
interpreter/native path. BPF support for escaping closure code pointers is
not a P1 acceptance guarantee; the mission observed a
`Relocations found but no .rodata section` linker failure for that shape,
so P2/P3 must either lower those calls directly, provide a linker-supported
rodata anchor, or restrict the BPF subset by ADR.

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


### Revised 2026-04-28 — enforced P1 harness and BPF byte check

P1 made the invariant executable: `zig build test` runs a determinism
property over the examples/UI corpus, comparing interpreter output with the
hosted Zig native backend. Arithmetic semantics were pinned to signed 64-bit
wrap for `+`, `-`, `*`, truncating division/remainder, and the stable
`ZXCAML_PANIC:division_by_zero` marker for zero divisors.

BPF is checked separately: semantic acceptance goes through the Solana
harness, and G13 byte reproducibility was recorded as PASS for
`examples/solana_hello.ml` on 2026-04-28. Full value-level BPF equivalence
for richer programs remains future work.

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
zig build-lib -target bpfel-freestanding -femit-llvm-bc
 ↓
sbpf-linker --cpu v2 --export entrypoint    (or --cpu v3 opt-in; ADR-013)
 ↓
Solana BPF .so
```

> **Historical pipeline note (2026-05-17).** The diagram above captures the
> P1/Pβ bridge shape. The current production path skips the bitcode +
> `sbpf-linker` stage and invokes direct `SOLANA_ZIG` /
> `solana-zig build-lib -target sbf-solana ...` to emit the final `.so`.

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

---

## ADR-012 — `sbpf-linker` is a build-time dependency, version pinned

**Date:** 2026-04-27
**Status:** Accepted
**Supersedes:** the implicit assumption in earlier drafts of
ADR-003 / `06-bpf-target.md` that "`zig build-obj`" alone produces
a Solana-loadable artefact.

> **Current-status note (2026-05-17).** This ADR is preserved as historical
> record for the earlier bitcode + linker chain. It is **superseded for
> current day-to-day builds** by the direct `SOLANA_ZIG` / `solana-zig
> build-lib -target sbf-solana` path, which emits the final Solana-loadable
> `.so` without `sbpf-linker`. Keep the text below as toolchain history, not
> as the current required/default dependency list.

### Context

While preparing the spike β preflight (BPF toolchain verification)
we cross-checked our planned chain against the working Zig→Solana
SDK at `github.com/DaviRain-Su/zignocchio`. The verified chain
has two steps, not one:

1. `zig build-lib … -femit-llvm-bc` (LLVM bitcode out).
2. `sbpf-linker --cpu v2 --export entrypoint` (SBPFv2 ELF
   `.so` out, accepted by Solana's loader; `v3` is opt-in per
   ADR-013 Revised 2026-04-27).

Stock `lld` does not produce a `.so` Solana's loader will accept:
the Solana ELF layout, the SBPF instruction set version
(SBPFv0/v1/v2/v3), and the symbol-export semantics differ from
generic eBPF. `sbpf-linker` is the linker that bridges these.

`sbpf-linker` is maintained at
`github.com/blueshift-gg/sbpf-linker` and is published on crates.io
as `sbpf-linker`.

### Decision

- `sbpf-linker` is a **build-time dependency** of `omlz`. It is
  required to produce a BPF artefact; it is not required to
  *run* a deployed BPF program.
- The pinned version for P1 is **`sbpf-linker 0.1.8`** (crates.io)
  with a fallback git-pin to a specific commit on `master` if a
  bug-fix-only newer version is required.
- The `omlz` build (`build.zig`) does **not** install
  `sbpf-linker`; it requires the binary on `PATH` and prints a
  diagnostic with install instructions if absent.
- CI installs it via `cargo install sbpf-linker --version 0.1.8`
  (or, if pinning to a commit becomes necessary, `cargo install
  --git https://github.com/blueshift-gg/sbpf-linker --rev <sha>`).

### Reasons

- We are not in a position to write a Solana-aware BPF linker;
  `sbpf-linker` is the only viable answer in 2026-04 and has a
  sufficient maintenance posture (active commits, a published
  crate, used by other Solana tooling).
- Pinning a *version* (and a fallback commit) gives us
  reproducible builds and a single coordinate to update when
  upstream changes.
- Keeping it off `build.zig`'s install path avoids the
  `cargo` boot-strapping rabbit hole; `zig build` remains the
  single driver per ADR-011, and `cargo install` is a one-time
  developer setup step like installing `solana-cli`.

### Consequences

- `omlz`'s install instructions list four prerequisites:
  `zig 0.16.x`, `ocaml 5.2.x` (with `compiler-libs`),
  `sbpf-linker` (pinned), and `solana-cli`.
- Upgrading `sbpf-linker` requires (a) a CI run, (b) re-running
  the BPF acceptance test, and (c) an addendum to this ADR with
  the new version coordinate. We do not silently float on
  `master`.
- If `sbpf-linker` ever breaks compatibility with our generated
  bitcode, we treat that as a P0 issue: report upstream, pin the
  last working version, and consider whether the bitcode shape is
  what should change instead.

### Revised 2026-04-27 — macOS LLVM 20 dlopen prerequisite

Spike β (`docs/preflight-results-spike-beta.md`) found that the
pinned `sbpf-linker 0.1.8` panics at runtime on stock macOS with:

```
sbpf-linker: unable to find LLVM shared lib
```

unless an LLVM 20 dynamic library is reachable via
`DYLD_FALLBACK_LIBRARY_PATH`. The cause:

- `sbpf-linker 0.1.8` depends on `aya-rustc-llvm-proxy 0.10.0`,
  which `dlopen`s the first `libLLVM*` it finds in
  `LD_LIBRARY_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`, or any `lib/`
  adjacent to a `PATH` entry.
- A stock macOS + Homebrew environment contains no such library
  by default; Homebrew Rust links against `llvm@21`'s
  `libLLVM.dylib`, but `sbpf-linker 0.1.8` was built against the
  LLVM 20 ABI.

**macOS workaround** (required to use `sbpf-linker 0.1.8`):

```sh
brew install llvm@20
export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix llvm@20)/lib"
```

**Linux note**: most distros ship a `libLLVM-20.so` discoverable
via the system linker; if not, set
`LD_LIBRARY_PATH=/path/to/llvm-20/lib` to the equivalent
directory.

This dependency is **transitive on `aya-rustc-llvm-proxy`**, not
something we control. If a future `sbpf-linker` release removes
or changes it (e.g. statically links LLVM), this revision note
is updated accordingly.

The `sbpf-linker = 0.1.8` pin itself is unchanged; only the
documented prerequisites grow. `06-bpf-target.md` §6 now carries
the macOS prerequisite block, and §8 carries a corresponding
troubleshooting row.


### Revised 2026-04-28 — operational warning noise and objdump path

P1 workers repeatedly observed `sbpf-linker 0.1.8` on macOS printing many
lines of the form `unable to open LLVM shared lib ... .a: dlopen failed`
while still linking successfully. These are benign archive-probe warnings
from the LLVM proxy when the final process exit code is 0 and the `.so` is
valid; they should not be treated as failure by CI.

Manual inspection on Homebrew macOS may also require the full LLVM tool path,
for example `/opt/homebrew/opt/llvm@20/bin/llvm-objdump`, because
`llvm-objdump` is not necessarily on `PATH`.

---

## ADR-013 — Solana SBF version is pinned at `v3` for P1

**Date:** 2026-04-27
**Status:** Accepted

> **Current-status note (2026-05-17).** This ADR preserves the historical
> `sbpf-linker --cpu` discussion so the evolution from P1 planning to the
> revised v2 addendum remains visible. Current operational guidance should use
> the direct `solana-zig` route documented in `06-bpf-target.md`; the
> `sbpf-linker --cpu ...` commands below are historical/superseded context,
> not a current required linker step.

### Context

Solana's BPF flavour has versioned. Roughly:

- **SBPFv0** — the original, very restricted (no calls, no shifts,
  …). Now legacy.
- **SBPFv1 / v2** — intermediate; broader instructions but still
  loader-restricted.
- **SBPFv3** — current default for new programs in 2026; supports
  the instructions LLVM normally emits.

`sbpf-linker` exposes `--cpu v0|v1|v2|v3`. zignocchio uses
`--cpu v3`.

### Decision

P1 pins the SBPF version at **`v3`** for all BPF builds.

- `omlz build --target=bpf` always invokes `sbpf-linker --cpu v3`.
- Programs that must run on older runtimes (rare in 2026, but
  conceivable for legacy chains) are explicitly **out of scope**
  for P1.

### Reasons

- v3 is what `solana-test-validator` and modern Solana mainnet
  loaders accept by default.
- Older versions impose instruction restrictions that LLVM does
  not honour without target-specific options; staying on v3 means
  we are not fighting the toolchain.
- A single version gives us one set of acceptance tests, one set
  of expected behaviours.

### Consequences

- Programs compiled by P1 will not run on legacy SBPF runtimes.
  This is acknowledged and accepted.
- If a future phase needs to ship multi-version support, the CLI
  flag `--sbpf-version` is reserved for that purpose.

### Revised 2026-04-27 — default is `v2`, `v3` is opt-in

Spike β (`docs/preflight-results-spike-beta.md`) verified the BPF
toolchain end-to-end against `DaviRain-Su/zignocchio`. Reading
zignocchio's `build.zig` and `AGENTS.md` revealed a fact that the
original ADR-013 misread: **zignocchio uses `--cpu v2`**, not
`--cpu v3`. The relevant `build.zig` comment is verbatim:

> `v2: No 32-bit jumps (Solana sBPF compatible)`

Empirically, the `hello.so` we built with `--cpu v2` was deployed
to `solana-test-validator` 3.1.12 and executed correctly
(107 compute units, `status: Ok`). v2 is what mainnet validators
default to today; v3 introduces newer features (e.g. static
syscalls) that require feature-gate activation and are not
universally accepted yet.

Therefore, this ADR is revised:

- **Default SBPF target is `v2`.** `omlz build --target=bpf`
  invokes `sbpf-linker --cpu v2 --export entrypoint`.
- **`v3` remains a documented opt-in path.** A CLI flag
  `--sbpf-version=v3` (or equivalent env var) lets users who
  explicitly need v3 features select it. P1 ships v2 only and
  has no acceptance test for v3; the v3 path is reserved, not
  validated.
- The original v3 wording above is preserved as historical
  record per the ADR convention; this addendum is the
  authoritative current statement.

Cascade applied in the same change-set: `06-bpf-target.md`,
`zignocchio-relationship.md`, `01-architecture.md`, `README.md`,
and the Chinese mirrors of all of the above were updated from
`--cpu v3` / `SBPFv3` to `--cpu v2` / `SBPFv2` (with `v3` noted
as the opt-in alternative where the doc context warrants).


### Revised 2026-04-28 — P1 acceptance validated on v2

The ADR title and original body remain historical. The authoritative P1
state is the 2026-04-27 revision plus the completed acceptance evidence:
`omlz build --target=bpf` used `sbpf-linker --cpu v2 --export entrypoint`,
and the Solana harness validated that v2 artifact. `--cpu v3` remains an
opt-in, unvalidated path in P1 and must not become the default without a new
ADR addendum and acceptance run.

---

## ADR-014 — Reuse `zignocchio` as inspiration only (Way A)

**Date:** 2026-04-27
**Status:** Accepted

### Context

`github.com/DaviRain-Su/zignocchio` is a working Zig→Solana SBF
SDK. Its scope materially overlaps with what ZxCaml's `runtime/`
will eventually need: an arena allocator, a BPF entrypoint
deserialiser, syscall bindings (via MurmurHash3-32), AccountInfo
parsing, PDA / CPI helpers, and litesvm/surfpool/mollusk test
harnesses.

Four strategies were considered for "using" zignocchio:

- **A.** Read it for ideas; ZxCaml writes its own runtime.
- **B.** Add it as a `git submodule` or `build.zig.zon` dep;
  generated code calls into its SDK.
- **C.** Vendor selected files (entrypoint, syscalls, allocator)
  into `runtime/zig/` with attribution.
- **D.** Fork it and maintain a ZxCaml-flavoured copy.

### Decision

We adopt **Way A**: zignocchio is **inspirational reference
material**. We may read its source freely; we **do not import its
code** into this repository.

This is the same posture ADR-009 takes toward OxCaml.

### Reasons

- **Consistency with the project's other "no fork, no vendor"
  decisions.** ADR-009 rules out forking OxCaml. The same logic
  applies here: a fork or vendor implies maintenance ownership of
  code we did not write.
- **License hygiene.** Importing code carries a license
  obligation; "read for ideas, write our own" carries none.
- **Scope independence.** zignocchio is positioned as a
  hand-written-Zig SDK for Solana developers. ZxCaml is a
  compiler whose generated code happens to also need that SDK
  surface. Coupling them couples our roadmap to theirs.
- **Smaller surface to keep current.** A vendored copy goes
  stale; a submodule pin requires us to track upstream. Reading
  for ideas costs nothing to keep current — we re-read when we
  need an idea.

### What this allows

- Reading zignocchio's source to learn how an SBPF (v2 by
  default; v3 opt-in) entrypoint is correctly written.
- Re-deriving its design (BumpAllocator → our `arena.zig`,
  syscall MurmurHash3-32 helper → our P3 `runtime/zig/syscalls.zig`)
  in our own code, with our own naming and error story.
- Citing it as the source of a non-obvious idea (e.g. the Zig
  0.16 low-address const-array workaround documented in
  `06-bpf-target.md` §4).

### What this forbids

- Copy-pasting source files from zignocchio into `runtime/zig/`
  or anywhere else in this repository.
- Adding zignocchio as a build dependency (submodule, zon, vendor
  directory).
- Forking it under the ZxCaml org.

### Relationship table

| Source | Our posture | ADR |
|---|---|---|
| OCaml `compiler-libs` | Used as a library at build time | ADR-010 |
| OxCaml | Inspirational reading only | ADR-009 |
| zignocchio | Inspirational reading only | ADR-014 |
| `sbpf-linker` | Build-time tool dependency, pinned | ADR-012 |
| `solana-cli` | Developer-time tool dependency | (implicit) |

### Consequences

- ZxCaml's `runtime/zig/` will, by P3, contain code that looks
  *very similar* to parts of zignocchio. This is expected: there
  is one correct way to deserialise the Solana BPF input buffer
  and one ergonomic way to write a bump allocator. Convergent
  evolution is fine; copy-paste is not.
- See `docs/zignocchio-relationship.md` for the longer narrative
  of what we learned from reading it and how that shaped P1.

---

## ADR-015 — Controlled mutable primitives (`array` / `for` / `ref`)

**Status:** Accepted (options B / R9.2 and C / R10; option D landed earlier; sub-option B.2 remains deferred)
**Date:** 2026-05-12

> **Status note (R9.2, 2026-05-12)** — Option B is landed for `int`
> element types: `[| ... |]` literals, `Array.get` / `a.(i)`,
> `Array.length`, `Array.set` / `a.(i) <- v`, and `Array.make N init`
> where `N` is an `int` literal. Storage stays arena-backed and writes
> in place. Polymorphic / non-int element types and dynamic-size
> `Array.make` from non-literal `N` remain deferred to a follow-up
> (working name B.2).
>
> **Status note (R10, 2026-05-12)** — Option C is now **accepted**.
> Single-cell `ref` of `int` and `bool` is plumbed through the
> frontend, Core IR, ANF, interpreter, and Zig codegen with
> arena-allocated storage (one slot per `ref e`). `!r` and `r := v`
> compile to direct pointer load/store. The determinism oracle
> covers `ref` programs via interp/native parity. `--no-alloc`
> rejects every `ref e` site (`DX2-NOALLOC`).
>
> **Still deferred (R10):**
> - `ref` of unsupported element types: `string`, `record`, `list`,
>   polymorphic. The frontend continues to reject these with
>   `E0013` ("this `ref` element type is not part of the ZxCaml
>   subset (R10)").
> - `ref` aliasing across function boundaries (single cell only;
>   sharing a `ref` through a closure or returning one is not
>   currently exercised and remains untested surface).
> - Other mutation forms — `setfield` outside `AccountFieldSet`,
>   instance-variable writes, override expressions — keep E0013
>   defensively.
> - Wire 1.5 freezes the new `ref-make` / `ref-get` / `ref-set`
>   sexps (see `docs/wire-compat.md`).
> - Sub-option B.2 (dynamic-size `Array.make` and non-int element
>   types) is still future work.
>
> **Status note (R11.5, 2026-05-12)** — Match scrutinee and
> `let`-destructure forms are no longer restricted to atom-shaped
> expressions. `match !cur with ...`, `match foo () with ...`,
> `match (if c then a else b) with ...`, and `let (a, b) = <expr>
> in ...` are accepted by the frontend via a synthetic
> `__zxc_match_scrut_<n>` binding lift. The `match`/`ref-get`
> deferred item is resolved; `tests/ui/ref_option.ml` is restored.

### Context

The current subset (`src/frontend/zxc_subset.ml`) rejects all of
OCaml's primary mutation surface: `Texp_array` (E0019),
`Texp_for` / `Texp_while` (E0017), and `ref` / `:=` / `!` (E0013).
This fit P1–P9 because the arena model (ADR-005, ADR-007) and the
determinism invariant (ADR-008) are easiest to reason about when
every value is immutable and every iteration is recursive.

Real OCaml programs lean on bounded mutation: fixed-size `int`
buffers, `ref` accumulators, counted `for` loops. Porting such a
program to ZxCaml today forces a `let rec` rewrite even when the
original was already verifier-friendly (stack-bounded loop, no
escape, no GC).

This ADR re-opens a small, controlled slice that fits the arena
model, the BPF verifier's preference for bounded loops, the
`no_alloc` checker (P3), and the determinism oracle (ADR-008).

### Options considered

- **A** — Status quo — keep the full ban on `array`, `for`, `while`,
  and `ref`. Programs continue to use `let rec` and immutable data.
- **B** — Bytes-style fixed-size arrays — allow a `bytes`-like
  `array` of `int` / `u8` whose length is fixed at allocation time,
  arena-backed, no GC objects as elements.
- **C** — Arena-allocated `ref` cells — accept OCaml's `ref` / `:=`
  / `!` but lower it to a one-slot arena allocation; reads and
  writes become explicit load/store on that slot.
- **D** — `for` / `while` as syntactic sugar — accept the surface
  syntax and desugar at the frontend bridge into the existing
  `let rec` tail-call lowering (P8). The runtime sees no new IR.

### Decision

Adopt **D + B + C** in that order:

1. **D first.** Desugar `for` / `while` to tail-recursive helpers
   at the frontend bridge: zero new Core IR, zero new runtime, no
   wire bump. Loop body purity is preserved because the loop
   variable is bound by recursion, not by mutation.
2. **B next.** Add a `Bytes`-shaped fixed-size mutable array of
   `int` / `u8` only. Length is fixed at allocation, storage is
   arena-allocated (ADR-005, ADR-007), elements never carry
   tracked pointers. Verifier sees bounded indexing; `no_alloc`
   sees a visible allocation site.
3. **C (R10, accepted).** Accept `ref` cells with `int` / `bool`
   element type as a single-slot arena allocation. The
   interpreter models the slot explicitly; the Zig backend emits
   a single pointer-load/store per `!r` / `r := v`. The
   determinism oracle treats interp and native as equivalent on
   ref-using programs (ADR-008). The "values are immutable"
   invariant is preserved everywhere else: only `ref` cells (and
   the previously accepted array slots) carry mutation, and the
   mutation is visible at every site through the explicit
   `ref-make` / `ref-get` / `ref-set` Core IR nodes.

Option **A** is rejected: real Solana programs (escrow state,
fee accumulators, vote tallies) want bounded indexed buffers and
counted loops, and forcing every such program through `let rec`
increases the porting tax without making the output safer.

### Consequences

- Positive: ports of OCaml code with `for` loops and small mutable
  byte/int buffers stop hitting E0017 / E0019.
- Negative: the interpreter grows a mutable-array primitive that
  ADR-008 must keep in lockstep with the Zig backend; out-of-bounds
  access becomes a new panic class.
- Wire format impact: option **D** is zero wire bump. Option **B**
  adds `Earray_make` / `Earray_get` / `Earray_set` Core IR nodes,
  i.e. a minor bump from `1.2` to `1.3`, gated by
  `docs/wire-compat.md`. Option **C** (R10) adds `ref-make` /
  `ref-get` / `ref-set` sexps, bumping the wire to `1.5`.
- `no_alloc` impact: `Earray_make` is an allocation site;
  `--no-alloc` rejects it. `get`/`set` and the `for`/`while`
  desugaring are allocation-free. `ref-make` is also an
  allocation site; `--no-alloc` rejects it with
  `DX2-NOALLOC` ("ref cell allocation is not allowed in a
  no_alloc context"). `ref-get` and `ref-set` are
  allocation-free.
- Codegen complexity: D reuses P8's tail-call lowering; B lowers
  to an arena bump plus bounds-checked load/store. No new BPF
  intrinsic.
- Documentation impact: update `02-grammar.md` (surface forms),
  `04-memory-model.md` (arrays live in the arena), and this ADR.

### Acceptance criteria for implementation

- [ ] Frontend accepts `for i = a to b do e done` and
      `while c do e done` and emits a desugared `let rec` Core IR.
- [ ] Frontend accepts `Array.make n x` / `Array.get` / `Array.set`
      for `int` and `u8` element types only; other element types
      keep raising E0019.
- [ ] Wire format bumped to `1.3` with a backwards-read shim for
      `1.2` until the next phase seal.
- [ ] Interpreter and Zig backend implement the new array ops and
      pass the determinism oracle on `examples/for_loop.ml` and
      `examples/byte_buffer.ml`.
- [ ] `no_alloc` rejects `Array.make` under `--no-alloc`; existing
      `--no-alloc` examples keep passing.
- [ ] Mollusk SVM test covers a program that uses a fixed-size
      byte buffer to assemble CPI instruction data.
- [ ] BPF byte-reproducibility (G13, ADR-008) covers the new
      examples.

### Alternatives rejected

- **A (status quo)** — rejected: porting tax is now the largest
  single subset complaint; keeping the ban indefinitely turns
  "subset of OCaml" into "different language".
- **C as "rejected for now"** — superseded by R10, which accepted
  option C for `int` / `bool` element types only (see status note
  above). The original concern (duplicates B at length 1,
  complicates the interpreter, weakens determinism) is addressed
  by limiting the element types and by keeping interp/native in
  lockstep through the determinism oracle.

---

## ADR-016 — Multi-file modules

**Status:** Proposed
**Date:** 2026-05-12

### Context

Today `omlz` accepts exactly one `.ml` file per build. The bundled
stdlib (P5 / P7) is the only multi-source surface, and it is
special-cased inside the frontend bridge rather than treated as a
real module system. There is no `open Foo` that points at another
user-written file, no per-file `.cmt` joining, and no notion of a
"project" in the sense `dune` uses.

This is a real limitation. The Mollusk suite currently has 27
integration tests, and several of them duplicate helper code
verbatim because there is no way to factor it into a shared file.
Real Solana programs (escrow + vault + token + admin) want at
least one shared `Types.ml` plus per-instruction files.

ADR-010 commits us to using upstream OCaml `compiler-libs` as the
frontend, and ADR-011 commits us to `build.zig` as the only build
driver with no `dune`. Any multi-file story has to live inside
those constraints: it must be drivable from a single `zig build`
step and it must reuse `ocamlc -bin-annot` cleanly.

### Options considered

- **A** — Stay single-file. Users keep concatenating manually or
  inlining helpers.
- **B** — Frontend-level `open Foo` — allow `open Foo` to refer
  to another `.ml` file in the same directory; the OCaml frontend
  bridge type-checks the dependency closure, concatenates the
  resulting `Typedtree`s in topological order, and emits a single
  sexp. No on-disk `.cmi` cache, no incremental compilation.
- **C** — Full `dune`-style project — adopt a `dune-project`
  file, per-library directories, dependency resolution, `.cmi`
  caching. This would supersede ADR-011's "no `dune`" rule.

### Decision

Adopt **option B**. The frontend bridge is extended to accept a
list of `.ml` files in dependency order (or, equivalently, an
entry file plus a project root from which `open Foo` resolves to
`./foo.ml`). The frontend type-checks all of them with
`compiler-libs`, joins the resulting `Typedtree`s, and emits a
single sexp that the Zig pipeline consumes unchanged from the
single-file shape, save for a new optional `file_id` annotation
on every node.

This is the smallest change that unblocks `open Types`, shared
helpers, and per-instruction files, while keeping ADR-011 intact
(no `dune`) and the existing wire contract stable except for that
additive annotation.

Option **A** is rejected because the cost of duplicating helpers
is now visible in the Mollusk suite and in the SPL examples
(ADR-014 cascade). Option **C** is rejected as out of proportion:
adopting `dune` would mean two build systems, a transitive opam
footprint, and a direct conflict with ADR-011, none of which is
justified by the current corpus size.

### Consequences

- Positive: `open Foo` works for user code. Shared `Types.ml` and
  multi-file Solana programs become natural. The Mollusk suite
  can deduplicate its helpers.
- Negative: there is no incremental compilation; every `omlz
  build` re-type-checks the full closure. Acceptable while the
  corpus is small.
- Wire format impact: each Core IR node grows an optional
  `file_id` field so source maps (P9 SRCMAP, see ADR-008 and
  `docs/source-map.md`) can attribute spans to the right file.
  This is an additive minor bump on top of whatever ADR-015
  lands on.
- `no_alloc` checker impact: none. `--no-alloc` operates on Core
  IR after the closure is joined, so it sees the same shape it
  sees today.
- Codegen complexity: zero. The Zig pipeline still reads one
  sexp, lowers one Core IR, and emits one artefact.
- Documentation impact: `07-repo-layout.md` documents the
  expected per-project file layout; `10-frontend-bridge.md`
  documents the closure-resolution rules and the
  `--entry` / `--root` CLI flags; `02-grammar.md` notes that
  `open Foo` resolves to `./foo.ml`.

### Acceptance criteria for implementation

- [ ] `omlz build --entry main.ml` resolves `open Foo` to
      `./foo.ml`, type-checks the closure, and produces the same
      sexp shape as today plus a `file_id` annotation.
- [ ] Cycles in `open` are reported as an `E01xx` diagnostic at
      the frontend (not as an OCaml type error).
- [ ] Wire format bumped (minor) to carry `file_id`; old wire
      readers continue to accept the new sexp (`file_id`
      optional).
- [ ] Source-map sidecars (`docs/source-map.md`) include the
      file path for every PC, and `omlz unmap` resolves PCs into
      `file:line:col` across files.
- [ ] Mollusk suite has at least one test that uses a shared
      `Types.ml` between two instruction files; previously
      duplicated helpers are removed.
- [ ] Determinism oracle (ADR-008) runs across the multi-file
      examples.

### Alternatives rejected

- **A (single-file)** — rejected because the duplication cost in
  the Mollusk suite and the SPL examples is now concrete, and the
  porting tax on real Solana programs is no longer abstract.
- **C (full `dune` project)** — rejected because it directly
  contradicts ADR-011 and pulls in an `opam` footprint we have
  explicitly avoided. If multi-file ever grows into "real
  packages with separate compilation", we revisit ADR-011 and
  this ADR together; until then, option B is the smaller commit.

---

## ADR-017 — Float replacement strategy

**Status:** Proposed
**Date:** 2026-05-12

### Context

Solana BPF has no FPU; the SBPF instruction set (ADR-013) omits
floating-point. The ZxCaml subset therefore rejects every
`Texp_constant(float)` at the frontend (`zxc_subset.ml`, E0011).

The ban is correct, but it cuts off a large class of programs.
Real Solana code computes percentages, interest rates, slippage
bounds, AMM prices, and oracle weights. In Rust those use `u128`
fixed-point math or crates like `rust_decimal`. In our subset the
author writes `0.05`, hits E0011, and either gives up or
hand-rolls Q-format math without library support.

This ADR is about replacing — not relaxing — the float ban with a
sanctioned answer.

### Options considered

- **A** — Keep the ban with no replacement. Authors hand-roll
  fixed-point arithmetic on `int` / `u64`.
- **B** — Ship a bundled `Decimal` / `Fixed` module backed by
  integer Q-format (e.g. Q64.64 or signed Q63.64), with
  documented overflow and rounding semantics and a tested
  arithmetic surface.
- **C** — Accept `float` syntactically and lower it to fixed-point
  silently at the frontend. The user writes `0.05`; the compiler
  rewrites it to a Q-format integer pair.

### Decision

Adopt **option B**. Add a `Fixed` module (working name) to the
bundled stdlib, backed by signed Q64.64 stored as a pair of
`int64`s (or, more likely, a struct of two `u64`s). The module
exports `of_int`, `to_int`, `of_parts num den`, `add`, `sub`,
`mul`, `div`, `cmp`, plus saturating and checked variants. The
representation, rounding mode (truncation toward zero), and
overflow behaviour (panic on `mul` / `div` overflow, wrap on
`add` / `sub`, matching ADR-008's pinned arithmetic semantics)
are documented in `05-backends.md` so the interpreter and the
BPF backend cannot diverge.

Option **A** is rejected because the answer "hand-roll it" is the
opposite of what a strict OCaml subset should offer; the entire
point of the subset is to make safe BPF code easy to write, and
two programs that hand-roll their own Q-format will disagree on
rounding.

Option **C** is rejected as actively dangerous. Silently rewriting
`0.05` into Q64.64 fixed-point would mean ZxCaml's interpreter and
the reference OCaml compiler (ADR-001's "must also be accepted by
the reference OCaml compiler") disagree on the value of every
float literal. That breaks ADR-008's determinism invariant by
construction, and it ambushes anyone who reads OCaml semantics
into the program.

### Consequences

- Positive: real-world Solana math (rates, prices, percentages)
  becomes expressible without leaving the subset. The bundled
  module gives one canonical implementation, so two programs that
  multiply a rate by an amount cannot disagree on rounding.
- Negative: precision is bounded by Q64.64. Users who need more
  precision must drop to bigint-style code, which is not in scope
  for this ADR.
- Wire format impact: minimal. `Fixed` values are represented as
  two `int` Core IR nodes; no new IR shape is required. The
  module surface is a stdlib addition, not a wire change.
- `no_alloc` checker impact: `Fixed` is a pair of unboxed
  integers in the BPF lowering and a small tuple in the
  interpreter; on the BPF path it allocates nothing. The
  `--no-alloc` checker stays truthful.
- Codegen complexity: moderate. `Fixed.mul` and `Fixed.div`
  require 128-bit intermediate products. The Zig backend can
  emit `u128` arithmetic (which LLVM lowers for SBPF v2 per
  ADR-013); the interpreter does the same in software. A
  determinism test pins their equivalence.
- Documentation impact: a new `docs/stdlib-fixed.md` (or a
  section in an existing stdlib doc) describes the type, the
  rounding mode, and the overflow rules. `02-grammar.md` notes
  that float literals remain rejected.

### Acceptance criteria for implementation

- [ ] `Fixed.t` and its operations are exported from the bundled
      stdlib.
- [ ] Rounding mode and overflow semantics are documented in
      `05-backends.md` and tested in `inline_tests.zig` and the
      determinism oracle.
- [ ] Determinism oracle covers `Fixed.add`, `sub`, `mul`, `div`
      across edge cases (zero, negative, overflow boundary).
- [ ] At least one Mollusk example (e.g. an AMM-style swap with
      a fee rate) uses `Fixed` end-to-end and passes.
- [ ] `Texp_constant(float)` continues to raise E0011 with a
      diagnostic hint that points authors at the `Fixed` module.
- [ ] BPF byte-reproducibility check (ADR-008 / G13) covers a
      `Fixed`-using example.

### Alternatives rejected

- **A (keep ban, no replacement)** — rejected because the cost of
  "hand-roll Q-format math" lands on every author who needs a
  rate or percentage, and two authors will not agree on rounding.
- **C (silent lowering of `float`)** — rejected because it breaks
  ADR-001 (program must also be accepted by reference OCaml) and
  ADR-008 (interpreter and backend must agree); reference OCaml's
  `0.05` is an IEEE-754 binary64 value, not Q64.64, so the two
  semantics diverge by construction. Cross-reference: this is
  also why option C in ADR-015 (silent rewrites of `ref` cells)
  was rejected — silent semantic shifts away from upstream OCaml
  are out of bounds.
