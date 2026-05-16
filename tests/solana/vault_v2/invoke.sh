#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${SOLANA_BPF:-}" != "1" ]]; then
  echo "SKIP: set SOLANA_BPF=1 to run the Solana BPF acceptance harness."
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT/tests/solana/surfpool_harness.sh"

TMPDIR="$(mktemp -d -t zxcaml-vault-v2-XXXXXX)"
PAYER_KEYPAIR="$TMPDIR/payer.json"
OWNER_KEYPAIR="$TMPDIR/owner.json"
PROGRAM_SO="$TMPDIR/vault_v2.so"
BUILD_LOG="$TMPDIR/build.log"
DEPLOY_LOG="$TMPDIR/deploy.log"
PROGRAM_ID=""
VAULT_PDA=""
DEPOSIT_AMOUNT=123456

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
    echo "ERROR: vault_v2 Surfpool harness failed (exit $status)." >&2
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

invoke_vault_flow() {
  python3 - "$PAYER_KEYPAIR" "$OWNER_KEYPAIR" "$PROGRAM_ID" "$VAULT_PDA" "$RPC_URL" "$DEPOSIT_AMOUNT" <<'PY'
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

payer_keypair_path, owner_keypair_path, program_id, vault_pda, rpc_url, deposit_amount = sys.argv[1:7]
deposit_amount = int(deposit_amount)
SYSTEM_PROGRAM = "11111111111111111111111111111111"
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

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

def get_balance(pubkey):
    return rpc("getBalance", [pubkey, {"commitment": "finalized"}])["value"]

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

def get_transaction(signature):
    return rpc("getTransaction", [
        signature,
        {
            "encoding": "json",
            "commitment": "finalized",
            "maxSupportedTransactionVersion": 0,
        },
    ])

def build_message(payer_pubkey, owner_pubkey, vault_pubkey, program_pubkey, data_bytes):
    blockhash_b58 = rpc("getLatestBlockhash", [{"commitment": "finalized"}])["value"]["blockhash"]
    blockhash = b58decode(blockhash_b58)
    if len(blockhash) != 32:
        raise RuntimeError("blockhash must decode to 32 bytes")

    account_keys = [
        b58decode(payer_pubkey),
        b58decode(owner_pubkey),
        b58decode(vault_pubkey),
        b58decode(SYSTEM_PROGRAM),
        b58decode(program_pubkey),
    ]
    if any(len(key) != 32 for key in account_keys):
        raise RuntimeError("all account keys must decode to 32 bytes")

    message = bytearray()
    message += bytes([2, 0, 2])
    message += compact_len(len(account_keys)) + b"".join(account_keys)
    message += blockhash
    message += compact_len(1)
    instruction_accounts = bytes([1, 2, 3])
    message += bytes([4]) + compact_len(len(instruction_accounts)) + instruction_accounts + compact_len(len(data_bytes)) + data_bytes
    return bytes(message)

def send_signed(message, payer_seed, owner_seed):
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
    return signature

payer_secret = json.load(open(payer_keypair_path, "r", encoding="utf-8"))
owner_secret = json.load(open(owner_keypair_path, "r", encoding="utf-8"))
if len(payer_secret) != 64 or len(owner_secret) != 64:
    raise RuntimeError("expected 64-byte Solana keypairs")
payer_seed = bytes(payer_secret[:32])
owner_seed = bytes(owner_secret[:32])
payer_pubkey = subprocess.check_output(["solana-keygen", "pubkey", payer_keypair_path], text=True).strip()
owner_pubkey = subprocess.check_output(["solana-keygen", "pubkey", owner_keypair_path], text=True).strip()

print(f"Preparing vault PDA {vault_pda}")
set_account(vault_pda, lamports=0, data_bytes=b"", owner_b58=SYSTEM_PROGRAM)

owner_before = get_balance(owner_pubkey)
vault_before = get_balance(vault_pda)
print(f"owner before deposit: {owner_before}")
print(f"vault before deposit: {vault_before}")

deposit_data = bytes([0]) + deposit_amount.to_bytes(8, "little")
deposit_message = build_message(payer_pubkey, owner_pubkey, vault_pda, program_id, deposit_data)
deposit_sig = send_signed(deposit_message, payer_seed, owner_seed)
deposit_tx = get_transaction(deposit_sig)
deposit_logs = (((deposit_tx or {}).get("meta") or {}).get("logMessages") or [])
for log in deposit_logs:
    print(f"deposit log: {log}")

owner_after_deposit = get_balance(owner_pubkey)
vault_after_deposit = get_balance(vault_pda)
print(f"owner after deposit: {owner_after_deposit}")
print(f"vault after deposit: {vault_after_deposit}")
if owner_after_deposit != owner_before - deposit_amount:
    raise RuntimeError(f"expected owner balance to decrease by {deposit_amount}, got before={owner_before} after={owner_after_deposit}")
if vault_after_deposit != vault_before + deposit_amount:
    raise RuntimeError(f"expected vault balance to increase by {deposit_amount}, got before={vault_before} after={vault_after_deposit}")

withdraw_data = bytes([1])
withdraw_message = build_message(payer_pubkey, owner_pubkey, vault_pda, program_id, withdraw_data)
withdraw_sig = send_signed(withdraw_message, payer_seed, owner_seed)
withdraw_tx = get_transaction(withdraw_sig)
withdraw_logs = (((withdraw_tx or {}).get("meta") or {}).get("logMessages") or [])
for log in withdraw_logs:
    print(f"withdraw log: {log}")

owner_after_withdraw = get_balance(owner_pubkey)
vault_after_withdraw = get_balance(vault_pda)
print(f"owner after withdraw: {owner_after_withdraw}")
print(f"vault after withdraw: {vault_after_withdraw}")
if owner_after_withdraw != owner_before:
    raise RuntimeError(f"expected owner balance to return to {owner_before}, got {owner_after_withdraw}")
if vault_after_withdraw != vault_before:
    raise RuntimeError(f"expected vault balance to return to {vault_before}, got {vault_after_withdraw}")

print(f"vault_v2 deposit signature: {deposit_sig}")
print(f"vault_v2 withdraw signature: {withdraw_sig}")
print("SUCCESS: vault_v2 deposit/withdraw preserved live Surfpool balances")
PY
}

cd "$ROOT"

for cmd in zig solana solana-keygen surfpool curl python3 openssl; do
  zxcaml_require_cmd "$cmd"
done

echo "==> building omlz"
zig build

echo "==> generating temporary payer and owner"
solana-keygen new --no-bip39-passphrase --force --silent -o "$PAYER_KEYPAIR" >/dev/null
solana-keygen new --no-bip39-passphrase --force --silent -o "$OWNER_KEYPAIR" >/dev/null
OWNER_PUBKEY="$(solana-keygen pubkey "$OWNER_KEYPAIR")"

zxcaml_start_surfpool

echo "==> funding temporary payer and owner"
solana --url "$RPC_URL" --keypair "$PAYER_KEYPAIR" --commitment finalized airdrop 10 >/dev/null
solana --url "$RPC_URL" --keypair "$OWNER_KEYPAIR" --commitment finalized airdrop 10 >/dev/null

echo "==> building BPF shared object"
"$ROOT/zig-out/bin/omlz" build --target=bpf "$ROOT/examples/vault_v2.ml" -o "$PROGRAM_SO" >"$BUILD_LOG" 2>&1
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

VAULT_PDA="$(solana find-program-derived-address --output json-compact "$PROGRAM_ID" string:vault pubkey:"$OWNER_PUBKEY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])')"
echo "==> derived vault PDA: $VAULT_PDA"

invoke_vault_flow
