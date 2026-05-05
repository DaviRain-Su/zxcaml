# Site Content Source of Truth (Mission-Internal)

This is a working note for Phase 4 and SITE2 site workers. It is intentionally excluded from the Cloudflare Pages publish set via root `.gitignore`; do not link to it from `site/index.html`.

## Recommended Homepage Positioning

- **Hero tagline:** `Functional Solana, today`.
- **Hero support claim:** ZxCaml lets builders write an OCaml-shaped `.ml` subset and compile through Zig into Solana BPF artifacts. Cite the existing framing that this is an OCaml dialect with a Zig/BPF backend (`README.md:5`) and the hackathon submission's OCaml-subset-to-Solana-BPF description (`docs/hackathon/colosseum-submission.md:18`, `docs/hackathon/colosseum-submission.md:21`).
- **Tone guardrail:** be confident, but do not imply full OCaml compatibility. The submission explicitly says the project is not claiming full OCaml compatibility yet (`docs/hackathon/colosseum-submission.md:23`).

## Core Facts for Metrics Cards

| Fact | Site wording to use | Citations / notes |
|---|---|---|
| Current phase | `P9 Developer Experience surfaces sealed` | `README.md` now states P9 is sealed and lists rustc-style diagnostics, `omlz-lsp`, source maps, wire compatibility, and `omlz unmap` as current features. |
| Wire format | `wire 1.2` | `src/frontend_bridge/sexp_parser.zig` sets `expected_wire_version = "1.2"`; P9/DX2 moved the wire to 1.2 for source-location plumbing while keeping a deprecated `--wire=1.1` compatibility emitter. |
| Example corpus | `54 examples` | Command evidence: `ls examples/*.ml | wc -l | tr -d ' '` returned 54. The inventory below lists every `examples/*.ml` file and cites each at line 1. |
| Backend count | `3 backends` | Public docs list tree-walk interpreter, Zig native codegen, and BPF codegen (`README.md:127`). CLI surfaces also expose `omlz run`, `--target=native`, and `--target=bpf` (`README.md:122`). |
| Zig tests | `223/224 Zig tests passed, 1 skipped` | Baseline command in this worker session: `eval "$(opam env --switch=zxcaml-p1)" && zig build test --summary all` produced `Build Summary: 47/47 steps succeeded; 223/224 tests passed (1 skipped)`. Mission library also records the same fact at `/Users/davirian/.factory/missions/edbbd282-2395-4281-a827-432055da98fa/library/site.md:13`. |
| Rust integration tests | `21 Mollusk integration tests` | `tests/Cargo.toml:11` declares the Mollusk SVM dependency. The test target declarations run from `tests/Cargo.toml:21` through `tests/Cargo.toml:102`, and the inventory below enumerates 21 `*_test.rs` targets. |
| Demo runtime | `107s end-to-end demo run` | Phase 4 mission library records `107s end-to-end` from the Phase 2 H-C handoff at `/Users/davirian/.factory/missions/edbbd282-2395-4281-a827-432055da98fa/library/site.md:15`. |
| Canonical GitHub URL | `https://github.com/DaviRain-Su/ZxCaml` | Existing site link uses the canonical mixed-case URL at `site/index.html:21`; the hackathon submission links the same repository case-insensitively at `docs/hackathon/colosseum-submission.md:73`. Use the mixed-case URL requested by the mission: `https://github.com/DaviRain-Su/ZxCaml`. |

## P9 Developer Experience Site Refresh

F-SITE2-1 should add a homepage block/section that makes the sealed P9 surfaces visible without implying full OCaml compatibility:

- **Rustc-style diagnostics:** mention caret diagnostics and the `--error-format=human|json|oneline` switch so human CLI output and machine-readable integrations are both represented.
- **LSP language server:** mention `omlz-lsp` by name and describe it as an LSP server that publishes diagnostics over stdio JSON-RPC.
- **Source maps:** mention deterministic source maps, embedded `.zxcaml.srcmap`, and `omlz unmap` for translating BPF program counters back to `.ml` source locations.
- **Wire reference:** the site should use wire `1.2`, not `1.1`, because P9 threads source locations through the frontend bridge for diagnostics, LSP, and source maps.

## Anchor Comparison Numbers

Use the generated comparison as the source of truth:

| Metric | ZxCaml | Anchor reference | Site wording | Citation |
|---|---:|---:|---|---|
| Source lines | 39 | 105 | `39 lines vs 105 lines` | `docs/hackathon/anchor-comparison.generated.md:14` |
| BPF artifact size | 6.5 KB | 183.5 KB | `6.5 KB vs 183.5 KB` | Source bytes are 6472 and 183504 at `docs/hackathon/anchor-comparison.generated.md:15`; decimal KB rounded to one digit gives 6.5 and 183.5. |
| Build time | wall-clock varies | wall-clock varies | `wall-clock varies; see docs/hackathon/anchor-comparison.generated.md for measured numbers` | Build-time numbers are machine-local; keep measured values in `docs/hackathon/anchor-comparison.generated.md`. |

## Hackathon Docs to Link

F-W3 should link every file below with GitHub web URLs of the form `https://github.com/DaviRain-Su/ZxCaml/blob/main/docs/hackathon/<filename>`. The docs index confirms this set at `docs/hackathon/README.md:11` through `docs/hackathon/README.md:20`.

| File | Citation |
|---|---|
| `docs/hackathon/anchor-comparison.generated.md` | `docs/hackathon/anchor-comparison.generated.md:2` |
| `docs/hackathon/anchor-comparison.md` | `docs/hackathon/anchor-comparison.md:1` |
| `docs/hackathon/colosseum-submission.md` | `docs/hackathon/colosseum-submission.md:1` |
| `docs/hackathon/demo-script.en.md` | `docs/hackathon/demo-script.en.md:1` |
| `docs/hackathon/demo-script.zh.md` | `docs/hackathon/demo-script.zh.md:1` |
| `docs/hackathon/pitch.en.md` | `docs/hackathon/pitch.en.md:1` |
| `docs/hackathon/pitch.zh.md` | `docs/hackathon/pitch.zh.md:1` |
| `docs/hackathon/README.md` | `docs/hackathon/README.md:1` |
| `docs/hackathon/recording-checklist.md` | `docs/hackathon/recording-checklist.md:1` |
| `docs/hackathon/shot-list.md` | `docs/hackathon/shot-list.md:1` |
| `docs/hackathon/timeline.md` | `docs/hackathon/timeline.md:1` |

## Example Inventory (54 `examples/*.ml`)

The example count was verified by listing `examples/*.ml`; this inventory is the citation set for the `54 examples` site metric.

| # | Example | Citation |
|---:|---|---|
| 1 | `arith_wrap.ml` | `examples/arith_wrap.ml:1` |
| 2 | `assert_demo.ml` | `examples/assert_demo.ml:1` |
| 3 | `box_bool_adt.ml` | `examples/box_bool_adt.ml:1` |
| 4 | `captured_loop.ml` | `examples/captured_loop.ml:1` |
| 5 | `closure_adt.ml` | `examples/closure_adt.ml:1` |
| 6 | `counter.ml` | `examples/counter.ml:1` |
| 7 | `counter_v2.ml` | `examples/counter_v2.ml:1` |
| 8 | `crypto_demo.ml` | `examples/crypto_demo.ml:1` |
| 9 | `demo.ml` | `examples/demo.ml:1` |
| 10 | `div_zero.ml` | `examples/div_zero.ml:1` |
| 11 | `enum_adt.ml` | `examples/enum_adt.ml:1` |
| 12 | `escrow_full.ml` | `examples/escrow_full.ml:1` |
| 13 | `external_demo.ml` | `examples/external_demo.ml:1` |
| 14 | `factorial.ml` | `examples/factorial.ml:1` |
| 15 | `first_class_closure_pass.ml` | `examples/first_class_closure_pass.ml:1` |
| 16 | `first_class_closure_return.ml` | `examples/first_class_closure_return.ml:1` |
| 17 | `guard_match.ml` | `examples/guard_match.ml:1` |
| 18 | `hackathon_greet.ml` | `examples/hackathon_greet.ml:1` |
| 19 | `hello.ml` | `examples/hello.ml:1` |
| 20 | `let_basic.ml` | `examples/let_basic.ml:1` |
| 21 | `list_sum.ml` | `examples/list_sum.ml:1` |
| 22 | `log_accounts.ml` | `examples/log_accounts.ml:1` |
| 23 | `logonly.ml` | `examples/logonly.ml:1` |
| 24 | `m0_unsupported.ml` | `examples/m0_unsupported.ml:1` |
| 25 | `m0_zero.ml` | `examples/m0_zero.ml:1` |
| 26 | `multi_ix.ml` | `examples/multi_ix.ml:1` |
| 27 | `mutual_rec.ml` | `examples/mutual_rec.ml:1` |
| 28 | `nested_let.ml` | `examples/nested_let.ml:1` |
| 29 | `nested_pattern.ml` | `examples/nested_pattern.ml:1` |
| 30 | `noop.ml` | `examples/noop.ml:1` |
| 31 | `option_adt.ml` | `examples/option_adt.ml:1` |
| 32 | `option_basic.ml` | `examples/option_basic.ml:1` |
| 33 | `option_chain.ml` | `examples/option_chain.ml:1` |
| 34 | `option_construct.ml` | `examples/option_construct.ml:1` |
| 35 | `pda_storage.ml` | `examples/pda_storage.ml:1` |
| 36 | `record_nested.ml` | `examples/record_nested.ml:1` |
| 37 | `record_param_box.ml` | `examples/record_param_box.ml:1` |
| 38 | `record_person.ml` | `examples/record_person.ml:1` |
| 39 | `region_demo.ml` | `examples/region_demo.ml:1` |
| 40 | `result_basic.ml` | `examples/result_basic.ml:1` |
| 41 | `simple_cpi.ml` | `examples/simple_cpi.ml:1` |
| 42 | `solana_hello.ml` | `examples/solana_hello.ml:1` |
| 43 | `spl_token_transfer.ml` | `examples/spl_token_transfer.ml:1` |
| 44 | `stdlib_f32.ml` | `examples/stdlib_f32.ml:1` |
| 45 | `stdlib_list.ml` | `examples/stdlib_list.ml:1` |
| 46 | `string_demo.ml` | `examples/string_demo.ml:1` |
| 47 | `syscall_test.ml` | `examples/syscall_test.ml:1` |
| 48 | `tail_rec.ml` | `examples/tail_rec.ml:1` |
| 49 | `token_vault.ml` | `examples/token_vault.ml:1` |
| 50 | `transfer_sol.ml` | `examples/transfer_sol.ml:1` |
| 51 | `tree_adt.ml` | `examples/tree_adt.ml:1` |
| 52 | `tuple_basic.ml` | `examples/tuple_basic.ml:1` |
| 53 | `vault.ml` | `examples/vault.ml:1` |
| 54 | `vault_v2.ml` | `examples/vault_v2.ml:1` |

## Rust/Mollusk Integration Test Inventory (21 targets)

`tests/Cargo.toml` disables Cargo autotests (`tests/Cargo.toml:6` through `tests/Cargo.toml:8`), so the explicit `[[test]]` entries are the authoritative integration target count.

| # | Target | Citation |
|---:|---|---|
| 1 | `hello_test` | `tests/Cargo.toml:21`, `tests/Cargo.toml:22` |
| 2 | `noop_test` | `tests/Cargo.toml:25`, `tests/Cargo.toml:26` |
| 3 | `logonly_test` | `tests/Cargo.toml:29`, `tests/Cargo.toml:30` |
| 4 | `transfer_sol_test` | `tests/Cargo.toml:33`, `tests/Cargo.toml:34` |
| 5 | `pda_storage_test` | `tests/Cargo.toml:37`, `tests/Cargo.toml:38` |
| 6 | `counter_v2_test` | `tests/Cargo.toml:41`, `tests/Cargo.toml:42` |
| 7 | `hackathon_greet_test` | `tests/Cargo.toml:45`, `tests/Cargo.toml:46` |
| 8 | `demo_test` | `tests/Cargo.toml:49`, `tests/Cargo.toml:50` |
| 9 | `simple_cpi_test` | `tests/Cargo.toml:53`, `tests/Cargo.toml:54` |
| 10 | `counter_test` | `tests/Cargo.toml:57`, `tests/Cargo.toml:58` |
| 11 | `vault_test` | `tests/Cargo.toml:61`, `tests/Cargo.toml:62` |
| 12 | `vault_v2_test` | `tests/Cargo.toml:65`, `tests/Cargo.toml:66` |
| 13 | `token_vault_test` | `tests/Cargo.toml:69`, `tests/Cargo.toml:70` |
| 14 | `escrow_full_test` | `tests/Cargo.toml:73`, `tests/Cargo.toml:74` |
| 15 | `external_demo_test` | `tests/Cargo.toml:77`, `tests/Cargo.toml:78` |
| 16 | `crypto_demo_test` | `tests/Cargo.toml:81`, `tests/Cargo.toml:82` |
| 17 | `region_demo_test` | `tests/Cargo.toml:85`, `tests/Cargo.toml:86` |
| 18 | `string_demo_test` | `tests/Cargo.toml:89`, `tests/Cargo.toml:90` |
| 19 | `tail_rec_test` | `tests/Cargo.toml:93`, `tests/Cargo.toml:94` |
| 20 | `mutual_rec_test` | `tests/Cargo.toml:97`, `tests/Cargo.toml:98` |
| 21 | `assert_panic_test` | `tests/Cargo.toml:101`, `tests/Cargo.toml:102` |

## Stale Source Notes for Later Workers

- `README.md` has been swept during Phase 5; use the newer source-specific facts above for current wire format, Mollusk target count, and example count.
- `docs/08-roadmap.md` and `README.md` were refreshed after P9; use the newer P9 source-specific facts above for current phase, wire format, and developer-experience surfaces.
- Anchor comparison wall-clock varies; see `docs/hackathon/anchor-comparison.generated.md` for measured numbers.
