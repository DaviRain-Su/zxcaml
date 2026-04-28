#!/usr/bin/env bash
# init.sh — ZxCaml P1 environment setup.
#
# This script is the single source of truth for local developer setup and CI.
# It is intentionally idempotent: rerunning it should verify or repair the
# toolchain without changing project source files.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
OCAML_VERSION="${OCAML_VERSION:-5.2.1}"
OPAM_SWITCH="${OPAM_SWITCH:-zxcaml-p1}"
SBPF_LINKER_VERSION="${SBPF_LINKER_VERSION:-0.1.8}"

OS="$(uname -s)"
ARCH="$(uname -m)"

append_path() {
  local dir="$1"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) export PATH="$dir:$PATH" ;;
  esac
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$dir" >>"$GITHUB_PATH"
  fi
}

persist_env() {
  local name="$1"
  local value="$2"
  export "$name=$value"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >>"$GITHUB_ENV"
  fi
}

have_versioned_zig() {
  command -v zig >/dev/null 2>&1 && [[ "$(zig version)" == "$ZIG_VERSION" ]]
}

zig_platform() {
  case "$OS:$ARCH" in
    Linux:x86_64) echo "x86_64-linux" ;;
    Linux:aarch64|Linux:arm64) echo "aarch64-linux" ;;
    Darwin:x86_64) echo "x86_64-macos" ;;
    Darwin:arm64|Darwin:aarch64) echo "aarch64-macos" ;;
    *)
      echo "ERROR: unsupported Zig platform $OS/$ARCH" >&2
      exit 1
      ;;
  esac
}

install_zig() {
  if have_versioned_zig; then
    echo "    zig $(zig version) OK"
    return
  fi

  local platform
  platform="$(zig_platform)"
  local zig_home="$HOME/zig"
  local zig_dir="$zig_home/zig-$platform-$ZIG_VERSION"
  append_path "$zig_dir"

  if have_versioned_zig; then
    echo "    zig $(zig version) OK ($zig_dir)"
    return
  fi

  echo "    Installing Zig $ZIG_VERSION for $platform into $zig_home..."
  mkdir -p "$zig_home"
  local archive="$zig_home/zig-$platform-$ZIG_VERSION.tar.xz"
  curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-$platform-$ZIG_VERSION.tar.xz" -o "$archive"
  tar -C "$zig_home" -xf "$archive"
  rm -f "$archive"
  append_path "$zig_dir"

  if ! have_versioned_zig; then
    echo "ERROR: zig $ZIG_VERSION was installed but is not active on PATH" >&2
    exit 1
  fi
  echo "    zig $(zig version) OK"
}

install_opam_if_needed() {
  if command -v opam >/dev/null 2>&1; then
    return
  fi

  case "$OS" in
    Darwin)
      if ! command -v brew >/dev/null 2>&1; then
        echo "ERROR: opam not found and Homebrew is unavailable" >&2
        exit 1
      fi
      echo "    Installing opam via Homebrew..."
      brew install opam
      ;;
    Linux)
      if ! command -v sudo >/dev/null 2>&1; then
        echo "ERROR: opam not found and sudo is unavailable for apt installation" >&2
        exit 1
      fi
      echo "    Installing opam via apt..."
      sudo apt-get update
      sudo apt-get install -y opam m4 pkg-config
      ;;
    *)
      echo "ERROR: opam not found on unsupported platform $OS" >&2
      exit 1
      ;;
  esac
}

setup_opam() {
  install_opam_if_needed

  if [[ ! -d "$HOME/.opam" ]]; then
    echo "    Initialising opam..."
    opam init -y --disable-sandboxing --bare
  fi

  if ! opam switch list --short 2>/dev/null | grep -Fxq "$OPAM_SWITCH"; then
    echo "    Creating opam switch $OPAM_SWITCH with OCaml $OCAML_VERSION..."
    opam switch create "$OPAM_SWITCH" "$OCAML_VERSION" -y
  fi

  eval "$(opam env --switch="$OPAM_SWITCH" --set-switch)"

  local reported
  reported="$(ocaml -vnum)"
  case "$reported" in
    5.2.*) echo "    OCaml $reported OK" ;;
    *)
      echo "ERROR: ocaml $reported active; expected 5.2.x" >&2
      exit 1
      ;;
  esac

  echo "    Installing OCaml frontend prerequisites..."
  opam install -y ocamlfind

  if ! ocamlfind list 2>/dev/null | grep -q '^compiler-libs '; then
    echo "ERROR: ocamlfind cannot see compiler-libs. Reinstall the OCaml switch." >&2
    exit 1
  fi

  persist_env OPAM_SWITCH_PREFIX "$OPAM_SWITCH_PREFIX"
  persist_env OPAMSWITCH "$OPAM_SWITCH"
  persist_env CAML_LD_LIBRARY_PATH "${CAML_LD_LIBRARY_PATH:-}"
  persist_env OCAML_TOPLEVEL_PATH "${OCAML_TOPLEVEL_PATH:-}"
  append_path "$OPAM_SWITCH_PREFIX/bin"
  echo "    compiler-libs visible to ocamlfind OK"
}

setup_sbpf_linker() {
  if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo not found. Install Rust via https://rustup.rs/" >&2
    exit 1
  fi

  append_path "$HOME/.cargo/bin"

  local current=""
  if command -v sbpf-linker >/dev/null 2>&1; then
    current="$(sbpf-linker --version 2>/dev/null | awk '{print $NF}')"
  fi

  if [[ "$current" == "$SBPF_LINKER_VERSION" ]]; then
    echo "    sbpf-linker $current OK"
  else
    echo "    Installing sbpf-linker $SBPF_LINKER_VERSION from crates.io..."
    cargo install sbpf-linker --version "$SBPF_LINKER_VERSION" --locked --force
  fi
}

setup_macos_llvm() {
  if [[ "$OS" != "Darwin" ]]; then
    return
  fi

  if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew is required on macOS for llvm@20" >&2
    exit 1
  fi

  if ! brew list llvm@20 >/dev/null 2>&1; then
    echo "    Installing llvm@20 via Homebrew..."
    brew install llvm@20
  fi

  local llvm_prefix
  llvm_prefix="$(brew --prefix llvm@20)"
  local existing="${DYLD_FALLBACK_LIBRARY_PATH:-}"
  case ":$existing:" in
    *":$llvm_prefix/lib:"*) persist_env DYLD_FALLBACK_LIBRARY_PATH "$existing" ;;
    *) persist_env DYLD_FALLBACK_LIBRARY_PATH "$llvm_prefix/lib${existing:+:$existing}" ;;
  esac
  echo "    DYLD_FALLBACK_LIBRARY_PATH includes $llvm_prefix/lib"
}

setup_solana_if_requested() {
  if [[ "${SOLANA_BPF:-}" != "1" ]]; then
    if ! command -v solana >/dev/null 2>&1; then
      echo "    solana-cli not found (OK: SOLANA_BPF is not enabled)"
    else
      echo "    $(solana --version 2>/dev/null | head -1) OK"
    fi
    return
  fi

  if command -v solana >/dev/null 2>&1 &&
     command -v solana-keygen >/dev/null 2>&1 &&
     command -v solana-test-validator >/dev/null 2>&1; then
    echo "    $(solana --version 2>/dev/null | head -1) OK"
    return
  fi

  echo "    Installing Solana CLI for SOLANA_BPF=1..."
  local installer="/tmp/solana-install-init"
  case "$OS:$ARCH" in
    Linux:x86_64) curl -fsSL "https://release.anza.xyz/stable/solana-install-init-x86_64-unknown-linux-gnu" -o "$installer" ;;
    Linux:aarch64|Linux:arm64) curl -fsSL "https://release.anza.xyz/stable/solana-install-init-aarch64-unknown-linux-gnu" -o "$installer" ;;
    Darwin:x86_64) curl -fsSL "https://release.anza.xyz/stable/solana-install-init-x86_64-apple-darwin" -o "$installer" ;;
    Darwin:arm64|Darwin:aarch64) curl -fsSL "https://release.anza.xyz/stable/solana-install-init-aarch64-apple-darwin" -o "$installer" ;;
    *)
      echo "ERROR: unsupported Solana CLI platform $OS/$ARCH" >&2
      exit 1
      ;;
  esac
  chmod +x "$installer"
  "$installer" stable

  append_path "$HOME/.local/share/solana/install/active_release/bin"
  if ! command -v solana >/dev/null 2>&1; then
    echo "ERROR: solana-cli installation did not put solana on PATH" >&2
    exit 1
  fi
  echo "    $(solana --version 2>/dev/null | head -1) OK"
}

echo "init.sh: $OS $ARCH on $ROOT"
echo "==> Checking Zig..."
install_zig
echo "==> Checking opam + OCaml..."
setup_opam
echo "==> Checking sbpf-linker..."
setup_sbpf_linker
echo "==> Checking macOS LLVM 20..."
setup_macos_llvm
echo "==> Checking solana-cli..."
setup_solana_if_requested

echo ""
echo "init.sh: environment ready."
echo "  workdir:        $ROOT"
echo "  zig:            $(zig version)"
echo "  opam switch:    $OPAM_SWITCH ($(ocaml -vnum))"
echo "  sbpf-linker:    $(sbpf-linker --version 2>/dev/null || echo MISSING)"
if command -v solana >/dev/null 2>&1; then
  echo "  solana-cli:     $(solana --version 2>/dev/null | head -1)"
else
  echo "  solana-cli:     not installed (SOLANA_BPF is not enabled)"
fi
