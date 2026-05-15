#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/solana/surfpool_harness.sh"

RPC_PORT="${SOLANA_RPC_PORT:-8899}"
RPC_URL="http://127.0.0.1:$RPC_PORT"
WS_PORT="${SOLANA_WS_PORT:-8900}"
ACTIVE_LISTENER_PID=""

cleanup_listener() {
  local pid="${1:-}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

cleanup() {
  cleanup_listener "$ACTIVE_LISTENER_PID"
}
trap cleanup EXIT

ensure_clean_harness_state() {
  local stale_pid=""
  if [[ -f "$SURFPOOL_PID_FILE" ]]; then
    stale_pid="$(cat "$SURFPOOL_PID_FILE" 2>/dev/null || true)"
    if [[ "$stale_pid" =~ ^[0-9]+$ ]] && kill -0 "$stale_pid" 2>/dev/null; then
      echo "ERROR: $SURFPOOL_PID_FILE still points to a live PID ($stale_pid); refusing to run conflict checks." >&2
      exit 1
    fi
  fi
  rm -f "$SURFPOOL_PID_FILE" "$SURFPOOL_PROGRAM_ID_FILE"
}

ensure_port_free() {
  local port="$1"
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: port 127.0.0.1:$port must be free before running preflight conflict checks." >&2
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
    exit 1
  fi
}

start_listener() {
  local port="$1"
  python3 - "$port" <<'PY' &
import socket
import sys
import time

port = int(sys.argv[1])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
time.sleep(30)
PY
  ACTIVE_LISTENER_PID="$!"
  for _ in $(seq 1 20); do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  cleanup_listener "$ACTIVE_LISTENER_PID"
  ACTIVE_LISTENER_PID=""
  echo "ERROR: temporary listener on 127.0.0.1:$port did not become ready." >&2
  exit 1
}

assert_conflict_failure() {
  local port="$1"
  local output=""
  local status=0

  ensure_clean_harness_state
  ensure_port_free "$port"
  start_listener "$port"

  echo "==> checking preflight conflict on 127.0.0.1:$port"
  set +e
  output="$(zxcaml_start_surfpool 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$output"

  if [[ $status -eq 0 ]]; then
    echo "ERROR: zxcaml_start_surfpool unexpectedly succeeded with a listener on 127.0.0.1:$port." >&2
    exit 1
  fi
  if [[ "$output" != *"127.0.0.1:$port"* ]]; then
    echo "ERROR: conflict diagnostic did not mention 127.0.0.1:$port." >&2
    exit 1
  fi
  if [[ "$output" != *"refusing to kill, reuse, or attach to unknown processes"* ]]; then
    echo "ERROR: conflict diagnostic did not explain the refusal to touch unknown processes." >&2
    exit 1
  fi
  if [[ -f "$SURFPOOL_PID_FILE" ]]; then
    echo "ERROR: preflight conflict created $SURFPOOL_PID_FILE even though launch should have been refused." >&2
    exit 1
  fi

  cleanup_listener "$ACTIVE_LISTENER_PID"
  ACTIVE_LISTENER_PID=""
  ensure_port_free "$port"
}

assert_conflict_failure "$RPC_PORT"
assert_conflict_failure "$WS_PORT"

echo "==> SUCCESS: Surfpool preflight refuses unknown listeners on RPC and WS ports"
