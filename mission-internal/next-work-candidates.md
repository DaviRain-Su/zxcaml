# Next-work candidates

Internal consolidated TODO across every planning surface (roadmap
future/optional, code-review backlog leftovers, language-subset gap
proposals, process items). Updated 2026-06-11 after the DX polish plan
(all six areas), ADR-016 multi-file modules, wire 1.6/1.7, and the
CR-3..CR-15 engineering pass all landed.

Promotion rule: picking a direction here means writing/refreshing a
`docs/2x-*` plan doc (bilingual) with its own scope and anti-creep
guard, per the docs/20 pattern. This file is the funnel, not the plan.

## A. Language-subset gaps (ADR-015 / ADR-017 follow-ups)

| Item | What | Why / value | Size guess |
|---|---|---|---|
| A1 | Generic arrays: non-`int` element types for `[| |]` / `Array.make` / get-set | R9 pinned arrays to `int`; `bytes array` already exists as a seeds type, and CR-14's tuple interning removed the main codegen blocker for composite elements. Unlocks real data-structure work. | M-L (ANF + codegen + no_alloc + docs) |
| A2 | Dynamic-size `Array.make` | E0019 currently demands a literal size. Needs an arena-budget story. | M |
| A3 | Broader `ref` element types (string/record/option beyond int-bool) | E0013 whitelist; R10 deferred. | M |
| A4 | ADR-017 fuller fixed-point/decimal design | Six-decimal `Fixed`/`Amount` exist; full design (precision policy, rounding, conversions) remains future per roadmap. | L (design-first) |
| A5 | Wire marker leftovers: `Constant` nodes carry no loc on the ttree side (`ttreeExprLoc` returns unknown) | Last known loc gap; would give `let entrypoint = 42`-class misuse a real span. Touches ttree types/decoder + frontend constant emission. | S-M |

## B. Multichain MTF gates (docs/19 + docs/20-functional-multichain-architecture-adr)

| Item | What | Precondition |
|---|---|---|
| B1 | MTF-2 follow-ups: NEAR storage / promises / caller identity / JSON-Borsh codecs | Named use case; each gate is its own slice |
| B2 | MTF-3 portable contract core API (chain-neutral capabilities + diagnostics) | ADR-sized proposal |
| B3 | MTF-4 EVM/Yul MVP backend | MTF-3 first |
| B4 | MTF-5 verified extraction profile (F*/Coq/WhyML input) | Named proof source |
| B5 | MTF-6 additional adapters (CosmWasm/Substrate/Stylus/IC) | Named use case + host model |

## C. Maintenance / backlog leftovers (mission-internal/code-review-backlog.md)

| Item | What | Status note |
|---|---|---|
| C1 | CR-9 lib facade (`src/lib.zig`) | Deferred until an embedding use case appears |
| C2 | CR-12 native codegen rejects user-constructed `account` records | Testing-ergonomics; decide allow-or-document |
| C3 | CR-16 LSP harness timeout flake under full parallel test load | Raise timeout or serialize the step |
| C4 | `omlz fmt --check` fails on `stdlib/core.ml` + newer examples | Pre-existing; formatter corpus never covered the stdlib; decide format-or-exempt |

## D. Process / release / docs

| Item | What |
|---|---|
| D1 | Cut a named CHANGELOG release for the current `[Unreleased]` block (wire 1.6/1.7, DX polish ×6, ADR-016, arena-marker + tuple-interning fixes) — the repo ships named slices, not semver. While there, merge the stale second `## [Unreleased]` header (CHANGELOG.md ~line 457, ELF-post-pass-era leftovers) into proper history. |
| D2 | M-WIKI-5: refresh the Factory wiki — the roadmap says "after the next meaningful baseline", and the current baseline qualifies. |
| D3 | Keep `docs/08-roadmap.md` "next priority" section current (done 2026-06-11 alongside this file; re-check after each direction lands). |

## Suggested ordering

D1+D3 are cheap hygiene and unblock a clean baseline. After that the
real fork is A1 (deepen the language; most user-visible) vs B1/B2
(widen the targets; strategic) — a product call, not an engineering
one. C-items are fill-in work between slices.
