#!/usr/bin/env bash
#
# Solana BPF acceptance harness for first-class closure hardening.
# Reuses the canonical hello harness while overriding the source program.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export ZXCAML_SOLANA_SRC="$ROOT/tests/solana/closures/closure_hardening.ml"

exec "$ROOT/tests/solana/hello/invoke.sh"
