#!/usr/bin/env bash
# Purpose: build the Colosseum hackathon greeting program and regenerate its
# canonical Anchor-compatible IDL artifact.
# Expected output: out/hackathon_greet.so and out/hackathon_greet.json are
# written, followed by a short success summary with both paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${REPO_ROOT}"

mkdir -p out

./zig-out/bin/omlz build --target=bpf examples/hackathon_greet.ml -o out/hackathon_greet.so
./zig-out/bin/omlz idl examples/hackathon_greet.ml > out/hackathon_greet.json

printf 'Built %s\n' "out/hackathon_greet.so"
printf 'Regenerated %s\n' "out/hackathon_greet.json"
