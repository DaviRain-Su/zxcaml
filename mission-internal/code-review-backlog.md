# Code Review Backlog

Internal working list from the 2026-06-10 full-repo code review. Items are
promoted into `docs/08-roadmap.md` or a `docs/2x-*` plan doc only when
scheduled; entries here carry no user-facing commitment. Severity is the
reviewer's call, not a CI gate.

Status values: `open`, `scheduled`, `done`, `accepted` (reviewed, no action
needed), `rejected`.

| ID | Area | Site | Finding | Proposed action | Severity | Status |
|----|------|------|---------|-----------------|----------|--------|
| CR-1 | driver | `src/driver/pipeline.zig` (`frontendSiblingFromArgv0`) | Bare-name `omlz` invocations fell back to cwd-relative `zig-out/bin/zxc-frontend`, so an installed `omlz` only worked from the repo root. | Done 2026-06-10: resolve the running executable's own directory first (argv0-with-dirname sibling lookup already existed). | medium | done |
| CR-2 | driver | `src/driver/bpf.zig` (`findLlvmObjcopy`) | `llvm-objcopy` discovery offered no explicit override and missed versioned names common on Linux. | Done 2026-06-10: `LLVM_OBJCOPY` env override (verbatim, fails loudly if invalid) + versioned-name probes; documented in docs/source-map.md. | low | done |
| CR-3 | codegen policy | `src/backend/zig_codegen/expr_emission.zig`, `runtime/zig/arena.zig` | Emitted programs and the `...OrTrap` arena helpers used `unreachable` on exhaustion — undefined behavior in release builds (optimizer may elide the bounds check), and no message. | Done 2026-06-10: decided panic-with-marker. All exhaustion paths abort via the runtime panic hook with stable `ZXCAML_PANIC:arena_exhausted`; documented in docs/04-memory-model.md (+ zh). | medium | done |
| CR-4 | lsp | `src/lsp/lsp_main.zig:1404,1409` | Temp-file cleanup swallows errors with `catch {}`. | Best-effort cleanup is acceptable here; optionally log under a verbose flag. | low | accepted |
| CR-5 | core/backend | `src/lower/region_infer.zig:60`, `src/backend/interp.zig:521` | `orelse unreachable` / `catch unreachable` flagged in review. | Verified unreachable: the former is assert-guarded invariant state, the latter formats a u64 into a 32-byte buffer. No action. | info | accepted |
| CR-6 | tests | `src/driver/bpf.zig` (smoke tests) | BPF smoke tests hardcoded `"zig-out/bin/omlz"` / `"zig-out/bin/zxc-frontend"` (cwd-dependent). | Done 2026-06-10: absolute `omlz_bin`/`zxc_frontend_bin` now flow through the shared `build_options`. | low | done |
| CR-7 | core | `src/core/anf/expr_lowering.zig` (`setCoreLoc`), `src/frontend/zxc_frontend.ml` | Audited 2026-06-10. Root cause: the Zig side is fully plumbed (`setCoreLoc` runs on every lowered expression), but the OCaml frontend emits `(located ...)` only on top-level let bindings, so every inner expression's loc is unknown and diagnostics/source maps degrade to function-level granularity. | Audit done: `tests/core/loc_test.zig` now pins the decl-level floor across a corpus sample. Follow-up shipped 2026-06-10 as wire 1.6: the frontend wraps inner expressions in `located`, ANF stamps expression-level Core IR locs, no_alloc/region diagnostics and source maps are expression-granular. | medium | done |
| CR-8 | cli | `src/omlz/cmd_common.zig` (`renderErrorDiagnostic`) | Two near-identical failure-rendering paths in the old main.zig. | Done 2026-06-10: converged during the check-command extraction. | low | done |
| CR-9 | architecture | `src/` (omlz + omlz-lsp roots) | No library facade; both binaries import compiler internals directly. | Deferred: introduce `src/lib.zig` only when an embedding use case appears (Zig lazy compilation makes the build-time win modest). | low | open |
| CR-10 | env | local opam | `zxcaml-p1` switch drifted to OCaml 5.4.1 (compiler-libs API breaks: `Texp_atomic_loc`, `Longident.Ldot` loc-wrapping); project pins 5.2.x. | Done 2026-06-10: switch recreated at 5.2.1; `init.sh` drift guard now prints the exact recreation commands. | medium | done |
| CR-11 | lsp | `src/lsp/session.zig` (`resolveOmlzPath`) | The LSP server spawned `omlz` via cwd-relative `zig-out/bin/omlz`, so an installed `omlz-lsp` only worked from the repo root (same class as CR-1). | Done 2026-06-10: resolved once at server start next to the `omlz-lsp` executable, with the historical fallback. | medium | done |
| CR-12 | codegen | `src/backend/zig_codegen/expr_emission.zig:278` | Native Zig codegen rejects user-constructed `account` records, so examples cannot fabricate accounts for native runs; `AccountMeta.of_account` had to be exercised through a typed helper function instead of a direct entrypoint demo. | Decide whether fabricated `account` values should be constructible on native (testing ergonomics) or document the restriction in docs/11. | low | open |
| CR-13 | core | `src/core/anf/type_ops.zig` (`lambdaParamIsAccount`) | The param heuristic types any lambda param read via `is_writable`/`is_signer` as `account`, so a `check_meta (m : account_meta)` helper misinfers its param as `account`. Wire 1.3 typed params should make the heuristic unnecessary when an annotation exists. | Prefer the wire-supplied param type over the field-read heuristic when present. | medium | open |

## Explicitly skipped (with reasons)

- **Codegen `Emitter` abstraction** — `append`/`appendPrint` are already
  shared free functions in `src/backend/zig_codegen/common.zig`; converting to
  method style would touch 100+ golden-tested call sites for zero behavior
  gain.
- **Moving `src/target/` under `src/driver/`** — the four target modules
  (registry/capability/preflight/manifest) form a coherent layer already; a
  move would churn the repo-layout contract for no structural win.
