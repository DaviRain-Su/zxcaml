# M0 Inventory and Structure Contract

This planning artifact defines the repository inventory, ownership map, artifact policy, target structure, compatibility rules, bilingual docs strategy, automation surfaces, and phase gates for feature `m0-inventory-structure-contract`.

## Scope and evidence

- Repo root: `/Users/davirian/dev/active/ZxCaml`
- Required assertions: `VAL-INV-001` through `VAL-INV-015`
- Inventory evidence sources:
  - `git ls-files`
  - `git status --ignored --short`
  - `README.md`
  - `docs/07-repo-layout.md`
  - `build.zig`
  - `.github/workflows/ci.yml`
  - `Makefile`
  - `package.json`
  - `slides/package.json`
  - `scripts/`

## Tracked top-level surface

Each tracked top-level path from `git ls-files` is classified below. Any untracked or ignored path is handled later in the artifact policy instead of the tracked-surface contract.

| Path | Tracked files | Class | Primary owner | Secondary / shared responsibility | M0 scope note |
| --- | ---: | --- | --- | --- | --- |
| `.github` | 1 | automation | Release / CI surface | Compiler and validation maintainers | Keep workflow path contract stable |
| `.gitignore` | 1 | policy | Repo hygiene | All workers | Source of truth for generated vs ignored paths |
| `.pi` | 1 | provenance record | Agent/provenance history | Mission audit | Out of cleanup move scope unless explicitly reassigned |
| `CHANGELOG.md` | 1 | historical docs | Release history | Docs sync later | Track only as docs surface |
| `INSTALLING.md` | 1 | active docs | Docs surface | Tooling / DX | Path and command references must stay valid |
| `Makefile` | 1 | automation | Developer workflow surface | Demo / slides flows | User-facing aliases must remain stable |
| `README.md` | 1 | active docs | Docs surface | Compiler / runtime facts | Public quickstart and status contract |
| `anf_tests.zig` | 1 | test root | Compiler validation | Zig test graph | Behavior-preserving characterization only |
| `build` | 1 | tracked artifact seed | Build/test artifact routing | CLI/build validators | Only `build/.gitkeep` is tracked |
| `build.zig` | 1 | source | Build orchestration | All validators | Public build graph root; path stable |
| `build.zig.zon` | 1 | dependency config | Build orchestration | Vendoring | Pinned Zig dependency manifest |
| `core_loc_tests.zig` | 1 | test root | Compiler validation | Zig test graph | Behavior-preserving characterization only |
| `demo.sh` | 1 | automation | Demo surface | Solana flow docs | Legacy demo entrypoint; keep callable or document migration later |
| `docs` | 68 | active + historical docs | Documentation surface | Every milestone after M0 | English current-state and history docs |
| `examples` | 108 | source corpus | Example surface | CLI/test runner/docs | User examples plus `examples/tests` fixtures |
| `init.sh` | 1 | automation | Environment bootstrap | CI / local setup | Stable bootstrap contract |
| `inline_tests.zig` | 1 | test root | Compiler validation | Zig test graph | Behavior-preserving characterization only |
| `mission-internal` | 3 | mission-history / planning artifacts | Mission history | Mission audit / docs sync follow-up | Tracked planning history stays out of public-doc cleanup unless a later docs milestone intentionally promotes it |
| `out` | 1 | tracked generated seed | Artifact routing | CLI/build/docs demo | Only `out/hackathon_greet.json` is tracked |
| `package.json` | 1 | automation | Site workflow surface | Cloudflare Pages deploy | Public npm script names must remain stable |
| `runtime` | 35 | source + runtime test support | Runtime surface | CLI/build/Surfpool | Split between `runtime/lsp` and `runtime/zig` |
| `scripts` | 21 | automation | Validator and demo scripts | CI / local workflows | Root shell entrypoints must keep repo-root semantics |
| `site` | 14 | deployment source | Site surface | Docs/demo | Published site assets plus an unpublished tracked note |
| `slides` | 6 | presentation source | Slides workflow | Demo / docs | Slide sources and lockfile are tracked |
| `spike` | 6 | historical research | Research archive | Docs / future archaeology | Explicitly out of cleanup moves unless referenced |
| `src` | 61 | compiler source | Compiler surface | CLI/build/runtime generation | Primary implementation tree |
| `stdlib` | 3 | source | Stdlib surface | CLI/test runner | Pure OCaml support sources and tests |
| `tests` | 351 | validation source | Validation surface | CLI/runtime/Surfpool/docs | Zig, Rust, LSP, UI, golden, and Solana harnesses |
| `vendor` | 155 | vendored dependency | Vendored SDK surface | Runtime adapters / build graph | Read-only for cleanup work |
| `wrangler.toml` | 1 | deployment config | Site workflow surface | Cloudflare Pages deploy | Root site deployment config |

## Ownership map for required workflow areas

### `src/`

| Path | Tracked files | Role | Primary owner | Secondary / shared responsibility |
| --- | ---: | --- | --- | --- |
| `src/main.zig` | 1 | CLI entrypoint and help surface | CLI surface | Build/runtime dispatch stability |
| `src/omlz/` | 3 | user-facing subcommand modules | CLI surface | Test/help coverage |
| `src/lsp/` | 5 | LSP server implementation | Editor / DX surface | CLI build/install graph |
| `src/build_lock.zig` | 1 | shared build lock helper | Build orchestration | CLI/tests that share generated outputs |
| `src/driver/` | 6 | pipeline, build, BPF, source-map routing | Build orchestration | Runtime shim generation |
| `src/frontend/` | 6 | OCaml compiler-libs bridge and formatter core | Frontend bridge | CLI / tests |
| `src/frontend_bridge/` | 3 | Zig wire parser and typed-tree mirror | Frontend bridge | Core IR lowering |
| `src/core/` | 17 | IR, lowering front-half, no-alloc, analysis | Compiler core | Diagnostics and codegen |
| `src/lower/` | 4 | lowered IR and strategy | Compiler core | Backend contracts |
| `src/backend/` | 12 | interpreter and Zig codegen | Backend/codegen | Runtime import contract |
| `src/util/` | 3 | diagnostics/render utilities | Shared compiler infrastructure | LSP and CLI output |

### `runtime/`

| Path | Tracked files | Role | Primary owner | Secondary / shared responsibility |
| --- | ---: | --- | --- | --- |
| `runtime/lsp/` | 2 | Python LSP harness fixtures | Editor / DX validation | Zig/LSP tests |
| `runtime/zig/arena.zig` | 1 | core runtime allocator | Runtime core | Generated output layout |
| `runtime/zig/{account,cpi,entry_context,spl_token,syscalls,sysvar}.zig` | 6 | Solana-facing runtime support | Runtime Solana surface | Surfpool, Cargo, examples |
| `runtime/zig/{bpf_entry,native_entry,panic,prelude,bs58}.zig` | 5 | shared entry/runtime shims | Runtime core | CLI build output |
| `runtime/zig/sdk/` | 3 | SDK adapter root and import smoke | SDK adapter surface | Generated import compatibility |
| `runtime/zig/programs/` | 15 | program-port helper modules | Runtime program adapters | Examples, Surfpool, Cargo |
| `runtime/zig/{ata_tests,programs_tests,syscall_equivalence_host_runner}.zig` | 3 | runtime characterization tests | Runtime validation | Zig test graph |

### `stdlib/`

| Path | Tracked files | Role | Primary owner | Secondary / shared responsibility |
| --- | ---: | --- | --- | --- |
| `stdlib/core.ml` | 1 | shipped stdlib surface | Stdlib surface | Examples/docs/tests |
| `stdlib/core_tests.ml` | 1 | stdlib behavior tests | Stdlib validation | `omlz test` coverage |
| `stdlib/generators.ml` | 1 | property-test generators | Stdlib validation | `tests/property*` and `omlz test` |

### `examples/`

| Path | Tracked files | Role | Primary owner | Secondary / shared responsibility |
| --- | ---: | --- | --- | --- |
| `examples/*.ml` | 95 | user-visible example corpus and Solana fixtures | Example surface | CLI smoke, docs, Cargo/Surfpool fixtures |
| `examples/tests/*.ml` | 12 | `omlz test` discovery fixtures | Test-runner surface | Examples README/docs |
| `examples/README.md` | 1 | example catalog and taxonomy | Example docs | M3 manifest parity |

### `tests/`

| Path | Tracked files | Role | Primary owner | Secondary / shared responsibility |
| --- | ---: | --- | --- | --- |
| `tests/Cargo.toml` | 1 | Rust/Mollusk entry manifest | Rust/Solana validation | Runtime/examples contract |
| `tests/*_test.rs`, support `.rs`, top-level `.zig` | 55 | top-level harnesses and Cargo targets | Validation surface | Build/runtime/example contracts |
| `tests/anf/` | 1 | ANF-specific tests | Compiler validation | Core lowering |
| `tests/cli/` | 10 | CLI help/error/report/srcmap/BPF contract tests | CLI validation | Build/runtime artifact routing |
| `tests/codegen/` | 6 | codegen regression tests | Backend validation | Runtime import contract |
| `tests/core/` | 1 | core compiler unit coverage | Compiler validation | IR contract |
| `tests/fixtures/` | 14 | reusable inputs for parser/fmt/property cases | Shared validation fixtures | CLI/LSP/fmt |
| `tests/frontend_bridge/` | 1 | wire/location compatibility test | Frontend bridge validation | Docs/wire contract |
| `tests/golden/` | 128 | IR/UI/fmt/golden baselines | Golden validation | Docs and CLI parity |
| `tests/idl/` | 3 | IDL smoke coverage | CLI/runtime validation | Docs/demo |
| `tests/inline/` | 1 | inline test support | Compiler validation | Zig test graph |
| `tests/lsp/` | 9 | LSP harness, bench, scripts | Editor / DX validation | Build/install graph |
| `tests/property/` | 2 | property-based regression tests | Compiler validation | Stdlib generators |
| `tests/solana/` | 16 | Surfpool/localnet flows | Runtime/Solana validation | Scripts/docs/demo |
| `tests/src/` | 1 | source-relative harness helpers | Compiler validation | Test graph completeness |
| `tests/ui/` | 102 | end-to-end diagnostics fixtures | CLI validation | Docs/examples negative cases |

### `scripts/`

| Path | Tracked files | Role | Primary owner | Secondary / shared responsibility |
| --- | ---: | --- | --- | --- |
| `scripts/check_examples_corpus.sh` | 1 | example-corpus validator | Validation automation | Examples/docs parity |
| `scripts/characterize_build_artifacts.sh` | 1 | generated-artifact characterization | Build/runtime validation | M0/M2/M6 evidence |
| `scripts/check_no_obsolete_runtime_surfaces.sh` | 1 | runtime public-surface guard | Runtime validation | M2/M6 evidence |
| `scripts/check_vendored_sdk_paths.sh` | 1 | vendored SDK path hygiene | SDK boundary enforcement | M2/M6 evidence |
| `scripts/check_vendored_sdk_secrets.sh` | 1 | vendored SDK secret hygiene | SDK boundary enforcement | M2/M6 evidence |
| `scripts/lsp_bench_30_rounds.py` | 1 | long-run LSP benchmark helper | Editor / DX validation | Performance history |
| `scripts/demo/` | 15 | hackathon demo flow and teardown | Demo automation | Slides/site/docs references |

### `vendor/`

| Path | Tracked files | Role | Primary owner | Secondary / shared responsibility |
| --- | ---: | --- | --- | --- |
| `vendor/solana-program-sdk-zig/README.md`, metadata, build files | 6 | vendored package metadata | Vendored SDK surface | Runtime adapter boundary |
| `vendor/solana-program-sdk-zig/packages/` | 37 | vendored package roots (`solana-codec`, `solana-system`, `spl-*`) | Vendored SDK surface | Runtime adapter imports |
| `vendor/solana-program-sdk-zig/src/` | 112 | vendored SDK implementation | Vendored SDK surface | Must remain read-only to repo cleanup workers |

## Source / generated / vendor / artifact policy

This table is the explicit policy required by `VAL-INV-003` and `VAL-INV-010`.

| Location | Status | Owner | Regeneration source | Cleanup / move rule |
| --- | --- | --- | --- | --- |
| `src/`, `runtime/zig/`, `runtime/lsp/`, `stdlib/`, `examples/`, `tests/`, `scripts/`, `site/`, `slides/`, `docs/` | first-party source | Area owner from inventory | edited directly | May be reorganized only through milestone-specific compatibility work |
| `vendor/solana-program-sdk-zig/` | vendored dependency | Vendored SDK surface | refreshed only by explicit vendoring workflow | No cleanup worker may edit or move vendor contents |
| `build/.gitkeep` | tracked artifact seed | Build/test artifact routing | maintained manually | Keep as placeholder; do not repurpose as source |
| `out/hackathon_greet.json` | tracked generated sample | Demo/docs surface | `./zig-out/bin/omlz idl examples/hackathon_greet.ml` | Treated as checked-in generated artifact; changes require intentional regeneration |
| `out/program.zig`, `out/native_entry.zig`, `out/bpf_entry.zig`, `out/runtime/**`, `out/*.map`, `out/*.so`, `out/*.bc`, `out/slides/**` | ignored generated artifacts | CLI/build/runtime flows | `omlz build`, tests, slides export | Safe to replace during validation; do not commit unless a milestone explicitly changes artifact baselines |
| `build/*.so`, `build/*.bc`, `build/characterization/**`, `build/characterization-tests/**`, `build/syscall_equivalence_host_runner` | ignored generated artifacts | Build/test validation | Zig/Cargo/characterization flows | Safe to replace during validation; never treat as editable source |
| `zig-cache/`, `.zig-cache/`, `zig-out/` | ignored build cache/install | Build orchestration | `zig build*` | Safe to replace; never move into tracked source |
| `.surfpool/`, `scripts/demo/.keypairs/`, `scripts/demo/.program_id`, `scripts/demo/.surfpool.pid` | ignored local state | Surfpool/demo automation | Surfpool/demo scripts | Delete only via exact cleanup commands for owned demo runs |
| `tests/target/`, `tests/Cargo.lock` | ignored Rust build artifacts | Cargo validation | `cargo test --manifest-path tests/Cargo.toml` | Safe to replace; keep out of tracked source |
| `slides/node_modules/`, `slides/dist/`, `.wrangler/`, `droid-wiki/`, `solana-zig/` | ignored local/generated tooling state | Slides/site/wiki tooling | `pnpm`, `wrangler`, wiki refresh, local vendoring | Out of tracked cleanup scope |
| `spike/bpf-toolchain/zignocchio/**`, `spike/ocaml-cmt-read/_build/` | ignored research artifacts | Spike archive | spike reproduction scripts | Keep spikes historical; generated outputs stay ignored |
| `mission-internal/` | tracked historical notes + ignored working-note prefix | Mission history | written intentionally with `git add -f` when needed | Use for mission-history artifacts; do not move into public docs until a docs milestone decides so |
| `.pi/sessions/*.jsonl` | tracked provenance record | Mission/provenance history | Factory agent capture | Treat as historical evidence, not product source |

## Target structure contract

M0 does not move code. It defines the target structure that later workers must converge toward while preserving compatibility.

| Workflow area | Current canonical roots | Target structure contract | Notes |
| --- | --- | --- | --- |
| CLI entry and command UX | `src/main.zig`, `src/omlz/`, `src/lsp/` | Keep `src/main.zig` as the thin public executable root; move command-specific logic behind stable submodules under `src/omlz/` and keep editor/LSP code isolated under `src/lsp/` | M1 may split hotspots but must not remove public command surfaces |
| Build orchestration | `build.zig`, `src/driver/`, `src/build_lock.zig` | Keep `build.zig` as the only build entrypoint; push reusable helper logic behind smaller build/driver modules rather than alternate roots | Public `zig build*` contract stays rooted at repo top |
| Frontend bridge | `src/frontend/`, `src/frontend_bridge/` | Preserve the single OCaml↔Zig seam and keep its paths explicit | No second language seam should be introduced |
| Core compiler | `src/core/`, `src/lower/`, `src/backend/`, `src/util/` | Preserve these as compiler-internal families with clearer submodule boundaries, not user-facing relocation targets | Internal refactors must keep help/tests/build behavior stable |
| Runtime core vs Solana support | `runtime/zig/*.zig`, `runtime/zig/sdk/`, `runtime/zig/programs/` | Normalize under one runtime root with explicit subfamilies: core runtime shims, Solana runtime helpers, SDK adapters, and program-port helpers | M2 may add compatibility shims while moving files |
| Standard library | `stdlib/*.ml` | Keep stdlib in its own OCaml root separate from runtime Zig code | No runtime imports from stdlib |
| User examples and fixtures | `examples/*.ml`, `examples/tests/*.ml`, `examples/README.md` | Keep documented user examples discoverable from `examples/`; keep `examples/tests/` as explicit test-runner fixtures; use manifests before any path move | M3 should prefer manifests/taxonomy over mass renames |
| Validation suites | `tests/` plus root `*_tests.zig` files | Keep `tests/Cargo.toml` as the Rust entrypoint and preserve suite-specific subdirectories under `tests/` | Reorg must not hide golden/UI/LSP/Surfpool fixtures |
| Automation | `scripts/`, `Makefile`, `package.json`, `slides/package.json`, `.github/workflows/ci.yml` | Keep repo-root entrypoints stable; underlying helpers may move only with exact path updates and sampled no-op validation | Automation is part of the compatibility contract |
| Docs and web/demo surfaces | `README.md`, `INSTALLING.md`, `docs/`, `site/`, `slides/`, `mission-internal/` | Public docs stay in `README.md`, `INSTALLING.md`, and `docs/`; mission-history and planning artifacts stay in `mission-internal/`; site/slides keep separate roots | M4 owns public docs sync, not M0 |
| Vendored code and spikes | `vendor/`, `spike/` | Vendor remains read-only; spike stays historical and out of product moves | Later workers may reference but not normalize them as source |

## Compatibility and migration rules

The old-path manifest in `mission-internal/m0-old-path-manifest.md` is the exhaustive baseline of externally consumed paths. The following rules are binding on later phases.

1. **Public command contract stays stable.**
   - `zig build`, `zig build test --summary none`, `cargo test --manifest-path tests/Cargo.toml`, `./scripts/check_examples_corpus.sh`, and existing `omlz` subcommands must keep their repo-root invocation contract.
2. **Top-level entrypoints do not move without a shim.**
   - `build.zig`, `init.sh`, `Makefile`, `package.json`, `wrangler.toml`, `.github/workflows/ci.yml`, `demo.sh`, and `tests/Cargo.toml` remain canonical roots.
3. **Generated runtime import paths stay stable until explicit cutover.**
   - `out/program.zig`, `out/native_entry.zig`, `out/bpf_entry.zig`, `out/runtime/**`, `runtime/zig/sdk/root.zig`, `runtime/zig/sdk/import_smoke.zig`, and the vendored compatibility roots consumed by `src/driver/{build,bpf}.zig` must remain reachable or receive exact replacements in the same change.
4. **Examples and tests remain runnable from their current documented entrypoints until M3 lands.**
   - No worker may move `examples/*.ml`, `examples/tests/*.ml`, `tests/solana/**`, `tests/golden/**`, or `tests/ui/**` without also updating manifests, docs, and validation in the same phase.
5. **Vendor paths are compatibility inputs, not move targets.**
   - `vendor/solana-program-sdk-zig/**` remains addressable from build/runtime shims and cannot be rewritten by cleanup work.
6. **Historical and unpublished docs keep explicit boundaries.**
   - `mission-internal/`, `spike/`, and `site/CONTENT.md` may be referenced as historical or unpublished surfaces, but later phases must not silently treat them as public product docs.

## Bilingual documentation strategy

M0 only defines the strategy; M4 performs the user-facing sync.

| Rule | Contract |
| --- | --- |
| Canonical terminology | English terminology is canonical for names, module labels, command flags, wire/runtime terms, and repo path spellings. |
| Required parity | Every active English current-state document touched after M4 must have a Chinese counterpart under `docs/zh/` or an explicit routed counterpart. |
| Update workflow | Any change to active English docs must be paired with the corresponding Chinese update in the same change unless the doc is explicitly historical/generated/unpublished. |
| Review criteria | Review checks must compare headings, commands, current facts, example paths, and repo-path references across English and Chinese pairs. |
| Historical handling | ADRs, spikes, and superseded docs keep history intact, but current-status notes must distinguish historical facts from active guidance. |
| Mission-history notes | Planning artifacts in `mission-internal/` may remain English-only during M0-M3, but any content promoted into active docs during M4 must gain Chinese parity. |

## Automation surface inventory

| Surface | Current entrypoints | Path assumptions that must remain valid | Planned proof |
| --- | --- | --- | --- |
| CI | `.github/workflows/ci.yml` | `./init.sh`, `zig build`, `zig build test`, `zig-out/bin/omlz`, `tests/Cargo.toml`, `scripts/check_examples_corpus.sh`, `tests/solana/hello/invoke.sh` | Static path validation in M0; runtime validation in later milestones |
| Root bootstrap | `init.sh` | repo-root tool bootstrap, OCaml/Zig/Rust/Solana setup | baseline install command |
| Make aliases | `make demo`, `make lsp-bench`, `make slides-export-pdf`, cleanup targets | `scripts/demo/**`, `zig-out/bin/omlz`, `slides/`, `out/slides/` | `make -n` spot checks in M0 |
| Root npm scripts | `npm run site:dev`, `npm run site:deploy` | `site/`, `wrangler.toml`, `package.json` | static path check in M0 |
| Slides package | `slides/package.json` scripts | `slides.zh.md`, `dist/`, `../out/slides` | static path check and `make -n slides-export-pdf` |
| Root demo | `demo.sh` | `examples/demo.ml`, `examples/spl_token_transfer.ml`, `tests/solana/hello/invoke.sh`, `zig-out/bin/omlz` | static path check only in M0 because the feature is behavior-neutral |
| Validation scripts | `scripts/check_examples_corpus.sh`, `scripts/characterize_build_artifacts.sh`, `scripts/check_no_obsolete_runtime_surfaces.sh`, `scripts/check_vendored_sdk_paths.sh`, `scripts/check_vendored_sdk_secrets.sh` | current repo-root relative paths in examples/tests/runtime/vendor/out/build | executed in milestone-specific validation suites |
| Demo helper scripts | `scripts/demo/*.sh` | `examples/hackathon_greet.ml`, `out/hackathon_greet.json`, Surfpool state, `slides/`, `docs/hackathon/**` | later smoke runs after relevant moves |
| Site source | `site/index.html`, `site/styles.css`, `site/assets/**`, `site/_headers`, `site/CONTENT.md` | relative asset paths and GitHub doc links | static path check in M0; docs/site sync later |

## Workflow sequencing and clean-tree phase gates

The mission order is fixed and later workers must preserve it.

| Phase | Scope | Start gate | End gate |
| --- | --- | --- | --- |
| M0 | inventory, ownership, policy, target structure, manifests | `git status --porcelain` empty; baseline `zig build test --summary none` passes | repo committed clean; `zig build`, `cargo test`, examples check, and automation spot checks pass |
| M1 | CLI/build split | M0 committed; old-path manifest available | repo committed clean; CLI/build validators pass |
| M2 | runtime/Solana layout normalization | M1 committed; SDK boundaries understood | repo committed clean; runtime import, Surfpool, and SDK hygiene validators pass |
| M3 | examples/tests organization | M2 committed; old-path + impact manifests available | repo committed clean; examples/tests manifests and validators pass |
| M4 | bilingual docs sync and docs checker | M3 committed; final layout known | repo committed clean; docs checker becomes mandatory |
| M5 | Solana DX/API planning scaffold | M4 committed; docs parity established | repo committed clean; planning-only docs parity checks pass |
| M6 | final integration | M5 committed; prior validators green | repo committed clean; ordered final smoke passes with no orphan processes |

### M0 evidence captured during this feature

- Phase-start `git status --porcelain`: empty
- Baseline validator: `zig build test --summary none` passed before any edits
- M0 file diff is limited to planning artifacts under `mission-internal/`

Later workers should append new phase-boundary evidence in mission handoffs and, when useful, cross-link it from `mission-internal/`.
