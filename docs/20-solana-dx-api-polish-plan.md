# 20 — Solana DX/API polish plan

> **Languages / 语言**: **English** · [简体中文](./zh/20-solana-dx-api-polish-plan.md)

> **Status:** Planning-only next-priority scaffold. This document does **not**
> implement new runtime, compiler, or SDK behavior by itself.

After the structure cleanup and bilingual docs-sync pass, the next deliberate
product-planning step is a **Solana-facing DX/API polish** slice. This plan is
intentionally narrow: it keeps the current compiler/runtime facts fixed while
preparing small follow-up features that make the existing Solana surface easier
to use, validate, and document.

## Scope and non-goals

- Scope is limited to **developer ergonomics and public API polish** around the
  current Solana path.
- The plan stays anchored to the existing **SDK-backed** runtime surface and the
  direct `SOLANA_ZIG` / `solana-zig build-lib` BPF flow.
- This plan is **not** a permission slip for a new compiler phase, a runtime
  rewrite, a multichain deliverable, a memory-model change, or a broad feature
  batch.
- Sealed work such as P1-P9 and R11-R14 remains closed unless a future feature
  explicitly reopens one narrow Solana-facing slice.

## Canonical assumptions future work must inherit

- **BPF build mode:** keep the current direct `SOLANA_ZIG` /
  `solana-zig build-lib` path described in
  [`06-bpf-target.md`](./06-bpf-target.md).
- **Runtime surface:** treat [`runtime-api.md`](./runtime-api.md) as the public
  Zig runtime compatibility surface.
- **Solana semantics and examples:** inherit the current account/syscall/CPI/SPL
  guidance from [`11-solana-p3.md`](./11-solana-p3.md).
- **Roadmap status:** keep [`08-roadmap.md`](./08-roadmap.md) as the canonical
  record that P1-P9 are sealed and that this DX/API work is the next priority.
- **Docs parity:** keep English and Chinese docs in lockstep and require
  [`./scripts/check_docs_sync.sh`](../scripts/check_docs_sync.sh) to stay green.
- **Local Solana validation:** use **Surfpool only** on `127.0.0.1:8899` /
  `127.0.0.1:8900`; do not revive the legacy `solana-test-validator` flow as
  active guidance.

## Focus areas for future implementation slices

| Area | DX/API polish intent | Example future artifact |
|---|---|---|
| Entrypoint ergonomics | Make SDK-backed entrypoint expectations easier to read and apply without changing the current ABI. | Narrow helper cleanup, clearer docs snippets, targeted harness fixture. |
| Account / meta helpers | Align `Account.*`, `account`, and `account_meta` naming/examples so common authority/writable flows are easier to discover. | Focused naming/docs pass plus targeted examples/tests. |
| Syscall / CPI / PDA helpers | Reduce friction around helper naming, example coverage, and call-shape documentation for syscalls, CPI, PDA seeds, and return data. | Example refresh plus targeted helper validation. |
| SDK-backed imports | Make canonical import roots and generated shim expectations obvious to contributors touching Solana-facing surfaces. | Docs/examples that point to the stable import roots. |
| Surfpool UX | Improve the local build/deploy/invoke loop so failures point to the right command, path, or account fixture faster. | Harness/docs cleanup with scoped validation. |
| Diagnostics and docs examples | Add clearer misuse examples and polished snippets for common Solana entrypoint/account/helper errors. | UI/example/docs additions tied to one narrow surface. |

Every row above is still **planning only** until a separate implementation
feature lands with its own scope and validation evidence.

## Acceptance gates for any future implementation

1. **Docs parity gate:** English and Chinese docs must be updated together, keep
   reciprocal links current, and pass `./scripts/check_docs_sync.sh`.
2. **Targeted examples/tests gate:** each slice must add or update focused
   examples, UI tests, Zig tests, or Mollusk/Surfpool fixtures for the exact
   Solana-facing surface it changes.
3. **Surfpool validation gate:** local Solana validation must run through the
   existing Surfpool harness path on `127.0.0.1:8899` / `127.0.0.1:8900`.
4. **No-regress gate:** future slices must keep the existing validator floor
   green:

   ```sh
   zig build
   zig build test --summary none
   cargo test --manifest-path tests/Cargo.toml
   ./scripts/check_examples_corpus.sh
   ./scripts/check_docs_sync.sh
   ```

5. **Canonical-link gate:** roadmap and plan links must continue to point at the
   current BPF build doc, Solana guide, runtime API doc, and DX roadmap entry.

## Explicit anti-creep guard

- Do **not** turn this plan into a catch-all backlog for new compiler phases.
- Do **not** use it to schedule the exploratory
  [functional multichain roadmap](./19-functional-multichain-roadmap.md).
- Do **not** interpret it as approval for runtime rewrites, allocator changes,
  or edits to `vendor/solana-program-sdk-zig/`.
- Do **not** switch the active local-node story away from Surfpool.

Any future item claiming this plan must show a direct **Solana developer
experience or API ergonomics** payoff and stay within the gates above.
