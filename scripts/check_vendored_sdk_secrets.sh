#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VENDOR_ROOT="vendor/solana-program-sdk-zig"

if rg -n -i \
  -e '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' \
  -e '(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer|mnemonic|seed phrase)\s*[:=]' \
  -e 'aws_secret_access_key' \
  -e 'gh[pousr]_[A-Za-z0-9]{20,}' \
  -e 'xox[baprs]-[A-Za-z0-9-]+' \
  "$VENDOR_ROOT"; then
  echo "Potential secret material found under $VENDOR_ROOT." >&2
  exit 1
fi

echo "No secret-pattern matches found under $VENDOR_ROOT."
