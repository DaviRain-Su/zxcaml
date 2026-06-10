# Code Review Backlog

Internal working list from the 2026-06-10 full-repo code review. Items are
promoted into `docs/08-roadmap.md` or a `docs/2x-*` plan doc only when
scheduled; entries here carry no user-facing commitment. Severity is the
reviewer's call, not a CI gate.

Status values: `open`, `scheduled`, `done`, `accepted` (reviewed, no action
needed), `rejected`.

| ID | Area | Site | Finding | Proposed action | Severity | Status |
|----|------|------|---------|-----------------|----------|--------|
| CR-1 | driver | `src/driver/pipeline.zig:26` | `zxc-frontend` is resolved via cwd-relative `zig-out/bin/zxc-frontend` first, so an installed `omlz` only works from the repo root. | Resolve relative to the `omlz` executable's own directory first, then fall back to the current default and `PATH`. | medium | scheduled |
| CR-2 | driver | `src/driver/bpf.zig:356-374` | `llvm-objcopy` discovery probes Homebrew prefixes + `PATH`, but offers no explicit override and misses versioned names common on Linux (`llvm-objcopy-18`). | Honor an `LLVM_OBJCOPY` env override; optionally probe versioned names. | low | scheduled |
| CR-3 | codegen policy | `src/backend/zig_codegen/expr_emission.zig:155,226` | Emitted programs contain `arena.alloc(...) catch unreachable`; on arena exhaustion a deployed program traps without a message. | Decide panic-with-message vs bare trap (BPF compute-unit cost tradeoff) and document the choice in `docs/04-memory-model.md` (+ zh mirror). | medium | open |
| CR-4 | lsp | `src/lsp/lsp_main.zig:1404,1409` | Temp-file cleanup swallows errors with `catch {}`. | Best-effort cleanup is acceptable here; optionally log under a verbose flag. | low | accepted |
| CR-5 | core/backend | `src/lower/region_infer.zig:60`, `src/backend/interp.zig:521` | `orelse unreachable` / `catch unreachable` flagged in review. | Verified unreachable: the former is assert-guarded invariant state, the latter formats a u64 into a 32-byte buffer. No action. | info | accepted |
| CR-6 | tests | `src/driver/bpf.zig:626-643` | BPF smoke test hardcodes `"zig-out/bin/omlz"` (cwd-dependent). | Pass `omlz_abs` via build options the way `tests/golden/run.zig` does (`build.zig:394-395`). | low | scheduled |
| CR-7 | core | `src/core/anf/module.zig` (`lowerLoc`:598, `setCoreLoc`:609) | Source-location propagation exists but coverage through `lowerApp`/`lowerLetExpr`/match arms has not been audited; gaps degrade diagnostics and source maps. | Audit against `core_loc_tests.zig`; add cases for any lowering path that drops spans. | medium | open |
| CR-8 | cli | `src/main.zig` (`renderNoAllocFailure`:472, `renderRegionFailure`:615) | Two near-identical failure-rendering paths. | Converge while extracting check-command handling into `src/omlz/check_cmd.zig`. | low | scheduled |
| CR-9 | architecture | `src/` (omlz + omlz-lsp roots) | No library facade; both binaries import compiler internals directly. | Deferred: introduce `src/lib.zig` only when an embedding use case appears (Zig lazy compilation makes the build-time win modest). | low | open |
| CR-10 | env | local opam | `zxcaml-p1` switch drifted to OCaml 5.4.1 (compiler-libs API breaks: `Texp_atomic_loc`, `Longident.Ldot` loc-wrapping); project pins 5.2.x. | Recreated the switch at 5.2.1 (2026-06-10). Consider an `init.sh` guard that detects drift and offers the recreation command. | medium | open |

## Explicitly skipped (with reasons)

- **Codegen `Emitter` abstraction** — `append`/`appendPrint` are already
  shared free functions in `src/backend/zig_codegen/common.zig`; converting to
  method style would touch 100+ golden-tested call sites for zero behavior
  gain.
- **Moving `src/target/` under `src/driver/`** — the four target modules
  (registry/capability/preflight/manifest) form a coherent layer already; a
  move would churn the repo-layout contract for no structural win.
