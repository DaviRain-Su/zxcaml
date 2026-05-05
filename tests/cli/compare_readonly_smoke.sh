#!/usr/bin/env bash
# Smoke test for scripts/demo/compare.sh default read-only behavior.
#
# This test intentionally starts from a clean Git working tree, runs the default
# compare script, verifies tracked files remain clean, verifies the gitignored
# out/compare-numbers.md report exists, and then removes that report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPORT="${REPO_ROOT}/out/compare-numbers.md"

cleanup() {
  rm -f "${REPORT}"
}
trap cleanup EXIT

cd "${REPO_ROOT}"

before="$(git status --porcelain)"
if [[ -n "${before}" ]]; then
  printf 'compare_readonly_smoke: working tree must be clean before the test\n' >&2
  printf '%s\n' "${before}" >&2
  exit 1
fi

rm -f "${REPORT}"

bash scripts/demo/compare.sh

after="$(git status --porcelain)"
if [[ -n "${after}" ]]; then
  printf 'compare_readonly_smoke: compare.sh dirtied the working tree\n' >&2
  printf '%s\n' "${after}" >&2
  exit 1
fi

test -s "${REPORT}"
printf 'compare_readonly_smoke: tree clean and %s exists\n' "${REPORT#${REPO_ROOT}/}"
