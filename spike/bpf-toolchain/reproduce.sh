#!/usr/bin/env bash
# Spike β — BPF toolchain reproduction script.
#
# Builds zignocchio's hello example and verifies the resulting .so deploys
# to a local solana-test-validator. Records evidence inline.
#
# Requires (must already be installed):
#   - zig 0.16.x
#   - cargo + rustc (Homebrew Rust on macOS works with the workaround below)
#   - solana-cli (3.x)
#   - sbpf-linker 0.1.8 (cargo install sbpf-linker --version 0.1.8 --locked)
#
# On macOS the LLVM dylib search workaround is applied automatically.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ZIG_DIR="$ROOT/zignocchio"

# 1. Clone zignocchio if missing (source is NOT vendored — see ADR-014).
if [[ ! -d "$ZIG_DIR" ]]; then
  echo "==> cloning zignocchio (ADR-014: not vendored, used for inspiration)"
  git clone https://github.com/DaviRain-Su/zignocchio.git "$ZIG_DIR"
fi

cd "$ZIG_DIR"
ZIGNOCCHIO_COMMIT="$(git rev-parse HEAD)"
echo "==> zignocchio commit: $ZIGNOCCHIO_COMMIT"

# 2. Generate LLVM bitcode for examples/hello/lib.zig.
echo "==> zig build-lib -target bpfel-freestanding -femit-llvm-bc=entrypoint.bc"
zig build-lib \
  -target bpfel-freestanding \
  -O ReleaseSmall \
  -femit-llvm-bc=entrypoint.bc \
  -fno-emit-bin \
  --dep sdk \
  -Mroot=examples/hello/lib.zig \
  -Msdk=sdk/zignocchio.zig

mkdir -p zig-out/lib

# 3. Link with sbpf-linker.
# macOS workaround: aya-rustc-llvm-proxy looks for libLLVM*.dylib in
# DYLD_FALLBACK_LIBRARY_PATH; without this it panics. We point it at
# Homebrew's llvm@20 (which matches sbpf-linker 0.1.8's LLVM ABI).
case "$(uname -s)" in
  Darwin)
    LLVM20_LIB="$(brew --prefix llvm@20 2>/dev/null)/lib"
    if [[ ! -f "$LLVM20_LIB/libLLVM.dylib" ]]; then
      echo "ERROR: $LLVM20_LIB/libLLVM.dylib not found." >&2
      echo "Run: brew install llvm@20" >&2
      exit 1
    fi
    export DYLD_FALLBACK_LIBRARY_PATH="$LLVM20_LIB${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
    # Override zignocchio's Linux-only LD_LIBRARY_PATH so it does not poison aya-rustc-llvm-proxy.
    unset LD_LIBRARY_PATH || true
    ;;
esac

echo "==> sbpf-linker --cpu v2  (note: zignocchio uses v2, not v3)"
sbpf-linker \
  --cpu v2 \
  --llvm-args=-bpf-stack-size=4096 \
  --export entrypoint \
  -o zig-out/lib/hello.so \
  entrypoint.bc

# 4. Inspect the artefact.
echo "==> file zig-out/lib/hello.so"
file zig-out/lib/hello.so

# 5. Boot a local validator and deploy.
TMPVAL="$(mktemp -d -t zxcaml-spike-XXXXXX)"
cleanup() {
  if [[ -n "${VAL_PID:-}" ]] && kill -0 "$VAL_PID" 2>/dev/null; then
    kill "$VAL_PID" 2>/dev/null || true
    sleep 1
  fi
  rm -rf "$TMPVAL"
}
trap cleanup EXIT

echo "==> starting solana-test-validator in $TMPVAL"
(cd "$TMPVAL" && solana-test-validator --reset --quiet >validator.log 2>&1 &)
VAL_PID=$!
sleep 6

# Use a throwaway keypair so we never touch the user's main wallet.
KEYPAIR="$TMPVAL/spike-key.json"
solana-keygen new --no-bip39-passphrase --force --silent -o "$KEYPAIR" >/dev/null

solana --url localhost --keypair "$KEYPAIR" airdrop 10 >/dev/null
echo "==> deploying"
DEPLOY_OUT="$(solana --url localhost --keypair "$KEYPAIR" program deploy zig-out/lib/hello.so)"
echo "$DEPLOY_OUT"
PROGRAM_ID="$(echo "$DEPLOY_OUT" | awk '/Program Id:/ {print $3}')"
echo "==> deployed program: $PROGRAM_ID"

solana --url localhost program show "$PROGRAM_ID"

echo
echo "==> SUCCESS: zignocchio hello built and deployed (commit $ZIGNOCCHIO_COMMIT)"
