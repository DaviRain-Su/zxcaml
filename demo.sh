#!/usr/bin/env bash
# ZxCaml Hackathon Demo Script
# Demonstrates: OCaml → Solana BPF compiler pipeline
#
# Usage: ./demo.sh [--skip-spl]

set -Eeuo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Configuration ───────────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_SPL=0

for arg in "$@"; do
  case "$arg" in
    --skip-spl) SKIP_SPL=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# ─── Cleanup ─────────────────────────────────────────────────────────────────
VALIDATOR_PID=""

cleanup() {
  if [[ -n "${VALIDATOR_PID:-}" ]] && kill -0 "$VALIDATOR_PID" 2>/dev/null; then
    kill "$VALIDATOR_PID" 2>/dev/null || true
    wait "$VALIDATOR_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ─── Header ──────────────────────────────────────────────────────────────────
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                                          ║${NC}"
echo -e "${BLUE}║   ${BOLD}ZxCaml Hackathon Demo${NC}${BLUE}                 ║${NC}"
echo -e "${BLUE}║   ${BOLD}OCaml → Solana BPF Compiler${NC}${BLUE}           ║${NC}"
echo -e "${BLUE}║                                          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo

# ─── Step 1: Show the source code ───────────────────────────────────────────
echo -e "${YELLOW}${BOLD}[1/5] Source Code (OCaml)${NC}"
echo -e "${YELLOW}────────────────────────────────────────${NC}"
cat examples/demo.ml
echo -e "${YELLOW}────────────────────────────────────────${NC}"
echo

# ─── Step 2: Type check ─────────────────────────────────────────────────────
echo -e "${YELLOW}${BOLD}[2/5] Type Checking (OCaml frontend)${NC}"
if "$ROOT/zig-out/bin/omlz" check examples/demo.ml; then
  echo -e "${GREEN}✔ Type check passed${NC}"
else
  echo -e "${RED}✘ Type check failed${NC}" >&2
  exit 1
fi
echo

# ─── Step 3: Compile to BPF ─────────────────────────────────────────────────
echo -e "${YELLOW}${BOLD}[3/5] Compiling to Solana BPF${NC}"
"$ROOT/zig-out/bin/omlz" build --target=bpf examples/demo.ml -o /tmp/zxcaml_demo.so
echo -e "${GREEN}✔ Compiled to BPF ELF${NC}"
file /tmp/zxcaml_demo.so
echo

# ─── Step 4: Deploy to test-validator ────────────────────────────────────────
echo -e "${YELLOW}${BOLD}[4/5] Deploying to Solana test-validator${NC}"
if SOLANA_BPF=1 ZXCAML_SOLANA_SRC="$ROOT/examples/demo.ml" ZXCAML_SOLANA_INVOKE_ACCOUNTS=1 "$ROOT/tests/solana/hello/invoke.sh"; then
  echo -e "${GREEN}✔ Deployed and invoked successfully${NC}"
else
  echo -e "${RED}✘ Deploy/invoke failed${NC}" >&2
  exit 1
fi
echo

# ─── Step 5: SPL Token Transfer demo (optional) ─────────────────────────────
echo -e "${YELLOW}${BOLD}[5/5] SPL Token Transfer (CPI)${NC}"
if [[ "$SKIP_SPL" -eq 1 ]]; then
  echo -e "${BLUE}⏭  Skipped (--skip-spl flag)${NC}"
elif command -v spl-token >/dev/null 2>&1; then
  if SOLANA_BPF=1 ZXCAML_SOLANA_SRC="$ROOT/examples/spl_token_transfer.ml" ZXCAML_SOLANA_SPL_TOKEN=1 "$ROOT/tests/solana/hello/invoke.sh"; then
    echo -e "${GREEN}✔ SPL Token transfer completed${NC}"
  else
    echo -e "${RED}✘ SPL Token transfer failed${NC}" >&2
    exit 1
  fi
else
  echo -e "${BLUE}⏭  Skipped (spl-token CLI not installed)${NC}"
fi
echo

# ─── Footer ──────────────────────────────────────────────────────────────────
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                                          ║${NC}"
echo -e "${GREEN}║   ${BOLD}✔ Demo Complete!${NC}${GREEN}                     ║${NC}"
echo -e "${BLUE}║                                          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo
echo -e "${BOLD}ZxCaml${NC} compiles OCaml programs to Solana BPF bytecode."
echo -e "Features: type inference, pattern matching, ADTs, closures,"
echo -e "account parsing, syscalls, CPI, SPL Token, no_alloc analysis, IDL generation."
