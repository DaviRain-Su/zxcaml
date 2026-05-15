#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OMLZ_BIN="${OMLZ_BIN:-./zig-out/bin/omlz}"

exclude_reason() {
  case "$1" in
    examples/m0_unsupported.ml)
      echo "intentional diagnostic fixture; expected to fail"
      ;;
    *)
      return 1
      ;;
  esac
}

ALL_EXAMPLES=()
while IFS= read -r example; do
  ALL_EXAMPLES+=("$example")
done < <(find examples -maxdepth 1 -type f -name '*.ml' | LC_ALL=C sort)

included=()
excluded=()

for example in "${ALL_EXAMPLES[@]}"; do
  if reason="$(exclude_reason "$example" 2>/dev/null)"; then
    excluded+=("$example")
  else
    included+=("$example")
  fi
done

echo "Examples corpus candidates (${#ALL_EXAMPLES[@]} files):"
for example in "${ALL_EXAMPLES[@]}"; do
  echo "  - $example"
done

echo
echo "Excluded examples (${#excluded[@]} files):"
for example in "${excluded[@]}"; do
  echo "  - $example :: $(exclude_reason "$example")"
done

echo
echo "Included examples (${#included[@]} files):"
for example in "${included[@]}"; do
  echo "  - $example"
done

echo
for example in "${included[@]}"; do
  echo "==> omlz check $example"
  "$OMLZ_BIN" check "$example"
  echo "PASS $example"
done

echo
echo "Examples corpus check passed: ${#included[@]} included, ${#excluded[@]} excluded."
