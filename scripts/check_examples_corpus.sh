#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OMLZ_BIN="${OMLZ_BIN:-./zig-out/bin/omlz}"
LAYOUT_CHECK="${ROOT}/scripts/check_examples_layout.py"

python3 "$LAYOUT_CHECK"

ALL_EXAMPLES=()
while IFS= read -r example; do
  [[ -n "$example" ]] || continue
  ALL_EXAMPLES+=("$example")
done < <(
  {
    python3 "$LAYOUT_CHECK" --print-category user_example
    python3 "$LAYOUT_CHECK" --print-category excluded_historical
  } | LC_ALL=C sort
)

included=()
while IFS= read -r example; do
  [[ -n "$example" ]] || continue
  included+=("$example")
done < <(python3 "$LAYOUT_CHECK" --print-category user_example)

excluded=()
while IFS= read -r example; do
  [[ -n "$example" ]] || continue
  excluded+=("$example")
done < <(python3 "$LAYOUT_CHECK" --print-category excluded_historical)

echo "Examples corpus candidates (${#ALL_EXAMPLES[@]} files):"
for example in "${ALL_EXAMPLES[@]}"; do
  echo "  - $example"
done

echo
echo "Excluded examples (${#excluded[@]} files):"
for example in "${excluded[@]}"; do
  echo "  - $example :: manifest category excluded_historical"
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
