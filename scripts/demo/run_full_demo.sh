#!/usr/bin/env bash
# Purpose: run the complete Colosseum Surfpool demo sequence with timestamps.
# Args: optional RPC_URL and GREET_CALLS environment variables forwarded to the
# component scripts.
# Expected output: setup, build, surfpool up, deploy, invoke, and teardown each
# print timestamped start/finish lines; final output reports demo success.
# Exit codes: 0 when the whole sequence succeeds and teardown is clean; non-zero
# if any step fails. Teardown is attempted automatically on failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_SECONDS="$(date +%s)"

stamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

run_step() {
  local label="$1"
  shift
  local before after elapsed
  before="$(date +%s)"
  printf '\n[%s] START %s\n' "$(stamp)" "${label}"
  "$@"
  after="$(date +%s)"
  elapsed=$((after - before))
  printf '[%s] DONE  %s (%ss)\n' "$(stamp)" "${label}" "${elapsed}"
}

cleanup_on_exit() {
  local status=$?
  if [[ ${status} -ne 0 ]]; then
    printf '\n[%s] ERROR: demo failed (exit %s); running teardown.\n' "$(stamp)" "${status}" >&2
    "${SCRIPT_DIR}/05_teardown.sh" || true
  fi
  exit "${status}"
}
trap cleanup_on_exit EXIT

run_step '00 setup' "${SCRIPT_DIR}/00_setup.sh"
run_step '01 build' "${SCRIPT_DIR}/01_build.sh"
run_step '02 surfpool up' "${SCRIPT_DIR}/02_surfpool_up.sh"
run_step '03 deploy' "${SCRIPT_DIR}/03_deploy.sh"
run_step '04 invoke' "${SCRIPT_DIR}/04_invoke.sh"
run_step '05 teardown' "${SCRIPT_DIR}/05_teardown.sh"

trap - EXIT
END_SECONDS="$(date +%s)"
printf '\n[%s] SUCCESS: full demo completed in %ss.\n' "$(stamp)" "$((END_SECONDS - START_SECONDS))"
