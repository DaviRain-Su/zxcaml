# Changelog

All notable user-visible changes to ZxCaml are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries are grouped by project phase because this repository has shipped phase
milestones rather than semver releases so far. Commit hashes cite the `git log`
evidence for each major bullet.

## [Unreleased]

### Added — let%%test_unit + omlz test runner

- Added `let%test_unit "name" = expr` frontend support, lowering test bodies into unit thunks and `__otest_registry__` for runner discovery (`46e7695`).
- Added the `omlz test` subcommand with default `examples/tests/*.ml` discovery, explicit `FILE...` support, cargo-style and JSON reporters, `--filter`, `--format`, `--no-color`, `NO_COLOR`, and exit codes 0/1/2 (`b189935`).
- Added LSP CodeLens support for `let%test_unit` bindings, including `omlz.runTest`, streaming through `$/omlz.testOutput`, pass/fail lens titles, and the ≤100 ms CodeLens latency harness (`cf27725`).
- Added three demo test programs under `examples/tests/` with eight passing `let%test_unit` cases plus the failure-template fixture used for reporter demos (`91efeac`).
- Fixed the frontend pre-scan so `let%test_unit` text inside OCaml comments is ignored cleanly instead of being parsed as a real test (`4048e8d`).

### Added

- Added project wiki generation plus a GitHub Actions auto-refresh workflow
  that regenerates the wiki on pushes to `main`.

## [Real-world Examples Batch 3] - 2026-05-06

### Added

- Added three SPL Token primitive example programs: `spl_burn` for Burn
  discriminator `8`, `spl_close_account` for CloseAccount discriminator `9`,
  and `spl_revoke` for Revoke discriminator `5` (`b0dce5e`, `1acf30b`,
  `8eac394`).
- Added Burn / CloseAccount / Revoke runtime support in
  `runtime/zig/spl_token.zig`, including six instruction encoders
  (`encode*` / `encode*Into`) plus six account-meta and instruction builders
  for the new primitives (`16a80fb`).
- Added three focused `runtime/zig/programs/spl_*.zig` wrappers that witness
  the SPL Token builders while mutating the mocked program-owned token-account
  state used by the Mollusk fixtures (`16a80fb`).
- Added Mollusk integration coverage in `tests/spl_burn_test.rs`,
  `tests/spl_close_account_test.rs`, and `tests/spl_revoke_test.rs`, and
  bumped the corpus counts from 57 to 60 examples and from 24 to 27 Mollusk
  tests (`b0dce5e`, `1acf30b`, `8eac394`, `f724b46`).

## [P9 LSP Resilience] - 2026-05-06

### Added

- Added LSP latency-harness stabilization with one warm-up sample followed by
  five measured checks, reporting the p50 median while preserving the 200ms
  threshold for the developer-experience budget (`2272a79`).

### Changed

- Changed `omlz-lsp` temp-file isolation to use per-pid subdirectories under
  `/tmp/omlz_lsp_<pid>/<id>.ml`, preventing concurrent servers from sharing the
  same transient source paths (`a77a358`).

### Fixed

- Fixed stale LSP temp cleanup across process boundaries by checking
  `kill(pid, 0)` on server startup before removing only dead peer directories
  (`a77a358`, `d10682e`).
- Fixed the Python latency harness pre-run path to call the
  `pre_clean_stale_tmp()` helper, applying the same cross-pid `kill(pid, 0)`
  cleanup before launching `omlz-lsp` (`d10682e`, `b649cbe`).

## [P8] Compiler Optimizations - 2026-05-01

### Added

- Added Core IR constant folding for compile-time arithmetic, comparisons,
  string concatenation, boolean conditionals, and constructor-match reductions
  (`7ffe0f8`).
- Added dead-code elimination that removes unused bindings and unreachable
  branches while preserving effectful or trapping work such as division and
  unsafe match folds (`ee10ee5`, `5f0c7e6`, `62659ae`).
- Added self-recursive tail call optimization, lowering tail calls into loops
  so deep recursive examples can run without consuming the host or BPF call
  stack (`281a5a7`, `ff09dbc`).
- Added small-function inlining with alpha-renaming across scalar, string,
  ADT, tuple, and record values, enabling later constant folding at call sites
  (`3fbd61c`, `f1efb40`).
- Added frontend and Core support for mutual recursion groups, general type
  aliases, and `assert` expressions (`46514a9`, `ae3b567`, `635b86c`,
  `82ba02a`, `57f80dc`, `f57dddf`).

## [Hackathon Demo + Site] - 2026-05-05

### Operational / Demo

This section records post-P8 operational hardening, real-world example
coverage, demo packaging, and public-site work. It is **not** a new compiler
feature phase.

- **Health & Real-World Examples (M-A through M-F):** hardened the build and
  source tree around the sealed compiler by fixing the build graph so
  `zxc-frontend` is installed before exe tests (`19151fe`), deriving frontend
  cleanup artifacts instead of hand-listing them (`42c8933`), splitting
  oversized Zig files to preserve the file-size budget (`d6700a6`, `91c9ef3`),
  documenting the AccountFieldSet mutation rule and backend-stub/inline-threshold
  maintenance points (`c2dc405`, `25cf0ec`, `19c12be`), removing the transient
  escrow placeholder before the real port landed (placeholder was untracked; the
  real `examples/escrow_full.ml` port is `38d8a4d`), creating this
  `CHANGELOG.md` (`e3b73bf`), and documenting the resulting example corpus with
  the capability matrix and real-world mapping guide (`7430921`, `a8c810e`).
- **Health & Real-World Examples (M-E / M-F corpus):** ported the zignocchio
  real-world set as eight example programs plus their Mollusk registrations:
  `noop`, `logonly`, `transfer_sol`, `pda_storage`, `counter_v2`, `vault_v2`,
  `token_vault`, and `escrow_full` (`7c59ec6`, `3f0668f`, `fb7f1cc`,
  `4206a4e`, `b617117`, `07db019`, `acd2f19`, `38d8a4d`).
- **Hackathon Demo (H-A through H-E):** packaged a recordable Colosseum demo
  with the bilingual storyboard under `docs/hackathon/` (`5416618`, `b7bc0c3`,
  `9611376`, `668af58`), the PDA-backed `examples/hackathon_greet.ml` example
  and IDL artifact (`d2fa541`, `d164650`), Surfpool deploy/invoke scripts under
  `scripts/demo/` plus the captured dry-run transcript (`e14a1a9`, `25cf003`),
  an isolated Anchor reference and generated comparison artifact (`1bc718a`,
  `621660c`), Colosseum submission and bilingual pitch copy (`ef86b00`,
  `6bb7160`), and the top-level `make demo`, `make demo-clean`, and
  `make demo-record-prep` entry points (`5f594be`).
- **Slidev Decks (Milestone S):** scaffolded the Slidev project, authored
  bilingual `slides/slides.{zh,en}.md` decks, added the PDF export pipeline, and
  tied `docs/hackathon/recording-checklist.md` into recording prep (`8128050`,
  `619e5df`, `811d994`, `2631e8b`, `2cae5e6`, `372fecf`).
- **Site refresh (Milestone W):** refreshed the static site with the
  `Functional Solana, today.` hero, current P8 / wire `1.1` / examples /
  backend / test metrics, the Anchor comparison card, a hackathon section that
  links every `docs/hackathon/*` file, a live code preview for
  `hackathon_greet`, and the deployed Cloudflare Pages URL
  [`https://zxcaml.pages.dev/`](https://zxcaml.pages.dev/) (`f94e89f`,
  `d96bf70`, `573ca24`, `e0bc7f9`).

## [P9 Developer Experience] - 2026-05-05

### Added

- Added DX1 diagnostics infrastructure with rustc-style human output,
  `--error-format` human/json/oneline modes, `--color` controls, JSON-lines
  diagnostics, and reblessed UI coverage (`f4b8a58`, `2068d3c`, `e88137e`,
  `34a5dd1`).
- Added the LSP surface as `omlz-lsp`, including Content-Length JSON-RPC
  framing, initialize/shutdown lifecycle handling, text-sync
  `publishDiagnostics`, latency probes, and build-test harness coverage
  (`7561b76`, `69abcb3`, `578383c`, `03c4ea5`, `7d2597c`, `567afb4`,
  `77de5f5`).
- Added SRCMAP/source map support with the JSON sidecar schema, BPF map
  construction, deterministic `.map` emission, `.zxcaml.srcmap` ELF embedding,
  `omlz unmap` reverse lookups, and loader/determinism tests (`828f4ba`,
  `4fcf183`, `00487eb`, `0a2fe1f`, `a5faaa8`, `8604864`).

### Changed

- Advanced DX2 location plumbing by bumping the frontend wire format to `1.2`,
  keeping deprecated `--wire=1.1` compatibility, preserving Core IR locations,
  rendering `no_alloc` and region failures with OCaml spans, and tailoring
  subset diagnostics (`d7513b6`, `1469bf0`, `f878677`, `59a0b02`, `2e30c89`,
  `8b4441a`, `31c7814`).

## [Runtime Refactor] - 2026-05-05

### Changed

- Split `runtime/zig/cpi.zig` down to pure CPI primitives with a ≤ 600-line
  target, moving the six `zxcaml_*_process` entry points into focused modules
  under `runtime/zig/programs/` (`26085cf`).
- Added the `runtime/zig/bs58.zig` module with encode/decode helpers and
  Pubkey-focused coverage, then switched the SPL Token runtime helper to
  consume the canonical Tokenkeg base58 program ID through `bs58`
  (`b3b2a4a`, `f34f6e4`).
- Documented the public runtime surface in `docs/runtime-api.md` and the
  Chinese mirror `docs/zh/runtime-api.md`, covering Arena, Syscalls, CPI,
  Account, SPL Token, Bs58, and the programs registry (`465b50f`, `7837c90`).
- Linked the new runtime API guide from the English/Chinese README and roadmap
  surfaces so users can navigate to `runtime-api.md` from the main docs
  (`6b7ec07`).

## [Real-world Examples Batch 2] - 2026-05-05

### Added

- Added the `examples/dao_voting.ml` real-world example for proposal and
  vote-record PDAs, yes/no vote counting, and double-vote rejection, with
  Mollusk coverage in `tests/dao_voting_test.rs` for yes-vote increments and
  double-vote blocking (`e656fdb`).
- Added the `examples/ata_transfer.ml` Associated Token Account flow, covering
  create-idempotent setup followed by a mocked SPL-Token transfer, with Mollusk
  coverage in `tests/ata_transfer_test.rs` for destination ATA initialization
  and token movement (`67a50e8`).
- Added the `examples/order_book.ml` maker/taker order-book example for order
  PDAs, full fills, partial fills, and mocked two-sided SPL-Token balance
  updates, with Mollusk coverage in `tests/order_book_test.rs` for both fill
  paths (`5340d40`).
- Extended the runtime surface for these examples with
  `runtime/zig/programs/ata.zig` Associated Token Account helpers and
  `runtime/zig/spl_token.zig` `encodeInitializeAccount` /
  `initializeAccountInstruction` support (`f1c3edc`).

## [P7] OCaml Subset Expansion - 2026-04-30

### Added

- Added desugaring for additional ordinary OCaml surface forms so accepted
  source can stay closer to idiomatic `.ml` syntax (`d610604`).
- Added extended pattern sexps and wired those patterns through the Zig
  pipeline for richer `match` and function-case programs (`4592969`,
  `189f5d5`).
- Added string and char frontend support plus code generation for string and
  char operations (`4d7ff9c`, `5cbe1ed`).
- Expanded bundled utility modules in `stdlib/core.ml`, broadening the
  developer-visible standard library surface (`af7aea1`).

### Changed

- Updated the README to describe the completed P7 OCaml subset expansion
  milestone and its expanded syntax coverage (`c1aa45e`).

## [P6] Region Inference - 2026-04-30

### Added

- Added Core IR escape analysis to identify non-escaping values and improve
  arena-pressure decisions (`a10eba6`, `a8fd805`).
- Added stack-region code generation for eligible local `let` bindings,
  allowing proven-local values to avoid arena allocation (`4c1c8af`).
- Added a region allocation example demonstrating the new allocation behavior
  (`4514081`).

### Changed

- Reduced unnecessary arena discard work in generated code and documented the
  P6 region inference milestone in the README (`5809054`, `ebee3e1`).

## [P5] Ecosystem Reach - 2026-04-30

### Added

- Added `external` declarations in the frontend and direct external-call code
  generation, enabling typed bindings from OCaml source to Zig runtime symbols
  (`3a344ae`, `ba4c5dd`).
- Added external declaration examples and fixed byte-slice external returns so
  FFI-style programs have working acceptance coverage (`a88dc85`, `331446d`,
  `cc40636`).
- Added Anchor-compatible IDL emission, including account annotations, multiple
  instruction entries, and buffered stdout JSON output (`05f9aa6`, `6a72fc9`,
  `5cf2735`, `4e9dc27`, `f2cc9c7`).
- Added persistent `Map` and `Set` modules plus crypto stdlib wrappers backed
  by runtime hash externals (`63f326a`, `c61af01`, `f7f3bbd`).

### Changed

- Extended CI to run Mollusk SVM tests and updated the README for the P5
  ecosystem reach milestone (`ff51f45`, `402d4e0`).

## [P4] Mollusk Acceptance and Instruction Data - 2026-04-30

### Added

- Added instruction-data plumbing to the BPF entrypoint path so programs can
  dispatch based on transaction input bytes (`b5e00a9`, `dd8e823`).
- Added a Mollusk SVM test harness and user-visible counter/vault integration
  tests that exercise compiled BPF programs in-process (`b98408e`, `c8f18e9`,
  `cd79a21`).
- Added `Pubkey` hex constants and examples using the new helper surface,
  improving ergonomics for Solana-style account and program identifiers
  (`5e0bc4c`, `3f8de65`).

## [P3] Solana-Shaped Subset - 2026-04-29

### Added

- Added zero-copy Solana account views from the BPF input buffer, including
  account-data and lamports mutation support through the generated runtime
  (`f578079`, `9e4c047`, `b28d14c`).
- Added syscall bindings, account/syscall examples, and deployment fixes for
  Solana runtime-facing programs (`f03f6cd`, `be54e83`, `879df0a`,
  `4d45987`).
- Added CPI records and helpers, `invoke`/`invoke_signed` runtime support, and
  a simple CPI transfer demo (`9eb18b9`, `c4d2bf5`, `0c96c4c`).
- Added SPL-Token transfer helpers and an SPL Token transfer example that can
  deploy successfully (`2b00434`, `b06dca3`, `ebdbf0f`).
- Added user-facing `omlz check --no-alloc`, structured error-code support, and
  `omlz idl` JSON output (`414c693`, `1a8ae85`, `0f27141`).

### Changed

- Documented the Solana P3 runtime integration and runtime example mapping in
  project docs (`c1fbd53`, `004e6c0`).

## [P2] Subset Expansion and Match Optimization - 2026-04-29

### Added

- Added user-defined ADT declarations and constructors, including parameterized
  payloads and nullary-constructor type-parameter inference (`54a01e4`,
  `1e92086`, `67f2d90`, `a3e3d10`, `ff7ea98`).
- Added nested constructor patterns, guarded match arms, and decision-tree match
  compilation with examples for the expanded pattern surface (`12f38cc`,
  `ce403cc`, `9f62cdc`, `245f307`, `72a0d0e`).
- Added tuple and record syntax through sexp `0.7`, including construction,
  field access, patterns, functional update, examples, and concrete record type
  preservation (`19d3786`, `91d70a8`, `852feca`, `e4d66eb`).
- Expanded the bundled `List`, `Option`, and `Result` stdlib surface and
  supported curried stdlib closure forms (`b39e261`, `9b7a5a8`, `96f10e0`,
  `49a841f`, `845359d`).
- Hardened first-class closure support for the BPF path and added closure/stdlib
  examples plus regression tests (`ba8848d`, `da74707`, `2f75d76`,
  `2ead543`).

### Changed

- Documented P2 syntax and updated the README for the completed subset
  expansion milestone (`71b9c99`, `1fcc48a`, `62eb138`).

## [P1] MVP OCaml Subset to Solana BPF - 2026-04-28

### Added

- Added the `omlz` compiler scaffold, OCaml frontend subprocess, sexp bridge,
  Core IR skeleton, interpreter, native build path, and BPF `.so` build path
  (`39fabc0`, `eb5ca12`, `a1f139e`, `b29f437`, `f1725e5`, `e3f781f`,
  `010289b`, `c1014bb`, `2fad318`).
- Added the initial accepted OCaml subset: `let`, option/result constructors,
  match expressions, `let rec`, lists, arithmetic, comparisons, conditionals,
  and first-class let-rec closure materialization (`451ecca`, `86f995d`,
  `d9875be`, `9bb39ab`, `bce8251`, `792c152`, `6b706de`, `31c044e`,
  `4c715c2`).
- Added determinism, golden, UI, Solana acceptance, diagnostic, stdlib, and
  examples coverage for the first end-to-end compiler milestone (`3e40be5`,
  `cb817dc`, `187f67b`, `afaa896`, `fca5bb5`, `2e61aa8`, `4ae4153`,
  `533ef81`).
- Added canonical CI, installation quickstart documentation, and the final P1
  documentation/readme sweep (`18c065e`, `e8b1124`, `30fa30e`, `05acd56`,
  `5b930c0`).
