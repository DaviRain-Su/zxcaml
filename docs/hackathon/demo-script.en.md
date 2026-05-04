# ZxCaml Colosseum Demo Script (English)

This script is synchronized with the 10-minute timeline in `docs/hackathon/timeline.md`.
It keeps the same section boundaries and narrative order as the Chinese script, while
using idiomatic English narration for a Colosseum and Solana builder audience.

## 0:00 – 0:35 — Hook: OCaml on Solana

- **Surface**: title-card
- **Scene cue**: Fade in from black to a centered project title and pipeline arrow; optionally layer subtle Solana and OCaml-flavored code textures in the background.
- **On-screen command / visual**: `ZxCaml — OCaml → Solana BPF`
- **Narration**: If you have built on Solana, you know the core constraints: the program has to be type-safe, deterministic, and small enough to land cleanly on BPF. ZxCaml has a direct goal: keep OCaml's type system, algebraic data types, and functional style, but replace the backend with a Solana-oriented compiler pipeline. In this demo, we start from a normal `.ml` source file and take it all the way to a real BPF artifact, IDL, Mollusk test, and Surfpool localnet deployment.

## 0:35 – 1:20 — Compiler pipeline in one picture

- **Surface**: IDE
- **Scene cue**: Open the architecture document at the pipeline diagram; move the cursor from `.ml source` down through each stage to `Solana BPF .so`.
- **On-screen command / visual**: Open `docs/01-architecture.md` at the pipeline diagram
- **Narration**: Let's start with the architecture. ZxCaml does not invent a new language, and it does not fork the OCaml compiler. We reuse upstream OCaml for parsing, type-checking, and Typedtree generation, then a small bridge turns that into ZxCaml's own Core IR. That Core IR is ANF-shaped, which makes deterministic lowering, arena-based memory planning, and Zig code generation much simpler. From there, the Zig toolchain and `sbpf-linker` produce Solana BPF. In short: borrow the frontend, replace the backend, and send familiar OCaml programs on-chain.

## 1:20 – 2:20 — Start `hackathon_greet.ml`

- **Surface**: IDE
- **Scene cue**: Switch to the example source and first show the file header, entrypoint, and the top-level shape of the two-instruction program.
- **On-screen command / visual**: Open `examples/hackathon_greet.ml`
- **Narration**: Now we move to the star of the demo: `hackathon_greet.ml`. It is a from-scratch greeting counter that stores state in a PDA and exposes two instructions: `init` creates the counter state, and `greet` increments it on each call while recording the first caller. The important part is that this still reads like ordinary OCaml source. You see pattern matching, records, and small composed functions; the target is not a local OCaml runtime, but a Solana program.

## 2:20 – 3:20 — Instruction dispatch and typed state

- **Surface**: IDE
- **Scene cue**: Highlight the discriminator branches, then move to the state encode/decode helpers; keep the sidebar visible so viewers can see everything remains inside the same `.ml` file.
- **On-screen command / visual**: Highlight `init = 0`, `greet = 1`, and state layout code
- **Narration**: Solana ABIs usually begin with bytes: the first discriminator chooses the instruction, and account data needs an explicit layout. Here, `init = 0` and `greet = 1` are represented as a tiny dispatch path, while typed state helpers turn raw account bytes back into readable program data. Viewers should see both layers at once: the low-level ABI is still respected, but the program logic stays in OCaml, reducing handwritten offsets, magic numbers, and accidental state mismatches.

## 3:20 – 4:10 — PDA and account flow

- **Surface**: IDE
- **Scene cue**: Jump from the PDA seed/bump helpers to the account write path; use the cursor to point through validation, initialization, incrementing, and write-back.
- **On-screen command / visual**: Highlight PDA seed/bump helpers and account write path
- **Narration**: Next is the account flow. The example checks the greeting PDA, makes sure the passed account is the one the program expects, writes the initial state during `init`, and then has each `greet` call read the previous state, compute the new counter, and write the result back deterministically. PDA seeds, bumps, and account permissions are still real Solana concepts here. ZxCaml does not hide the model; it packages those details into clear helpers and typed functions that are easier to maintain.

## 4:10 – 5:10 — Build BPF and emit IDL

- **Surface**: terminal
- **Scene cue**: Switch to the terminal and run the build command; after the build succeeds, emit the IDL and pause briefly on the output path.
- **On-screen command / visual**: `./scripts/demo/01_build.sh && ./zig-out/bin/omlz idl examples/hackathon_greet.ml > out/hackathon_greet.json`
- **Narration**: Once the source is ready, we do not switch to a mock path. `01_build.sh` calls `omlz build --target=bpf` and compiles the same `.ml` file into a deployable Solana `.so`. Immediately after that, we emit an Anchor-compatible IDL from the same source. The program logic and interface description come from one source of truth, so the JSON in the demo is not hand-maintained; it is generated by the compiler pipeline understanding the program.

## 5:10 – 6:10 — Prove behavior with Mollusk

- **Surface**: terminal
- **Scene cue**: Stay in the terminal and run the single Mollusk integration test; after it passes, highlight output related to `init`, the two `greet` calls, and the final counter assertion.
- **On-screen command / visual**: `cargo test -p zxcaml-tests --test hackathon_greet_test`
- **Narration**: Before deployment, we use Mollusk for a fast, repeatable proof of behavior. The test loads the generated BPF program in an SVM environment, runs one `init`, runs two `greet` calls, and then checks that the PDA state changed to the exact expected value. The message is more than “the test passed.” The same on-chain artifact has already gone through a real execution path: account inputs, instruction data, and state writes are all covered.

## 6:10 – 7:20 — Start Surfpool and deploy

- **Surface**: terminal
- **Scene cue**: Open a new terminal pane or clear the screen, start Surfpool, wait for RPC readiness, then run the deploy script and zoom in on the program ID.
- **On-screen command / visual**: `./scripts/demo/02_surfpool_up.sh && ./scripts/demo/03_deploy.sh`
- **Narration**: Now we move from in-process testing to a local Solana network. Surfpool gives us a clean localnet for recording; after startup, the script waits for RPC readiness and deploys the BPF `.so` with a freshly generated program keypair. This is the critical handoff from compiler demo to Solana workflow. When the program ID appears on screen, the ZxCaml output has entered the local chain exactly like a normal Solana program.

## 7:20 – 8:30 — Invoke on localnet and inspect state

- **Surface**: terminal
- **Scene cue**: Run the invoke script; pause on the transaction signatures, successful init/greet logs, and the printed account-state readback.
- **On-screen command / visual**: `./scripts/demo/04_invoke.sh`
- **Narration**: After deployment, we send real transactions against the program. The script submits `init` and `greet` instructions with the correct PDA seeds and account list, then reads back the greeting account. This segment should underline that we are not only proving the artifact can deploy. We are proving the deployed program responds to instructions, updates on-chain state, and exposes the counter change in a way a Solana builder can inspect end to end.

## 8:30 – 9:20 — Anchor comparison

- **Surface**: terminal
- **Scene cue**: Run the comparison script and open the comparison document; move through the line count, artifact size, compile-time, and ergonomics tables.
- **On-screen command / visual**: `./scripts/demo/compare.sh && open docs/hackathon/anchor-comparison.md`
- **Narration**: Finally, we make an honest comparison with Anchor. Anchor is the mature default for much of the Solana ecosystem, so this section is not about dismissing it. It shows the alternative ZxCaml offers: model the same account and instruction semantics with OCaml's types and functional structure. The comparison script recomputes source line count, BPF artifact size, and any measurable compile time, while the document captures the developer-experience tradeoffs around discriminators, PDA ergonomics, and generated interfaces.

## 9:20 – 10:00 — Close and call to action

- **Surface**: title-card
- **Scene cue**: Return to the closing title card; show GitHub, docs, demo script paths, and the final reproducibility command.
- **On-screen command / visual**: Show repo/docs links and `./scripts/demo/run_full_demo.sh`
- **Narration**: Today we started with a normal OCaml `.ml` file, sent it through the ZxCaml pipeline, produced BPF, emitted IDL, validated behavior with Mollusk, deployed to a Surfpool localnet, and invoked it with real state changes. That is the experience ZxCaml wants to give Solana builders: strong types and functional abstraction, while still producing deterministic, compact, deployable on-chain programs. Open the repo, run `./scripts/demo/run_full_demo.sh`, inspect the source, scripts, and tests, and tell us which OCaml program you want to bring to Solana next.
