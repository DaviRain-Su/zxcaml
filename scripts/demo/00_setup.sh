#!/usr/bin/env bash
# Purpose: verify the local tools required for the Colosseum Surfpool demo.
# Args: none.
# Expected output: surfpool, solana, solana-keygen, curl, python3, openssl,
# and omlz versions/paths are printed; missing tools include install hints.
# Exit codes: 0 when all prerequisites are present; 1 when any tool is missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

missing=0

report_cmd() {
  local name="$1"
  shift
  if command -v "${name}" >/dev/null 2>&1; then
    printf 'OK: %s -> %s\n' "${name}" "$(command -v "${name}")"
    "$@" || true
  else
    printf 'MISSING: %s\n' "${name}" >&2
    missing=1
  fi
}

printf '==> ZxCaml Surfpool demo setup check\n'
printf 'repo: %s\n' "${REPO_ROOT}"

report_cmd surfpool surfpool --version
report_cmd solana solana --version
report_cmd solana-keygen solana-keygen --version
report_cmd curl curl --version
report_cmd python3 python3 --version
report_cmd openssl openssl version

if [[ -x "${REPO_ROOT}/zig-out/bin/omlz" ]]; then
  printf 'OK: omlz -> %s\n' "${REPO_ROOT}/zig-out/bin/omlz"
  "${REPO_ROOT}/zig-out/bin/omlz" --version
else
  printf 'MISSING: %s\n' "${REPO_ROOT}/zig-out/bin/omlz" >&2
  printf 'Install/build it with: eval "$(opam env --switch=zxcaml-p1)" && zig build\n' >&2
  missing=1
fi

if [[ ${missing} -ne 0 ]]; then
  cat >&2 <<'EOF'

Install hints:
  surfpool: cargo install surfpool-cli
            or follow https://docs.surfpool.run/toolchain/getting-started
  solana:   sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"
  omlz:     from the repository root, run ./init.sh then zig build

EOF
  exit 1
fi

printf 'READY: all demo prerequisites are available.\n'
