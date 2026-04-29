#!/usr/bin/env bash
#
# Opt-in Solana BPF acceptance harness for ZxCaml's minimal hello program.
# The script owns one temporary validator process and one temporary keypair,
# then builds, deploys, and invokes tests/solana/hello/solana_hello.ml
# (or $ZXCAML_SOLANA_SRC when a feature-specific harness overrides it).

set -Eeuo pipefail

if [[ "${SOLANA_BPF:-}" != "1" ]]; then
  echo "SKIP: set SOLANA_BPF=1 to run the Solana BPF acceptance harness."
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="${ZXCAML_SOLANA_SRC:-$ROOT/tests/solana/hello/solana_hello.ml}"
PROGRAM_STEM="$(basename "$SRC" .ml)"
TMPDIR="$(mktemp -d -t zxcaml-solana-hello-XXXXXX)"
LEDGER="$TMPDIR/ledger"
KEYPAIR="$TMPDIR/payer.json"
RECIPIENT_KEYPAIR="$TMPDIR/recipient.json"
MINT_KEYPAIR="$TMPDIR/mint.json"
SOURCE_TOKEN_KEYPAIR="$TMPDIR/source-token.json"
DEST_TOKEN_KEYPAIR="$TMPDIR/destination-token.json"
PROGRAM_SO="$TMPDIR/$PROGRAM_STEM.so"
VALIDATOR_LOG="$TMPDIR/validator.log"
BUILD_LOG="$TMPDIR/build.log"
DEPLOY_LOG="$TMPDIR/deploy.log"
VAL_PID=""

RPC_PORT="${SOLANA_RPC_PORT:-8899}"
RPC_URL="http://127.0.0.1:$RPC_PORT"

cleanup() {
  if [[ -n "${VAL_PID:-}" ]] && kill -0 "$VAL_PID" 2>/dev/null; then
    kill "$VAL_PID" 2>/dev/null || true
    wait "$VAL_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
}

diagnose() {
  local status=$?
  trap - ERR
  if [[ $status -ne 0 ]]; then
    echo
    echo "ERROR: Solana BPF acceptance harness failed (exit $status)." >&2
    echo "ERROR: temporary workdir was $TMPDIR" >&2
    if [[ -f "$VALIDATOR_LOG" ]]; then
      echo "----- solana-test-validator diagnostics -----" >&2
      tail -n 120 "$VALIDATOR_LOG" >&2 || true
    fi
    if [[ -f "$BUILD_LOG" ]]; then
      echo "----- omlz BPF build diagnostics -----" >&2
      tail -n 120 "$BUILD_LOG" >&2 || true
    fi
    if [[ -f "$DEPLOY_LOG" ]]; then
      echo "----- solana program deploy diagnostics -----" >&2
      tail -n 120 "$DEPLOY_LOG" >&2 || true
    fi
  fi
  cleanup
  exit "$status"
}
trap diagnose EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command '$1' not found. Run ./init.sh first." >&2
    exit 1
  fi
}

rpc_json() {
  local method="$1"
  local params="${2:-[]}"
  curl -sf \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
    "$RPC_URL"
}

wait_for_validator() {
  echo "==> waiting for solana-test-validator RPC at $RPC_URL"
  local slot=""
  for _ in $(seq 1 90); do
    if [[ -n "${VAL_PID:-}" ]] && ! kill -0 "$VAL_PID" 2>/dev/null; then
      echo "ERROR: solana-test-validator exited before RPC became ready." >&2
      return 1
    fi

    slot="$(rpc_json getSlot 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result", 0))' 2>/dev/null || true)"
    if [[ "$slot" =~ ^[0-9]+$ ]] && (( slot > 0 )); then
      echo "==> validator ready at slot $slot"
      return 0
    fi
    sleep 1
  done

  echo "ERROR: solana-test-validator did not report slot > 0 within 90s." >&2
  return 1
}

invoke_noop() {
  python3 - "$KEYPAIR" "$PROGRAM_ID" "$RPC_URL" <<'PY'
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

keypair_path, program_id, rpc_url = sys.argv[1:4]
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

def b58decode(s):
    n = 0
    for ch in s:
        n *= 58
        n += ALPHABET.index(ch)
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    pad = len(s) - len(s.lstrip("1"))
    return b"\x00" * pad + raw

def b58encode(data):
    n = int.from_bytes(data, "big")
    out = ""
    while n:
        n, rem = divmod(n, 58)
        out = ALPHABET[rem] + out
    pad = len(data) - len(data.lstrip(b"\x00"))
    return "1" * pad + (out or "")

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
    # PKCS#8 DER for an Ed25519 private key containing a 32-byte seed:
    #   SEQUENCE { version=0, alg=1.3.101.112, OCTET STRING(seed) }
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

try:
    secret = json.load(open(keypair_path, "r", encoding="utf-8"))
    if len(secret) != 64:
        raise RuntimeError(f"expected a 64-byte Solana keypair, got {len(secret)} bytes")
    seed = bytes(secret[:32])
    payer = bytes(secret[32:])
    program = b58decode(program_id)
    if len(program) != 32:
        raise RuntimeError(f"program id decoded to {len(program)} bytes, expected 32")

    blockhash_b58 = rpc("getLatestBlockhash", [{"commitment": "finalized"}])["value"]["blockhash"]
    blockhash = b58decode(blockhash_b58)
    if len(blockhash) != 32:
        raise RuntimeError(f"blockhash decoded to {len(blockhash)} bytes, expected 32")

    simple_cpi = os.environ.get("ZXCAML_SOLANA_SIMPLE_CPI") == "1"
    spl_token = os.environ.get("ZXCAML_SOLANA_SPL_TOKEN") == "1"
    include_accounts = os.environ.get("ZXCAML_SOLANA_INVOKE_ACCOUNTS") == "1" or simple_cpi or spl_token
    system_program = b"\x00" * 32
    token_program_b58 = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    token_program = b58decode(token_program_b58)
    if len(token_program) != 32:
        raise RuntimeError(f"SPL Token program decoded to {len(token_program)} bytes, expected 32")

    def token_balance(account_b58):
        balance = rpc("getTokenAccountBalance", [account_b58, {"commitment": "finalized"}])
        return int(balance["value"]["amount"])

    if simple_cpi:
        recipient_b58 = os.environ.get("ZXCAML_SIMPLE_CPI_RECIPIENT")
        if not recipient_b58:
            raise RuntimeError("ZXCAML_SOLANA_SIMPLE_CPI requires ZXCAML_SIMPLE_CPI_RECIPIENT")
        recipient = b58decode(recipient_b58)
        if len(recipient) != 32:
            raise RuntimeError(f"recipient decoded to {len(recipient)} bytes, expected 32")
        account_keys = [payer, recipient, program, system_program]
        instruction_accounts = bytes([0, 1, 3])
        program_index = 2
        readonly_unsigned = 2
        recipient_before = rpc("getBalance", [recipient_b58, {"commitment": "finalized"}])["value"]
        source_token_before = None
        destination_token_before = None
    elif spl_token:
        source_token_b58 = os.environ.get("ZXCAML_SPL_SOURCE_TOKEN_ACCOUNT")
        destination_token_b58 = os.environ.get("ZXCAML_SPL_DEST_TOKEN_ACCOUNT")
        if not source_token_b58 or not destination_token_b58:
            raise RuntimeError("ZXCAML_SOLANA_SPL_TOKEN requires source and destination token account env vars")
        source_token = b58decode(source_token_b58)
        destination_token = b58decode(destination_token_b58)
        if len(source_token) != 32 or len(destination_token) != 32:
            raise RuntimeError("SPL token account pubkeys must decode to 32 bytes")
        account_keys = [payer, source_token, destination_token, program, token_program]
        instruction_accounts = bytes([1, 2, 0, 4])
        program_index = 3
        readonly_unsigned = 2
        recipient_before = None
        source_token_before = token_balance(source_token_b58)
        destination_token_before = token_balance(destination_token_b58)
    else:
        account_keys = [payer, program] + ([system_program] if include_accounts else [])
        instruction_accounts = bytes([0, 2]) if include_accounts else b""
        program_index = 1
        readonly_unsigned = 2 if include_accounts else 1
        recipient_before = None
        source_token_before = None
        destination_token_before = None

    # Legacy message:
    # - payer signs and pays fees
    # - deployed program is a readonly unsigned executable account
    # - optional feature harness mode passes payer + system program accounts
    # - single instruction: call program_id with no instruction data
    message = bytearray()
    message += bytes([1, 0, readonly_unsigned])
    message += compact_len(len(account_keys)) + b"".join(account_keys)
    message += blockhash
    message += compact_len(1)
    message += bytes([program_index]) + compact_len(len(instruction_accounts)) + instruction_accounts + compact_len(0)

    signature = sign_ed25519(seed, bytes(message))
    if len(signature) != 64:
        raise RuntimeError(f"openssl produced {len(signature)} signature bytes, expected 64")

    transaction = compact_len(1) + signature + bytes(message)
    encoded_tx = base64.b64encode(transaction).decode()
    expected_signature = b58encode(signature)

    actual_signature = rpc("sendTransaction", [
        encoded_tx,
        {
            "encoding": "base64",
            "skipPreflight": False,
            "preflightCommitment": "processed",
            "maxRetries": 5,
        },
    ])
    if actual_signature != expected_signature:
        raise RuntimeError(f"RPC returned signature {actual_signature}, expected {expected_signature}")

    print(f"==> no-op signature: {actual_signature}")

    final_status = None
    for _ in range(90):
        statuses = rpc("getSignatureStatuses", [[actual_signature], {"searchTransactionHistory": True}])
        status = statuses["value"][0]
        if status is not None:
            final_status = status
            if status.get("confirmationStatus") == "finalized":
                break
        time.sleep(1)
    else:
        raise RuntimeError(f"transaction did not finalize within 90s; last status={final_status}")

    err = final_status.get("err")
    print(f"==> no-op confirmationStatus: {final_status.get('confirmationStatus')}")
    print(f"==> transaction err: {json.dumps(err)}")
    if err is not None:
        raise RuntimeError(f"program invocation failed with err={err}")

    if simple_cpi:
        recipient_after = rpc("getBalance", [recipient_b58, {"commitment": "finalized"}])["value"]
        print(f"==> simple CPI recipient balance: before={recipient_before} after={recipient_after}")
        if recipient_after != recipient_before + 1:
            raise RuntimeError(
                f"expected simple CPI transfer to add 1 lamport to recipient; before={recipient_before} after={recipient_after}"
            )
    if spl_token:
        source_token_after = token_balance(source_token_b58)
        destination_token_after = token_balance(destination_token_b58)
        print(
            "==> SPL Token balances: "
            f"source_before={source_token_before} source_after={source_token_after} "
            f"destination_before={destination_token_before} destination_after={destination_token_after}"
        )
        if source_token_after != source_token_before - 1:
            raise RuntimeError(
                f"expected source token balance to decrease by 1; before={source_token_before} after={source_token_after}"
            )
        if destination_token_after != destination_token_before + 1:
            raise RuntimeError(
                "expected destination token balance to increase by 1; "
                f"before={destination_token_before} after={destination_token_after}"
            )

    tx = rpc("getTransaction", [
        actual_signature,
        {
            "encoding": "json",
            "commitment": "finalized",
            "maxSupportedTransactionVersion": 0,
        },
    ])
    logs = (((tx or {}).get("meta") or {}).get("logMessages") or [])
    for log in logs:
        print(f"==> log: {log}")
    if os.environ.get("ZXCAML_EXPECT_ACCOUNT_LOGS") == "1":
        zero_pubkey_hex = "0" * 64
        if not any(zero_pubkey_hex in log for log in logs):
            raise RuntimeError("expected transaction logs to include the system-program account key")
except Exception as exc:
    print(f"ERROR: no-op invocation failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

cd "$ROOT"

for cmd in zig solana solana-keygen solana-test-validator curl python3 openssl sbpf-linker; do
  require_cmd "$cmd"
done
if [[ "${ZXCAML_SOLANA_SPL_TOKEN:-}" == "1" ]]; then
  require_cmd spl-token
fi

echo "==> building omlz"
zig build

echo "==> generating temporary payer"
solana-keygen new --no-bip39-passphrase --force --silent -o "$KEYPAIR" >/dev/null

echo "==> starting solana-test-validator in $LEDGER"
solana-test-validator --reset --quiet --ledger "$LEDGER" --rpc-port "$RPC_PORT" >"$VALIDATOR_LOG" 2>&1 &
VAL_PID=$!
wait_for_validator

echo "==> funding temporary payer"
solana --url "$RPC_URL" --keypair "$KEYPAIR" --commitment finalized airdrop 10 >/dev/null
if [[ "${ZXCAML_SOLANA_SIMPLE_CPI:-}" == "1" ]]; then
  echo "==> creating temporary CPI recipient"
  solana-keygen new --no-bip39-passphrase --force --silent -o "$RECIPIENT_KEYPAIR" >/dev/null
  export ZXCAML_SIMPLE_CPI_RECIPIENT
  ZXCAML_SIMPLE_CPI_RECIPIENT="$(solana-keygen pubkey "$RECIPIENT_KEYPAIR")"
  solana --url "$RPC_URL" --keypair "$KEYPAIR" --commitment finalized transfer --allow-unfunded-recipient "$ZXCAML_SIMPLE_CPI_RECIPIENT" 1 >/dev/null
fi
if [[ "${ZXCAML_SOLANA_SPL_TOKEN:-}" == "1" ]]; then
  echo "==> creating temporary SPL Token mint and accounts"
  PAYER_PUBKEY="$(solana-keygen pubkey "$KEYPAIR")"
  solana-keygen new --no-bip39-passphrase --force --silent -o "$MINT_KEYPAIR" >/dev/null
  solana-keygen new --no-bip39-passphrase --force --silent -o "$SOURCE_TOKEN_KEYPAIR" >/dev/null
  solana-keygen new --no-bip39-passphrase --force --silent -o "$DEST_TOKEN_KEYPAIR" >/dev/null
  MINT_PUBKEY="$(solana-keygen pubkey "$MINT_KEYPAIR")"
  export ZXCAML_SPL_SOURCE_TOKEN_ACCOUNT
  export ZXCAML_SPL_DEST_TOKEN_ACCOUNT
  ZXCAML_SPL_SOURCE_TOKEN_ACCOUNT="$(solana-keygen pubkey "$SOURCE_TOKEN_KEYPAIR")"
  ZXCAML_SPL_DEST_TOKEN_ACCOUNT="$(solana-keygen pubkey "$DEST_TOKEN_KEYPAIR")"
  spl-token --url "$RPC_URL" --fee-payer "$KEYPAIR" create-token --decimals 0 --mint-authority "$PAYER_PUBKEY" "$MINT_KEYPAIR" >/dev/null
  spl-token --url "$RPC_URL" --fee-payer "$KEYPAIR" create-account "$MINT_PUBKEY" "$SOURCE_TOKEN_KEYPAIR" --owner "$PAYER_PUBKEY" >/dev/null
  spl-token --url "$RPC_URL" --fee-payer "$KEYPAIR" create-account "$MINT_PUBKEY" "$DEST_TOKEN_KEYPAIR" --owner "$PAYER_PUBKEY" >/dev/null
  spl-token --url "$RPC_URL" --fee-payer "$KEYPAIR" mint "$MINT_PUBKEY" 10 "$ZXCAML_SPL_SOURCE_TOKEN_ACCOUNT" --mint-authority "$KEYPAIR" >/dev/null
fi

echo "==> building BPF shared object"
"$ROOT/zig-out/bin/omlz" build --target=bpf "$SRC" -o "$PROGRAM_SO" >"$BUILD_LOG" 2>&1
test -s "$PROGRAM_SO"
FILE_OUT="$(file "$PROGRAM_SO")"
echo "==> built artifact: $FILE_OUT"
case "$FILE_OUT" in
  *ELF*eBPF*) ;;
  *)
    echo "ERROR: BPF build did not produce an eBPF ELF shared object." >&2
    exit 1
    ;;
esac

echo "==> deploying program"
DEPLOY_OUT="$(solana --url "$RPC_URL" --keypair "$KEYPAIR" --commitment finalized program deploy "$PROGRAM_SO" 2>&1 | tee "$DEPLOY_LOG")"
PROGRAM_ID="$(printf '%s\n' "$DEPLOY_OUT" | python3 -c 'import re,sys; m=re.search(r"Program Id: ([1-9A-HJ-NP-Za-km-z]+)", sys.stdin.read()); print(m.group(1) if m else "")')"
if [[ -z "$PROGRAM_ID" ]]; then
  echo "ERROR: could not parse deployed Program Id from solana program deploy output." >&2
  exit 1
fi
echo "==> deployed program: $PROGRAM_ID"

echo "==> invoking deployed program with no accounts and no instruction data"
invoke_noop
echo "==> SUCCESS: solana hello deployed and invoked"
