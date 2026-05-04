# ZxCaml — OCaml to Solana BPF

## Problem

Solana is fast, deterministic, and unforgiving. That is exactly why its
developer experience should give builders more help before a transaction ever
touches chain. Today, most production Solana programs live in Rust and Anchor;
that stack is powerful, but it leaves a gap for builders who want the clarity
of typed functional programming: algebraic data types, exhaustive pattern
matching, pure helper code, and compact business logic. ZxCaml explores that
gap honestly: can we keep an OCaml-shaped source language while producing real
Solana BPF artifacts instead of a toy VM? The current repo answers with a
working compiler path and a demo program under
[`examples/hackathon_greet.ml`](../../examples/hackathon_greet.ml).

## Solution

ZxCaml is an OCaml-subset compiler that targets Solana BPF through Zig. Builders
write ordinary `.ml` files, the frontend reuses upstream OCaml `compiler-libs`
for parsing and type checking, and the owned backend lowers typed Core IR into
GC-free Zig that links into a Solana-loadable `.so`. The pitch is simple:
borrow OCaml's frontend, throw away its runtime, and land on BPF. The project is
not claiming full OCaml compatibility yet; it is proving a practical slice with
Solana accounts, syscalls, CPI helpers, IDL emission, Mollusk tests, and a
PDA-backed greeting counter demo.

## Architecture

The pipeline is intentionally small at the language boundary:
`.ml` source goes through `ocamlc -bin-annot`, `zxc-frontend` emits a versioned
S-expression, Zig parses that into a Typedtree mirror, ANF lowering produces the
typed Core IR contract, the arena lowering strategy removes reliance on the
OCaml runtime, and the Zig backend drives `zig build-lib` plus `sbpf-linker` to
produce Solana BPF. See the canonical architecture diagram in
[`docs/01-architecture.md#4-architectural-diagram`](../01-architecture.md#4-architectural-diagram).

## Demo

- Video: **TODO — paste final Colosseum demo video URL here.**
- Screenshots: **TODO — add project page screenshots / recording stills here.**
- Repro path: run
  [`./scripts/demo/run_full_demo.sh`](../../scripts/demo/run_full_demo.sh) to
  build the greeting program, start Surfpool, deploy, invoke, inspect state, and
  tear down.
- Storyboard:
  [`docs/hackathon/timeline.md`](./timeline.md),
  [`demo-script.en.md`](./demo-script.en.md),
  [`demo-script.zh.md`](./demo-script.zh.md), and
  [`shot-list.md`](./shot-list.md).
- Comparison: [`docs/hackathon/anchor-comparison.md`](./anchor-comparison.md)
  compares the same greeting-counter behavior against an Anchor reference.

## Tech Stack

- **Source language:** OCaml subset (`.ml`) with ADTs, pattern matching, records,
  strings, closures, and a growing functional stdlib.
- **Frontend:** upstream OCaml 5.2 `compiler-libs`, used as a library.
- **Compiler/backend:** Zig 0.16, ANF/Core IR, arena/region-aware lowering,
  Zig codegen, and `sbpf-linker` for SBPF v2.
- **Solana surface:** account views, syscalls, CPI/PDA helpers, Anchor-style IDL,
  Mollusk SVM tests, Surfpool localnet scripts.

## Team

ZxCaml is led by **DaviRain-Su** with Factory Droid contributors helping drive
the Colosseum demo sprint: compiler hardening, real-world example ports,
Surfpool scripts, Anchor comparison artifacts, bilingual scripts, and this
submission package. The project is early, research-flavored infrastructure, but
the checked-in demo is designed to be reproducible from the repository root.

## Links

- GitHub: <https://github.com/DaviRain-Su/zxcaml>
- Project overview: [`README.md`](../../README.md)
- Architecture docs: [`docs/01-architecture.md`](../01-architecture.md)
- Hackathon assets: [`docs/hackathon/`](./)
- Demo scripts: [`scripts/demo/`](../../scripts/demo/)
