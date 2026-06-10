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
SOLANA_CLI_VERSION="${SOLANA_CLI_VERSION:-stable}"

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
      echo "The $OPAM_SWITCH switch has drifted (e.g. via opam upgrade); compiler-libs" >&2
      echo "from other OCaml series break the frontend build. Recreate it with:" >&2
      echo "  opam switch remove $OPAM_SWITCH -y" >&2
      echo "  opam switch create $OPAM_SWITCH ocaml-base-compiler.$OCAML_VERSION -y" >&2
      echo "  opam install -y --switch=$OPAM_SWITCH ocamlfind" >&2
      echo "then re-run ./init.sh." >&2
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

note_optional_llvm_tools() {
  echo "    optional: llvm-objcopy is used only for source-map embedding. It is non-fatal if missing."
}

setup_solana_zig() {
  local solana_zig_version="${SOLANA_ZIG_VERSION:-v1.53.0}"
  local solana_zig_dir="$ROOT/solana-zig"

  if [[ -x "$solana_zig_dir/zig" ]]; then
    echo "    solana-zig $("$solana_zig_dir/zig" version 2>/dev/null) OK ($solana_zig_dir/zig)"
    # Create a 'solana-zig' symlink in the same directory as the system zig,
    # which is already on PATH. Do NOT add solana-zig dir to PATH directly
    # because that would override the system zig used for native builds.
    # Also create in ~/.local/bin as fallback.
    local zig_dir=""
    local zig_home="$HOME/zig"
    for d in "$zig_home"/zig-*; do
      if [[ -x "$d/zig" ]]; then zig_dir="$d"; break; fi
    done
    mkdir -p "$HOME/.local/bin"
    if [[ -n "$zig_dir" ]]; then
      ln -sf "$solana_zig_dir/zig" "$zig_dir/solana-zig" 2>/dev/null || true
    fi
    ln -sf "$solana_zig_dir/zig" "$HOME/.local/bin/solana-zig" 2>/dev/null || true
    append_path "$HOME/.local/bin"
    return
  fi

  echo "    Downloading solana-zig $solana_zig_version..."
  local arch
  arch="$(uname -m)"
  if [[ "$arch" == "arm64" ]]; then
    arch="aarch64"
  fi
  local os
  local abi
  case "$OS" in
    Linux)  os="linux";  abi="musl"  ;;
    Darwin) os="macos"; abi="none"  ;;
    *)      echo "    skipping (unsupported OS: $OS)"; return ;;
  esac

  local tarball="zig-$arch-$os-$abi.tar.bz2"
  local url="https://github.com/joncinque/solana-zig-bootstrap/releases/download/solana-$solana_zig_version/$tarball"

  mkdir -p "$solana_zig_dir"
  (cd "$solana_zig_dir" && \
    curl --proto '=https' --tlsv1.2 -SfOL "$url" && \
    tar -xjf "$tarball" && \
    mv "zig-$arch-$os-$abi-baseline"/* . 2>/dev/null || true && \
    rm -rf "$tarball" "zig-$arch-$os-$abi-baseline" 2>/dev/null)

  if [[ -x "$solana_zig_dir/zig" ]]; then
    echo "    solana-zig $("$solana_zig_dir/zig" version 2>/dev/null) installed"
    local zig_dir=""
    local zig_home="$HOME/zig"
    for d in "$zig_home"/zig-*; do
      if [[ -x "$d/zig" ]]; then zig_dir="$d"; break; fi
    done
    mkdir -p "$HOME/.local/bin"
    if [[ -n "$zig_dir" ]]; then
      ln -sf "$solana_zig_dir/zig" "$zig_dir/solana-zig" 2>/dev/null || true
    fi
    ln -sf "$solana_zig_dir/zig" "$HOME/.local/bin/solana-zig" 2>/dev/null || true
    append_path "$HOME/.local/bin"
  else
    echo "    WARNING: solana-zig download failed; check network or repository availability" >&2
  fi
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
  curl -fsSL "https://release.anza.xyz/${SOLANA_CLI_VERSION}/install" -o "$installer"
  sh "$installer"

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
echo "==> Checking LLVM tooling..."
note_optional_llvm_tools

echo "==> Checking solana-zig..."
setup_solana_zig

echo "==> Checking solana-cli..."
setup_solana_if_requested

echo ""
echo "init.sh: environment ready."
echo "  workdir:        $ROOT"
echo "  zig:            $(zig version)"
echo "  opam switch:    $OPAM_SWITCH ($(ocaml -vnum))"
if command -v solana >/dev/null 2>&1; then
  echo "  solana-cli:     $(solana --version 2>/dev/null | head -1)"
else
  echo "  solana-cli:     not installed (SOLANA_BPF is not enabled)"
fi
