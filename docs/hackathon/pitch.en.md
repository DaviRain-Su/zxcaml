OCaml on Solana should not mean a toy VM; with ZxCaml, an ordinary `.ml` file can become a real deployable BPF program.

In the demo, ZxCaml compiles `hackathon_greet.ml`, a PDA-backed greeting counter, into a `.so` and Anchor-compatible IDL, proves init plus two greet calls in Mollusk, then deploys to Surfpool and reads back real account state.

The difference is that ZxCaml borrows upstream OCaml for parsing and type checking, but replaces the runtime and backend with ANF/Core IR, arena lowering, and Zig codegen for deterministic, compact, GC-free Solana artifacts.

Open the repo, run `./scripts/demo/run_full_demo.sh`, inspect the source, scripts, and tests, and tell us which OCaml program you want to bring to Solana next.
