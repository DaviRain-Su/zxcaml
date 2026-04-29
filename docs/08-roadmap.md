# 08 — Roadmap

> **Languages / 语言**: **English** · [简体中文](./zh/08-roadmap.md)

## 1. Phases

| Phase | Theme | Done when… |
|---|---|---|
| **P1** | MVP: OCaml subset → BPF `.so` | `examples/solana_hello.ml` deploys and returns 0 |
| **P2** | Subset expansion + match optimization | user ADTs, nested/guarded patterns, tuples, records, stdlib, and BPF closures |
| **P3** | Solana-shaped subset | account views, syscalls, CPI, SPL-Token example, no-alloc analysis, and IDL |
| P4 | Region inference | escape analysis, `Region::Region(id)`, optional stack allocation |
| P5 | Ecosystem reach | Zig FFI declarations, larger native stdlib subset |
| P6 (opt) | Self-hosting | rewrite `src/core/anf.zig` (and friends) in our subset |
| P7 (opt) | Formalisation | Core IR semantics, LLM/verifier surface |

Phases are **not** time-boxed in this document. They are scope-boxed.

## 2. Phase 1 — MVP

### 2.1 Scope (must)

- `zxc-frontend` (OCaml glue): drives `compiler-libs`, walks
  `Typedtree`, enforces the P1 subset
  (`10-frontend-bridge.md` §4), emits `.cir.sexp`.
- `frontend_bridge` (Zig): parses `.cir.sexp` into the `ttree`
  mirror.
- ANF lowering to Core IR with `Layout` annotations.
- `ArenaStrategy` lowering to Lowered IR.
- `ZigBackend` emitting `.zig` source.
- Tree-walk interpreter consuming Core IR.
- Runtime: `arena.zig`, `panic.zig`, `prelude.zig`,
  `bpf_entry.zig`.
- Stdlib: `option`, `result`, `list`.
- CLI: `omlz check / build / run` (see §2.3).
- Determinism property: interpreter ≡ Zig backend on the example
  corpus.
- Acceptance: `solana_hello.ml` deploys and returns `0` on
  `solana-test-validator`.

We deliberately do **not** include "write our own lexer / parser /
HM" in P1. Per ADR-010, that work is done by upstream OCaml.

### 2.2 Out of scope (must not)

- functor / module syntax beyond plain `let`s
- GADTs, polymorphic variants, effects
- mutation, exceptions, references
- LSP / formatter / debugger
- IDL / Anchor / CPI / syscalls beyond the entrypoint
- multi-file modules (one `.ml` source + bundled stdlib)
- non-BPF targets as a deliverable

### 2.3 CLI surface

```
omlz check <file>                  -- parse + typecheck, emit diagnostics
omlz check --emit=core-ir <file>   -- print Core IR to stdout (golden tests)
omlz run   <file>                  -- frontend → interpreter; print result
omlz build <file>
            [--target=bpf|native]  -- default: bpf
            [--backend=zig|...]    -- default: zig
            [-o <path>]            -- output object/exe
            [--arena-bytes=N]      -- runtime arena size
            [--keep-zig]           -- keep generated .zig under out/
omlz version
```

### 2.4 Internal milestones (suggested PR boundaries)

```
P1.0  Skeleton              build.zig (Zig 0.16) drives both OCaml and Zig steps;
                            `omlz --version`; arena util; diagnostics util.
P1.1  zxc-frontend MVP      Smallest OCaml program that loads a .cmt and prints
                            "ok"; wired into build.zig via ocamlfind.
P1.2  Subset walker         `zxc_subset.ml` rejects every Typedtree node
                            outside the §4 whitelist, with locations.
P1.3  Sexp serialiser       `.cir.sexp` for the accepted subset, version 0.1.
P1.4  Sexp parser (Zig)     `frontend_bridge` parses 0.1 into `ttree`.
P1.5  ANF lowering          ttree → Core IR with Layout fields.
P1.6  IR pretty-printer     Golden tests on `omlz check --emit=core-ir`.
P1.7  Interpreter           `omlz run hello.ml` returns Some 1.
P1.8  ArenaStrategy         Lowered IR.
P1.9  ZigBackend            Generates `.zig` that `zig build-exe` accepts natively.
P1.10 Runtime + entrypoint  BPF shim, arena, panic.
P1.11 BPF driver            `omlz build --target=bpf` produces a Solana-loadable .so.
P1.12 Solana harness        Deploy + invoke on solana-test-validator.
P1.13 Determinism suite     interpreter ≡ Zig native; BPF acceptance is separate.
```

The shape changed from the previous draft: P1.1–P1.4 used to be
"Lexer / Parser / Name resolution / Type inference" written in
Zig. Per ADR-010 those are now upstream OCaml plus a small glue.

Each milestone has at least one test (UI, golden, or integration).

### 2.5 P1 acceptance corpus

```
examples/hello.ml             - list head, ADT, match
examples/option_chain.ml      - chained Option.map / Option.bind
examples/result_basic.ml      - Result construction and pattern
examples/list_sum.ml          - recursive sum over a list
examples/solana_hello.ml      - BPF entrypoint returning 0
```

The first four run through the interpreter and the Zig backend
(native). The fifth runs through Zig BPF and `solana-test-validator`.

### 2.6 P1 release notes (2026-04-28)

P1 shipped the walking skeleton described by the ADR set
([ADR list](./09-decisions.md)): upstream OCaml `compiler-libs` produce
a versioned sexp (`0.4`), Zig parses that into Core IR, the interpreter
and native Zig backend execute the acceptance corpus, and the BPF path
builds `examples/solana_hello.ml` into a Solana-loadable `.so` via
`zig build-lib -femit-llvm-bc` plus `sbpf-linker --cpu v2`.

| Area | Worker commits |
|---|---|
| Skeleton, frontend subprocess, sexp bridge, Core IR, interpreter, native and BPF build path | [39fabc0](https://github.com/DaviRain-Su/zxcaml/commit/39fabc0), [eb5ca12](https://github.com/DaviRain-Su/zxcaml/commit/eb5ca12), [a1f139e](https://github.com/DaviRain-Su/zxcaml/commit/a1f139e), [b29f437](https://github.com/DaviRain-Su/zxcaml/commit/b29f437), [f1725e5](https://github.com/DaviRain-Su/zxcaml/commit/f1725e5), [e3f781f](https://github.com/DaviRain-Su/zxcaml/commit/e3f781f), [010289b](https://github.com/DaviRain-Su/zxcaml/commit/010289b), [c1014bb](https://github.com/DaviRain-Su/zxcaml/commit/c1014bb), [2fad318](https://github.com/DaviRain-Su/zxcaml/commit/2fad318) |
| Let bindings, option/result constructors, match, recursion/closures, lists, arithmetic, conditionals | [451ecca](https://github.com/DaviRain-Su/zxcaml/commit/451ecca), [e3dd63a](https://github.com/DaviRain-Su/zxcaml/commit/e3dd63a), [86f995d](https://github.com/DaviRain-Su/zxcaml/commit/86f995d), [287c093](https://github.com/DaviRain-Su/zxcaml/commit/287c093), [d9875be](https://github.com/DaviRain-Su/zxcaml/commit/d9875be), [9bb39ab](https://github.com/DaviRain-Su/zxcaml/commit/9bb39ab), [a52574c](https://github.com/DaviRain-Su/zxcaml/commit/a52574c), [bce8251](https://github.com/DaviRain-Su/zxcaml/commit/bce8251), [65cbce5](https://github.com/DaviRain-Su/zxcaml/commit/65cbce5), [4c715c2](https://github.com/DaviRain-Su/zxcaml/commit/4c715c2), [792c152](https://github.com/DaviRain-Su/zxcaml/commit/792c152), [382969c](https://github.com/DaviRain-Su/zxcaml/commit/382969c), [6b706de](https://github.com/DaviRain-Su/zxcaml/commit/6b706de), [31c044e](https://github.com/DaviRain-Su/zxcaml/commit/31c044e) |
| Determinism, golden tests, UI tests, Solana harness, diagnostics | [3e40be5](https://github.com/DaviRain-Su/zxcaml/commit/3e40be5), [cb817dc](https://github.com/DaviRain-Su/zxcaml/commit/cb817dc), [187f67b](https://github.com/DaviRain-Su/zxcaml/commit/187f67b), [afaa896](https://github.com/DaviRain-Su/zxcaml/commit/afaa896), [fca5bb5](https://github.com/DaviRain-Su/zxcaml/commit/fca5bb5), [2e61aa8](https://github.com/DaviRain-Su/zxcaml/commit/2e61aa8) |
| Acceptance corpus, CI, install docs, final docs sweep | [4ae4153](https://github.com/DaviRain-Su/zxcaml/commit/4ae4153), [533ef81](https://github.com/DaviRain-Su/zxcaml/commit/533ef81), [18c065e](https://github.com/DaviRain-Su/zxcaml/commit/18c065e), [e8b1124](https://github.com/DaviRain-Su/zxcaml/commit/e8b1124) |

Implemented in P1:

- CLI: `omlz check`, `omlz run`, and `omlz build --target=native|bpf`.
- Accepted user subset: single-binding `let` / `let rec`, one-argument
  lambdas, applications, `if`, `match`, integer/string constants,
  arithmetic/comparison primops, and the bundled option/result/list
  constructors.
- Runtime: static-buffer bump arena, panic/prelude helpers, native and
  BPF entry shims.
- Quality gates: interpreter ≡ native determinism over the corpus,
  Core IR golden tests, UI tests, Solana deploy/invoke harness, CI,
  and G13 BPF byte reproducibility documented as PASS in
  `06-bpf-target.md` §7.

Deferred to P2+ at the time of the P1 release:

- user-defined ADTs, records, tuples, nested constructor patterns,
  guarded match arms, exceptions-as-result helpers, mutation/ref, and
  modules/functors;
- first-class closures as a supported BPF acceptance shape (native and
  interpreter paths existed, but BPF code-pointer relocations needed a later
  design choice);
- Solana-shaped APIs beyond the entrypoint: account decoding, syscalls,
  CPI, IDL generation, and no-allocation analysis;
- region inference / multi-arena ownership work and any non-BPF
  deliverable target.

## 3. Phase 2 — Subset expansion + match optimization (2026-04-29)

**Status:** Implemented for the P2 milestone. P2 expanded the accepted OCaml
subset and kept the P1 BPF pipeline intact.

Implemented in P2:

- user-defined ADT declarations, including parameterized and recursive ADTs;
- nested constructor patterns and guarded `when` match arms;
- decision-tree match compilation with constructor dispatch and guard fallthrough;
- tuple construction, tuple patterns, and `fst` / `snd` projection helpers;
- record declarations, construction, field access, record patterns, nested
  records, parameterized records, and functional record update;
- stdlib expansion for `List`, `Option`, and `Result`;
- first-class closure hardening for the BPF path;
- examples covering ADTs, patterns, tuples, records, stdlib use, and closures.

P2 did **not** add new external toolchain dependencies. The wire format is
currently **sexp `0.7`**: `0.5` added type declarations, `0.6` added nested
patterns and guards, and `0.7` added tuple/record nodes.

Deferred to P3+:

- Solana-shaped APIs beyond the entrypoint: account decoding, syscalls, CPI,
  IDL generation, and no-allocation analysis;
- modules/functors, exceptions, mutable state, arrays, objects, GADTs,
  polymorphic variants, and effects;
- region inference / multi-arena ownership work and any non-BPF deliverable
  target.

## 4. Phase 3 — Solana-shaped subset (2026-04-29)

**Status:** Implemented for the P3 milestone. P3 shifted the project from a
language subset that can compile to BPF into a Solana runtime-aware compiler
slice.

Implemented in P3:

- built-in `account` values backed by zero-copy views over the Solana BPF input
  buffer;
- runtime syscall bindings using MurmurHash3-32 dispatch addresses;
- CPI records and helpers (`instruction`, `account_meta`, `invoke`,
  `invoke_signed`), PDA helpers, and return-data bindings;
- account data/lamports mutation support through the zero-copy account buffer;
- SPL-Token transfer instruction encoding and a Tokenkeg transfer acceptance
  example;
- structured error-code conventions;
- `omlz check --no-alloc`, a conservative Core IR allocation analysis;
- `omlz idl`, a one-shot ZxCaml JSON IDL emitter;
- BPF entry arena increased from 1 KiB to 32 KiB;
- examples for account/syscall, syscall-only, simple CPI, and SPL-Token flows;
- CI smoke checks for `no_alloc` and IDL JSON emission.

The wire format is currently **sexp `0.9`**: `0.8` added account/syscall
references, and `0.9` added CPI type/function references.

For the operational guide, see [`11-solana-p3.md`](./11-solana-p3.md).

## 5. Phase 4 — Region inference

- Add `Region::Region(id)` to the IR.
- Escape analysis pass on Core IR.
- `RegionStrategy` (still arena-based, but per-region).
- Optional stack allocation for proven-non-escaping locals.
- No user-facing syntax change in P4; this is purely an
  optimisation.

## 6. Phase 5 — Ecosystem reach

- `external` declarations bound to Zig functions.
- Tooling to vendor a Zig package as an `omlz` dependency.
- Larger native stdlib (`Map`, `Set`, basic crypto wrappers).
- Anchor-style IDL emission.

## 7. Phase 6 — Self-hosting (optional)

- Rewrite `src/core/anf.zig` and `src/core/pretty.zig` in our subset.
- Run the rewritten code through `omlz` and link the resulting object
  back into the compiler.
- This is the dogfooding gate; not required for the project to ship.

## 8. Phase 7 — Formalisation (optional)

- A small-step semantics for Core IR (paper or Lean / Coq).
- A surface for LLMs / verifiers to consume Core IR (S-expression
  serialisation? deterministic JSON?).
- Property tests: refinement between Core IR and Lowered IR.

## 8a. Phase PX — Multi-target expansion (optional, gated)

**Status:** Not scheduled. Not on the critical path. This phase
exists only to give "what about other targets?" a defined shape so
it does not creep into earlier phases.

### Context

Because the Zig backend emits `.zig` source, the Zig toolchain can in
principle lower to any of its supported targets (`aarch64`, `x86_64`,
`riscv*`, `wasm32`, `nvptx*`, `amdgcn`, …; see `06-bpf-target.md`
§10 for the long list and the cold shower that goes with it).

This does **not** mean those targets are supported. PX is the place
where a target moves from "the toolchain can technically reach it" to
"ZxCaml supports it".

### Activation gate

PX activates only when **all** of the following are true for a
specific target:

1. **A concrete use case exists**, named in writing, with at least
   one champion who will use the output.
2. **An owner exists** for the runtime shim work for that target
   (entrypoint, panic, memory plan, calling convention to user
   code).
3. **The BPF-shaped language constraints fit the use case**, or a
   relaxation is proposed as a new ADR (e.g. "WASM target may use
   the host allocator instead of a single arena").
4. **A CI lane and an acceptance example are added** as part of the
   same change.

If any of the four is missing, the target stays out. Speculative
multi-target support is a leak, not a feature.

### Plausible candidates (illustrative, not committed)

- **`wasm32-freestanding`** — for an in-browser Solana program
  simulator. Gate: who is the user? what tool consumes the output?
- **`x86_64-linux`** — for fuzzing / property testing harnesses
  that want native speed and crash dumps. Gate: a real fuzzing
  harness, not "wouldn't it be nice".
- **`riscv64-linux` / embedded BPF (Linux kernel eBPF)** — outside
  Solana's BPF flavour but adjacent. Gate: a specific eBPF program
  someone needs to ship.

### Note: x86 / arm native is **not** a PX candidate

If your goal is "I want to run my ZxCaml program on x86 / arm for
local testing or fuzzing", you do **not** need PX, because every
ZxCaml program is by construction a valid OCaml program (ADR-001)
and the developer's machine already has an OCaml toolchain
installed for `omlz`'s frontend bridge (ADR-010). Just compile the
same `.ml` with `ocaml` (or OxCaml) and run it. See the README
section "Native execution comes for free" and
`docs/oxcaml-relationship.md` for the full discussion.

PX is reserved for targets where this trick does **not** apply —
i.e., targets where neither upstream OCaml nor `omlz` produces a
runnable binary today, and where someone has a concrete reason to
make `omlz` produce one.

### What PX is **not**

- Not "support every Zig target". The toolchain breadth does not
  imply ZxCaml breadth.
- Not "make the language general-purpose". The BPF-shaped
  constraints (no GC, no syscalls, no threads, no exceptions) stay
  in place unless an ADR explicitly relaxes them per target.
- Not a P1 / P2 / P3 deliverable. It is intentionally placed after
  the main numbered phases, and is itself optional.

### Relationship to existing phases

PX **does not block any earlier phase**. P1–P5 happen as planned
with BPF as the only validated target. PX exists so that, when a
real second target eventually shows up, it lands through a defined
process instead of organically blurring the project's focus.

## 9. Anti-goals (every phase)

- We never accept the OCaml C runtime in compiled output.
- We never adopt a feature that requires GC.
- We never fork the OCaml compiler (ADR-009).
- We never silently drift out of the OCaml subset; ADR-010 makes
  drift structurally impossible because the upstream compiler is
  the parser/type-checker.
- We do **not** depend on `opam` packages **beyond** what ships in
  the OCaml distribution (`compiler-libs.common`). The frontend
  bridge has zero third-party `opam` dependencies.
