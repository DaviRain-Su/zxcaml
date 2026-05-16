# 07 — Repo layout

> **Languages / 语言**: **English** · [简体中文](./zh/07-repo-layout.md)

This document records the **current** repository contract after the CLI/build
split, runtime-layout normalization, and examples/tests reorganization passes.
Older path sketches are preserved in history, but the paths below are the ones
that docs, validators, and generated-code shims should treat as canonical.

## 1. Top-level

```text
ZxCaml/
├── README.md / INSTALLING.md       -- user-facing entry docs
├── build.zig / build.zig.zon       -- single Zig build driver + dependency pins
├── src/                            -- compiler, CLI, LSP, frontend bridge
├── runtime/zig/                    -- runtime core, Solana support, SDK adapters, program ports
├── stdlib/                         -- bundled OCaml stdlib surface
├── examples/                       -- user-facing `.ml` examples plus `examples/tests/` OCaml-native test corpus
├── tests/                          -- Zig, Rust/Mollusk, LSP, UI, golden, and Surfpool harness coverage
├── scripts/                        -- validators, artifact checks, demo automation
├── docs/                           -- English docs
├── docs/zh/                        -- Chinese docs and routed counterparts
├── vendor/                         -- vendored dependencies (including `solana-program-sdk-zig`)
├── out/                            -- generated Zig/runtime/source-map artifacts
└── .github/workflows/              -- CI entrypoints
```

### 1.1 Single OCaml ↔ Zig seam

There is still exactly one inter-language boundary:

- `src/frontend/` — OCaml `compiler-libs` glue (`zxc-frontend`)
- `src/frontend_bridge/` — Zig wire parser / typedtree mirror

Everything above that seam is upstream-OCaml-facing frontend work; everything
below it is Zig-owned lowering, runtime, build orchestration, or developer
tooling.

## 2. `src/` — compiler, CLI, and LSP

```text
src/
├── main.zig              -- top-level `omlz` entrypoint and command wiring
├── build_lock.zig        -- build-output coordination / serialization helpers
├── frontend/             -- OCaml bridge, formatter front-end, wire emitter
├── frontend_bridge/      -- sexp lexer/parser + Typedtree mirror
├── core/                 -- Core IR, ANF lowering, pretty-printers
├── lower/                -- Lowered IR + lowering strategy
├── backend/              -- interpreter + Zig codegen
├── driver/               -- build/run/BPF/source-map orchestration
├── omlz/                 -- CLI subcommand implementation family
├── lsp/                  -- `omlz-lsp` implementation
└── util/                 -- shared compiler utilities
```

Important ownership boundaries:

- `src/main.zig` is the stable CLI executable root.
- `src/omlz/` owns subcommand behavior; keep public command names and help
  surfaces stable.
- `src/driver/` owns build/native/BPF/source-map orchestration.
- `src/lsp/` owns the stdio JSON-RPC server and benchmark helpers.

## 3. `runtime/zig/` — runtime core, Solana support, adapters, and ports

```text
runtime/zig/
├── arena.zig / panic.zig / prelude.zig / core.zig
├── account.zig / cpi.zig / syscalls.zig / sysvar.zig / spl_token.zig / bs58.zig
├── bpf_entry.zig / native_entry.zig / entry_context.zig
├── sdk/                  -- SDK-backed adapter roots and import-smoke surfaces
├── programs/             -- program-port helpers for Solana fixtures/examples
├── root.zig / shims.zig / solana.zig
└── *_tests.zig / import_matrix.zig / host runners
```

Current responsibilities are intentionally split:

- **runtime core:** arena, panic, prelude, entry shims
- **Solana support:** accounts, syscalls, sysvars, CPI, SPL Token, Bs58
- **SDK adapters:** `runtime/zig/sdk/**` bridges generated/runtime imports onto
  the vendored `solana-program-sdk-zig` surface
- **program ports:** `runtime/zig/programs/**` contains example-specific helper
  entrypoints used by generated code and test fixtures

Generated artifacts copy or embed from this tree; public/generated import paths
must remain stable or be updated atomically with all consumers.

## 4. `stdlib/`

`stdlib/core.ml` and `stdlib/generators.ml` remain the canonical bundled OCaml
surface. They must stay valid for both:

- the upstream OCaml toolchain used by `zxc-frontend`, and
- the ZxCaml subset consumed by `omlz`.

`stdlib/` is surface code only; it does not import runtime Zig files directly.

## 5. `examples/`

```text
examples/
├── README.md             -- example catalog / taxonomy
├── *.ml                  -- 95 user-facing example and fixture programs
├── tests/                -- default `omlz test` discovery root
└── ml-layout-manifest.tsv
```

Current example families include:

- core subset / stdlib smoke examples
- Solana account / syscall / sysvar / CPI / SPL / ATA / vault / DAO flows
- diagnostics / formatting / mutable-state / fixed-point demos
- hackathon and comparison fixtures

`examples/tests/*.ml` is the default OCaml-native test corpus for `omlz test`.
The intentionally failing diagnostic fixture remains `examples/m0_unsupported.ml`
and should stay excluded from pass-only corpus loops.

## 6. `tests/`

```text
tests/
├── Cargo.toml / *_test.rs         -- Rust/Mollusk integration suite
├── bpf_test_support.rs            -- shared Rust BPF build/load helpers
├── equivalence_test_support.rs    -- shared interpreter/native equivalence helpers
├── cli/ / lsp/ / golden/ / ui/    -- Zig and tooling-focused validation assets
├── idl/ / inline/ / property/     -- focused compiler/runtime suites
└── solana/                        -- Surfpool-backed deploy/invoke harnesses
```

Key contracts:

- `tests/Cargo.toml` is the stable Rust entrypoint.
- `tests/solana/**` is the stable Surfpool/localnet harness surface.
- `tests/ui/**`, `tests/golden/**`, and `tests/lsp/**` are baseline assets; do
  not move them without same-change harness updates.

## 7. `scripts/`

`scripts/` is a public automation surface, not just an implementation detail.
Important entrypoints include:

- `check_examples_corpus.sh`
- `check_examples_layout.py`
- `check_docs_sync.sh`
- `characterize_build_artifacts.sh`
- `check_no_obsolete_runtime_surfaces.sh`
- `check_vendored_sdk_paths.sh`
- `check_vendored_sdk_secrets.sh`
- `demo/**`

These commands are referenced by `services.yaml`, CI, docs, and mission
validators, so repo-root invocation behavior must remain stable.

## 8. Docs, demos, and generated artifacts

- `docs/` and `docs/zh/` are the current-state doc surfaces; bilingual routing
  is mandatory for active guidance.
- `scripts/demo/**` is the canonical hackathon/demo automation surface.
- `demo.sh` is the lightweight repo-root demo wrapper.
- `out/` is the canonical generated-artifact location for emitted Zig, runtime
  copies, source maps, and related transient build outputs.

## 9. Conventions

- **Surfpool is the only active local Solana backend.** Current docs and
  harnesses should not treat any legacy validator workflow as the live path.
- **Vendor paths are inputs, not refactor targets.** Do not edit
  `vendor/solana-program-sdk-zig/**` during normal repository cleanup work.
- **Keep repo-root commands stable.** `zig build`, `cargo test --manifest-path
  tests/Cargo.toml`, `./scripts/check_examples_corpus.sh`, and
  `./scripts/check_docs_sync.sh` are compatibility surfaces.
- **Keep generated code under `out/`.** No emitted artifacts should spill into
  `src/`, `runtime/zig/`, or example/test fixture directories unless a
  regeneration flow explicitly requires it.
