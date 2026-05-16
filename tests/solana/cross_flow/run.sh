#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

export SOLANA_BPF="${SOLANA_BPF:-1}"
export SOLANA_RPC_PORT="${SOLANA_RPC_PORT:-8899}"
export SOLANA_WS_PORT="${SOLANA_WS_PORT:-8900}"

"$ROOT/tests/solana/vault_v2/invoke.sh"
"$ROOT/tests/solana/order_book/invoke.sh"
"$ROOT/tests/solana/token/invoke.sh"
"$ROOT/tests/solana/combined/invoke.sh"
