# ZxCaml Colosseum Hackathon Assets

This directory is the index for the recordable Colosseum demo package: the
storyboard, bilingual narration, submission copy, comparison artifacts, and the
Surfpool scripts that reproduce the live localnet segment.

## Hackathon docs

| File | Purpose |
|---|---|
| [`anchor-comparison.generated.md`](./anchor-comparison.generated.md) | Generated numeric comparison between ZxCaml and the Anchor reference. |
| [`anchor-comparison.md`](./anchor-comparison.md) | Human-readable ZxCaml vs Anchor comparison for the greeting counter demo. |
| [`colosseum-submission.md`](./colosseum-submission.md) | Colosseum project-page draft. |
| [`demo-script.en.md`](./demo-script.en.md) | English 10-minute demo narration. |
| [`demo-script.zh.md`](./demo-script.zh.md) | 简体中文 10-minute demo narration. |
| [`pitch.en.md`](./pitch.en.md) | English 60-second elevator pitch. |
| [`pitch.zh.md`](./pitch.zh.md) | 简体中文 60-second elevator pitch. |
| [`recording-checklist.md`](./recording-checklist.md) | Recording-day workflow checklist with slide, terminal, OBS scene, and fallback cues. |
| [`shot-list.md`](./shot-list.md) | Recording shot list mapped to the timeline. |
| [`timeline.md`](./timeline.md) | Authoritative 10-minute demo timeline. |

## Demo scripts

Run the complete localnet path with:

```sh
make demo
```

| File | Purpose |
|---|---|
| [`../../scripts/demo/00_setup.sh`](../../scripts/demo/00_setup.sh) | Verifies Surfpool, Solana, Python, OpenSSL, and `omlz` prerequisites. |
| [`../../scripts/demo/01_build.sh`](../../scripts/demo/01_build.sh) | Builds `out/hackathon_greet.so` and regenerates `out/hackathon_greet.json`. |
| [`../../scripts/demo/02_surfpool_up.sh`](../../scripts/demo/02_surfpool_up.sh) | Starts Surfpool and waits for local RPC readiness. |
| [`../../scripts/demo/03_deploy.sh`](../../scripts/demo/03_deploy.sh) | Funds the payer and deploys the BPF artifact to Surfpool. |
| [`../../scripts/demo/04_invoke.sh`](../../scripts/demo/04_invoke.sh) | Sends `init` plus `greet` calls and verifies the decoded PDA counter. |
| [`../../scripts/demo/05_teardown.sh`](../../scripts/demo/05_teardown.sh) | Stops the recorded Surfpool PID and removes local Surfpool state. |
| [`../../scripts/demo/README.md`](../../scripts/demo/README.md) | Usage notes, expected output, troubleshooting, and script-specific notes. |
| [`../../scripts/demo/compare.sh`](../../scripts/demo/compare.sh) | Regenerates comparison measurements and updates the generated comparison doc. |
| [`../../scripts/demo/run_full_demo.sh`](../../scripts/demo/run_full_demo.sh) | One-shot setup → build → Surfpool up → deploy → invoke → teardown runner. |
| [`../../scripts/demo/run_log.expected.txt`](../../scripts/demo/run_log.expected.txt) | Reference transcript showing a successful dry run. |

## Anchor reference files

| File | Purpose |
|---|---|
| [`../../scripts/demo/anchor_reference/Anchor.toml`](../../scripts/demo/anchor_reference/Anchor.toml) | Isolated Anchor configuration for the fairness reference. |
| [`../../scripts/demo/anchor_reference/Cargo.toml`](../../scripts/demo/anchor_reference/Cargo.toml) | Isolated Cargo workspace for the Anchor reference. |
| [`../../scripts/demo/anchor_reference/README.md`](../../scripts/demo/anchor_reference/README.md) | Explains the Anchor reference's comparison-only role. |
| [`../../scripts/demo/anchor_reference/programs/hackathon_greet_anchor/Cargo.toml`](../../scripts/demo/anchor_reference/programs/hackathon_greet_anchor/Cargo.toml) | Anchor program crate manifest. |
| [`../../scripts/demo/anchor_reference/programs/hackathon_greet_anchor/src/lib.rs`](../../scripts/demo/anchor_reference/programs/hackathon_greet_anchor/src/lib.rs) | Anchor implementation mirroring `hackathon_greet` semantics. |

## Generated local state

`make demo` and the component scripts may create ignored local artifacts under
`out/`, `.surfpool/`, `scripts/demo/.keypairs/`,
`scripts/demo/.program_id`, and `scripts/demo/.surfpool.pid`. Remove them with:

```sh
make demo-clean
```
