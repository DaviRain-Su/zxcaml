# 08 — Roadmap

> **Languages / 语言**: **English** · [简体中文](./zh/08-roadmap.md)

## 1. Phases

| Phase | Theme | Done when… |
|---|---|---|
| **P1** | MVP: OCaml subset → BPF `.o` | `examples/solana_hello.ml` deploys and returns 0 |
| P2 | ADT completeness | nested patterns, record update, basic exceptions-as-result |
| P3 | Solana-shaped subset | `account` type, no-alloc analysis, syscall bindings, real Anchor-style program |
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
P1.11 BPF driver            `omlz build --target=bpf` produces a .o.
P1.12 Solana harness        Deploy + invoke on solana-test-validator.
P1.13 Determinism suite     interpreter ≡ Zig native ≡ Zig BPF (where applicable).
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

## 3. Phase 2 — ADT completeness

- Nested patterns in `match`.
- Record update syntax `{ r with x = 1 }`.
- `result`-based error propagation helper (no exceptions).
- Decision-tree match compilation.
- Larger stdlib: `Option.map / bind / get_or`, `Result.map / bind`,
  `List.map / filter / fold / length / rev / append`.
- Begin populating `examples/` with non-trivial programs.

## 4. Phase 3 — Solana-shaped subset

- `account` type: a typed view over BPF account input bytes.
- A `no_alloc` attribute and an analysis that proves a function
  performs no arena allocation.
- Syscall bindings: `sol_log`, `sol_get_clock_sysvar`, basic CPI
  signatures.
- A real example: a small SPL-Token-style transfer program.
- IDL emission stub (one-shot JSON, not Anchor-compatible yet).

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
