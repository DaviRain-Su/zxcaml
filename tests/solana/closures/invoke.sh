#!/usr/bin/env bash
#
# Solana BPF acceptance harness for first-class closure hardening.
# Reuses the canonical hello harness while overriding the source program.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

run_case() {
  local name="$1"
  local src="$2"
  echo "==> closure acceptance case: $name"
  ZXCAML_SOLANA_SRC="$src" "$ROOT/tests/solana/hello/invoke.sh"
}

run_case "List.map immediate closure" "$ROOT/tests/solana/closures/list_map.ml"
run_case "match returns ADT-capturing closure" "$ROOT/tests/solana/closures/closure_hardening.ml"
run_case "closure captures multiple environment values" "$ROOT/tests/solana/closures/multi_env.ml"
run_case "escaping nested closure" "$ROOT/tests/solana/closures/nested_escape.ml"
