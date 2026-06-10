# AGENTS.md — agent guide for ZxCaml

> **Languages / 语言**: **English** · [简体中文](./docs/zh/AGENTS.md)

This is the entry point for coding agents (Claude Code, Codex, Cursor, …).
It routes to the authoritative docs instead of duplicating them — when this
file and a linked doc disagree, the linked doc wins.

## What this is

ZxCaml is an **OCaml dialect with a Zig/BPF backend**. We do not fork or
re-implement OCaml: upstream `compiler-libs` does parsing and type checking,
and we own everything after the Typedtree. The primary target is Solana
BPF/SBF; native binaries and experimental WASM/NEAR targets share the same
pipeline. The CLI binary is `omlz`.

Pipeline in one line:

`.ml` → `ocamlc -bin-annot` (`.cmt`) → `zxc-frontend` (sexp wire `1.7`) →
`omlz` (ANF Core IR → const-fold/DCE/inline → region inference + arena
lowering → Zig codegen | tree-walk interpreter) → `solana-zig build-lib`
→ `.so`

## Build & test commands

These are the commands CI runs. Tests and scripts assume the **repo root as
cwd** (contract: [docs/07-repo-layout.md](./docs/07-repo-layout.md)).

```sh
./init.sh
zig build
zig build test --summary none
cargo test --manifest-path tests/Cargo.toml
./scripts/check_examples_corpus.sh
./scripts/check_docs_sync.sh
zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```

- `./init.sh` — toolchain setup (Zig 0.16.0, OCaml 5.2.x via opam, Rust,
  optionally solana-zig). Same script CI uses.
- `zig build test` — units, golden Core-IR snapshots, UI/diagnostic tests,
  determinism property test (interpreter ≡ native), formatter goldens,
  LSP and CLI tests.
- `cargo test --manifest-path tests/Cargo.toml` — Mollusk SVM integration
  tests; needs the `.so` artifacts that `zig build test` produces.
- The last line is the BPF smoke test; it needs `solana-zig` on `PATH`
  (or `SOLANA_ZIG`, see Gotchas).
- Surfpool acceptance (opt-in, needs a local validator):
  `SOLANA_BPF=1 SOLANA_RPC_PORT=8899 tests/solana/hello/invoke.sh`

## Pipeline map

| Stage | Where |
|---|---|
| OCaml frontend glue (subset check, sexp emit) | `src/frontend/` (OCaml) |
| Sexp wire parser + Typedtree mirror | `src/frontend_bridge/` |
| ANF Core IR, optimizations (`const_fold`, `dce`, `inline`, `static_report`, `no_alloc`) | `src/core/` |
| Region inference + arena lowering (LIR) | `src/lower/` |
| Zig codegen / tree-walk interpreter | `src/backend/` |
| Build orchestration (frontend subprocess, BPF/WASM/NEAR drivers, IDL, source maps, doctor) | `src/driver/` |
| CLI subcommand implementations | `src/omlz/` |
| LSP server (`omlz-lsp`) | `src/lsp/` |
| Target registry / capability matrix / preflight | `src/target/` |
| Diagnostics types + rendering | `src/util/` |
| Runtime (arena, Solana syscalls, CPI, SPL adapters) | `runtime/zig/` |
| Bundled OCaml stdlib surface | `stdlib/` |
| Vendored Solana SDK (**never edit**) | `vendor/solana-program-sdk-zig/` |
| Example programs + manifest | `examples/` |
| Zig/Rust/LSP/golden/acceptance tests | `tests/` |
| Generated artifacts only (safe to delete) | `out/`, `zig-out/` |

## Invariants — never break these

- **Determinism**: interpreter output ≡ native codegen output for every
  example. Enforced by a property test in `zig build test`. (ADR-008)
- **Every ZxCaml program is valid OCaml**: we accept a strict subset; never
  add syntax upstream OCaml would reject. (ADR-001)
- **Arena-only memory**: no GC, no free; 32 KiB entry arena native, 3 KiB on
  BPF. See [docs/04-memory-model.md](./docs/04-memory-model.md).
- **Wire format is versioned** (currently `1.7`): changes to the
  frontend↔Zig sexp format must follow
  [docs/wire-compat.md](./docs/wire-compat.md) (additive bumps, documented).
- **Bilingual docs gate**: `./scripts/check_docs_sync.sh` enforces
  English/Chinese pairs. Any **new `docs/*.md` must be classified** in that
  script (mirrored/basic/routed/historical) and get a `docs/zh/` counterpart,
  or CI fails. Root-level agent files are registered there too.
- **Examples manifest**: `examples/` is locked to
  `examples/ml-layout-manifest.tsv`; adding/removing `.ml` files requires
  updating the manifest (`./scripts/check_examples_corpus.sh` gates it), and
  README/roadmap example counts are validated against the filesystem.
- **Sealed phases**: P1–P9 and the R-slices in
  [docs/08-roadmap.md](./docs/08-roadmap.md) are closed. Don't reopen sealed
  scope; new work gets its own plan doc (pattern:
  [docs/20-solana-dx-api-polish-plan.md](./docs/20-solana-dx-api-polish-plan.md)).

## Gotchas

- **`SOLANA_ZIG`**: unset/empty/`"1"` → `solana-zig` from `PATH`; any other
  value is used verbatim as command/path; `"0"` is rejected.
- **`SOLANA_BPF=1`** gates the local-validator acceptance tests; unset means
  they're skipped (CI runs them opt-in, not on macOS runners).
- **`llvm-objcopy` is optional**: without it, `.zxcaml.srcmap` embedding is
  skipped (sidecar `.map` still works). Homebrew LLVM and standard paths are
  probed.
- **Zig 0.16 APIs**: this codebase uses the `std.Io` era APIs. Don't apply
  pre-0.15 patterns (old ArrayList init, old Writer, …).
- **CHANGELOG** follows Keep-a-Changelog with per-slice headers; only
  user-visible changes get entries.
- **`mission-internal/`** holds internal working notes (scout reports,
  audits, backlogs) — not user guidance, not scanned by the docs gate.
- Generated Zig/runtime artifacts live under `out/`; never hand-edit them.

## Doc router

| Need | Read |
|---|---|
| Directory contract & ownership | [docs/07-repo-layout.md](./docs/07-repo-layout.md) |
| Architecture & IR layers | [docs/01-architecture.md](./docs/01-architecture.md) |
| Accepted OCaml subset | [docs/02-grammar.md](./docs/02-grammar.md) |
| Core IR (ANF) contract | [docs/03-core-ir.md](./docs/03-core-ir.md) |
| Memory model (arena/regions) | [docs/04-memory-model.md](./docs/04-memory-model.md) |
| Backends (codegen, interpreter) | [docs/05-backends.md](./docs/05-backends.md) |
| Solana BPF target & toolchain | [docs/06-bpf-target.md](./docs/06-bpf-target.md) |
| Status & roadmap | [docs/08-roadmap.md](./docs/08-roadmap.md) |
| ADR index (locked decisions) | [docs/09-decisions.md](./docs/09-decisions.md) |
| Frontend bridge & wire format | [docs/10-frontend-bridge.md](./docs/10-frontend-bridge.md), [docs/wire-compat.md](./docs/wire-compat.md) |
| Solana accounts/CPI/SPL/no_alloc/IDL | [docs/11-solana-p3.md](./docs/11-solana-p3.md) |
| Public runtime API surface | [docs/runtime-api.md](./docs/runtime-api.md) |
| `omlz test` (property tests) | [docs/13-omlz-test.md](./docs/13-omlz-test.md) |
| Diagnostics format | [docs/diagnostics.md](./docs/diagnostics.md) |
| LSP server & editor setup | [docs/lsp.md](./docs/lsp.md) |
| Source maps & `omlz unmap` | [docs/source-map.md](./docs/source-map.md) |
| Toolchain install & troubleshooting | [INSTALLING.md](./INSTALLING.md) |
