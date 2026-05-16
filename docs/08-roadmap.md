# 08 — Roadmap

> **Languages / 语言**: **English** · [简体中文](./zh/08-roadmap.md)

This roadmap now separates sealed compiler phases from demo/operational work and
future optional ideas. Current canonical facts for the user-facing docs: the
frontend bridge accepts sexp wire format `1.5`, the examples corpus contains 95
`.ml` programs, the Mollusk SVM suite contains 44 Rust integration-test files
(66 Rust test cases), and P1-P9
are sealed in [`CHANGELOG.md`](../CHANGELOG.md).
Real-world Examples Batch 2 is tracked in [`CHANGELOG.md`](../CHANGELOG.md#real-world-examples-batch-2---2026-05-05).
Real-world Examples Batch 3 adds the SPL Token primitive examples
`spl_burn`, `spl_close_account`, and `spl_revoke`.
R13 is closed as the account-guard product polish slice: `Account.*` helpers,
`account_guard`, IDL signer/writable/error metadata, and UI misuse diagnostics
are all represented in tests and docs. The public Zig runtime surface is
documented in [`docs/runtime-api.md`](./runtime-api.md).

## Completed phases (P1–P9)

| Phase | Status | One-line summary | Changelog citation |
|---|---|---|---|
| P1 | ✅ | MVP OCaml subset to Solana BPF: `omlz` scaffold, OCaml frontend bridge, Core IR, interpreter, native build path, and BPF `.so` build path. | [`[P1]`](../CHANGELOG.md#p1-mvp-ocaml-subset-to-solana-bpf---2026-04-28) |
| P2 | ✅ | Subset expansion and match optimization: user ADTs, nested/guarded patterns, tuples, records, stdlib expansion, and hardened BPF closures. | [`[P2]`](../CHANGELOG.md#p2-subset-expansion-and-match-optimization---2026-04-29) |
| P3 | ✅ | Solana-shaped subset: zero-copy account views, syscalls, CPI helpers, SPL-Token support, `omlz check --no-alloc`, and IDL output. | [`[P3]`](../CHANGELOG.md#p3-solana-shaped-subset---2026-04-29) |
| P4 | ✅ | Mollusk acceptance and instruction data: transaction input dispatch, in-process SVM tests, and Pubkey helper ergonomics. | [`[P4]`](../CHANGELOG.md#p4-mollusk-acceptance-and-instruction-data---2026-04-30) |
| P5 | ✅ | Ecosystem reach: typed `external` declarations, Zig runtime bindings, Anchor-compatible IDL emission, Map/Set, and crypto wrappers. | [`[P5]`](../CHANGELOG.md#p5-ecosystem-reach---2026-04-30) |
| P6 | ✅ | Region inference: escape analysis, stack-region codegen for eligible locals, and region allocation examples. | [`[P6]`](../CHANGELOG.md#p6-region-inference---2026-04-30) |
| P7 | ✅ | OCaml subset expansion: desugared surface forms, richer patterns, string/char support, and broader stdlib utilities. | [`[P7]`](../CHANGELOG.md#p7-ocaml-subset-expansion---2026-04-30) |
| P8 | ✅ | Compiler optimizations: constant folding, dead-code elimination, self-recursive tail call optimization, function inlining, and mutual recursion groups. | [`[P8]`](../CHANGELOG.md#p8-compiler-optimizations---2026-05-01) |
| P9 | ✅ sealed | Developer experience: rustc-style diagnostics, wire `1.2` location plumbing, `omlz-lsp`, and deterministic source maps with `omlz unmap`. | [`[P9 Developer Experience]`](../CHANGELOG.md#p9-developer-experience---2026-05-05) |

Phases are **not** time-boxed in this document. They are scope-boxed, and a
phase only moves into this table after the corresponding changelog section is
present.

### P9 — Developer Experience ✅ sealed

P9 is sealed as a product-quality developer-experience pass spanning four
milestones:

- **DX1 — rustc-style diagnostics:** human diagnostics now render source
  snippets with caret spans, with `--error-format=human|json|oneline` for
  terminal, tooling, and CI use.
- **DX2 — wire 1.2 location plumbing:** frontend sexps and Core IR preserve
  OCaml locations so no_alloc, region, and subset failures can point at the
  originating `.ml` span.
- **LSP — `omlz-lsp`:** the stdio language server speaks LSP JSON-RPC and
  publishes diagnostics for editor clients.
- **SRCMAP — source maps:** BPF builds emit deterministic `.map` sidecars,
  embed `.zxcaml.srcmap`, and let `omlz unmap` resolve program counters back to
  OCaml source locations.

## Hackathon work (post-P8)

- The frozen hackathon package is indexed in
  [`docs/hackathon/README.md`](./hackathon/README.md): timeline, bilingual demo
  scripts, shot list, Colosseum submission copy, Anchor comparison artifacts,
  Slidev recording checklist, and related demo script links.
- The one-shot reproducibility entry point is `make demo` from the repository
  root; the same hackathon index also points at `make demo-clean` and the
  component scripts under `scripts/demo/`.
- The public landing page for the current demo narrative is
  [`https://zxcaml.pages.dev/`](https://zxcaml.pages.dev/), which presents the
  P1-P9 compiler state and post-P8 hackathon assets without treating the demo as
  a new compiler phase.

## Phase 19–21 wrap-up ledger

The Phase 19, Phase 20, and Phase 21 operational/documentation pass is sealed.
These milestones did not reopen P1-P9 scope; they hardened formatter coverage,
refreshed the Factory wiki, and closed the formatter lex-wart debt surfaced by
the fmt corpus expansion.

| Milestone | Status | Seal marker / tag | Completed | Notes |
|---|---|---|---|---|
| M-WIKI-2 | ✅ sealed | `post-lspfix3-baseline` + Factory wiki run [`a114e5ee`](https://app.factory.ai/wiki/a114e5ee-acef-458a-bcb7-91c1f95c1c7a) | 2026-05-07 | Refreshed the cloud wiki at the Phase 18 / M-LSPFIX-3 baseline. |
| M-FMT-3 | ✅ sealed | `post-fmt3-baseline` | 2026-05-07 | Expanded the `omlz fmt` corpus to the 20-golden trajectory while keeping the formatter source locked. |
| M-LSPFIX-3 | ✅ sealed | `post-lspfix3-baseline` | 2026-05-07 | Removed the legacy Python latency assertion path and restored strict-parallel no-regress validation. |
| M-FMT-FIXES | ✅ sealed | `post-fmt-fixes-baseline` | 2026-05-08 | Fixed polymorphic type-variable, labelled/optional argument, and PPX-local formatter lex warts. |
| M-WIKI-3 | ✅ sealed | `post-fmt-fixes-baseline` + Factory wiki run [`52ce54d4`](https://app.factory.ai/wiki/52ce54d4-145a-4bc1-b530-bd947c501564) | 2026-05-07 | Refreshed the cloud wiki with Phase 19 + Phase 20 content. |
| M-FMT-DEEPNESTED | ✅ sealed | `post-fmt-deepnested-baseline` | 2026-05-08 | Landed the generic `) word` spacing rule and re-captured the single `deeply_nested` golden delta. |

### Closed tech debt

- **TD-FMT-LEX-WARTS — ✅ closed/resolved** at `post-fmt-fixes-baseline`
  (2026-05-08). The Phase 19 formatter scout's four lex-level warts are now
  fixed and represented in the fmt golden corpus; Phase 21's
  `post-fmt-deepnested-baseline` then sealed the final generic `) word`
  spacing follow-up.

### R-series product polish ledger

| Slice | Status | Completed | Notes |
|---|---|---:|---|
| R11 — Fixed-point math surface | ✅ sealed | 2026-05-15 | Added deterministic `Fixed` / `Amount` helpers, `fixed_amm_quote`, tests, and bilingual docs. |
| R12 — Mutable state hardening | ✅ sealed | 2026-05-15 | Hardened `int array`, `for` / `while`, and `int` / `bool` refs across interpreter/native/BPF with stress coverage. |
| R13 — Solana account guard polish | ✅ sealed | 2026-05-15 | Added `Account` guard/read helpers, `account_guard`, Mollusk coverage, IDL metadata/error output, UI misuse diagnostics, and bilingual docs. |
| R14 — IDL error metadata polish | ✅ sealed | 2026-05-15 | Added derived human-readable `msg` fields for `error_` constants and refreshed IDL/docs coverage. |

### Phase 22+ candidates

- **Documentation/process hygiene:** the bilingual docs-sync and drift-prevention
  pass is part of the sealed maintenance surface. Keep
  `./scripts/check_docs_sync.sh` green, keep English/Chinese routing
  reciprocal, and treat Surfpool/local-path drift as a blocker rather than a
  follow-up chore.
- **Next priority: Solana DX/API polish planning.** Before reopening broader
  runtime or compiler scope, the repository's next deliberate product-planning
  step is a planning-only Solana DX/API polish scaffold: entrypoint ergonomics,
  account/meta helper naming, Surfpool UX, diagnostics examples, and acceptance
  gates.
- **Functional multichain roadmap:** [`docs/19-functional-multichain-roadmap.md`](./19-functional-multichain-roadmap.md)
  records the exploratory thesis that ZxCaml can unify smart-contract business
  logic through a contract-safe OCaml subset while keeping chain runtimes behind
  explicit adapters. MTF-0 + MTF-1 are now landed as the target contract plus an
  experimental generic WASM smoke target, and MTF-2 now lands an experimental
  NEAR no-storage adapter MVP; MTF-3 through MTF-6 remain future, explicitly
  gated work.
- **Codegen/runtime new directions:** only schedule concrete work with a named
  runtime, BPF, WASM-chain, EVM/Yul, or codegen acceptance target; speculative
  multi-target or allocator changes still require an ADR-sized proposal.
- **BPF toolchain migration:** default status (2026-05-11) is direct `solana-zig` mode (`SOLANA_ZIG` unset/empty/`1`); this is the canonical build path.
- **Tooling policy:** `sbpf-linker` is no longer required in normal workflows; maintain compatibility notes only as historical context.
- **M-WIKI-5 wiki refresh:** refresh the Factory wiki after the next meaningful
  compiler/runtime/docs baseline rather than after every small docs-only commit.
- **Maintenance hold:** pause new feature scope and keep the repository on
  validator, drift, and process-hygiene work if no high-confidence runtime or
  codegen direction is ready.
- **Language-subset gap proposals:** ADR-015 is partially landed and now has R12 stress coverage across controlled `int` arrays, `for` / `while` loops, and `int` / `bool` refs; follow-ups remain deferred for dynamic/generic arrays and broader ref aliasing/types. ADR-017's deterministic-number direction now has an initial six-decimal `Fixed` / `Amount` stdlib surface; fuller fixed-point/decimal design remains future work. R13 is sealed as a Solana account-guard polish slice. ADR-016 (multi-file modules via frontend `open Foo`) remains proposed in [`09-decisions.md`](./09-decisions.md).

## Future / optional

The prose below is retained for optional ideas that are outside the sealed P1-P9
compiler scope and outside the post-P8 hackathon/demo work.

### FM — Functional multichain contract core (optional, exploratory)

**Status:** Partially landed for MTF-0 + MTF-1 plus the experimental MTF-2
NEAR no-storage adapter MVP. MTF-3 through MTF-6 are still not scheduled and
remain gated. Captured in
[`19-functional-multichain-roadmap.md`](./19-functional-multichain-roadmap.md).

This direction reframes future target work around a portable contract core:
write deterministic business logic once in the ZxCaml OCaml subset, then bind it
to Solana, WASM chains, EVM, or other runtimes through explicit adapters. The
portable layer is pure/state-machine logic; the adapter layer owns entrypoints,
storage, caller identity, serialization, logging, calls, errors, metadata, and
acceptance tests.

Candidate implementation sequence:

1. **MTF-0 target ADR** — pin the portable subset, target terminology, and `int`
   / word-size policy.
2. **MTF-1 generic WASM** — landed as `omlz build --target=wasm`, an
   experimental import-free pure-logic smoke target validated through Node
   WebAssembly acceptance.
3. **MTF-2 NEAR adapter** — landed experimentally as a no-storage MVP with
   exported methods, minimal NEAR host imports, and real near-sandbox
   acceptance; storage/promises/caller/JSON/Borsh remain gated.
4. **MTF-3 portable contract API** — define chain-neutral capabilities and
   diagnostics for unsupported targets.
5. **MTF-4 EVM/Yul MVP** — add a sibling backend that emits Yul/bytecode rather
   than routing EVM through generated Zig source.
6. **MTF-5 verified extraction profile** — accept constrained OCaml extracted
   from F*, Coq, or WhyML for formally verified business logic.
7. **MTF-6 additional adapters** — CosmWasm, Substrate contracts, Stylus, or IC
   only after a named use case and host model exist.

This direction can host formally verified contract logic, but it does not make
all ZxCaml output automatically formally verified. Proof claims belong to the
upstream proof/extraction source plus the specific verified subset boundary.

### PX — Multi-target expansion (optional, gated)

**Status:** Not scheduled. Not on the critical path. This phase
exists only to give "what about other targets?" a defined shape so
it does not creep into earlier phases.

#### Context

Because the Zig backend emits `.zig` source, the Zig toolchain can in
principle lower to any of its supported targets (`aarch64`, `x86_64`,
`riscv*`, `wasm32`, `nvptx*`, `amdgcn`, …; see `06-bpf-target.md`
§10 for the long list and the cold shower that goes with it).

This does **not** mean those targets are supported. PX is the place
where a target moves from "the toolchain can technically reach it" to
"ZxCaml supports it".

#### Activation gate

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

#### Plausible candidates (illustrative, not committed)

- **`wasm32-freestanding`** — for an in-browser Solana program
  simulator. Gate: who is the user? what tool consumes the output?
- **`x86_64-linux`** — for fuzzing / property testing harnesses
  that want native speed and crash dumps. Gate: a real fuzzing
  harness, not "wouldn't it be nice".
- **`riscv64-linux` / embedded BPF (Linux kernel eBPF)** — outside
  Solana's BPF flavour but adjacent. Gate: a specific eBPF program
  someone needs to ship.

#### Note: x86 / arm native is **not** a PX candidate

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

#### What PX is **not**

- Not "support every Zig target". The toolchain breadth does not
  imply ZxCaml breadth.
- Not "make the language general-purpose". The BPF-shaped
  constraints (no GC, no syscalls, no threads, no exceptions) stay
  in place unless an ADR explicitly relaxes them per target.
- Not part of the sealed P1-P9 deliverable set. It is intentionally placed after
  the main numbered phases, and is itself optional.

#### Relationship to existing phases

PX **does not block any earlier phase**. P1–P9 are sealed with BPF as
the only validated target. PX exists so that, when a real second target
eventually shows up, it lands through a defined process instead of
organically blurring the project's focus.

### Self-hosting (was P6, optional)

- Rewrite `src/core/anf.zig` and `src/core/pretty.zig` in our subset.
- Run the rewritten code through `omlz` and link the resulting object
  back into the compiler.
- This is the dogfooding gate; not required for the project to ship.

### Formalisation (was P7, optional)

- A small-step semantics for Core IR (paper or Lean / Coq).
- A surface for LLMs / verifiers to consume Core IR (S-expression
  serialisation? deterministic JSON?).
- Property tests: refinement between Core IR and Lowered IR.

### Anti-goals (all future work)

- We never accept the OCaml C runtime in compiled output.
- We never adopt a feature that requires GC.
- We never fork the OCaml compiler (ADR-009).
- We never silently drift out of the OCaml subset; ADR-010 makes
  drift structurally impossible because the upstream compiler is
  the parser/type-checker.
- We do **not** depend on `opam` packages **beyond** what ships in
  the OCaml distribution (`compiler-libs.common`). The frontend
  bridge has zero third-party `opam` dependencies.
