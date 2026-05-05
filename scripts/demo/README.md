# Surfpool Demo Scripts

These scripts run the Colosseum hackathon `hackathon_greet` demo from build to local Surfpool invocation.

## Usage

From the repository root:

```sh
./scripts/demo/00_setup.sh
./scripts/demo/01_build.sh
./scripts/demo/02_surfpool_up.sh
./scripts/demo/03_deploy.sh
./scripts/demo/04_invoke.sh
./scripts/demo/05_teardown.sh
```

Or run the whole sequence with timestamps:

```sh
./scripts/demo/run_full_demo.sh
```

Generated local artifacts live under `out/`, `scripts/demo/.keypairs/`, `scripts/demo/.program_id`, `scripts/demo/.surfpool.pid`, and `.surfpool/`.

## Deep clean

`make clean` removes normal demo and slide outputs while preserving `scripts/demo/anchor_reference/target/`, which can contain large but valid Anchor/Cargo build artifacts.

To opt in to removing that Anchor build cache, run:

```sh
make demo-clean-deep
```

The deep-clean target deletes `scripts/demo/anchor_reference/target/` only when it exists and prints the approximate disk space freed.

## Expected Output

A successful run prints:

```text
READY: all demo prerequisites are available.
Built out/hackathon_greet.so
Regenerated out/hackathon_greet.json
RPC ready at http://127.0.0.1:8899
Deployed program id: <PROGRAM_ID>
Greeting PDA: <PDA> (bump=255, seeds=['greet', maker])
init signature: <SIGNATURE>
greet 1 signature: <SIGNATURE>
greet 2 signature: <SIGNATURE>
decoded counter: 2
SUCCESS: hackathon_greet counter=2
CLEAN: no surfpool processes remain.
```

## Troubleshooting

- **`surfpool` missing**: install with `cargo install surfpool-cli` or follow the Surfpool installation guide.
- **`solana` missing**: install the Solana/Agave CLI, then ensure it is on `PATH`.
- **`omlz` missing**: run `./init.sh`, then `eval "$(opam env --switch=zxcaml-p1)" && zig build`.
- **RPC port already in use**: stop the process currently serving `http://127.0.0.1:8899`, or run with a different `RPC_URL`/Surfpool port once the scripts are adjusted consistently.
- **Stale Surfpool state**: run `./scripts/demo/05_teardown.sh`, then retry.
- **Invocation account errors**: `04_invoke.sh` uses Surfpool's `surfnet_setAccount` cheatcode to prepare the program-owned PDA account required by the current demo runtime fixture.

## Notes

`04_invoke.sh` defaults to two greet calls (`GREET_CALLS=2`) so the final counter mirrors the Mollusk integration test. Override it with, for example, `GREET_CALLS=1 ./scripts/demo/04_invoke.sh`.
