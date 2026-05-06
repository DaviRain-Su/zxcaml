#!/usr/bin/env python3
import json
import glob
import os
import select
import subprocess
import sys
import time


BIN = "zig-out/bin/omlz-lsp"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def send(proc, msg):
    body = json.dumps(msg, separators=(",", ":")).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    proc.stdin.flush()


def read_byte(proc, timeout=2.0):
    ready, _, _ = select.select([proc.stdout], [], [], timeout)
    assert ready, "timeout waiting for LSP response"
    b = os.read(proc.stdout.fileno(), 1)
    assert b, "EOF before LSP response"
    return b


def read_exact(proc, length, timeout=2.0):
    chunks = []
    remaining = length
    while remaining:
        ready, _, _ = select.select([proc.stdout], [], [], timeout)
        assert ready, "timeout waiting for LSP response body"
        chunk = os.read(proc.stdout.fileno(), remaining)
        assert chunk, "EOF before full LSP body"
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def recv(proc):
    header = b""
    while b"\r\n\r\n" not in header:
        header += read_byte(proc)
    length = None
    for line in header.decode().split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    assert length is not None, "missing Content-Length"
    return json.loads(read_exact(proc, length))


def fixture_path(name):
    return os.path.join(ROOT, "tests", "lsp", name)


def fixture_uri(name):
    return "file://" + fixture_path(name)


def read_fixture(name):
    with open(fixture_path(name), "r", encoding="utf-8") as f:
        return f.read()


def assert_diagnostic_shape(diag, *, expect_error=True):
    assert isinstance(diag.get("message"), str) and diag["message"], diag
    assert isinstance(diag.get("severity"), int), diag
    if expect_error:
        assert diag["severity"] == 1, diag
    rng = diag["range"]
    assert rng["start"]["line"] >= 0, diag
    assert rng["start"]["character"] >= 0, diag
    assert rng["end"]["line"] >= rng["start"]["line"], diag
    assert rng["end"]["character"] >= 0, diag


def recv_publish_diagnostics(proc, uri):
    while True:
        msg = recv(proc)
        if msg.get("method") != "textDocument/publishDiagnostics":
            continue
        params = msg["params"]
        assert params["uri"] == uri, params
        assert isinstance(params["diagnostics"], list), params
        return params


def assert_no_lsp_process():
    assert subprocess.run(["pgrep", "-f", "omlz-lsp"], stdout=subprocess.DEVNULL).returncode == 1


def assert_no_temp_files():
    leftovers = glob.glob("/tmp/omlz_lsp_*.ml")
    assert leftovers == [], "leftover temp files: " + repr(leftovers)


def start_and_initialize():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": None, "capabilities": {}}})
        response = recv(proc)
        result = response["result"]
        assert result["capabilities"]["textDocumentSync"] == 1
        assert result["serverInfo"]["name"] == "omlz-lsp"
        assert isinstance(result["serverInfo"]["version"], str) and result["serverInfo"]["version"]
        send(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})
        return proc
    except BaseException:
        stop(proc)
        raise


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)
    assert_no_lsp_process()
    assert_no_temp_files()


def initialize():
    proc = start_and_initialize()
    stop(proc)


def didopen_parse_err():
    proc = start_and_initialize()
    uri = fixture_uri("parse_err.ml")
    try:
        send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "ocaml", "version": 1, "text": read_fixture("parse_err.ml")}}})
        params = recv_publish_diagnostics(proc, uri)
        assert len(params["diagnostics"]) >= 1, params
        assert_diagnostic_shape(params["diagnostics"][0])
    finally:
        stop(proc)


def didopen_clean():
    proc = start_and_initialize()
    uri = fixture_uri("ok.ml")
    try:
        send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "ocaml", "version": 1, "text": read_fixture("ok.ml")}}})
        params = recv_publish_diagnostics(proc, uri)
        assert params["diagnostics"] == [], params
    finally:
        stop(proc)


def didchange_roundtrip():
    proc = start_and_initialize()
    uri = fixture_uri("ok.ml")
    clean_text = read_fixture("ok.ml")
    broken_text = read_fixture("type_err.ml")
    try:
        send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "ocaml", "version": 1, "text": clean_text}}})
        clean_params = recv_publish_diagnostics(proc, uri)
        assert clean_params["diagnostics"] == [], clean_params

        send(proc, {"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {"textDocument": {"uri": uri, "version": 2}, "contentChanges": [{"text": broken_text}]}})
        broken_params = recv_publish_diagnostics(proc, uri)
        assert len(broken_params["diagnostics"]) >= 1, broken_params
        assert_diagnostic_shape(broken_params["diagnostics"][0])

        send(proc, {"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {"textDocument": {"uri": uri, "version": 3}, "contentChanges": [{"text": clean_text}]}})
        fixed_params = recv_publish_diagnostics(proc, uri)
        assert fixed_params["diagnostics"] == [], fixed_params
    finally:
        stop(proc)


def shutdown():
    proc = start_and_initialize()
    sentinel = f"/tmp/omlz_lsp_{proc.pid}_sentinel.ml"
    with open(sentinel, "w", encoding="utf-8") as f:
        f.write("let _ = 1\n")
    try:
        send(proc, {"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": None})
        response = recv(proc)
        assert response == {"jsonrpc": "2.0", "id": 2, "result": None}, response
        send(proc, {"jsonrpc": "2.0", "method": "exit", "params": None})
        proc.wait(timeout=2)
        assert proc.returncode == 0, proc.returncode
        assert_no_lsp_process()
        assert_no_temp_files()
    finally:
        if proc.poll() is None:
            stop(proc)
        if os.path.exists(sentinel):
            os.unlink(sentinel)


def latency():
    # Fork-per-request latency budget and expected ~80 ms steady-state are cited in
    # mission-internal/p9-investigation/report.md §3 and Appendix C.
    uri = fixture_uri("latency.ml")
    text = read_fixture("latency.ml")
    elapsed_ms = []
    raw_samples_ms = []
    proc = start_and_initialize()
    try:
        # One warm-up didOpen performs the full diagnostics roundtrip but is
        # excluded from the p50 median so cold-start variance does not skew it.
        start = time.perf_counter()
        send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "ocaml", "version": 1, "text": text}}})
        params = recv_publish_diagnostics(proc, uri)
        raw_samples_ms.append((time.perf_counter() - start) * 1000.0)
        assert params["diagnostics"] == [], params

        for run in range(5):
            start = time.perf_counter()
            send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "ocaml", "version": run + 2, "text": text}}})
            params = recv_publish_diagnostics(proc, uri)
            sample_ms = (time.perf_counter() - start) * 1000.0
            elapsed_ms.append(sample_ms)
            raw_samples_ms.append(sample_ms)
            assert params["diagnostics"] == [], params
    finally:
        stop(proc)

    sorted_samples = sorted(elapsed_ms)
    median_ms = sorted_samples[len(sorted_samples) // 2]
    print(f"latency_median={median_ms:.1f}ms")
    assert median_ms <= 200.0, f"raw_samples_ms={raw_samples_ms}"


def all_checks():
    failures = []
    for name in [
        "initialize",
        "didopen_parse_err",
        "didopen_clean",
        "didchange_roundtrip",
        "shutdown",
        "latency",
    ]:
        try:
            commands[name]()
        except BaseException as exc:
            failures.append((name, exc))
            print(f"FAIL {name}: {exc!r}", file=sys.stderr)
            break
        else:
            print(f"PASS {name}")

    if failures:
        raise AssertionError(f"LSP harness failed at {failures[0][0]}")


if __name__ == "__main__":
    commands = {
        "initialize": initialize,
        "didopen_parse_err": didopen_parse_err,
        "didopen_clean": didopen_clean,
        "didchange_roundtrip": didchange_roundtrip,
        "shutdown": shutdown,
        "latency": latency,
        "all": all_checks,
    }
    assert len(sys.argv) == 2 and sys.argv[1] in commands, "usage: run_lsp_check.py " + "|".join(commands)
    commands[sys.argv[1]]()
