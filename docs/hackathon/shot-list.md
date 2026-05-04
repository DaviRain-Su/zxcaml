# ZxCaml Colosseum Demo Shot List

This shot list follows the section boundaries in `docs/hackathon/timeline.md`
exactly. Use it as the recording checklist for the 10-minute Colosseum demo;
do not change timestamps here unless the authoritative timeline changes first.

## Recording Setup

- **Canvas**: 16:9, 1440p or 1080p. Use one focused window at a time.
- **Terminal**: dark theme, 16–18 pt monospace, repository root
  `/Users/davirian/dev/active/ZxCaml`, prompt hidden or short.
- **IDE**: hide unrelated sidebars except where a file path must be visible.
  Use 16–18 pt font and keep the active file tab readable.
- **Browser / Explorer**: only use if the Surfpool or Solana Explorer view is
  already rehearsed; otherwise the timeline stays terminal-only for localnet.
- **Cut rule**: every section starts on a clean frame with the target file,
  command, or title already visible unless the transition explicitly says to
  type/run live.

## Section-by-Section Shots

| Time | Section | Surface | Expected window content | Transition / cut | Pre-recorded asset references |
|------|---------|---------|-------------------------|------------------|-------------------------------|
| 0:00 – 0:35 | Hook: OCaml on Solana | title-card | Center title `ZxCaml — OCaml → Solana BPF`; subtitle `Typed OCaml programs, deterministic Solana artifacts`; small footer with repo path. | Fade in from black over 1 second. Hold the title for the full hook; cut on narration phrase "Surfpool localnet deployment." | Title card built from text only; optional background texture from `docs/01-architecture.md` pipeline diagram, blurred. |
| 0:35 – 1:20 | Compiler pipeline in one picture | IDE | `docs/01-architecture.md` open at the pipeline diagram. Cursor starts at `.ml source`, then moves stage-by-stage to `Solana BPF .so`. | Hard cut from title card to IDE. Do not scroll quickly; use slow cursor movement or brief zoom punches for `zxc-frontend`, `Core IR`, and `sbpf-linker`. | `docs/01-architecture.md` section `## 1. Pipeline`; optional cropped architecture diagram exported from the Mermaid diagram in the same file. |
| 1:20 – 2:20 | Start `hackathon_greet.ml` | IDE | `examples/hackathon_greet.ml` open at the top of the file. Visible areas: file header comment, entrypoint, and top-level instruction structure. | Cut to source file already open. If the file is not yet authored during rehearsal, use a prepared recording take after Milestone H-B lands; do not substitute another example. | Source file reference: `examples/hackathon_greet.ml`. No additional asset. |
| 2:20 – 3:20 | Instruction dispatch and typed state | IDE | Same file, scrolled to discriminator dispatch and typed state encode/decode helpers. Highlight `init = 0`, `greet = 1`, state fields, and byte layout helpers. | Continue from previous IDE shot with a gentle scroll. Add two short zoom punches: first on discriminator branches, second on state encode/decode. | Source file reference: `examples/hackathon_greet.ml`; optional static callout labels `discriminator` and `typed state layout`. |
| 3:20 – 4:10 | PDA and account flow | IDE | Same file, scrolled to PDA seed/bump validation and the account write path. Cursor points in order: PDA check, initialization write, counter increment, final account-data write. | Continue in IDE. Use a visible cursor trail or step-by-step selection so the recorder can match narration to code without searching. | Source file reference: `examples/hackathon_greet.ml`; optional callout label `PDA-backed greeting account`. |
| 4:10 – 5:10 | Build BPF and emit IDL | terminal | Clean terminal at repo root. Run `./scripts/demo/01_build.sh && ./zig-out/bin/omlz idl examples/hackathon_greet.ml > out/hackathon_greet.json`. End frame shows successful build output plus `out/hackathon_greet.json` path. | Hard cut from IDE to terminal. Command should be pasted or prefilled, then executed live. If build output is long, trim dead time with a jump cut while preserving start and success frames. | Script reference: `scripts/demo/01_build.sh`; generated artifact references: `out/hackathon_greet.so`, `out/hackathon_greet.json`. |
| 5:10 – 6:10 | Prove behavior with Mollusk | terminal | Terminal at repo root or `tests/` directory. Run `cargo test -p zxcaml-tests --test hackathon_greet_test`. End frame must show test result OK and visible mentions of init + two greet assertions if available. | Cut from previous terminal output to a fresh prompt. Execute live. Hold final `test result: ok` frame for at least 2 seconds before cutting. | Test reference: `tests/hackathon_greet_test.rs`; BPF artifact from previous section. |
| 6:10 – 7:20 | Start Surfpool and deploy | terminal | Terminal with two sequential commands: `./scripts/demo/02_surfpool_up.sh && ./scripts/demo/03_deploy.sh`. End frame shows Surfpool RPC readiness, deploy success, and program ID. | Clear terminal or open a new pane before this section. If Surfpool startup exceeds the time budget, use a jump cut from "starting" to "RPC ready"; keep the PID/log line visible for process hygiene. | Script references: `scripts/demo/02_surfpool_up.sh`, `scripts/demo/03_deploy.sh`; generated keypair directory `scripts/demo/.keypairs/` if shown, but do not zoom into private key bytes. |
| 7:20 – 8:30 | Invoke on localnet and inspect state | terminal | Terminal runs `./scripts/demo/04_invoke.sh`. Visible output must include init transaction, greet transaction(s), PDA/account address, and final state readback with counter value. | Continue terminal take from deploy or hard cut to fresh prompt. Pause after each important line: transaction signature, account address, final counter. | Script reference: `scripts/demo/04_invoke.sh`; optional browser-Solana-Explorer cutaway only if local explorer is already open to the deployed program/account. |
| 8:30 – 9:20 | Anchor comparison | terminal | Run `./scripts/demo/compare.sh && open docs/hackathon/anchor-comparison.md`. Then show comparison document with line count, artifact size, compile time where available, and ergonomics notes. | Terminal command first, then cut to IDE or browser preview of `docs/hackathon/anchor-comparison.md`. Use slow scroll across the comparison table; avoid editing during recording. | Script reference: `scripts/demo/compare.sh`; doc reference: `docs/hackathon/anchor-comparison.md`; generated numbers may cite `docs/hackathon/anchor-comparison.generated.md` after Milestone H-D. |
| 9:20 – 10:00 | Close and call to action | title-card | Closing card with `ZxCaml`, GitHub/repo link placeholder, docs path `docs/hackathon/`, and reproducibility command `./scripts/demo/run_full_demo.sh`. | Fade from comparison document to closing title card. Hold the final command on screen for the last 8–10 seconds, then fade to black. | Title card built from text only; reference command `scripts/demo/run_full_demo.sh`. |

## Recorder Checklist

- Confirm the visible section order and timestamps match `docs/hackathon/timeline.md`.
- Keep every command exactly as shown in the table unless the underlying script
  path changes in a later milestone and the timeline is updated first.
- Never show secret key material; if `scripts/demo/.keypairs/` appears, keep
  the shot at directory or filename level only.
- After any Surfpool recording take, run the teardown flow from
  `scripts/demo/05_teardown.sh` before starting another take.
