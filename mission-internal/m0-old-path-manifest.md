# M0 Old-Path Manifest

This manifest enumerates the current path contract that later cleanup phases must preserve through compatibility shims or same-change updates. It is intentionally path-centric so M1-M6 workers can diff proposed moves against current consumers before changing layout.

## Manifest rules

- “Consumer surfaces” names the tracked build files, scripts, docs, tests, CI, or generated outputs that currently rely on the old path.
- “Compatibility rule” states whether the path must stay stable, may move behind a shim, or must be updated everywhere in one phase.
- “Validation surface” names the proof that must stay green after a move.

| Old path / prefix | Consumer surfaces today | Why it is externally consumed | Compatibility rule before moves | Validation surface |
| --- | --- | --- | --- | --- |
| `build.zig` | `zig build*`, CI, docs, README, Makefile-derived workflows | sole build entrypoint | keep root path stable | `zig build`, `zig build test --summary none` |
| `src/main.zig` | `build.zig`, CLI help/tests, docs | `omlz` executable root | may thin internally, but keep built executable behavior stable | CLI help and subcommand tests |
| `src/omlz/` | `src/main.zig`, CLI tests, docs | subcommand implementation family | may split internally without changing command names/help | `zig build test --summary none` |
| `src/lsp/` | `build.zig`, `tests/lsp/**`, docs | `omlz-lsp` implementation | may refactor internally; keep installed binaries and JSON-RPC behavior | LSP tests and `make lsp-bench` |
| `src/driver/` | `src/main.zig`, `build.zig`, docs | build/run/BPF/source-map pipeline internals | may move only with exact same-change updates to callers | BPF, source-map, help, build validators |
| `src/frontend/` | `build.zig`, docs, formatter/tests | OCaml compiler-libs bridge and formatter core | keep seam explicit; path changes require build + docs updates together | `zig build`, formatter tests |
| `src/frontend_bridge/` | `build.zig`, wire tests, docs | Zig wire parser and typed-tree mirror | move only with build/test/docs updates in one phase | wire compatibility tests |
| `src/core/`, `src/lower/`, `src/backend/`, `src/util/` | `build.zig`, compiler tests, docs | compiler-internal module families | internal reorg allowed, but all imports/tests must update atomically | Zig test suite |
| `runtime/lsp/` | `tests/lsp/run_lsp_check.py`, docs | LSP harness fixtures | may move only with harness updates in same change | LSP harness |
| `runtime/zig/arena.zig` | `build.zig`, `src/driver/{build,bpf}.zig`, generated `out/runtime/**` | generated runtime shim | keep reachable until generator changes and import matrix update land together | artifact characterization, BPF builds |
| `runtime/zig/account.zig` | `build.zig`, `src/driver/{build,bpf}.zig`, runtime tests, generated outputs | Solana account runtime surface | may move behind shim; public/generated import path must keep working | Zig tests, Cargo tests, Surfpool flows |
| `runtime/zig/cpi.zig` | `build.zig`, `src/driver/{build,bpf}.zig`, examples/tests/docs | CPI runtime surface | same-change shim or path update required | Cargo + Surfpool CPI flows |
| `runtime/zig/entry_context.zig` | `build.zig`, `src/driver/{build,bpf}.zig`, generated outputs | SDK-backed entry context | keep reachable for generated runtime copy stage | artifact characterization |
| `runtime/zig/{panic,prelude,bs58}.zig` | `build.zig`, `src/driver/{build,bpf}.zig`, docs | shared runtime support | same-change update required if moved | Zig tests, BPF smoke |
| `runtime/zig/{spl_token,syscalls,sysvar}.zig` | `build.zig`, `src/driver/{build,bpf}.zig`, examples/tests/docs | Solana helper runtime surface | preserve public/generated reachability | Cargo tests, Surfpool flows |
| `runtime/zig/bpf_entry.zig` | `src/driver/bpf.zig`, `out/bpf_entry.zig`, docs | generated BPF entry shim | keep generated destination stable unless source-map/build contract changes atomically | BPF smoke, artifact characterization |
| `runtime/zig/native_entry.zig` | `src/driver/build.zig`, `out/native_entry.zig`, docs | generated native entry shim | keep generated destination stable unless same-change update | native build tests |
| `runtime/zig/sdk/root.zig` | `build.zig`, `src/driver/{build,bpf}.zig`, import smoke, generated outputs | public SDK adapter root | may move only with compatibility export/shim | vendored SDK import smoke |
| `runtime/zig/sdk/import_smoke.zig` | `build.zig`, import smoke target | validation-only SDK import surface | keep reachable or update the smoke target in same phase | `zig build vendored-sdk-import-smoke` |
| `runtime/zig/sdk/solana_program_sdk_m4.zig` | `build.zig`, `src/driver/{build,bpf}.zig` | adapter bridge to vendored SDK | same-change update required | runtime import smoke, BPF build |
| `runtime/zig/programs/common.zig` | `src/driver/{build,bpf}.zig`, program-port helpers | shared program-port support | keep reachable until generator/ports move together | artifact characterization, program tests |
| `runtime/zig/programs/*.zig` | `src/driver/{build,bpf}.zig`, examples, Cargo tests, Surfpool flows | program-port helpers for Solana fixtures | may move only with updated copy list + all downstream validations | Cargo tests, Surfpool flows |
| `vendor/solana-program-sdk-zig/src/zxcaml_m2_root.zig` | `build.zig`, `src/driver/{build,bpf}.zig` | vendored compatibility root | must stay stable; do not edit vendor | vendored SDK path scan, import smoke |
| `vendor/solana-program-sdk-zig/packages/solana-codec/src/root.zig` | `build.zig`, `src/driver/{build,bpf}.zig` | vendored codec root | must stay stable; do not edit vendor | import smoke |
| `vendor/solana-program-sdk-zig/packages/spl-token/src/zxcaml_m4_root.zig` | `build.zig`, `src/driver/{build,bpf}.zig` | vendored SPL-Token compatibility root | must stay stable; do not edit vendor | import smoke, SPL flows |
| `vendor/solana-program-sdk-zig/packages/spl-ata/src/zxcaml_m4_root.zig` | `build.zig`, `src/driver/{build,bpf}.zig` | vendored SPL-ATA compatibility root | must stay stable; do not edit vendor | import smoke, ATA flows |
| `stdlib/core.ml` | examples, docs, LSP completion, tests | shipped stdlib implementation | keep root path stable unless docs/tests/update flow changes atomically | examples check, Zig tests |
| `stdlib/generators.ml` | `tests/property*`, `omlz test`, docs | property generator contract | keep reachable until test-runner updates land | test runner/property tests |
| `examples/*.ml` | README, docs, examples corpus script, CLI smoke, Cargo tests, Surfpool flows, site/demo references | user-facing example and fixture surface | no path move before M3 manifest + docs + validators | examples corpus, Cargo, Surfpool |
| `examples/tests/*.ml` | `src/omlz/test.zig`, examples README, docs | default `omlz test` discovery root | keep stable until M3 explicit replacement exists | `omlz test` validators |
| `examples/README.md` | docs, example discoverability, M3 parity checks | human-facing example index | keep links current if any example path changes | examples README check |
| `tests/Cargo.toml` | README, docs, CI references, local validation | Rust/Mollusk entrypoint | root manifest path stays stable | `cargo test --manifest-path tests/Cargo.toml` |
| `tests/*_test.rs` | `tests/Cargo.toml`, docs, validation flow | Rust integration targets | path changes require same-change manifest edits | Cargo test suite |
| `tests/bpf_test_support.rs`, `tests/equivalence_test_support.rs` | Rust integration tests | shared harness logic | may move only with same-change import updates | Cargo test suite |
| `tests/golden/**` | Zig tests, docs, formatter/IR/source-map baselines | committed snapshot contract | keep relative paths stable until dedicated M3 migration updates all callers | Zig tests |
| `tests/ui/**` | Zig tests, diagnostics docs | UI baseline contract | same-change test harness and docs update required | Zig tests |
| `tests/lsp/**` | `build.zig`, Makefile, docs | LSP validation and benchmark surface | keep stable or update all harness callers together | Zig tests, `make lsp-bench` |
| `tests/idl/**` | CI, docs, IDL smoke | IDL validation fixtures | same-change updates only | Zig tests, IDL smoke |
| `tests/solana/**` | README, docs, scripts, `demo.sh`, services manifest | Surfpool/localnet harness surface | keep stable until M3/M6 validate replacements | Surfpool commands |
| `scripts/check_examples_corpus.sh` | services manifest, docs, CI/local validation | user-facing validator command | keep repo-root invocation stable | examples check |
| `scripts/characterize_build_artifacts.sh` | services manifest, M0/M2/M6 evidence | artifact contract validator | keep stable | artifact characterization |
| `scripts/check_no_obsolete_runtime_surfaces.sh` | services manifest | runtime surface validator | keep stable | obsolete-surface scan |
| `scripts/check_vendored_sdk_paths.sh` | services manifest | SDK boundary validator | keep stable | vendored SDK path scan |
| `scripts/check_vendored_sdk_secrets.sh` | services manifest | SDK hygiene validator | keep stable | vendored SDK secret scan |
| `scripts/lsp_bench_30_rounds.py` | docs and perf history | extended DX benchmark helper | may move only with docs/update flow | optional perf evidence |
| `scripts/demo/**` | `Makefile`, docs/hackathon, slides, demo flows | hackathon automation surface | same-change updates required if moved | demo spot checks, later Surfpool smoke |
| `demo.sh` | user-facing demo command, docs | historical demo wrapper | keep callable or later document migration explicitly | static path check in M0 |
| `.github/workflows/ci.yml` | GitHub Actions | CI path contract | keep workflow path stable | static path validation |
| `Makefile` | local developer workflows | stable alias surface | target names stay stable | `make -n` spot checks |
| `package.json` | site workflows | stable npm script names | script names stay stable | package path checks |
| `slides/package.json` | slides workflows | slide build/dev/export contract | keep script names and referenced files stable | static path check, `make -n slides-export-pdf` |
| `site/index.html`, `site/styles.css`, `site/assets/**`, `site/_headers` | root npm scripts, deploy workflow | published site surface | may move only with coordinated deploy and link updates | static path check |
| `site/CONTENT.md` | mission-history note for site work | tracked but unpublished note | treat as mission-only/historical, not public route | static path check only |
| `README.md`, `INSTALLING.md`, `docs/**` | public docs, validators, future docs parity | path references consumed by humans and docs checks | update paths in same change as any move | docs checks from M4 onward |
| `out/program.zig` | `src/main.zig`, tests, docs | generated Zig output path | path contract must stay stable until CLI/build contract intentionally changes | source-map/BPF/build tests |
| `out/native_entry.zig` | `src/main.zig`, `src/driver/build.zig`, docs | generated native entry shim path | same-change update required if renamed | native build tests |
| `out/bpf_entry.zig` | `src/driver/bpf.zig`, tests, docs | generated BPF entry shim path | same-change update required if renamed | BPF build tests |
| `out/runtime/**` | `src/driver/{build,bpf}.zig`, docs, characterization scripts | generated runtime copy tree | same-change generator updates required | artifact characterization |
| `out/*.map` | `omlz unmap`, docs, source-map tests | generated source-map contract | keep default location semantics stable | source-map tests |
| `out/hackathon_greet.json` | site preview, docs/hackathon, demo scripts | checked-in generated IDL sample | keep reachable or update all doc/demo references together | static path checks, IDL smoke |
| `build/.gitkeep` | artifact routing assumptions | tracked build dir seed | keep as placeholder | static path check |
| `zig-out/bin/omlz`, `zig-out/bin/zxc-frontend`, `zig-out/bin/omlz-lsp`, `zig-out/bin/lsp-bench` | README, docs, Makefile, tests | installed binary paths from `zig build` | install graph behavior must remain stable | `zig build`, CLI/LSP tests |

## Manifest usage in later milestones

1. Before moving a path family, grep this manifest for the old prefix.
2. Update every listed consumer in the same phase, or add a compatibility shim/alias.
3. Run the listed validation surface before handoff.
4. Record the move outcome in the phase handoff so M6 can prove old-to-new coverage.
