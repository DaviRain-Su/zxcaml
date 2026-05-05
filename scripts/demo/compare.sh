#!/usr/bin/env bash
# Purpose: measure the Colosseum demo's ZxCaml greeting program against the
# isolated Anchor reference by source line count, BPF artifact size, and build
# time.
# Args: none, --write, --help.
# Expected output: by default, out/compare-numbers.md is written and tracked
# files are left untouched. With --write, docs/hackathon/anchor-comparison.generated.md
# is rewritten. The human-authored anchor-comparison.md is never modified here.
# Exit codes: 0 when ZxCaml builds and measurements are written; 2 for usage
# errors; non-zero if required source files are missing or the ZxCaml BPF build
# fails. Anchor build failures fall back to the committed snapshot values
# documented below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ZXCAML_SRC="${REPO_ROOT}/examples/hackathon_greet.ml"
ZXCAML_SO="${REPO_ROOT}/out/hackathon_greet.so"
ANCHOR_DIR="${REPO_ROOT}/scripts/demo/anchor_reference"
ANCHOR_SRC="${ANCHOR_DIR}/programs/hackathon_greet_anchor/src/lib.rs"
GENERATED_DOC="${REPO_ROOT}/docs/hackathon/anchor-comparison.generated.md"
DEFAULT_REPORT="${REPO_ROOT}/out/compare-numbers.md"
WRITE_MODE=0

# Snapshot recorded on this repository/machine when Anchor/cargo build-sbf is
# unavailable. `scripts/demo/compare.sh` still rebuilds ZxCaml and recomputes
# source line counts before falling back to these Anchor artifact values.
SNAPSHOT_ANCHOR_SO_BYTES=183504
SNAPSHOT_ANCHOR_BUILD_SECONDS=18
SNAPSHOT_ANCHOR_STATUS="snapshot: cargo build-sbf was unavailable; last successful Anchor measurement committed by F-HD2"

TMP_DIR=""

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

require_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    printf 'required file is missing: %s\n' "${path}" >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF_USAGE'
Usage:
  bash scripts/demo/compare.sh [--write]
  bash scripts/demo/compare.sh --help

Default mode writes measured numbers to out/compare-numbers.md and does not
touch tracked documentation. Use --write to refresh only
docs/hackathon/anchor-comparison.generated.md.
EOF_USAGE
}

parse_args() {
  while (($#)); do
    case "$1" in
      --write)
        WRITE_MODE=1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

line_count() {
  wc -l < "$1" | tr -d '[:space:]'
}

byte_count() {
  wc -c < "$1" | tr -d '[:space:]'
}

measure_command() {
  local __result_var="$1"
  shift
  local start="${SECONDS}"
  "$@"
  local status=$?
  printf -v "${__result_var}" '%s' "$((SECONDS - start))"
  return "${status}"
}

build_zxcaml() {
  cd "${REPO_ROOT}"
  if command -v opam >/dev/null 2>&1; then
    eval "$(opam env --switch=zxcaml-p1)"
  fi
  "${SCRIPT_DIR}/01_build.sh" >&2
}

prepare_anchor_workspace() {
  TMP_DIR="$(mktemp -d)"
  local work="${TMP_DIR}/anchor_reference"

  mkdir -p "${work}/programs/hackathon_greet_anchor/src"
  cp "${ANCHOR_DIR}/Cargo.toml" "${work}/Cargo.toml"
  cp "${ANCHOR_DIR}/Anchor.toml" "${work}/Anchor.toml"
  cp "${ANCHOR_DIR}/programs/hackathon_greet_anchor/Cargo.toml" \
    "${work}/programs/hackathon_greet_anchor/Cargo.toml"
  cp "${ANCHOR_SRC}" "${work}/programs/hackathon_greet_anchor/src/lib.rs"
}

build_anchor_reference() {
  prepare_anchor_workspace
  local work="${TMP_DIR}/anchor_reference"
  local out_dir="${TMP_DIR}/anchor-deploy"
  mkdir -p "${out_dir}"

  PATH="${HOME}/.cargo/bin:${PATH}" \
    CARGO_TARGET_DIR="${TMP_DIR}/anchor-target" \
    cargo build-sbf \
      --manifest-path "${work}/Cargo.toml" \
      --sbf-out-dir "${out_dir}" >&2

  local so="${out_dir}/hackathon_greet_anchor.so"
  if [[ ! -s "${so}" ]]; then
    printf 'Anchor build completed but artifact is missing: %s\n' "${so}" >&2
    return 1
  fi
  ANCHOR_SO_BYTES="$(byte_count "${so}")"
}

main() {
  parse_args "$@"

  require_file "${ZXCAML_SRC}"
  require_file "${ANCHOR_SRC}"

  local report_doc
  local regenerate_command
  if [[ "${WRITE_MODE}" -eq 1 ]]; then
    report_doc="${GENERATED_DOC}"
    regenerate_command="./scripts/demo/compare.sh --write"
    printf '[compare.sh] writing %s\n' "${GENERATED_DOC#${REPO_ROOT}/}"
  else
    report_doc="${DEFAULT_REPORT}"
    regenerate_command="./scripts/demo/compare.sh"
  fi
  mkdir -p "$(dirname "${report_doc}")" "${REPO_ROOT}/out"

  ZXCAML_LINES="$(line_count "${ZXCAML_SRC}")"
  ANCHOR_LINES="$(line_count "${ANCHOR_SRC}")"

  measure_command ZXCAML_BUILD_SECONDS build_zxcaml
  ZXCAML_SO_BYTES="$(byte_count "${ZXCAML_SO}")"

  ANCHOR_SO_BYTES="${SNAPSHOT_ANCHOR_SO_BYTES}"
  ANCHOR_BUILD_SECONDS="${SNAPSHOT_ANCHOR_BUILD_SECONDS}"
  ANCHOR_STATUS="${SNAPSHOT_ANCHOR_STATUS}"
  if command -v cargo >/dev/null 2>&1 && command -v cargo-build-sbf >/dev/null 2>&1; then
    if measure_command ANCHOR_BUILD_SECONDS build_anchor_reference; then
      ANCHOR_STATUS="built: cargo build-sbf succeeded in an isolated temporary copy"
    else
      printf 'warning: Anchor build failed; using snapshot artifact numbers.\n' >&2
    fi
  else
    printf 'warning: cargo or cargo-build-sbf unavailable; using snapshot artifact numbers.\n' >&2
  fi

  cat > "${report_doc}" <<EOF_DOC
<!-- Generated by scripts/demo/compare.sh; do not edit by hand. -->
# Anchor Comparison Measurements

Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Regenerate from the repository root:

\`\`\`sh
${regenerate_command}
\`\`\`

| Metric | ZxCaml \`examples/hackathon_greet.ml\` | Anchor reference \`lib.rs\` | Notes |
|---|---:|---:|---|
| Source lines (\`wc -l\`) | ${ZXCAML_LINES} | ${ANCHOR_LINES} | Counts include comments and blank lines for both files. |
| BPF artifact size (bytes) | ${ZXCAML_SO_BYTES} | ${ANCHOR_SO_BYTES} | ZxCaml artifact: \`out/hackathon_greet.so\`; Anchor artifact is measured from a temporary \`cargo build-sbf\` output. |
| Build time (seconds) | ${ZXCAML_BUILD_SECONDS} | ${ANCHOR_BUILD_SECONDS} | Wall-clock seconds measured by Bash \`SECONDS\`; use as a local demo snapshot, not a benchmark. |

Anchor measurement status: ${ANCHOR_STATUS}.

## Inputs

- ZxCaml source: \`${ZXCAML_SRC#${REPO_ROOT}/}\`
- Anchor source: \`${ANCHOR_SRC#${REPO_ROOT}/}\`
- ZxCaml build command: \`scripts/demo/01_build.sh\`
- Anchor build command: \`cargo build-sbf --manifest-path <temp-anchor-copy>/Cargo.toml --sbf-out-dir <temp-output>\`

## Fallback Snapshot

If Anchor or \`cargo build-sbf\` is unavailable, this script keeps the ZxCaml
measurement live and uses the stored Anchor snapshot:

- Anchor BPF artifact size: ${SNAPSHOT_ANCHOR_SO_BYTES} bytes
- Anchor build time: ${SNAPSHOT_ANCHOR_BUILD_SECONDS} seconds

To refresh the snapshot, install Anchor 0.32.1 and Solana CLI 3.1.12+, then run
\`${regenerate_command}\` from the repository root.
EOF_DOC

  printf '[compare.sh] wrote %s (ZxCaml: %s lines, %s bytes; Anchor: %s lines, %s bytes)\n' \
    "${report_doc#${REPO_ROOT}/}" \
    "${ZXCAML_LINES}" \
    "${ZXCAML_SO_BYTES}" \
    "${ANCHOR_LINES}" \
    "${ANCHOR_SO_BYTES}"
  if [[ "${WRITE_MODE}" -eq 0 ]]; then
    printf '[compare.sh] use --write to refresh %s\n' "${GENERATED_DOC#${REPO_ROOT}/}"
  fi
}

main "$@"
