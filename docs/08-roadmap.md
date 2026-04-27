# 08 — Roadmap

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

- Lexer + parser for the subset in `02-grammar.md`.
- HM type inference + ADT, no functors / GADTs.
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
P1.0  Skeleton              build.zig (Zig 0.16), `omlz --version`,
                            arena util, diagnostics util
P1.1  Lexer                 token stream for the §2 grammar
P1.2  Parser                Surface AST for the full subset
P1.3  Name resolution       binders, scopes, shadowing
P1.4  Type inference        HM + ADT, error messages
P1.5  ANF lowering          Core IR with Layout fields
P1.6  IR pretty-printer     golden tests
P1.7  Interpreter           `omlz run` returns Some 1 for hello.ml
P1.8  ArenaStrategy         Lowered IR
P1.9  ZigBackend            generates `.zig` that builds natively
P1.10 Runtime + entrypoint  BPF shim, arena, panic
P1.11 BPF driver            `omlz build --target=bpf` produces .o
P1.12 Solana harness        deploy + invoke on test-validator
P1.13 Determinism suite     interpreter ≡ Zig native ≡ Zig BPF (where applicable)
```

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

- We never accept the OCaml C runtime.
- We never adopt a feature that requires GC.
- We never depend on `opam` packages at build time.
- We never fork the OCaml compiler.
- We never silently drift out of the OCaml subset; the sanity
  oracle (`02-grammar.md` §8) is a CI gate.
