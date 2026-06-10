# 21 — Multi-file modules implementation plan (ADR-016)

> **Languages / 语言**: **English** · [简体中文](./zh/21-multifile-modules-plan.md)

> **Status:** Implementation plan for ADR-016 option B. This document pins the
> as-built scope before code lands; it does not reopen sealed P1-P9 / R-slice
> work.

ADR-016 ([`09-decisions.md`](./09-decisions.md)) accepted frontend-level
`open Foo` multi-file support: the OCaml frontend type-checks the dependency
closure, joins the resulting Typedtrees, and emits one sexp. This plan records
the implementation contract and the deltas between the ADR text (written
2026-05-12, before wire `1.6`) and the repository as it exists today.

## Deltas vs. the ADR text

| ADR-016 statement | As-built decision | Reason |
|---|---|---|
| "Wire format bumped (minor) to carry `file_id`" | **No wire bump; wire stays `1.6`.** | Wire `1.6` already carries a file atom in every `(loc file line col end_line end_col)` node; diagnostics (`src/util/diag.zig`), source maps (`src/driver/srcmap.zig` `ml_file`), and `omlz unmap` are already per-file. Multi-file attribution needs no new shape. |
| "`--entry` / `--root` CLI flags" | **No new flags.** The existing positional input is the entry; the project root is the entry file's directory. | A second way to name the input adds surface without capability. |
| "Mollusk suite … previously duplicated helpers are removed" | A new multi-file example trio plus a Mollusk test lands with this slice; retrofitting sealed single-file examples is deferred. | Rewriting sealed corpus entries churns goldens without DX payoff; the dedup criterion is satisfied going forward. |

## Resolution and join semantics

- **R1 — discovery.** Before invoking `ocamlc`, the frontend parses the entry
  file with `compiler-libs` `Parse.implementation` and scans top-level
  `open M` items. `M` resolves to `<entry_dir>/<uncapitalized M>.ml`
  (`open Vault_types` → `vault_types.ml`). Discovery recurses through
  dependencies. A parse failure during discovery is ignored; `ocamlc` reports
  the syntax error through the existing path.
- **R2 — reserved names.** `open M` where `M` names a bundled stdlib module
  (`Core`, `Generators`, and the builtin module surface: `Account`,
  `AccountMeta`, `Pubkey`, `Crypto`, `Sysvar`, `Fixed`, `Amount`, …) is
  rejected (E0103), as is a user file that shadows one of those names. The
  stdlib stays auto-opened and special-cased.
- **R3 — compilation.** Dependencies compile in topological order into a
  shared temp directory as `<name>.cmo` so the module name matches the file
  (`ocamlc -bin-annot -I <stdlib> -I <deps> -open Core -open Generators -c`).
  The entry file compiles last with the same `-I <deps>` flag. Every file
  yields its own `.cmt`.
- **R4 — join.** Each `.cmt`'s Typedtree is converted in topological order
  through one shared subset environment (so ADTs/records declared in a
  dependency resolve in later files), and declarations concatenate into a
  single module, entry last. Resolved top-level `Tstr_open` items are skipped
  during conversion; everything else keeps today's subset rules.
- **R5 — flat namespace.** Emitted names are unqualified. Duplicate top-level
  value/type/constructor names across the closure are rejected (E0102) instead
  of mangled, keeping the sexp shape byte-identical to single-file output.
  Qualified references `Foo.x` to a user module emit plain `x`.
- **R6 — dependency edges are `open` only.** Using `Foo.x` without
  `open Foo` is not a dependency edge; `ocamlc` reports an unbound module.
  `include`, nested/local opens, and `let%test` blocks in dependency files
  stay out of scope.
- **R7 — single-file programs are unchanged.** A program with no user `open`
  produces a byte-identical sexp to today's output. Determinism (ADR-008)
  extends to multi-file: topological order is DFS post-order following source
  order of `open` items.

## New diagnostics

| Code | Meaning |
|---|---|
| `E0100` | `open M` cannot be resolved to `<entry_dir>/<m>.ml` |
| `E0101` | `open` dependency cycle (the message lists the cycle path) |
| `E0102` | duplicate top-level name across the file closure |
| `E0103` | `open` of a bundled stdlib module, or a user file shadowing one |

All four register in `src/util/diag_explain.zig`, the frontend mirror test,
and [`diagnostics.md`](./diagnostics.md).

## Implementation slices

1. **S1 frontend driver** — discovery, resolution, cycle check, topological
   multi-`.cmt` compilation in `src/frontend/zxc_frontend.ml`.
2. **S2 subset join** — shared-environment conversion, `Tstr_open` skip,
   user-module path resolution, duplicate detection in
   `src/frontend/zxc_subset.ml`.
3. **S3 tooling** — E010x explain entries; audit `src/build_lock.zig` input
   hashing and LSP sibling-file diagnostic publishing.
4. **S4 validation** — UI fixtures (resolve / missing / cycle / duplicate /
   reserved), a multi-file example trio in `examples/` with manifest update,
   a Mollusk shared-types test, determinism across the trio.
5. **S5 docs closeout** — `02-grammar.md`, `10-frontend-bridge.md`,
   `07-repo-layout.md`, `wire-compat.md` note, `diagnostics.md`, ADR-016
   addendum (Proposed → Accepted as built), README/roadmap counts, Chinese
   mirrors, CHANGELOG.

## Acceptance gates

1. ADR-016 criteria as revised by the delta table above, all demonstrably
   green.
2. The standing no-regress floor:

   ```sh
   zig build
   zig build test --summary none
   cargo test --manifest-path tests/Cargo.toml
   ./scripts/check_examples_corpus.sh
   ./scripts/check_docs_sync.sh
   ```

3. Single-file sexp output stays byte-identical (golden snapshots unchanged
   except intentionally added fixtures).

## Anti-creep guard

- No `dune`, no `.cmi` caching, no incremental compilation (ADR-011 intact).
- No wire bump, no Core IR change, no codegen change.
- No name mangling; E0102 keeps the flat namespace honest until a real need
  for cross-file shadowing appears.
