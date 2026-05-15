#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if rg -n \
  --hidden \
  --glob '!build/**' \
  --glob '!out/**' \
  --glob '!.git/**' \
  --glob '!.zig-cache/**' \
  --glob '!zig-out/**' \
  --glob '!.pi/**' \
  --glob '!vendor/solana-program-sdk-zig/VENDORED-SOURCE.json' \
  '(/Users/[A-Za-z0-9_-]+(/[A-Za-z0-9._-]+)*/solana-program-sdk-zig)|(/home/[A-Za-z0-9_-]+(/[A-Za-z0-9._-]+)*/solana-program-sdk-zig)' \
  .; then
  echo "Found developer-local solana-program-sdk-zig path reference." >&2
  exit 1
fi

echo "No developer-local solana-program-sdk-zig path references found in committed paths."
