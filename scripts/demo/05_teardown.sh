#!/usr/bin/env bash
# Purpose: stop the Surfpool process started by scripts/demo/02_surfpool_up.sh
# and remove generated localnet cache state.
# Args: none.
# Expected output: the recorded Surfpool PID is terminated,
# scripts/demo/.surfpool.pid is removed, .surfpool/ is deleted, and no
# surfpool process remains.
# Exit codes: 0 when cleanup succeeds; non-zero if the recorded process cannot
# be stopped or another surfpool process is still running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PID_FILE="${SCRIPT_DIR}/.surfpool.pid"

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    printf 'Stopping Surfpool PID %s...\n' "${pid}"
    kill "${pid}" 2>/dev/null || true
    for _ in $(seq 1 3); do
      if ! kill -0 "${pid}" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    if kill -0 "${pid}" 2>/dev/null; then
      printf 'Surfpool PID %s still alive after 3s; sending SIGKILL.\n' "${pid}"
      kill -9 "${pid}" 2>/dev/null || true
    fi
  else
    printf 'No live Surfpool process found for pidfile value %s.\n' "${pid}"
  fi
  rm -f "${PID_FILE}"
else
  printf 'No Surfpool pidfile found at %s.\n' "${PID_FILE}"
fi

rm -rf "${REPO_ROOT}/.surfpool"
printf 'Removed %s\n' "${REPO_ROOT}/.surfpool"

if pgrep -f '[s]urfpool' >/dev/null 2>&1; then
  printf 'ERROR: at least one surfpool process is still running. Refusing to kill unknown processes.\n' >&2
  pgrep -af '[s]urfpool' >&2 || true
  exit 1
fi

printf 'CLEAN: no surfpool processes remain.\n'
