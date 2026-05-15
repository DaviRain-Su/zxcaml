#!/usr/bin/env bash

SURFPOOL_STATE_DIR="${ROOT:?ROOT must be set before sourcing}/.surfpool/tests-solana"
SURFPOOL_PID_FILE="${SURFPOOL_STATE_DIR}/surfpool.pid"
SURFPOOL_PROGRAM_ID_FILE="${SURFPOOL_STATE_DIR}/program_id"
SURFPOOL_LOG_DIR="${ROOT}/.surfpool/logs"
SURFPOOL_LOG_FILE="${SURFPOOL_LOG_DIR}/surfpool.log"

zxcaml_require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command '$1' not found. Run ./init.sh first." >&2
    return 1
  fi
}

zxcaml_show_file_tail() {
  local file_path="$1"
  local line_count="${2:-80}"
  python3 - "$file_path" "$line_count" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
count = int(sys.argv[2])
if not path.exists():
    sys.exit(0)
lines = path.read_text(errors="replace").splitlines()
for line in lines[-count:]:
    print(line)
PY
}

zxcaml_rpc_json() {
  local method="$1"
  local params="${2:-[]}"
  curl -sf \
    --connect-timeout "${ZXCAML_SURFPOOL_RPC_CONNECT_TIMEOUT:-1}" \
    --max-time "${ZXCAML_SURFPOOL_RPC_MAX_TIME:-2}" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
    "$RPC_URL"
}

zxcaml_surfpool_ready() {
  zxcaml_rpc_json getHealth '[]' 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("result") == "ok" else 1)' 2>/dev/null
}

zxcaml_surfpool_pid_owned() {
  local pid="$1"
  local command_line
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$command_line" ]] || return 1
  [[ "$command_line" == *"surfpool start"* ]] || return 1
  [[ "$command_line" == *"--host 127.0.0.1"* ]] || return 1
  [[ "$command_line" == *"--port ${RPC_PORT}"* ]] || return 1
  [[ "$command_line" == *"--ws-port ${WS_PORT}"* ]] || return 1
}

zxcaml_report_port_listener() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
}

zxcaml_explain_port_conflict() {
  local port="$1"
  echo "ERROR: required Surfpool port 127.0.0.1:$port is already in use by a listener that is not owned by ${SURFPOOL_PID_FILE}." >&2
  echo "ERROR: stop that listener and rerun the harness; refusing to kill, reuse, or attach to unknown processes." >&2
  zxcaml_report_port_listener "$port"
}

zxcaml_remove_stale_state() {
  mkdir -p "$SURFPOOL_STATE_DIR" "$SURFPOOL_LOG_DIR"

  if [[ -f "$SURFPOOL_PID_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$SURFPOOL_PID_FILE")"
    if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
      if zxcaml_surfpool_pid_owned "$old_pid"; then
        echo "ERROR: stale harness-owned Surfpool PID $old_pid is still running. Refusing to reuse it." >&2
      else
        echo "ERROR: $SURFPOOL_PID_FILE points to live PID $old_pid that is not the harness-owned Surfpool process." >&2
      fi
      return 1
    fi
    echo "==> removing stale Surfpool pidfile: $SURFPOOL_PID_FILE"
    rm -f "$SURFPOOL_PID_FILE"
  fi

  if [[ -f "$SURFPOOL_PROGRAM_ID_FILE" ]]; then
    echo "==> removing stale harness program id file: $SURFPOOL_PROGRAM_ID_FILE"
    rm -f "$SURFPOOL_PROGRAM_ID_FILE"
  fi
}

zxcaml_check_port_conflicts() {
  local conflict=0
  local port
  for port in "$RPC_PORT" "$WS_PORT"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      zxcaml_explain_port_conflict "$port"
      conflict=1
    fi
  done
  (( conflict == 0 ))
}

zxcaml_start_surfpool() {
  zxcaml_remove_stale_state || return 1

  zxcaml_check_port_conflicts || return 1

  if zxcaml_surfpool_ready; then
    echo "ERROR: $RPC_URL already answers getHealth, but no harness pidfile exists. Refusing to attach to an unknown Surfpool process." >&2
    return 1
  fi

  : >"$SURFPOOL_LOG_FILE"
  echo "==> starting Surfpool at $RPC_URL (ws://127.0.0.1:$WS_PORT)"
  echo "==> Surfpool log: $SURFPOOL_LOG_FILE"
  (
    cd "$ROOT"
    exec surfpool start \
      --no-tui \
      --no-studio \
      --no-deploy \
      --offline \
      --host 127.0.0.1 \
      --port "$RPC_PORT" \
      --ws-port "$WS_PORT" \
      --log-path .surfpool/logs
  ) >"$SURFPOOL_LOG_FILE" 2>&1 &
  SURFPOOL_PID=$!
  export SURFPOOL_PID
  printf '%s\n' "$SURFPOOL_PID" >"$SURFPOOL_PID_FILE"
  echo "==> Surfpool PID: $SURFPOOL_PID"

  local _ready=0
  for _ in $(seq 1 90); do
    if ! kill -0 "$SURFPOOL_PID" 2>/dev/null; then
      echo "ERROR: Surfpool exited before getHealth became ready." >&2
      zxcaml_show_file_tail "$SURFPOOL_LOG_FILE" 120 >&2
      rm -f "$SURFPOOL_PID_FILE"
      return 1
    fi
    if zxcaml_surfpool_ready; then
      echo "==> Surfpool getHealth ok at $RPC_URL"
      _ready=1
      break
    fi
    sleep 1
  done

  if (( _ready == 0 )); then
    echo "ERROR: Surfpool getHealth did not report ok within 90s." >&2
    zxcaml_show_file_tail "$SURFPOOL_LOG_FILE" 120 >&2
    return 1
  fi
}

zxcaml_run_fixture_hook() {
  local hook="${ZXCAML_SOLANA_FIXTURE_SCRIPT:-}"
  if [[ -z "$hook" ]]; then
    return 0
  fi
  if [[ ! -f "$hook" ]]; then
    echo "ERROR: ZXCAML_SOLANA_FIXTURE_SCRIPT points to missing file: $hook" >&2
    return 1
  fi
  if [[ ! -x "$hook" ]]; then
    echo "ERROR: ZXCAML_SOLANA_FIXTURE_SCRIPT is not executable: $hook" >&2
    return 1
  fi

  echo "==> running Surfpool fixture hook: $hook"
  ZXCAML_SURFPOOL_RPC_URL="$RPC_URL" \
    ZXCAML_SURFPOOL_WS_URL="ws://127.0.0.1:$WS_PORT" \
    ZXCAML_SURFPOOL_PROGRAM_ID="$PROGRAM_ID" \
    ZXCAML_SURFPOOL_PAYER_KEYPAIR="$KEYPAIR" \
    ZXCAML_SURFPOOL_PROGRAM_SO="$PROGRAM_SO" \
    ZXCAML_SURFPOOL_STATE_DIR="$SURFPOOL_STATE_DIR" \
    "$hook"
}

zxcaml_stop_surfpool() {
  local pid="${SURFPOOL_PID:-}"
  if [[ -z "$pid" && -f "$SURFPOOL_PID_FILE" ]]; then
    pid="$(cat "$SURFPOOL_PID_FILE")"
  fi

  if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    if ! zxcaml_surfpool_pid_owned "$pid"; then
      echo "ERROR: refusing to stop PID $pid because it does not match the harness-owned Surfpool process." >&2
      return 1
    fi

    echo "==> stopping Surfpool PID $pid"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 3); do
      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        break
      fi
      if [[ "$(ps -p "$pid" -o stat= 2>/dev/null | tr -d ' ')" == Z* ]]; then
        wait "$pid" 2>/dev/null || true
        break
      fi
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "==> Surfpool PID $pid still alive after 3s; sending SIGKILL"
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  fi

  rm -f "$SURFPOOL_PID_FILE" "$SURFPOOL_PROGRAM_ID_FILE"

  local conflict=0
  local port
  for port in "$RPC_PORT" "$WS_PORT"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "ERROR: port 127.0.0.1:$port still has a listener after harness teardown." >&2
      zxcaml_report_port_listener "$port"
      conflict=1
    fi
  done
  (( conflict == 0 ))
}
