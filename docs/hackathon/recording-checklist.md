# Recording-Day Checklist

Use this checklist on recording day after `make demo-record-prep` succeeds. Keep
Slidev on one screen, the terminal or IDE on the other, and switch OBS scenes at
the timestamp boundaries below. If something breaks, follow the fallback note
instead of changing the frozen timeline during the take.

## Preflight

- Run `make demo-record-prep` and confirm `READY TO RECORD` plus both slide PDF
  paths appear.
- Open `out/slides/zh.pdf` or `out/slides/en.pdf` to the matching section slide.
- Keep the terminal at `/Users/davirian/dev/active/ZxCaml` with a short prompt.
- Confirm OBS Scene labels match the checklist before starting the final take.

## Section Checklist

| Timestamp | Slide ID / heading | Terminal command | OBS scene | Fallback note |
|---|---|---|---|---|
| 0:00 – 0:35 | S02 / `## 0:00–0:35 Hook: OCaml on Solana` | `no terminal` | OBS Scene 01 — title card | If Slidev is not ready, use the exported PDF title slide and hold on the opening card. |
| 0:35 – 1:20 | S03 / `## 0:35–1:20 Architecture Overview: Borrow the frontend, replace the backend` | `no terminal` | OBS Scene 02 — slides plus IDE architecture | If the IDE view is mis-cued, stay on the architecture slide and point to the Mermaid pipeline. |
| 1:20 – 2:20 | S04 / `## 1:20–2:20 The star: hackathon_greet.ml` | `no terminal` | OBS Scene 03 — IDE source intro | If the file scroll position is wrong, cut to the slide while reopening `examples/hackathon_greet.ml`. |
| 2:20 – 3:20 | S05 / `## 2:20–3:20 Instruction dispatch and typed state` | `no terminal` | OBS Scene 04 — IDE dispatch walk | If highlighting fails, narrate from the slide and use a static cursor on `init = 0` / `greet = 1`. |
| 3:20 – 4:10 | S06 / `## 3:20–4:10 PDA and account flow` | `no terminal` | OBS Scene 05 — IDE PDA flow | If the account-write code is hard to find, stay on the PDA slide and mention the rehearsed source path. |
| 4:10 – 5:10 | S07 / `## 4:10–5:10 Build BPF and emit IDL` | `./scripts/demo/01_build.sh && ./zig-out/bin/omlz idl examples/hackathon_greet.ml > out/hackathon_greet.json` | OBS Scene 06 — terminal build | If the build is slow, jump-cut from command start to success output while preserving the final artifact paths. |
| 5:10 – 6:10 | S08 / `## 5:10–6:10 Prove behavior with Mollusk` | `cargo test -p zxcaml-tests --test hackathon_greet_test` | OBS Scene 07 — terminal tests | If Cargo recompiles too much, use the cached successful output from rehearsal and hold on `test result: ok`. |
| 6:10 – 7:20 | S09 / `## 6:10–7:20 Start Surfpool and deploy` | `./scripts/demo/02_surfpool_up.sh && ./scripts/demo/03_deploy.sh` | OBS Scene 08 — terminal deploy | If Surfpool startup exceeds the budget, jump-cut to the RPC-ready and deploy-success lines. |
| 7:20 – 8:30 | S10 / `## 7:20–8:30 Invoke on localnet and inspect state` | `./scripts/demo/04_invoke.sh` | OBS Scene 09 — terminal invoke | If live invoke fails, show `scripts/demo/run_log.expected.txt` and explain the expected counter readback. |
| 8:30 – 9:20 | S11 / `## 8:30–9:20 Anchor comparison` | `./scripts/demo/compare.sh && open docs/hackathon/anchor-comparison.md` | OBS Scene 10 — comparison doc | If the generated comparison is already current, skip rerun and open `docs/hackathon/anchor-comparison.md` directly. |
| 9:20 – 10:00 | S12 / `## 9:20–10:00 Close and call to action` | `no terminal` | OBS Scene 11 — closing card | If the deck navigation misses the closing slide, use the exported PDF and keep `./scripts/demo/run_full_demo.sh` visible. |
| 10:00 – 10:30 | Budget cap (10:30) / hold S12 closing card | `no terminal` | OBS Scene 11 — closing card | If the recording overruns after 10:00, do not add new material: hold the closing card, finish the call to action in one sentence, and cut before the 10:30 upper bound. |

## Post-Take Cleanup

- Run `make demo-clean` after any take that starts Surfpool.
- Verify no Surfpool or Solana validator process is still running before a retake.
