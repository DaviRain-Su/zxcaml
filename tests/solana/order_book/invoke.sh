#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${SOLANA_BPF:-}" != "1" ]]; then
  echo "SKIP: set SOLANA_BPF=1 to run the Solana BPF acceptance harness."
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT/tests/solana/surfpool_harness.sh"

TMPDIR="$(mktemp -d -t zxcaml-order-book-XXXXXX)"
PAYER_KEYPAIR="$TMPDIR/payer.json"
MAKER_KEYPAIR="$TMPDIR/maker.json"
TAKER_KEYPAIR="$TMPDIR/taker.json"
BASE_MINT_KEYPAIR="$TMPDIR/base-mint.json"
QUOTE_MINT_KEYPAIR="$TMPDIR/quote-mint.json"
PROGRAM_SO="$TMPDIR/order_book.so"
BUILD_LOG="$TMPDIR/build.log"
DEPLOY_LOG="$TMPDIR/deploy.log"
PROGRAM_ID=""
ORDER_PDA=""
ORDER_ID=42
BASE_AMOUNT=10
FILL_AMOUNT=10
PRICE=4
ORDER_LAMPORTS=1000000
TOKEN_LAMPORTS=2039280

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
    echo "ERROR: order_book Surfpool harness failed (exit $status)." >&2
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

invoke_order_book_flow() {
  python3 - \
    "$MAKER_KEYPAIR" "$TAKER_KEYPAIR" "$PROGRAM_ID" "$ORDER_PDA" "$RPC_URL" \
    "$BASE_MINT_PUBKEY" "$QUOTE_MINT_PUBKEY" "$ORDER_ID" "$BASE_AMOUNT" "$FILL_AMOUNT" "$PRICE" "$ORDER_LAMPORTS" "$TOKEN_LAMPORTS" <<'PY'
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

(
    maker_keypair_path,
    taker_keypair_path,
    program_id,
    order_pda,
    rpc_url,
    base_mint_pubkey,
    quote_mint_pubkey,
    order_id,
    base_amount,
    fill_amount,
    price,
    order_lamports,
    token_lamports,
) = sys.argv[1:14]
order_id = int(order_id)
base_amount = int(base_amount)
fill_amount = int(fill_amount)
price = int(price)
order_lamports = int(order_lamports)
token_lamports = int(token_lamports)
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
ORDER_SPACE = 49
TOKEN_ACCOUNT_LEN = 165

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

def get_account(pubkey_b58, *, allow_missing=False):
    result = rpc("getAccountInfo", [pubkey_b58, {"encoding": "base64", "commitment": "finalized"}])["value"]
    if result is None:
        if allow_missing:
            return None
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

def token_account_data(mint_b58, owner_b58, amount):
    mint = b58decode(mint_b58)
    owner = b58decode(owner_b58)
    data = bytearray(TOKEN_ACCOUNT_LEN)
    data[0:32] = mint
    data[32:64] = owner
    data[64:72] = amount.to_bytes(8, "little")
    data[108] = 1
    return bytes(data)

def token_amount(account_info):
    return int.from_bytes(base64.b64decode(account_info["data"][0])[64:72], "little")

def build_post_message(maker_pubkey):
    blockhash_b58 = rpc("getLatestBlockhash", [{"commitment": "finalized"}])["value"]["blockhash"]
    blockhash = b58decode(blockhash_b58)
    account_keys = [b58decode(maker_pubkey), b58decode(order_pda), b58decode(program_id)]
    message = bytearray()
    message += bytes([1, 0, 1])
    message += compact_len(len(account_keys)) + b"".join(account_keys)
    message += blockhash
    message += compact_len(1)
    ix_accounts = bytes([1, 0])
    data = bytes([0x01]) + order_id.to_bytes(8, "little") + bytes([0]) + base_amount.to_bytes(8, "little") + price.to_bytes(8, "little")
    message += bytes([2]) + compact_len(len(ix_accounts)) + ix_accounts + compact_len(len(data)) + data
    return bytes(message)

def build_fill_message(taker_pubkey, maker_pubkey, maker_base, taker_base, taker_quote, maker_quote):
    blockhash_b58 = rpc("getLatestBlockhash", [{"commitment": "finalized"}])["value"]["blockhash"]
    blockhash = b58decode(blockhash_b58)
    account_keys = [
        b58decode(taker_pubkey),
        b58decode(order_pda),
        b58decode(maker_base),
        b58decode(taker_base),
        b58decode(taker_quote),
        b58decode(maker_quote),
        b58decode(maker_pubkey),
        b58decode(program_id),
    ]
    message = bytearray()
    message += bytes([1, 0, 1])
    message += compact_len(len(account_keys)) + b"".join(account_keys)
    message += blockhash
    message += compact_len(1)
    ix_accounts = bytes([1, 2, 3, 4, 5, 6, 0])
    data = bytes([0x02]) + fill_amount.to_bytes(8, "little")
    message += bytes([7]) + compact_len(len(ix_accounts)) + ix_accounts + compact_len(len(data)) + data
    return bytes(message)

def send_signed(message, signer_seed):
    sig = sign_ed25519(signer_seed, message)
    tx = compact_len(1) + sig + message
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

maker_secret = json.load(open(maker_keypair_path, "r", encoding="utf-8"))
taker_secret = json.load(open(taker_keypair_path, "r", encoding="utf-8"))
if len(maker_secret) != 64 or len(taker_secret) != 64:
    raise RuntimeError("expected 64-byte Solana keypairs")
maker_seed = bytes(maker_secret[:32])
taker_seed = bytes(taker_secret[:32])
maker_pubkey = subprocess.check_output(["solana-keygen", "pubkey", maker_keypair_path], text=True).strip()
taker_pubkey = subprocess.check_output(["solana-keygen", "pubkey", taker_keypair_path], text=True).strip()

maker_base = subprocess.check_output(["solana-keygen", "new", "--no-bip39-passphrase", "--force", "--silent", "-o", os.path.join(os.path.dirname(maker_keypair_path), "maker-base.json")], stderr=subprocess.DEVNULL)  # nosec B603
maker_base_pubkey = subprocess.check_output(["solana-keygen", "pubkey", os.path.join(os.path.dirname(maker_keypair_path), "maker-base.json")], text=True).strip()
taker_base_pubkey = subprocess.check_output(["solana-keygen", "new", "--no-bip39-passphrase", "--force", "--silent", "-o", os.path.join(os.path.dirname(maker_keypair_path), "taker-base.json")], stderr=subprocess.DEVNULL)
taker_base_pubkey = subprocess.check_output(["solana-keygen", "pubkey", os.path.join(os.path.dirname(maker_keypair_path), "taker-base.json")], text=True).strip()
taker_quote_pubkey = subprocess.check_output(["solana-keygen", "new", "--no-bip39-passphrase", "--force", "--silent", "-o", os.path.join(os.path.dirname(maker_keypair_path), "taker-quote.json")], stderr=subprocess.DEVNULL)
taker_quote_pubkey = subprocess.check_output(["solana-keygen", "pubkey", os.path.join(os.path.dirname(maker_keypair_path), "taker-quote.json")], text=True).strip()
maker_quote_pubkey = subprocess.check_output(["solana-keygen", "new", "--no-bip39-passphrase", "--force", "--silent", "-o", os.path.join(os.path.dirname(maker_keypair_path), "maker-quote.json")], stderr=subprocess.DEVNULL)
maker_quote_pubkey = subprocess.check_output(["solana-keygen", "pubkey", os.path.join(os.path.dirname(maker_keypair_path), "maker-quote.json")], text=True).strip()

set_account(order_pda, lamports=order_lamports, data_bytes=b"\x00" * ORDER_SPACE, owner_b58=program_id)
set_account(maker_base_pubkey, lamports=token_lamports, data_bytes=token_account_data(base_mint_pubkey, maker_pubkey, base_amount), owner_b58=program_id)
set_account(taker_base_pubkey, lamports=token_lamports, data_bytes=token_account_data(base_mint_pubkey, taker_pubkey, 0), owner_b58=program_id)
set_account(taker_quote_pubkey, lamports=token_lamports, data_bytes=token_account_data(quote_mint_pubkey, taker_pubkey, price * base_amount), owner_b58=program_id)
set_account(maker_quote_pubkey, lamports=token_lamports, data_bytes=token_account_data(quote_mint_pubkey, maker_pubkey, 0), owner_b58=program_id)

post_sig = send_signed(build_post_message(maker_pubkey), maker_seed)
post_tx = get_transaction(post_sig)
for log in (((post_tx or {}).get("meta") or {}).get("logMessages") or []):
    print(f"post log: {log}")

order_after_post = get_account(order_pda)
order_data = base64.b64decode(order_after_post["data"][0])
if order_data[0:32] != b58decode(maker_pubkey):
    raise RuntimeError("order account did not record maker pubkey after post")
if order_data[32] != 0:
    raise RuntimeError(f"expected order side 0, got {order_data[32]}")
if int.from_bytes(order_data[33:41], "little") != base_amount:
    raise RuntimeError("order base amount mismatch after post")
if int.from_bytes(order_data[41:49], "little") != price:
    raise RuntimeError("order price mismatch after post")

maker_before_fill = get_balance(maker_pubkey)
fill_sig = send_signed(build_fill_message(taker_pubkey, maker_pubkey, maker_base_pubkey, taker_base_pubkey, taker_quote_pubkey, maker_quote_pubkey), taker_seed)
fill_tx = get_transaction(fill_sig)
for log in (((fill_tx or {}).get("meta") or {}).get("logMessages") or []):
    print(f"fill log: {log}")

order_after_fill = get_account(order_pda, allow_missing=True)
maker_base_after = token_amount(get_account(maker_base_pubkey))
taker_base_after = token_amount(get_account(taker_base_pubkey))
taker_quote_after = token_amount(get_account(taker_quote_pubkey))
maker_quote_after = token_amount(get_account(maker_quote_pubkey))
maker_after_fill = get_balance(maker_pubkey)

if order_after_fill is not None:
    order_fill_data = base64.b64decode(order_after_fill["data"][0])
    if order_after_fill["lamports"] != 0:
        raise RuntimeError(f"expected closed order lamports 0, got {order_after_fill['lamports']}")
    if any(order_fill_data[:ORDER_SPACE]):
        raise RuntimeError("expected closed order data to be zeroed")
if maker_base_after != 0:
    raise RuntimeError(f"expected maker base balance 0, got {maker_base_after}")
if taker_base_after != fill_amount:
    raise RuntimeError(f"expected taker base balance {fill_amount}, got {taker_base_after}")
if taker_quote_after != 0:
    raise RuntimeError(f"expected taker quote balance 0, got {taker_quote_after}")
if maker_quote_after != price * fill_amount:
    raise RuntimeError(f"expected maker quote balance {price * fill_amount}, got {maker_quote_after}")
if maker_after_fill != maker_before_fill + order_lamports:
    raise RuntimeError(
        f"expected maker lamports to increase by {order_lamports}; before={maker_before_fill} after={maker_after_fill}"
    )

print(f"order_book post signature: {post_sig}")
print(f"order_book fill signature: {fill_sig}")
print(
    "SUCCESS: order_book live flow preserved order state and multi-account balances "
    f"(maker_base={maker_base_after}, taker_base={taker_base_after}, maker_quote={maker_quote_after})"
)
PY
}

cd "$ROOT"

for cmd in zig solana solana-keygen surfpool curl python3 openssl; do
  zxcaml_require_cmd "$cmd"
done

echo "==> building omlz"
zig build

echo "==> generating temporary payer, taker, and mint keys"
solana-keygen new --no-bip39-passphrase --force --silent -o "$PAYER_KEYPAIR" >/dev/null
solana-keygen new --no-bip39-passphrase --force --silent -o "$TAKER_KEYPAIR" >/dev/null
solana-keygen new --no-bip39-passphrase --force --silent -o "$BASE_MINT_KEYPAIR" >/dev/null
solana-keygen new --no-bip39-passphrase --force --silent -o "$QUOTE_MINT_KEYPAIR" >/dev/null
BASE_MINT_PUBKEY="$(solana-keygen pubkey "$BASE_MINT_KEYPAIR")"
QUOTE_MINT_PUBKEY="$(solana-keygen pubkey "$QUOTE_MINT_KEYPAIR")"

zxcaml_start_surfpool

echo "==> funding deployer and taker"
solana --url "$RPC_URL" --keypair "$PAYER_KEYPAIR" --commitment finalized airdrop 10 >/dev/null
solana --url "$RPC_URL" --keypair "$TAKER_KEYPAIR" --commitment finalized airdrop 10 >/dev/null

echo "==> building BPF shared object"
"$ROOT/zig-out/bin/omlz" build --target=bpf "$ROOT/examples/order_book.ml" -o "$PROGRAM_SO" >"$BUILD_LOG" 2>&1
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

echo "==> searching for maker keypair with canonical bump 255"
FOUND_MAKER=0
for attempt in $(seq 1 1024); do
  CANDIDATE_KEYPAIR="$TMPDIR/maker-candidate-$attempt.json"
  solana-keygen new --no-bip39-passphrase --force --silent -o "$CANDIDATE_KEYPAIR" >/dev/null
  CANDIDATE_PUBKEY="$(solana-keygen pubkey "$CANDIDATE_KEYPAIR")"
  PDA_JSON="$(solana find-program-derived-address --output json-compact "$PROGRAM_ID" string:order pubkey:"$CANDIDATE_PUBKEY" u64le:"$ORDER_ID")"
  BUMP_SEED="$(printf '%s\n' "$PDA_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bumpSeed"])')"
  if [[ "$BUMP_SEED" == "255" ]]; then
    mv "$CANDIDATE_KEYPAIR" "$MAKER_KEYPAIR"
    ORDER_PDA="$(printf '%s\n' "$PDA_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])')"
    FOUND_MAKER=1
    break
  fi
  rm -f "$CANDIDATE_KEYPAIR"
done
if [[ "$FOUND_MAKER" != "1" ]]; then
  echo "ERROR: unable to find a maker keypair with canonical bump 255 for order id $ORDER_ID." >&2
  exit 1
fi
echo "==> maker pubkey: $(solana-keygen pubkey "$MAKER_KEYPAIR")"
echo "==> derived order PDA: $ORDER_PDA"

echo "==> funding maker"
solana --url "$RPC_URL" --keypair "$MAKER_KEYPAIR" --commitment finalized airdrop 10 >/dev/null

invoke_order_book_flow
