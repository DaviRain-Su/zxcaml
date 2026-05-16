#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${SOLANA_BPF:-}" != "1" ]]; then
  echo "SKIP: set SOLANA_BPF=1 to run the Solana BPF acceptance harness."
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT/tests/solana/surfpool_harness.sh"

TMPDIR="$(mktemp -d -t zxcaml-account-parser-view-XXXXXX)"
KEYPAIR="$TMPDIR/payer.json"
SUBJECT_KEYPAIR="$TMPDIR/subject.json"
ALIAS_KEYPAIR="$TMPDIR/alias.json"
OUTPUT_KEYPAIR="$TMPDIR/output.json"
PROGRAM_SO="$TMPDIR/account_parser_view.so"
BUILD_LOG="$TMPDIR/build.log"
DEPLOY_LOG="$TMPDIR/deploy.log"
PROGRAM_ID=""

RPC_PORT="${SOLANA_RPC_PORT:-8899}"
RPC_URL="http://127.0.0.1:$RPC_PORT"
WS_PORT="${SOLANA_WS_PORT:-8900}"

cleanup() {
  local cleanup_status=0
  if ! zxcaml_stop_surfpool; then
    cleanup_status=1
  fi
  rm -rf "$TMPDIR"
  return "$cleanup_status"
}

diagnose() {
  local status=$?
  local cleanup_status=0
  trap - ERR
  if [[ $status -ne 0 ]]; then
    echo
    echo "ERROR: account parser/view Surfpool harness failed (exit $status)." >&2
    echo "ERROR: temporary workdir was $TMPDIR" >&2
    if [[ -f "$SURFPOOL_LOG_FILE" ]]; then
      echo "----- Surfpool diagnostics -----" >&2
      zxcaml_show_file_tail "$SURFPOOL_LOG_FILE" 120 >&2 || true
    fi
    if [[ -f "$BUILD_LOG" ]]; then
      echo "----- omlz BPF build diagnostics -----" >&2
      zxcaml_show_file_tail "$BUILD_LOG" 120 >&2 || true
    fi
    if [[ -f "$DEPLOY_LOG" ]]; then
      echo "----- solana program deploy diagnostics -----" >&2
      zxcaml_show_file_tail "$DEPLOY_LOG" 120 >&2 || true
    fi
  fi
  cleanup || cleanup_status=$?
  if [[ $status -eq 0 && $cleanup_status -ne 0 ]]; then
    status=$cleanup_status
  fi
  exit "$status"
}
trap diagnose EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

invoke_and_compare() {
  python3 - "$KEYPAIR" "$PROGRAM_ID" "$RPC_URL" "$SUBJECT_PUBKEY" "$ALIAS_PUBKEY" "$OUTPUT_PUBKEY" <<'PY'
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

keypair_path, program_id, rpc_url, subject_b58, alias_b58, output_b58 = sys.argv[1:7]
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
SUBJECT_DATA = bytes.fromhex("0102030405060708")
SUBJECT_LAMPORTS = 4242

def b58decode(s):
    n = 0
    for ch in s:
        n *= 58
        n += ALPHABET.index(ch)
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    pad = len(s) - len(s.lstrip("1"))
    return b"\x00" * pad + raw

def compact_len(n):
    out = bytearray()
    while True:
        elem = n & 0x7F
        n >>= 7
        if n:
            out.append(elem | 0x80)
        else:
            out.append(elem)
            return bytes(out)

def rpc(method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
    req = urllib.request.Request(rpc_url, data=body, headers={"Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=10) as response:
        decoded = json.loads(response.read().decode())
    if "error" in decoded:
        raise RuntimeError(f"RPC {method} failed: {decoded['error']}")
    return decoded["result"]

def sign_ed25519(seed, message):
    der = bytes.fromhex("302e020100300506032b657004220420") + seed
    with tempfile.TemporaryDirectory(prefix="zxcaml-sign-") as tmp:
        key_path = os.path.join(tmp, "ed25519.der")
        msg_path = os.path.join(tmp, "message.bin")
        sig_path = os.path.join(tmp, "signature.bin")
        open(key_path, "wb").write(der)
        open(msg_path, "wb").write(message)
        subprocess.run(
            ["openssl", "pkeyutl", "-sign", "-rawin", "-keyform", "DER", "-inkey", key_path, "-in", msg_path, "-out", sig_path],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return open(sig_path, "rb").read()

def await_signature(signature):
    final_status = None
    for _ in range(90):
        statuses = rpc("getSignatureStatuses", [[signature], {"searchTransactionHistory": True}])
        status = statuses["value"][0]
        if status is not None:
            final_status = status
            if status.get("confirmationStatus") == "finalized":
                break
        time.sleep(1)
    else:
        raise RuntimeError(f"transaction did not finalize within 90s; last status={final_status}")
    if final_status.get("err") is not None:
        raise RuntimeError(f"program invocation failed with err={final_status.get('err')}")

def get_account(pubkey_b58):
    result = rpc("getAccountInfo", [pubkey_b58, {"encoding": "base64", "commitment": "finalized"}])["value"]
    if result is None:
        raise RuntimeError(f"account {pubkey_b58} not found")
    return result

def set_account(pubkey_b58, *, lamports, data_bytes, owner_b58, executable=False, rent_epoch=0):
    update = {
        "lamports": lamports,
        "data": data_bytes.hex(),
        "owner": owner_b58,
        "executable": executable,
        "rent_epoch": rent_epoch,
    }
    try:
        rpc("surfnet_setAccount", [pubkey_b58, update])
    except Exception:
        update["data"] = "0x" + data_bytes.hex()
        rpc("surfnet_setAccount", [pubkey_b58, update])

secret = json.load(open(keypair_path, "r", encoding="utf-8"))
if len(secret) != 64:
    raise RuntimeError(f"expected a 64-byte Solana keypair, got {len(secret)} bytes")
seed = bytes(secret[:32])
payer = bytes(secret[32:])
program = b58decode(program_id)
subject = b58decode(subject_b58)
alias_key = b58decode(alias_b58)
output = b58decode(output_b58)
if any(len(value) != 32 for value in (program, subject, alias_key, output)):
    raise RuntimeError("all pubkeys must decode to 32 bytes")

print(f"Preparing Surfpool subject account: {subject_b58}")
set_account(subject_b58, lamports=SUBJECT_LAMPORTS, data_bytes=SUBJECT_DATA, owner_b58=alias_b58)
print(f"Preparing Surfpool alias account: {alias_b58}")
set_account(alias_b58, lamports=7, data_bytes=b"", owner_b58=subject_b58)
print(f"Preparing Surfpool output account: {output_b58}")
set_account(output_b58, lamports=1, data_bytes=b"\x00" * 91, owner_b58=program_id)

blockhash_b58 = rpc("getLatestBlockhash", [{"commitment": "finalized"}])["value"]["blockhash"]
blockhash = b58decode(blockhash_b58)
if len(blockhash) != 32:
    raise RuntimeError("blockhash must decode to 32 bytes")

message = bytearray()
message += bytes([1, 0, 3])
message += compact_len(5) + payer + output + subject + alias_key + program
message += blockhash
message += compact_len(1)
message += bytes([4]) + compact_len(3) + bytes([2, 3, 1]) + compact_len(1) + bytes([0])
message = bytes(message)

signature = sign_ed25519(seed, message)
transaction = compact_len(1) + signature + message
tx_signature = rpc("sendTransaction", [
    base64.b64encode(transaction).decode(),
    {
        "encoding": "base64",
        "skipPreflight": False,
        "preflightCommitment": "processed",
        "maxRetries": 5,
    },
])
print(f"account_parser_view signature: {tx_signature}")
await_signature(tx_signature)

subject_info = get_account(subject_b58)
output_info = get_account(output_b58)
subject_data = base64.b64decode(subject_info["data"][0])
output_data = base64.b64decode(output_info["data"][0])

expected = bytearray()
expected += subject
expected += alias_key
expected += SUBJECT_LAMPORTS.to_bytes(8, "little")
expected += bytes([0, 0, 0])
expected += len(SUBJECT_DATA).to_bytes(8, "little")
expected += SUBJECT_DATA

print(f"subject owner: {subject_info['owner']}")
print(f"subject lamports: {subject_info['lamports']}")
print(f"subject executable: {subject_info['executable']}")
print(f"subject data: {subject_data.hex()}")
print(f"reported data: {output_data.hex()}")

if subject_info["owner"] != alias_b58:
    raise RuntimeError(f"expected subject owner {alias_b58}, got {subject_info['owner']}")
if subject_info["lamports"] != SUBJECT_LAMPORTS:
    raise RuntimeError(f"expected subject lamports {SUBJECT_LAMPORTS}, got {subject_info['lamports']}")
if subject_info["executable"]:
    raise RuntimeError("expected subject executable flag to remain false")
if subject_data != SUBJECT_DATA:
    raise RuntimeError(f"expected subject data {SUBJECT_DATA.hex()}, got {subject_data.hex()}")
if output_data[:91] != expected:
    raise RuntimeError(
        "reported parser/view bytes do not match live Surfpool account state:\n"
        f"expected={expected.hex()}\nactual={output_data[:91].hex()}"
    )

print("SUCCESS: account parser/view report matches live Surfpool account state")
PY
}

cd "$ROOT"

for cmd in zig solana solana-keygen surfpool curl python3 openssl; do
  zxcaml_require_cmd "$cmd"
done

echo "==> building omlz"
zig build

echo "==> generating temporary payer and fixture accounts"
solana-keygen new --no-bip39-passphrase --force --silent -o "$KEYPAIR" >/dev/null
solana-keygen new --no-bip39-passphrase --force --silent -o "$SUBJECT_KEYPAIR" >/dev/null
solana-keygen new --no-bip39-passphrase --force --silent -o "$ALIAS_KEYPAIR" >/dev/null
solana-keygen new --no-bip39-passphrase --force --silent -o "$OUTPUT_KEYPAIR" >/dev/null
SUBJECT_PUBKEY="$(solana-keygen pubkey "$SUBJECT_KEYPAIR")"
ALIAS_PUBKEY="$(solana-keygen pubkey "$ALIAS_KEYPAIR")"
OUTPUT_PUBKEY="$(solana-keygen pubkey "$OUTPUT_KEYPAIR")"

zxcaml_start_surfpool

echo "==> funding temporary payer"
solana --url "$RPC_URL" --keypair "$KEYPAIR" --commitment finalized airdrop 10 >/dev/null

echo "==> building BPF shared object"
"$ROOT/zig-out/bin/omlz" build --target=bpf "$ROOT/examples/account_parser_view.ml" -o "$PROGRAM_SO" >"$BUILD_LOG" 2>&1
test -s "$PROGRAM_SO"

echo "==> deploying program"
DEPLOY_OUT="$(solana --url "$RPC_URL" --keypair "$KEYPAIR" --commitment finalized program deploy --use-rpc "$PROGRAM_SO" 2>&1 | tee "$DEPLOY_LOG")"
PROGRAM_ID="$(printf '%s\n' "$DEPLOY_OUT" | python3 -c 'import re,sys; m=re.search(r"Program Id: ([1-9A-HJ-NP-Za-km-z]+)", sys.stdin.read()); print(m.group(1) if m else "")')"
if [[ -z "$PROGRAM_ID" ]]; then
  echo "ERROR: could not parse deployed Program Id from solana program deploy output." >&2
  exit 1
fi
printf '%s\n' "$PROGRAM_ID" >"$SURFPOOL_PROGRAM_ID_FILE"
echo "==> deployed program: $PROGRAM_ID"

invoke_and_compare
