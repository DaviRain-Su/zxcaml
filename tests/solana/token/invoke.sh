#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

export ZXCAML_SOLANA_SRC="${ZXCAML_SOLANA_SRC:-$ROOT/examples/spl_token_transfer.ml}"
export ZXCAML_SOLANA_SPL_TOKEN=1
export ZXCAML_SOLANA_SPL_ASSOCIATED_ACCOUNTS=1

"$ROOT/tests/solana/hello/invoke.sh"
