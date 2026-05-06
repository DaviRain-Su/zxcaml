# 08 — Roadmap

> **Languages / 语言**: **English** · [简体中文](./zh/08-roadmap.md)

This roadmap now separates sealed compiler phases from demo/operational work and
future optional ideas. Current canonical facts for the user-facing docs: the
frontend bridge accepts sexp wire format `1.2`, the examples corpus contains 57
`.ml` programs, the Mollusk SVM suite contains 24 integration tests, and P1-P9
are sealed in [`CHANGELOG.md`](../CHANGELOG.md).
Real-world Examples Batch 2 is tracked in [`CHANGELOG.md`](../CHANGELOG.md#real-world-examples-batch-2---2026-05-05).
The public Zig runtime surface is documented in [`docs/runtime-api.md`](./runtime-api.md).

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

## Future / optional

The prose below is retained for optional ideas that are outside the sealed P1-P9
compiler scope and outside the post-P8 hackathon/demo work.

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
