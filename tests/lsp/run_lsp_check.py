#!/usr/bin/env python3
import json
import subprocess
import sys


BIN = "zig-out/bin/omlz-lsp"


def send(proc, msg):
    body = json.dumps(msg, separators=(",", ":")).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    proc.stdin.flush()


def recv(proc):
    header = b""
    while b"\r\n\r\n" not in header:
        b = proc.stdout.read(1)
        assert b, "EOF before LSP response"
        header += b
    length = None
    for line in header.decode().split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    assert length is not None, "missing Content-Length"
    return json.loads(proc.stdout.read(length))


def assert_no_lsp_process():
    assert subprocess.run(["pgrep", "-f", "omlz-lsp"], stdout=subprocess.DEVNULL).returncode == 1


def initialize():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": None, "capabilities": {}}})
        response = recv(proc)
        result = response["result"]
        assert result["capabilities"]["textDocumentSync"] == 1
        assert result["serverInfo"]["name"] == "omlz-lsp"
        assert isinstance(result["serverInfo"]["version"], str) and result["serverInfo"]["version"]
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)
    assert_no_lsp_process()


if __name__ == "__main__":
    assert len(sys.argv) == 2 and sys.argv[1] == "initialize", "usage: run_lsp_check.py initialize"
    initialize()
