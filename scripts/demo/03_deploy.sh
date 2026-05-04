#!/usr/bin/env bash
# Purpose: deploy out/hackathon_greet.so to the running Surfpool localnet with
# a deterministic demo keypair directory.
# Args: optional RPC_URL environment variable; defaults to http://127.0.0.1:8899.
# Expected output: payer/program keypairs exist under scripts/demo/.keypairs,
# the payer is funded, solana program deploy succeeds, and the program id is
# written to scripts/demo/.program_id.
# Exit codes: 0 on successful deploy; non-zero if artifacts, RPC, funding, or
# deployment fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RPC_URL="${RPC_URL:-http://127.0.0.1:8899}"
KEYPAIR_DIR="${SCRIPT_DIR}/.keypairs"
PAYER_KEYPAIR="${KEYPAIR_DIR}/payer.json"
PROGRAM_KEYPAIR="${KEYPAIR_DIR}/program.json"
PROGRAM_SO="${REPO_ROOT}/out/hackathon_greet.so"
PROGRAM_ID_FILE="${SCRIPT_DIR}/.program_id"

cd "${REPO_ROOT}"

if [[ ! -s "${PROGRAM_SO}" ]]; then
  printf 'ERROR: %s not found. Run scripts/demo/01_build.sh first.\n' "${PROGRAM_SO}" >&2
  exit 1
fi

mkdir -p "${KEYPAIR_DIR}"
chmod 700 "${KEYPAIR_DIR}"

if [[ ! -s "${PAYER_KEYPAIR}" ]]; then
  solana-keygen new --no-bip39-passphrase --force --silent -o "${PAYER_KEYPAIR}" >/dev/null
fi
if [[ ! -s "${PROGRAM_KEYPAIR}" ]]; then
  solana-keygen new --no-bip39-passphrase --force --silent -o "${PROGRAM_KEYPAIR}" >/dev/null
fi

payer_pubkey="$(solana-keygen pubkey "${PAYER_KEYPAIR}")"
program_pubkey="$(solana-keygen pubkey "${PROGRAM_KEYPAIR}")"
printf 'Payer: %s\n' "${payer_pubkey}"
printf 'Program keypair: %s\n' "${program_pubkey}"

printf 'Funding payer on %s...\n' "${RPC_URL}"
solana --url "${RPC_URL}" --keypair "${PAYER_KEYPAIR}" --commitment finalized airdrop 10 >/dev/null

printf 'Deploying %s...\n' "${PROGRAM_SO}"
set +e
deploy_out="$(solana --url "${RPC_URL}" --keypair "${PAYER_KEYPAIR}" --commitment finalized program deploy --use-rpc "${PROGRAM_SO}" --program-id "${PROGRAM_KEYPAIR}" 2>&1)"
deploy_status=$?
set -e
printf '%s\n' "${deploy_out}"
if [[ ${deploy_status} -ne 0 ]]; then
  printf 'ERROR: solana program deploy failed with exit %s.\n' "${deploy_status}" >&2
  exit "${deploy_status}"
fi
program_id="$(printf '%s\n' "${deploy_out}" | python3 -c 'import re,sys; m=re.search(r"Program Id: ([1-9A-HJ-NP-Za-km-z]+)", sys.stdin.read()); print(m.group(1) if m else "")')"
if [[ -z "${program_id}" ]]; then
  printf 'ERROR: could not parse Program Id from deploy output.\n' >&2
  exit 1
fi
printf '%s\n' "${program_id}" >"${PROGRAM_ID_FILE}"
printf 'Deployed program id: %s\n' "${program_id}"
