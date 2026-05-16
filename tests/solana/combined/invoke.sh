#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${SOLANA_BPF:-}" != "1" ]]; then
  echo "SKIP: set SOLANA_BPF=1 to run the Solana BPF acceptance harness."
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT/tests/solana/surfpool_harness.sh"

TMPDIR="$(mktemp -d -t zxcaml-combined-flow-XXXXXX)"
PAYER_KEYPAIR="$TMPDIR/payer.json"
OWNER_KEYPAIR="$TMPDIR/owner.json"
RECIPIENT_KEYPAIR="$TMPDIR/recipient.json"
OUTPUT_KEYPAIR="$TMPDIR/output.json"
PROGRAM_SO="$TMPDIR/combined_flow.so"
BUILD_LOG="$TMPDIR/build.log"
DEPLOY_LOG="$TMPDIR/deploy.log"
PROGRAM_ID=""
GREETING_PDA=""

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
    echo "ERROR: combined-flow Surfpool harness failed (exit $status)." >&2
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

invoke_combined_flow() {
  python3 - "$PAYER_KEYPAIR" "$OWNER_KEYPAIR" "$PROGRAM_ID" "$GREETING_PDA" "$OUTPUT_PUBKEY" "$RECIPIENT_PUBKEY" "$RPC_URL" <<'PY'
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

payer_keypair_path, owner_keypair_path, program_id, greeting_pda, output_pubkey, recipient_pubkey, rpc_url = sys.argv[1:8]
SYSTEM_PROGRAM = "11111111111111111111111111111111"
CLOCK_SYSVAR = "SysvarC1ock11111111111111111111111111111111"
RENT_SYSVAR = "SysvarRent111111111111111111111111111111111"
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
INSTRUCTION_DATA = b"\x01"

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
        raise RuntimeError(f"transaction failed with err={final_status.get('err')}")

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

def get_account(pubkey_b58):
    result = rpc("getAccountInfo", [pubkey_b58, {"encoding": "base64", "commitment": "finalized"}])["value"]
    if result is None:
        raise RuntimeError(f"account {pubkey_b58} not found")
    return result

def get_balance(pubkey_b58):
    return rpc("getBalance", [pubkey_b58, {"commitment": "finalized"}])["value"]

def get_transaction(signature):
    return rpc("getTransaction", [
        signature,
        {
            "encoding": "json",
            "commitment": "finalized",
            "maxSupportedTransactionVersion": 0,
        },
    ])

payer_secret = json.load(open(payer_keypair_path, "r", encoding="utf-8"))
owner_secret = json.load(open(owner_keypair_path, "r", encoding="utf-8"))
if len(payer_secret) != 64 or len(owner_secret) != 64:
    raise RuntimeError("expected 64-byte Solana keypairs")
payer_seed = bytes(payer_secret[:32])
owner_seed = bytes(owner_secret[:32])
payer_pubkey = subprocess.check_output(["solana-keygen", "pubkey", payer_keypair_path], text=True).strip()
owner_pubkey = subprocess.check_output(["solana-keygen", "pubkey", owner_keypair_path], text=True).strip()

set_account(greeting_pda, lamports=1_000_000, data_bytes=b"\x00" * 40, owner_b58=program_id)
set_account(output_pubkey, lamports=1, data_bytes=b"\x00" * 32, owner_b58=program_id)
set_account(recipient_pubkey, lamports=5, data_bytes=b"", owner_b58=SYSTEM_PROGRAM)

recipient_before = get_balance(recipient_pubkey)
blockhash_b58 = rpc("getLatestBlockhash", [{"commitment": "finalized"}])["value"]["blockhash"]
blockhash = b58decode(blockhash_b58)
account_keys = [
    b58decode(payer_pubkey),
    b58decode(owner_pubkey),
    b58decode(greeting_pda),
    b58decode(recipient_pubkey),
    b58decode(output_pubkey),
    b58decode(SYSTEM_PROGRAM),
    b58decode(CLOCK_SYSVAR),
    b58decode(RENT_SYSVAR),
    b58decode(program_id),
]
if any(len(key) != 32 for key in account_keys):
    raise RuntimeError("all account keys must decode to 32 bytes")

message = bytearray()
message += bytes([2, 0, 4])
message += compact_len(len(account_keys)) + b"".join(account_keys)
message += blockhash
message += compact_len(1)
ix_accounts = bytes([4, 6, 7, 2, 1, 3, 5])
message += bytes([8]) + compact_len(len(ix_accounts)) + ix_accounts + compact_len(len(INSTRUCTION_DATA)) + INSTRUCTION_DATA
message = bytes(message)

payer_sig = sign_ed25519(payer_seed, message)
owner_sig = sign_ed25519(owner_seed, message)
tx = compact_len(2) + payer_sig + owner_sig + message
signature = rpc("sendTransaction", [
    base64.b64encode(tx).decode(),
    {
        "encoding": "base64",
        "skipPreflight": False,
        "preflightCommitment": "processed",
        "maxRetries": 5,
    },
])
await_signature(signature)
tx_data = get_transaction(signature)
logs = (((tx_data or {}).get("meta") or {}).get("logMessages") or [])
for log in logs:
    print(f"combined log: {log}")

recipient_after = get_balance(recipient_pubkey)
if recipient_after != recipient_before + 1:
    raise RuntimeError(f"expected recipient balance to increase by 1; before={recipient_before} after={recipient_after}")

greeting_info = get_account(greeting_pda)
greeting_data = base64.b64decode(greeting_info["data"][0])
if greeting_data[0:32] != b58decode(owner_pubkey):
    raise RuntimeError("greeting PDA did not record owner pubkey")
if int.from_bytes(greeting_data[32:40], "little") != 1:
    raise RuntimeError("greeting PDA count did not increment to 1")

expected_digest = hashlib.sha256(INSTRUCTION_DATA).digest()
output_info = get_account(output_pubkey)
output_data = base64.b64decode(output_info["data"][0])
if output_data[:32] != expected_digest:
    raise RuntimeError(
        "output account digest mismatch:\n"
        f"expected={expected_digest.hex()}\nactual={output_data[:32].hex()}"
    )

return_data = (((tx_data or {}).get("meta") or {}).get("returnData") or {})
if return_data.get("programId") != program_id:
    raise RuntimeError(
        f"expected returnData programId {program_id}, got {return_data.get('programId')}"
    )
encoded, encoding = return_data.get("data") or ["", ""]
if encoding != "base64":
    raise RuntimeError(f"unexpected returnData encoding {encoding}")
if base64.b64decode(encoded) != INSTRUCTION_DATA:
    raise RuntimeError("returnData payload did not round-trip the instruction data")

log64_line = next((log for log in logs if "0x" in log or re.search(r"\b\d+\b.*\b\d+\b.*\b\d+\b.*\b\d+\b", log)), None)
if log64_line is None:
    raise RuntimeError("could not find the sysvar/log64 line in transaction logs")
numbers = [int(value, 0) for value in re.findall(r"0x[0-9a-fA-F]+|\b\d+\b", log64_line)]
if len(numbers) < 5:
    raise RuntimeError(f"expected at least five numbers in log64 line, got {numbers}")
direct_clock_slot, reader_clock_slot, direct_rent, reader_rent, remaining = numbers[:5]
if direct_clock_slot != reader_clock_slot:
    raise RuntimeError(f"direct clock slot {direct_clock_slot} did not match reader slot {reader_clock_slot}")
if direct_rent != reader_rent:
    raise RuntimeError(f"direct rent {direct_rent} did not match reader rent {reader_rent}")
if remaining <= 0:
    raise RuntimeError(f"remaining compute units must be positive, got {remaining}")

print(f"combined flow signature: {signature}")
print(
    "SUCCESS: combined flow validated CPI, PDA state, return-data, crypto digest, "
    f"and sysvar parity (slot={direct_clock_slot}, rent={direct_rent}, remaining={remaining})"
)
PY
}

cd "$ROOT"

for cmd in zig solana solana-keygen surfpool curl python3 openssl; do
  zxcaml_require_cmd "$cmd"
done

echo "==> building omlz"
zig build

echo "==> generating temporary payer, owner, recipient, and output accounts"
solana-keygen new --no-bip39-passphrase --force --silent -o "$PAYER_KEYPAIR" >/dev/null
solana-keygen new --no-bip39-passphrase --force --silent -o "$OWNER_KEYPAIR" >/dev/null
solana-keygen new --no-bip39-passphrase --force --silent -o "$RECIPIENT_KEYPAIR" >/dev/null
solana-keygen new --no-bip39-passphrase --force --silent -o "$OUTPUT_KEYPAIR" >/dev/null
OWNER_PUBKEY="$(solana-keygen pubkey "$OWNER_KEYPAIR")"
RECIPIENT_PUBKEY="$(solana-keygen pubkey "$RECIPIENT_KEYPAIR")"
OUTPUT_PUBKEY="$(solana-keygen pubkey "$OUTPUT_KEYPAIR")"

zxcaml_start_surfpool

echo "==> funding temporary payer and owner"
solana --url "$RPC_URL" --keypair "$PAYER_KEYPAIR" --commitment finalized airdrop 10 >/dev/null
solana --url "$RPC_URL" --keypair "$OWNER_KEYPAIR" --commitment finalized airdrop 10 >/dev/null

echo "==> building BPF shared object"
"$ROOT/zig-out/bin/omlz" build --target=bpf "$ROOT/examples/combined_flow.ml" -o "$PROGRAM_SO" >"$BUILD_LOG" 2>&1
test -s "$PROGRAM_SO"

echo "==> deploying program"
DEPLOY_OUT="$(solana --url "$RPC_URL" --keypair "$PAYER_KEYPAIR" --commitment finalized program deploy --use-rpc "$PROGRAM_SO" 2>&1 | tee "$DEPLOY_LOG")"
PROGRAM_ID="$(printf '%s\n' "$DEPLOY_OUT" | python3 -c 'import re,sys; m=re.search(r"Program Id: ([1-9A-HJ-NP-Za-km-z]+)", sys.stdin.read()); print(m.group(1) if m else "")')"
if [[ -z "$PROGRAM_ID" ]]; then
  echo "ERROR: could not parse deployed Program Id from solana program deploy output." >&2
  exit 1
fi
printf '%s\n' "$PROGRAM_ID" >"$SURFPOOL_PROGRAM_ID_FILE"
echo "==> deployed program: $PROGRAM_ID"

GREETING_PDA="$(solana find-program-derived-address --output json-compact "$PROGRAM_ID" string:greet pubkey:"$OWNER_PUBKEY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])')"
echo "==> derived greeting PDA: $GREETING_PDA"

invoke_combined_flow
