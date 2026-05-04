# Colosseum Hackathon Demo Timeline

This is the authoritative timeline for the 10-minute Colosseum hackathon
video. `demo-script.zh.md`, `demo-script.en.md`, and `shot-list.md` must keep
the same section boundaries and narrative order.

| Time | Section | Surface | Narration cue | On-screen command |
|------|---------|---------|---------------|-------------------|
| 0:00 – 0:35 | Hook: OCaml on Solana | title-card | Open with the problem: Solana programs need safety, determinism, and compact BPF output; ZxCaml lets builders keep OCaml's typed functional model while targeting Solana. | Show title card: `ZxCaml — OCaml → Solana BPF` |
| 0:35 – 1:20 | Compiler pipeline in one picture | IDE | Explain the core path: upstream OCaml frontend, ZxCaml Typedtree bridge, ANF/Core IR, Zig codegen, then Solana BPF. Emphasize "borrow the frontend, replace the backend." | Open `docs/01-architecture.md` at the pipeline diagram |
| 1:20 – 2:20 | Start `hackathon_greet.ml` | IDE | Introduce the demo program: a PDA-backed greeting counter with two instructions, `init` and `greet`, written as ordinary `.ml` source. | Open `examples/hackathon_greet.ml` |
| 2:20 – 3:20 | Instruction dispatch and typed state | IDE | Walk through discriminator handling and typed state encode/decode so viewers see the Solana ABI represented in a small, readable functional program. | Highlight `init = 0`, `greet = 1`, and state layout code |
| 3:20 – 4:10 | PDA and account flow | IDE | Show how the program derives or checks the greeting PDA, initializes state, and increments the counter on each greeting while preserving deterministic account writes. | Highlight PDA seed/bump helpers and account write path |
| 4:10 – 5:10 | Build BPF and emit IDL | terminal | Switch from code to artifacts: build the real BPF shared object and emit Anchor-compatible IDL from the same source file. | `./scripts/demo/01_build.sh && ./zig-out/bin/omlz idl examples/hackathon_greet.ml > out/hackathon_greet.json` |
| 5:10 – 6:10 | Prove behavior with Mollusk | terminal | Run the integration test that performs init plus two greet calls and asserts the PDA state changed exactly as expected. | `cargo test -p zxcaml-tests --test hackathon_greet_test` |
| 6:10 – 7:20 | Start Surfpool and deploy | terminal | Move from in-process testing to a local Solana network: start Surfpool, deploy the BPF artifact with a fresh program keypair, and show the program ID. | `./scripts/demo/02_surfpool_up.sh && ./scripts/demo/03_deploy.sh` |
| 7:20 – 8:30 | Invoke on localnet and inspect state | terminal | Send init and greet instructions against the live localnet deployment, then read back the greeting account to demonstrate real on-chain state transitions. | `./scripts/demo/04_invoke.sh` |
| 8:30 – 9:20 | Anchor comparison | terminal | Compare ZxCaml and an equivalent Anchor reference honestly: source line count, artifact size, compile time where available, and ergonomics tradeoffs. | `./scripts/demo/compare.sh && open docs/hackathon/anchor-comparison.md` |
| 9:20 – 10:00 | Close and call to action | title-card | Close with the takeaway: typed OCaml programs can become Solana BPF artifacts today; invite viewers to inspect the repo, scripts, and examples. | Show repo/docs links and `./scripts/demo/run_full_demo.sh` |

## Timing Notes

- Total runtime: **10:00**, safely under the **10:30** upper bound.
- Section count: **11**.
- Later scripts and the shot list must keep these timestamps unchanged unless this
  file is intentionally revised first.
- Surfpool startup and deploy latency are budgeted in the `6:10 – 7:20`
  segment; the recording should use a rehearsed terminal transcript if startup
  takes longer on the day.
