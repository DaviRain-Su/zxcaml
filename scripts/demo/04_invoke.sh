#!/usr/bin/env bash
# Purpose: invoke the deployed hackathon_greet program on Surfpool, using the
# canonical PDA seeds ["greet", maker_pubkey] with bump 255.
# Args: optional RPC_URL (default http://127.0.0.1:8899) and GREET_CALLS
# (default 2) environment variables.
# Expected output: init and greet transaction signatures are printed, then the
# greeting PDA state is decoded as maker=<pubkey> and counter=<GREET_CALLS>.
# Exit codes: 0 when all transactions finalize and state matches; non-zero on
# missing deploy artifacts, transaction failure, PDA mismatch, or decode error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPC_URL="${RPC_URL:-http://127.0.0.1:8899}"
KEYPAIR_DIR="${SCRIPT_DIR}/.keypairs"
PAYER_KEYPAIR="${KEYPAIR_DIR}/payer.json"
MAKER_KEYPAIR="${KEYPAIR_DIR}/maker.json"
PROGRAM_ID_FILE="${SCRIPT_DIR}/.program_id"
GREET_CALLS="${GREET_CALLS:-2}"

if [[ ! "${GREET_CALLS}" =~ ^[0-9]+$ ]] || [[ "${GREET_CALLS}" -lt 1 ]]; then
  printf 'ERROR: GREET_CALLS must be a positive integer.\n' >&2
  exit 1
fi
if [[ ! -s "${PAYER_KEYPAIR}" ]]; then
  printf 'ERROR: payer keypair missing at %s. Run scripts/demo/03_deploy.sh first.\n' "${PAYER_KEYPAIR}" >&2
  exit 1
fi
if [[ ! -s "${PROGRAM_ID_FILE}" ]]; then
  printf 'ERROR: program id file missing at %s. Run scripts/demo/03_deploy.sh first.\n' "${PROGRAM_ID_FILE}" >&2
  exit 1
fi

program_id="$(cat "${PROGRAM_ID_FILE}")"

python3 - "${RPC_URL}" "${PAYER_KEYPAIR}" "${MAKER_KEYPAIR}" "${program_id}" "${GREET_CALLS}" <<'PY'
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

rpc_url, payer_keypair_path, maker_keypair_path, program_id_b58, greet_calls_s = sys.argv[1:6]
greet_calls = int(greet_calls_s)
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
PDA_MARKER = b"ProgramDerivedAddress"
GREET_SPACE = 40
RENT_EXEMPT_LAMPORTS = 1_000_000
P = 2**255 - 19
D = (-121665 * pow(121666, P - 2, P)) % P
I = pow(2, (P - 1) // 4, P)

def b58decode(s):
    n = 0
    for ch in s:
        n = n * 58 + ALPHABET.index(ch)
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    return b"\x00" * (len(s) - len(s.lstrip("1"))) + raw

def b58encode(data):
    n = int.from_bytes(data, "big")
    out = ""
    while n:
        n, rem = divmod(n, 58)
        out = ALPHABET[rem] + out
    return "1" * (len(data) - len(data.lstrip(b"\x00"))) + (out or "")

def compact_len(n):
    out = bytearray()
    while True:
        elem = n & 0x7F
        n >>= 7
        out.append(elem | 0x80 if n else elem)
        if not n:
            return bytes(out)

def rpc(method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
    req = urllib.request.Request(rpc_url, data=body, headers={"Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=15) as response:
        decoded = json.loads(response.read().decode())
    if "error" in decoded:
        raise RuntimeError(f"RPC {method} failed: {decoded['error']}")
    return decoded.get("result")

def xrecover(y):
    xx = (y*y - 1) * pow(D*y*y + 1, P - 2, P)
    x = pow(xx, (P + 3) // 8, P)
    if (x*x - xx) % P != 0:
        x = (x * I) % P
    if (x*x - xx) % P != 0:
        return None
    if x & 1:
        x = P - x
    return x

def is_on_curve(pubkey):
    if len(pubkey) != 32:
        return False
    y = int.from_bytes(pubkey, "little") & ((1 << 255) - 1)
    return y < P and xrecover(y) is not None

def create_program_address(seeds, program_id):
    digest = hashlib.sha256(b"".join(seeds) + program_id + PDA_MARKER).digest()
    if is_on_curve(digest):
        raise ValueError("derived address is on curve")
    return digest

def find_program_address(seeds, program_id):
    for bump in range(255, -1, -1):
        try:
            return create_program_address([*seeds, bytes([bump])], program_id), bump
        except ValueError:
            pass
    raise RuntimeError("unable to find viable PDA bump")

def read_keypair(path):
    secret = json.loads(Path(path).read_text())
    if len(secret) != 64:
        raise RuntimeError(f"expected 64-byte Solana keypair at {path}, got {len(secret)}")
    return bytes(secret[:32]), bytes(secret[32:])

def sign_ed25519(seed, message):
    der = bytes.fromhex("302e020100300506032b657004220420") + seed
    with tempfile.TemporaryDirectory(prefix="zxcaml-sign-") as tmp:
        key_path = os.path.join(tmp, "ed25519.der")
        msg_path = os.path.join(tmp, "message.bin")
        sig_path = os.path.join(tmp, "signature.bin")
        Path(key_path).write_bytes(der)
        Path(msg_path).write_bytes(message)
        subprocess.run(
            ["openssl", "pkeyutl", "-sign", "-rawin", "-keyform", "DER", "-inkey", key_path, "-in", msg_path, "-out", sig_path],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return Path(sig_path).read_bytes()

def maker_pubkey_from_file(path):
    return read_keypair(path)[1] if Path(path).exists() else None

def generate_maker_with_bump_255(path, program_id):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    existing = maker_pubkey_from_file(path)
    if existing is not None:
        pda, bump = find_program_address([b"greet", existing], program_id)
        if bump == 255:
            return existing, pda, bump
    for _ in range(200):
        subprocess.run(["solana-keygen", "new", "--no-bip39-passphrase", "--force", "--silent", "-o", path], check=True, stdout=subprocess.DEVNULL)
        maker = read_keypair(path)[1]
        pda, bump = find_program_address([b"greet", maker], program_id)
        if bump == 255:
            return maker, pda, bump
    raise RuntimeError("could not generate maker whose greet PDA has bump 255")

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
        raise RuntimeError(f"transaction {signature} did not finalize; last status={final_status}")
    if final_status.get("err") is not None:
        raise RuntimeError(f"transaction {signature} failed: {final_status.get('err')}")

def send_instruction(payer_seed, payer_pub, maker_seed, maker_pub, greeting_pub, program_id, discriminator):
    blockhash = b58decode(rpc("getLatestBlockhash", [{"commitment": "finalized"}])["value"]["blockhash"])
    account_keys = [payer_pub, maker_pub, greeting_pub, program_id]
    message = bytearray()
    message += bytes([2, 1, 1])
    message += compact_len(len(account_keys)) + b"".join(account_keys)
    message += blockhash
    message += compact_len(1)
    message += bytes([3]) + compact_len(2) + bytes([2, 1]) + compact_len(1) + bytes([discriminator])
    message = bytes(message)
    sigs = [sign_ed25519(payer_seed, message), sign_ed25519(maker_seed, message)]
    tx = compact_len(len(sigs)) + b"".join(sigs) + message
    signature = rpc("sendTransaction", [base64.b64encode(tx).decode(), {
        "encoding": "base64",
        "skipPreflight": False,
        "preflightCommitment": "processed",
        "maxRetries": 5,
    }])
    await_signature(signature)
    return signature

def set_greeting_account(greeting_b58, program_b58):
    data_hex = "00" * GREET_SPACE
    update = {
        "lamports": RENT_EXEMPT_LAMPORTS,
        "data": data_hex,
        "owner": program_b58,
        "executable": False,
        "rent_epoch": 0,
    }
    try:
        rpc("surfnet_setAccount", [greeting_b58, update])
    except Exception:
        update["data"] = "0x" + data_hex
        rpc("surfnet_setAccount", [greeting_b58, update])

def request_airdrop(pubkey_b58, lamports):
    sig = rpc("requestAirdrop", [pubkey_b58, lamports])
    await_signature(sig)

program_id = b58decode(program_id_b58)
if len(program_id) != 32:
    raise RuntimeError("program id must decode to 32 bytes")
payer_seed, payer_pub = read_keypair(payer_keypair_path)
_, greeting_pub, bump = generate_maker_with_bump_255(maker_keypair_path, program_id)
maker_seed, maker_pub = read_keypair(maker_keypair_path)
greeting_b58 = b58encode(greeting_pub)
maker_b58 = b58encode(maker_pub)

print(f"Program: {program_id_b58}")
print(f"Maker: {maker_b58}")
print(f"Greeting PDA: {greeting_b58} (bump={bump}, seeds=['greet', maker])")
print("Preparing Surfpool PDA account with surfnet_setAccount...")
set_greeting_account(greeting_b58, program_id_b58)
print("Funding maker signer...")
request_airdrop(maker_b58, 1_000_000_000)

sig = send_instruction(payer_seed, payer_pub, maker_seed, maker_pub, greeting_pub, program_id, 0)
print(f"init signature: {sig}")
for i in range(greet_calls):
    sig = send_instruction(payer_seed, payer_pub, maker_seed, maker_pub, greeting_pub, program_id, 1)
    print(f"greet {i + 1} signature: {sig}")

account = rpc("getAccountInfo", [greeting_b58, {"encoding": "base64", "commitment": "finalized"}])["value"]
if account is None:
    raise RuntimeError("greeting account not found after invoke")
data = base64.b64decode(account["data"][0])
stored_maker = data[:32]
counter = int.from_bytes(data[32:40], "little")
print(f"decoded maker: {b58encode(stored_maker)}")
print(f"decoded counter: {counter}")
if stored_maker != maker_pub:
    raise RuntimeError("stored maker does not match signer")
if counter != greet_calls:
    raise RuntimeError(f"expected counter {greet_calls}, got {counter}")
print(f"SUCCESS: hackathon_greet counter={counter}")
PY
