#!/usr/bin/env python3
import json
import errno
import glob
import os
import select
import shutil
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


def recv_response(proc, request_id):
    while True:
        msg = recv(proc)
        if msg.get("id") == request_id:
            return msg


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


def open_document(proc, fixture_name, version=1):
    uri = fixture_uri(fixture_name)
    send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "ocaml", "version": version, "text": read_fixture(fixture_name)}}})
    params = recv_publish_diagnostics(proc, uri)
    assert params["diagnostics"] == [], params
    return uri


def assert_no_lsp_process():
    assert subprocess.run(["pgrep", "-f", "omlz-lsp"], stdout=subprocess.DEVNULL).returncode == 1


def tmp_path_pid(path):
    base = os.path.basename(path)
    prefix = "omlz_lsp_"
    if not base.startswith(prefix):
        return None

    rest = base[len(prefix):]
    digit_count = 0
    while digit_count < len(rest) and rest[digit_count].isdigit():
        digit_count += 1
    if digit_count == 0:
        return None

    suffix = rest[digit_count:]
    if suffix and not (suffix.startswith("_") and base.endswith(".ml")):
        return None

    pid = int(rest[:digit_count])
    return pid if pid > 0 else None


def pid_is_dead(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except OSError as exc:
        return exc.errno == errno.ESRCH or exc.errno == 3
    return False


def pre_clean_stale_tmp():
    for path in glob.glob("/tmp/omlz_lsp_*"):
        pid = tmp_path_pid(path)
        if pid is None or not pid_is_dead(pid):
            continue

        try:
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path)
            else:
                os.unlink(path)
        except FileNotFoundError:
            continue


def assert_no_temp_files():
    leftovers = glob.glob("/tmp/omlz_lsp_*.ml")
    leftovers.extend(path for path in glob.glob("/tmp/omlz_lsp_*") if os.path.isdir(path))
    assert leftovers == [], "leftover temp files: " + repr(leftovers)


def start_and_initialize():
    pre_clean_stale_tmp()
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
    pre_clean_stale_tmp()
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


def request_codelens(proc, uri, request_id):
    send(proc, {"jsonrpc": "2.0", "id": request_id, "method": "textDocument/codeLens", "params": {"textDocument": {"uri": uri}}})
    response = recv_response(proc, request_id)
    assert "result" in response, response
    assert isinstance(response["result"], list), response
    return response["result"]


def assert_run_lens(lens, uri, name, title_prefix="▶ Run test"):
    rng = lens["range"]
    assert rng["start"]["line"] >= 0, lens
    assert rng["start"]["character"] >= 0, lens
    assert rng["end"]["line"] >= rng["start"]["line"], lens
    command = lens["command"]
    assert command["title"].startswith(title_prefix), command
    assert command["command"] == "omlz.runTest", command
    assert command["arguments"] == [uri, name], command


def codelens():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "codelens_tests.ml")
        lenses = request_codelens(proc, uri, 20)
        names = [lens["command"]["arguments"][1] for lens in lenses]
        assert names == ["lsp codelens first passes", "lsp codelens second fails"], lenses
        assert_run_lens(lenses[0], uri, "lsp codelens first passes")
        assert_run_lens(lenses[1], uri, "lsp codelens second fails")
    finally:
        stop(proc)


def codelens_zero():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "ok.ml")
        lenses = request_codelens(proc, uri, 21)
        assert lenses == [], lenses
    finally:
        stop(proc)


def recv_executecommand(proc, request_id, *, expect_failure):
    saw_response = False
    saw_log = False
    saw_custom_output = False
    saw_summary = False
    saw_show_error = False
    first_failure = None
    deadline = time.time() + 5.0

    while time.time() < deadline:
        msg = recv(proc)
        if msg.get("id") == request_id:
            assert msg.get("result") is None, msg
            saw_response = True
            continue

        method = msg.get("method")
        if method == "window/logMessage":
            line = msg["params"]["message"]
            json.loads(line)
            saw_log = True
        elif method == "$/omlz.testOutput":
            line = msg["params"]["line"]
            payload = json.loads(line)
            saw_custom_output = True
            if payload.get("type") == "test" and payload.get("status") == "failed" and first_failure is None:
                first_failure = payload
            if payload.get("type") == "summary":
                saw_summary = True
        elif method == "window/showMessage":
            assert msg["params"]["type"] == 1, msg
            saw_show_error = True

        if saw_response and saw_log and saw_custom_output and saw_summary and (not expect_failure or saw_show_error):
            break

    assert saw_response, "missing executeCommand response"
    assert saw_log, "missing window/logMessage stream"
    assert saw_custom_output, "missing $/omlz.testOutput stream"
    assert saw_summary, "missing summary output"
    if expect_failure:
        assert saw_show_error, "missing error showMessage"
        assert first_failure is not None, "missing first failing test output"
        assert first_failure["name"] == "lsp codelens second fails", first_failure
        assert first_failure["line"] >= 1, first_failure
    else:
        assert first_failure is None, first_failure


def executecommand():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "codelens_tests.ml")
        send(proc, {"jsonrpc": "2.0", "id": 30, "method": "workspace/executeCommand", "params": {"command": "omlz.runTest", "arguments": [uri, "lsp codelens first passes"]}})
        recv_executecommand(proc, 30, expect_failure=False)
        lenses = request_codelens(proc, uri, 31)
        first = next(lens for lens in lenses if lens["command"]["arguments"][1] == "lsp codelens first passes")
        assert first["command"]["title"] == "✓ lsp codelens first passes", first
    finally:
        stop(proc)


def executecommand_failure():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "codelens_tests.ml")
        send(proc, {"jsonrpc": "2.0", "id": 40, "method": "workspace/executeCommand", "params": {"command": "omlz.runTest", "arguments": [uri, "lsp codelens second fails"]}})
        recv_executecommand(proc, 40, expect_failure=True)
        lenses = request_codelens(proc, uri, 41)
        failed = next(lens for lens in lenses if lens["command"]["arguments"][1] == "lsp codelens second fails")
        assert failed["command"]["title"].startswith("✗ lsp codelens second fails (line "), failed
    finally:
        stop(proc)


def codelens_latency():
    uri = fixture_uri("codelens_tests.ml")
    text = read_fixture("codelens_tests.ml")
    measured_ms = []
    raw_samples_ms = []
    proc = start_and_initialize()
    try:
        send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "ocaml", "version": 1, "text": text}}})
        params = recv_publish_diagnostics(proc, uri)
        assert params["diagnostics"] == [], params

        start = time.perf_counter()
        lenses = request_codelens(proc, uri, 50)
        raw_samples_ms.append((time.perf_counter() - start) * 1000.0)
        assert len(lenses) == 2, lenses

        for run in range(5):
            start = time.perf_counter()
            lenses = request_codelens(proc, uri, 51 + run)
            sample_ms = (time.perf_counter() - start) * 1000.0
            measured_ms.append(sample_ms)
            raw_samples_ms.append(sample_ms)
            assert len(lenses) == 2, lenses
    finally:
        stop(proc)

    sorted_samples = sorted(measured_ms)
    median_ms = sorted_samples[len(sorted_samples) // 2]
    print(f"codelens_latency_median={median_ms:.1f}ms")
    assert median_ms <= 100.0, f"raw_samples_ms={raw_samples_ms}"


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
        "codelens",
        "codelens_zero",
        "executecommand",
        "executecommand_failure",
        "codelens_latency",
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
        "codelens": codelens,
        "codelens_zero": codelens_zero,
        "executecommand": executecommand,
        "executecommand_failure": executecommand_failure,
        "codelens_latency": codelens_latency,
        "all": all_checks,
    }
    assert len(sys.argv) == 2 and sys.argv[1] in commands, "usage: run_lsp_check.py " + "|".join(commands)
    commands[sys.argv[1]]()
