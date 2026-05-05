---
theme: default
title: ZxCaml Colosseum Demo
---

# ZxCaml — OCaml → Solana BPF

Colosseum 10-minute demo English deck

From a normal `.ml` source file to a real BPF artifact, IDL, Mollusk test, and Surfpool localnet deployment.

<!-- speaker: In this demo, we start from a normal `.ml` source file and take it all the way to a real BPF artifact, IDL, Mollusk test, and Surfpool localnet deployment. -->

---

## 0:00–0:35 Hook: OCaml on Solana

Solana programs need three things at once:

- Type safety
- Deterministic execution
- Compact output that lands cleanly on BPF

ZxCaml's path: keep OCaml's type system, ADTs, and functional style; replace the backend; compile for Solana.

<!-- speaker: If you have built on Solana, you know the core constraints: the program has to be type-safe, deterministic, and small enough to land cleanly on BPF. ZxCaml has a direct goal: keep OCaml's type system, algebraic data types, and functional style, but replace the backend with a Solana-oriented compiler pipeline. -->

---

## 0:35–1:20 Architecture Overview: Borrow the frontend, replace the backend

```mermaid
graph LR
  OCaml["OCaml .ml"] --> CoreIR["Core IR"]
  CoreIR --> ANF["ANF"]
  ANF --> Zig["Zig codegen"]
  Zig --> BPF["Solana BPF .so"]
```

- Upstream OCaml frontend: parsing, type-checking, Typedtree
- ZxCaml bridge: Typedtree → Core IR
- ANF/Core IR: deterministic lowering, arena strategy, code generation

<!-- speaker: Let's start with the architecture. ZxCaml does not invent a new language, and it does not fork the OCaml compiler. We reuse upstream OCaml for parsing, type-checking, and Typedtree generation, then a small bridge turns that into ZxCaml's own Core IR. That Core IR is ANF-shaped, which makes deterministic lowering, arena-based memory planning, and Zig code generation much simpler. From there, the Zig toolchain and `sbpf-linker` produce Solana BPF. In short: borrow the frontend, replace the backend, and send familiar OCaml programs on-chain. -->

---

## 1:20–2:20 The star: `hackathon_greet.ml`

```ocaml {1|2|3|all}
external hackathon_greet_process : account -> account -> bytes -> int
  = "hackathon_greet_process"
let instruction_init (greeting_account : account) (maker : account) = ...
let instruction_greet (greeting_account : account) (maker : account) = ...
```

- PDA-backed greeting counter
- Two instructions: `init` initializes, `greet` increments the counter
- Still ordinary `.ml` source

<!-- speaker: Now we move to the star of the demo: `hackathon_greet.ml`. It is a from-scratch greeting counter that stores state in a PDA and exposes two instructions: `init` creates the counter state, and `greet` increments it on each call while recording the first caller. The important part is that this still reads like ordinary OCaml source. You see pattern matching, records, and small composed functions; the target is not a local OCaml runtime, but a Solana program. -->

---

## 2:20–3:20 Instruction dispatch and typed state

```ocaml {1|2-5|6-9|all}
let discriminator = read_u8 instruction_data 0 in
if discriminator = 0 then
  hackathon_greet_process greeting_account maker instruction_data
else if discriminator = 1 then
  hackathon_greet_process greeting_account maker instruction_data
else 1
```

- Discriminators: `init = 0`, `greet = 1`
- Account data layout is explicit and auditable
- OCaml stays at the top layer, reducing handwritten offset risk

<!-- speaker: Solana ABIs usually begin with bytes: the first discriminator chooses the instruction, and account data needs an explicit layout. Here, `init = 0` and `greet = 1` are represented as a tiny dispatch path, while typed state helpers turn raw account bytes back into readable program data. Viewers should see both layers at once: the low-level ABI is still respected, but the program logic stays in OCaml, reducing handwritten offsets, magic numbers, and accidental state mismatches. -->

---

## 3:20–4:10 PDA and account flow

PDA-backed state write path:

1. Check the greeting PDA and account permissions
2. `init` writes the starting state
3. `greet` reads the old state and computes the new counter
4. Deterministically write the account data back

On-chain details are not hidden; they are compressed into helpers and small functions.

<!-- speaker: Next is the account flow. The example checks the greeting PDA, makes sure the passed account is the one the program expects, writes the initial state during `init`, and then has each `greet` call read the previous state, compute the new counter, and write the result back deterministically. PDA seeds, bumps, and account permissions are still real Solana concepts here. ZxCaml does not hide the model; it packages those details into clear helpers and typed functions that are easier to maintain. -->

---

## 4:10–5:10 Build BPF and emit IDL

```sh
./scripts/demo/01_build.sh
./zig-out/bin/omlz idl examples/hackathon_greet.ml > out/hackathon_greet.json
```

- The same `.ml` file generates a real Solana `.so`
- The same source emits Anchor-compatible IDL
- Program logic and interface description share one source of truth

<!-- speaker: Once the source is ready, we do not switch to a mock path. `01_build.sh` calls `omlz build --target=bpf` and compiles the same `.ml` file into a deployable Solana `.so`. Immediately after that, we emit an Anchor-compatible IDL from the same source. The program logic and interface description come from one source of truth, so the JSON in the demo is not hand-maintained; it is generated by the compiler pipeline understanding the program. -->

---

## 5:10–6:10 Prove behavior with Mollusk

```sh
cargo test -p zxcaml-tests --test hackathon_greet_test
```

The test covers the real execution path:

- Loads the generated BPF program
- Runs one `init`
- Runs two `greet` calls
- Asserts the PDA state changed exactly as expected

<!-- speaker: Before deployment, we use Mollusk for a fast, repeatable proof of behavior. The test loads the generated BPF program in an SVM environment, runs one `init`, runs two `greet` calls, and then checks that the PDA state changed to the exact expected value. The message is more than “the test passed.” The same on-chain artifact has already gone through a real execution path: account inputs, instruction data, and state writes are all covered. -->

---

## 6:10–7:20 Start Surfpool and deploy

```sh
./scripts/demo/02_surfpool_up.sh
./scripts/demo/03_deploy.sh
```

Move from in-process testing to a local Solana network:

- Wait for Surfpool RPC readiness
- Deploy the BPF `.so` with a fresh program keypair
- Show the program ID and prove the standard deployment flow works

<!-- speaker: Now we move from in-process testing to a local Solana network. Surfpool gives us a clean localnet for recording; after startup, the script waits for RPC readiness and deploys the BPF `.so` with a freshly generated program keypair. This is the critical handoff from compiler demo to Solana workflow. When the program ID appears on screen, the ZxCaml output has entered the local chain exactly like a normal Solana program. -->

---

## 7:20–8:30 Invoke on localnet and inspect state

```sh
./scripts/demo/04_invoke.sh
```

Recording focus:

- Submit `init` and `greet` transactions
- Use the correct PDA seeds and account list
- Read back the greeting account state
- Show the counter change

<!-- speaker: After deployment, we send real transactions against the program. The script submits `init` and `greet` instructions with the correct PDA seeds and account list, then reads back the greeting account. This segment should underline that we are not only proving the artifact can deploy. We are proving the deployed program responds to instructions, updates on-chain state, and exposes the counter change in a way a Solana builder can inspect end to end. -->

---

## 8:30–9:20 Anchor comparison

| Metric | ZxCaml `hackathon_greet.ml` | Anchor reference `lib.rs` |
|---|---:|---:|
| Source lines | 39 | 105 |
| BPF artifact size | 6.5 KB | 183.5 KB |
| Local build time | 1 second | 42 seconds |

The conclusion is not to replace Anchor; it is to offer Solana builders an OCaml + functional-modeling path.

<!-- speaker: Finally, we make an honest comparison with Anchor. Anchor is the mature default for much of the Solana ecosystem, so this section is not about dismissing it. It shows the alternative ZxCaml offers: model the same account and instruction semantics with OCaml's types and functional structure. The comparison script recomputes source line count, BPF artifact size, and any measurable compile time, while the document captures the developer-experience tradeoffs around discriminators, PDA ergonomics, and generated interfaces. -->

---

## P9 Developer Experience: rustc-style caret diagnostics

P9 turns errors from one-line logs into source-localized snippets:

```text
error[OCAML-FRONTEND]: This expression has type "string"
 --> examples/demo.ml:1:13
  |
1 | let _: int = "json"
  |             ^^^^^^
```

- Default human output: rustc-style heading, location, source line, and caret span
- `--error-format=human|json|oneline`: terminal, LSP, and CI each get the right format
- `--color=auto|always|never` plus `NO_COLOR` keep logs reproducible

<!-- speaker: The first P9 developer-experience layer is diagnostics. Before P9, an error was mostly a one-line log. Now the default output is a rustc-style block with an error code, file location, source line, and caret highlight. Local users keep the human format, tools and editors consume `--error-format=json`, and CI can still choose `oneline`. The point is to move from seeing an error message to landing directly on the source span. -->

---

## P9 Developer Experience: `omlz-lsp` Zig stdio LSP

```text
editor didOpen/didChange
        │
        ▼
omlz-lsp (Zig, stdio JSON-RPC)
        │ forks
        ▼
omlz check --error-format=json
        │
        ▼
textDocument/publishDiagnostics
```

- LSP 3.17 base protocol: `initialize`, `didOpen`, `didChange`, `shutdown`
- Full-document sync, fork-per-request, no long-lived OCaml frontend state
- Harness-observed median `~138ms`, fast enough for editor debounce

<!-- speaker: The second layer is the editor loop. `omlz-lsp` is a Zig stdio language server that speaks standard LSP JSON-RPC framing. It stays deliberately small: on didOpen or didChange, it writes the document to a temporary `.ml` file, runs `omlz check --error-format=json`, and publishes diagnostics back to the editor. The harness observes a median latency of roughly one hundred thirty-eight milliseconds, which is well within an interactive debounce window. -->

---

## P9 Developer Experience: source maps + `omlz unmap`

BPF runtime positions can resolve back to OCaml source:

```sh
./zig-out/bin/omlz build --target=bpf examples/hackathon_greet.ml -o out/hackathon_greet.so
./zig-out/bin/omlz unmap --so out/hackathon_greet.so --pc 0x80
```

- Deterministic JSON sidecar: `out/<name>.map`
- BPF `.so` embeds a `.zxcaml.srcmap` metadata section
- `omlz unmap`: PC → `examples/*.ml:line:col`

<!-- speaker: The third layer closes the on-chain debugging loop. P9 source maps connect BPF program counters back to OCaml file, line, and column locations. Builds write a deterministic `.map` sidecar and embed compressed metadata in the `.zxcaml.srcmap` ELF section. When a Mollusk failure or runtime PC appears, `omlz unmap` can translate that low-level address back to the `.ml` source a developer actually wrote. -->

---

## 9:20–10:00 Close and call to action

Today's loop:

`.ml` source → ZxCaml pipeline → BPF → IDL → Mollusk → Surfpool localnet

```sh
./scripts/demo/run_full_demo.sh
```

Inspect the source, scripts, and tests — then tell us which OCaml program you want to bring to Solana.

<!-- speaker: Today we started with a normal OCaml `.ml` file, sent it through the ZxCaml pipeline, produced BPF, emitted IDL, validated behavior with Mollusk, deployed to a Surfpool localnet, and invoked it with real state changes. That is the experience ZxCaml wants to give Solana builders: strong types and functional abstraction, while still producing deterministic, compact, deployable on-chain programs. Open the repo, run `./scripts/demo/run_full_demo.sh`, inspect the source, scripts, and tests, and tell us which OCaml program you want to bring to Solana next. -->

---

# Thank you

ZxCaml: Borrow the frontend. Replace the backend. Land on BPF.

<!-- speaker: Thank you for watching. -->
