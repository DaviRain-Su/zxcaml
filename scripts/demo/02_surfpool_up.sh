#!/usr/bin/env bash
# Purpose: start a headless Surfpool localnet for the Colosseum demo.
# Args: optional RPC_URL environment variable; defaults to http://127.0.0.1:8899.
# Expected output: the Surfpool PID is written to scripts/demo/.surfpool.pid,
# RPC readiness is confirmed, and the log path is printed.
# Exit codes: 0 when RPC getHealth is ready within 30s; non-zero on port
# conflict, early Surfpool exit, or readiness timeout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PID_FILE="${SCRIPT_DIR}/.surfpool.pid"
RPC_URL="${RPC_URL:-http://127.0.0.1:8899}"
RPC_PORT="${RPC_URL##*:}"
RPC_PORT="${RPC_PORT%%/*}"
LOG_DIR="${REPO_ROOT}/.surfpool/logs"
LOG_FILE="${LOG_DIR}/surfpool.log"

rpc_call() {
  local method="$1"
  local params="${2:-[]}"
  curl -sf -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
    "${RPC_URL}"
}

rpc_ready() {
  rpc_call getHealth '[]' 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("result") == "ok" else 1)' 2>/dev/null
}

if [[ -f "${PID_FILE}" ]]; then
  old_pid="$(cat "${PID_FILE}")"
  if [[ "${old_pid}" =~ ^[0-9]+$ ]] && kill -0 "${old_pid}" 2>/dev/null; then
    printf 'Surfpool already running with PID %s (pidfile %s).\n' "${old_pid}" "${PID_FILE}"
    if rpc_ready; then
      printf 'RPC ready at %s\n' "${RPC_URL}"
      exit 0
    fi
    printf 'ERROR: pidfile process exists but RPC is not healthy. Run scripts/demo/05_teardown.sh first.\n' >&2
    exit 1
  fi
  rm -f "${PID_FILE}"
fi

if rpc_ready; then
  printf 'ERROR: %s already answers getHealth, but no demo pidfile exists. Refusing to attach to an unknown process.\n' "${RPC_URL}" >&2
  exit 1
fi

mkdir -p "${LOG_DIR}"
: >"${LOG_FILE}"

printf 'Starting Surfpool on RPC %s (log: %s)\n' "${RPC_URL}" "${LOG_FILE}"
(
  cd "${REPO_ROOT}"
  exec surfpool start --no-tui --no-studio --no-deploy --offline --port "${RPC_PORT}" --log-path .surfpool/logs
) >"${LOG_FILE}" 2>&1 &
pid=$!
printf '%s\n' "${pid}" >"${PID_FILE}"
printf 'Surfpool PID: %s\n' "${pid}"

for _ in $(seq 1 30); do
  if ! kill -0 "${pid}" 2>/dev/null; then
    printf 'ERROR: Surfpool exited before RPC became ready. Last log lines:\n' >&2
    python3 - "${LOG_FILE}" <<'PY' >&2
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text(errors='replace').splitlines()
print('\n'.join(lines[-80:]))
PY
    rm -f "${PID_FILE}"
    exit 1
  fi
  if rpc_ready; then
    printf 'RPC ready at %s\n' "${RPC_URL}"
    exit 0
  fi
  sleep 1
done

printf 'ERROR: Surfpool RPC did not become ready within 30s.\n' >&2
kill "${pid}" 2>/dev/null || true
rm -f "${PID_FILE}"
exit 1
