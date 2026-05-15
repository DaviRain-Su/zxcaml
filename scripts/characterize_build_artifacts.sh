#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OMLZ_BIN="${OMLZ_BIN:-./zig-out/bin/omlz}"
REPORT_DIR="${ZXCAML_BUILD_CHARACTERIZATION_DIR:-build/characterization}"
if [[ "$REPORT_DIR" != /* ]]; then
  REPORT_DIR="$ROOT/$REPORT_DIR"
fi
REPORT_PATH="$REPORT_DIR/build-artifact-report.txt"

mkdir -p "$REPORT_DIR"

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
import sys

path = sys.argv[1]
h = hashlib.sha256()
with open(path, "rb") as fh:
    for chunk in iter(lambda: fh.read(1024 * 1024), b""):
        h.update(chunk)
print(h.hexdigest())
PY
}

file_size() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.getsize(sys.argv[1]))
PY
}

map_first_entry() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

entry = data["entries"][0]
print(f"{entry['pc']}\t{entry['ml_file']}:{entry['ml_line']}:{entry['ml_col']}")
PY
}

has_llvm_objcopy() {
  command -v llvm-objcopy >/dev/null 2>&1 \
    || [[ -x /opt/homebrew/bin/llvm-objcopy ]] \
    || [[ -x /usr/local/bin/llvm-objcopy ]] \
    || [[ -x /usr/bin/llvm-objcopy ]]
}

assert_contains() {
  local needle="$1"
  local path="$2"
  if ! grep -Fq -- "$needle" "$path"; then
    echo "Expected to find '$needle' in $path" >&2
    exit 1
  fi
}

copy_artifact_set() {
  local prefix="$1"
  cp out/program.zig "$REPORT_DIR/${prefix}.program.zig"
  cp out/bpf_entry.zig "$REPORT_DIR/${prefix}.bpf_entry.zig"
}

rm -f \
  "$REPORT_DIR"/solana_hello.default.so \
  "$REPORT_DIR"/solana_hello.default.stdout \
  "$REPORT_DIR"/solana_hello.default.stderr \
  "$REPORT_DIR"/solana_hello.program.zig \
  "$REPORT_DIR"/solana_hello.bpf_entry.zig \
  "$REPORT_DIR"/solana_hello.map \
  "$REPORT_DIR"/hackathon_greet.custom.so \
  "$REPORT_DIR"/hackathon_greet.custom.stdout \
  "$REPORT_DIR"/hackathon_greet.custom.stderr \
  "$REPORT_DIR"/hackathon_greet.program.zig \
  "$REPORT_DIR"/hackathon_greet.bpf_entry.zig \
  "$REPORT_DIR"/hackathon_greet.map \
  "$REPORT_DIR"/solana_zig_wrapper.log \
  "$REPORT_DIR"/solana_zig_wrapper.sh \
  "$REPORT_DIR"/solana_zig_zero.stdout \
  "$REPORT_DIR"/solana_zig_zero.stderr \
  "$REPORT_PATH"

DEFAULT_SO="$REPORT_DIR/solana_hello.default.so"
DEFAULT_STDOUT="$REPORT_DIR/solana_hello.default.stdout"
DEFAULT_STDERR="$REPORT_DIR/solana_hello.default.stderr"
DEFAULT_MAP="out/solana_hello.map"

CUSTOM_SO="$REPORT_DIR/hackathon_greet.custom.so"
CUSTOM_STDOUT="$REPORT_DIR/hackathon_greet.custom.stdout"
CUSTOM_STDERR="$REPORT_DIR/hackathon_greet.custom.stderr"
CUSTOM_MAP="out/hackathon_greet.map"
WRAPPER_PATH="$REPORT_DIR/solana_zig_wrapper.sh"
WRAPPER_LOG="$REPORT_DIR/solana_zig_wrapper.log"

ZERO_STDOUT="$REPORT_DIR/solana_zig_zero.stdout"
ZERO_STDERR="$REPORT_DIR/solana_zig_zero.stderr"

rm -f out/program.zig out/bpf_entry.zig "$DEFAULT_MAP" "$CUSTOM_MAP"

env -u SOLANA_ZIG "$OMLZ_BIN" build --target=bpf --keep-zig examples/solana_hello.ml -o "$DEFAULT_SO" >"$DEFAULT_STDOUT" 2>"$DEFAULT_STDERR"

[[ -f out/program.zig ]]
[[ -f out/bpf_entry.zig ]]
[[ -f "$DEFAULT_SO" ]]
[[ -f "$DEFAULT_MAP" ]]
assert_contains '@import("program.zig")' out/bpf_entry.zig
copy_artifact_set "solana_hello"
cp "$DEFAULT_MAP" "$REPORT_DIR/solana_hello.map"

default_source_sha="$(sha256_file examples/solana_hello.ml)"
default_program_sha="$(sha256_file "$REPORT_DIR/solana_hello.program.zig")"
default_bpf_entry_sha="$(sha256_file "$REPORT_DIR/solana_hello.bpf_entry.zig")"
default_so_sha="$(sha256_file "$DEFAULT_SO")"
default_map_sha="$(sha256_file "$REPORT_DIR/solana_hello.map")"
default_so_size="$(file_size "$DEFAULT_SO")"

IFS=$'\t' read -r default_pc default_loc < <(map_first_entry "$DEFAULT_MAP")
default_unmap_pc="$(printf '0x%x' "$default_pc")"
default_unmap_output="$("$OMLZ_BIN" unmap --map "$DEFAULT_MAP" --pc "$default_unmap_pc")"
if [[ "$default_unmap_output" != *"$default_loc"* ]]; then
  echo "Unexpected unmap output for $default_unmap_pc: $default_unmap_output" >&2
  exit 1
fi

if ! has_llvm_objcopy; then
  assert_contains "warning: llvm-objcopy not found on PATH" "$DEFAULT_STDERR"
  assert_contains ".map sidecar is still written" "$DEFAULT_STDERR"
fi

cat >"$WRAPPER_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_path="__WRAPPER_LOG__"
: > "$log_path"
printf 'cwd=%s\n' "$PWD" >> "$log_path"
i=0
for arg in "$@"; do
  printf 'argv[%s]=%s\n' "$i" "$arg" >> "$log_path"
  i=$((i + 1))
done
exec "./solana-zig/zig" "$@"
EOF
python3 - "$WRAPPER_PATH" "$WRAPPER_LOG" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
log = sys.argv[2]
path.write_text(path.read_text(encoding="utf-8").replace("__WRAPPER_LOG__", log), encoding="utf-8")
PY
chmod +x "$WRAPPER_PATH"

env "SOLANA_ZIG=$WRAPPER_PATH" "$OMLZ_BIN" build --target=bpf --keep-zig examples/hackathon_greet.ml -o "$CUSTOM_SO" >"$CUSTOM_STDOUT" 2>"$CUSTOM_STDERR"

[[ -f out/program.zig ]]
[[ -f out/bpf_entry.zig ]]
[[ -f "$CUSTOM_SO" ]]
[[ -f "$CUSTOM_MAP" ]]
copy_artifact_set "hackathon_greet"
cp "$CUSTOM_MAP" "$REPORT_DIR/hackathon_greet.map"

custom_source_sha="$(sha256_file examples/hackathon_greet.ml)"
custom_program_sha="$(sha256_file "$REPORT_DIR/hackathon_greet.program.zig")"
custom_bpf_entry_sha="$(sha256_file "$REPORT_DIR/hackathon_greet.bpf_entry.zig")"
custom_so_sha="$(sha256_file "$CUSTOM_SO")"
custom_map_sha="$(sha256_file "$REPORT_DIR/hackathon_greet.map")"
custom_so_size="$(file_size "$CUSTOM_SO")"

if [[ "$default_program_sha" == "$custom_program_sha" ]]; then
  echo "Expected generated Zig digest to change between sources" >&2
  exit 1
fi

assert_contains "argv[0]=build-lib" "$WRAPPER_LOG"
assert_contains "-target" "$WRAPPER_LOG"
assert_contains "sbf-solana" "$WRAPPER_LOG"
assert_contains "-fPIC" "$WRAPPER_LOG"
assert_contains "-fstrip" "$WRAPPER_LOG"
assert_contains "-dynamic" "$WRAPPER_LOG"
assert_contains "-fentry=entrypoint" "$WRAPPER_LOG"
assert_contains "-Mroot=out/bpf_entry.zig" "$WRAPPER_LOG"
assert_contains "-Mvendored_sdk=out/runtime/sdk/root.zig" "$WRAPPER_LOG"
assert_contains "-Msolana_program_sdk=vendor/solana-program-sdk-zig/src/root.zig" "$WRAPPER_LOG"
assert_contains "-Msolana_codec=vendor/solana-program-sdk-zig/packages/solana-codec/src/root.zig" "$WRAPPER_LOG"
assert_contains "-Mspl_token=vendor/solana-program-sdk-zig/packages/spl-token/src/root.zig" "$WRAPPER_LOG"
assert_contains "-Mspl_ata=vendor/solana-program-sdk-zig/packages/spl-ata/src/root.zig" "$WRAPPER_LOG"
assert_contains "-femit-bin=$CUSTOM_SO" "$WRAPPER_LOG"

set +e
env "SOLANA_ZIG=0" "$OMLZ_BIN" build --target=bpf examples/solana_hello.ml -o "$REPORT_DIR/solana_zig_zero.so" >"$ZERO_STDOUT" 2>"$ZERO_STDERR"
zero_exit=$?
set -e

if [[ $zero_exit -eq 0 ]]; then
  echo "Expected SOLANA_ZIG=0 build to fail" >&2
  exit 1
fi
assert_contains "error: SOLANA_ZIG=0 is not supported" "$ZERO_STDERR"

{
  echo "# Build and artifact characterization baseline"
  echo
  echo "tool_versions:"
  echo "  zig: $(zig version)"
  echo "  solana-zig: $(solana-zig version)"
  echo "  cargo: $(cargo --version)"
  echo "  rustc: $(rustc --version)"
  echo "  ocamlc: $(opam exec --switch=zxcaml-p1 -- ocamlc -version)"
  echo "  surfpool: $(surfpool --version)"
  echo "  solana: $(solana --version)"
  echo
  echo "default_build:"
  echo "  source: examples/solana_hello.ml"
  echo "  source_sha256: $default_source_sha"
  echo "  generated_zig: $REPORT_DIR/solana_hello.program.zig"
  echo "  generated_zig_sha256: $default_program_sha"
  echo "  bpf_entry: $REPORT_DIR/solana_hello.bpf_entry.zig"
  echo "  bpf_entry_sha256: $default_bpf_entry_sha"
  echo "  sbf_input_path: out/bpf_entry.zig"
  echo "  sbf_output: $DEFAULT_SO"
  echo "  sbf_output_sha256: $default_so_sha"
  echo "  sbf_output_bytes: $default_so_size"
  echo "  source_map: $REPORT_DIR/solana_hello.map"
  echo "  source_map_sha256: $default_map_sha"
  echo "  unmap_pc: $default_unmap_pc"
  echo "  unmap_result: $default_unmap_output"
  echo "  stderr_log: $DEFAULT_STDERR"
  echo
  echo "custom_build:"
  echo "  source: examples/hackathon_greet.ml"
  echo "  source_sha256: $custom_source_sha"
  echo "  generated_zig: $REPORT_DIR/hackathon_greet.program.zig"
  echo "  generated_zig_sha256: $custom_program_sha"
  echo "  bpf_entry: $REPORT_DIR/hackathon_greet.bpf_entry.zig"
  echo "  bpf_entry_sha256: $custom_bpf_entry_sha"
  echo "  sbf_input_path: out/bpf_entry.zig"
  echo "  sbf_output: $CUSTOM_SO"
  echo "  sbf_output_sha256: $custom_so_sha"
  echo "  sbf_output_bytes: $custom_so_size"
  echo "  source_map: $REPORT_DIR/hackathon_greet.map"
  echo "  source_map_sha256: $custom_map_sha"
  echo "  solana_zig_wrapper: $WRAPPER_PATH"
  echo "  solana_zig_wrapper_log: $WRAPPER_LOG"
  echo
  echo "override_semantics:"
  echo "  default_mode: env -u SOLANA_ZIG"
  echo "  custom_mode: SOLANA_ZIG=$WRAPPER_PATH"
  echo "  invalid_mode_exit: $zero_exit"
  echo "  invalid_mode_stderr: $ZERO_STDERR"
  echo
  echo "artifact_identity:"
  echo "  generated_zig_changed_between_sources: yes"
  echo "  program_zig_imported_by_bpf_entry: yes"
  echo "  covered_assertions: VAL-COMPILER-004, VAL-COMPILER-005, VAL-COMPILER-006, VAL-COMPILER-010, VAL-COMPILER-011, VAL-COMPILER-013, VAL-CROSS-002, VAL-CROSS-015"
} >"$REPORT_PATH"

echo "Build artifact characterization report written to $REPORT_PATH"
