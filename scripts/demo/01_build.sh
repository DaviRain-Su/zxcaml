#!/usr/bin/env bash
# Purpose: build the Colosseum hackathon greeting program and regenerate its
# canonical Anchor-compatible IDL artifact.
# Args: none.
# Expected output: out/hackathon_greet.so and out/hackathon_greet.json are
# written, followed by a short success summary with both paths.
# Exit codes: 0 when the BPF artifact and IDL are generated; non-zero if the
# compiler build, BPF build, or IDL generation fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${REPO_ROOT}"

if [[ ! -x "./zig-out/bin/omlz" ]]; then
  printf 'omlz not found; running zig build first...\n'
  if command -v opam >/dev/null 2>&1; then
    eval "$(opam env --switch=zxcaml-p1)"
  fi
  zig build
fi

mkdir -p out

./zig-out/bin/omlz build --target=bpf examples/hackathon_greet.ml -o out/hackathon_greet.so
./zig-out/bin/omlz idl examples/hackathon_greet.ml > out/hackathon_greet.json

test -s out/hackathon_greet.so
test -s out/hackathon_greet.json

printf 'Built %s\n' "out/hackathon_greet.so"
printf 'Regenerated %s\n' "out/hackathon_greet.json"
