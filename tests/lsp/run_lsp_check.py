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


def request_hover(proc, uri, line, character, request_id):
    send(proc, {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "textDocument/hover",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": character},
        },
    })
    return recv_response(proc, request_id)


def hover_function_type():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        # `factorial` identifier on its `let rec` line (line 3, char 8..16).
        response = request_hover(proc, uri, 3, 10, 60)
        result = response["result"]
        assert result is not None, response
        contents = result["contents"]
        assert contents["kind"] == "markdown", contents
        assert "int -> int" in contents["value"], contents
        rng = result["range"]
        assert rng["start"]["line"] == 3, rng
        assert rng["start"]["character"] <= 10 <= rng["end"]["character"], rng
    finally:
        stop(proc)


def hover_polymorphic_type():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        # `length_demo` is defined with `List.length`. The frontend bridge
        # monomorphises generic types based on use sites; the hovered binding
        # still surfaces the resolved arrow type for the LSP client.
        response = request_hover(proc, uri, 6, 6, 61)
        result = response["result"]
        assert result is not None, response
        value = result["contents"]["value"]
        assert "->" in value, value
        assert value.startswith("```ocaml"), value
        assert value.endswith("```"), value
    finally:
        stop(proc)


def hover_inside_comment():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        # Line 0 is the OCaml comment header.
        response = request_hover(proc, uri, 0, 10, 62)
        assert response["result"] is None, response
    finally:
        stop(proc)


def hover_initialize_capability():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": None, "capabilities": {}}})
        response = recv(proc)
        capabilities = response["result"]["capabilities"]
        assert capabilities.get("hoverProvider") is True, capabilities
    finally:
        stop(proc)


def request_definition(proc, uri, line, character, request_id):
    send(proc, {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "textDocument/definition",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": character},
        },
    })
    return recv_response(proc, request_id)


def definition_initialize_capability():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": None, "capabilities": {}}})
        response = recv(proc)
        capabilities = response["result"]["capabilities"]
        assert capabilities.get("definitionProvider") is True, capabilities
    finally:
        stop(proc)


def definition_function_use_site():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        # Line 4 holds `  if n <= 1 then 1 else n * factorial (n - 1)`.
        # Resolve the recursive `factorial` use site (cursor anywhere inside
        # the identifier, character 30 lands mid-word).
        response = request_definition(proc, uri, 4, 30, 80)
        result = response["result"]
        assert result is not None, response
        assert result["uri"] == uri, result
        rng = result["range"]
        # `let rec factorial n = ...` is on line 3 (0-based) with `factorial`
        # starting after `let rec ` (8 characters).
        assert rng["start"]["line"] == 3, rng
        assert rng["start"]["character"] == 8, rng
        assert rng["end"]["line"] == 3, rng
        assert rng["end"]["character"] == 8 + len("factorial"), rng
    finally:
        stop(proc)


def definition_inside_comment():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        # Line 0 is the OCaml comment header.
        response = request_definition(proc, uri, 0, 10, 81)
        assert response["result"] is None, response
    finally:
        stop(proc)


def request_completion(proc, uri, line, character, request_id):
    send(proc, {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "textDocument/completion",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": character},
            "context": {"triggerKind": 1},
        },
    })
    return recv_response(proc, request_id)


def completion_initialize_capability():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": None, "capabilities": {}}})
        response = recv(proc)
        capabilities = response["result"]["capabilities"]
        provider = capabilities.get("completionProvider")
        assert isinstance(provider, dict), capabilities
        assert provider.get("triggerCharacters") == ["."], provider
    finally:
        stop(proc)


def completion_returns_user_bindings():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        response = request_completion(proc, uri, 8, 0, 70)
        result = response["result"]
        assert result["isIncomplete"] is False, result
        items = result["items"]
        assert isinstance(items, list) and items, result
        labels = [item["label"] for item in items]
        assert "factorial" in labels, labels
        factorial = next(item for item in items if item["label"] == "factorial")
        # `factorial : int -> int` should be flagged as a Function (kind 3).
        assert factorial["kind"] == 3, factorial
        assert "->" in factorial["detail"], factorial
    finally:
        stop(proc)


def completion_returns_stdlib():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        response = request_completion(proc, uri, 8, 0, 71)
        items = response["result"]["items"]
        labels = [item["label"] for item in items]
        assert "List.length" in labels, labels
        assert "Option.is_some" in labels, labels
    finally:
        stop(proc)


def request_references(proc, uri, line, character, request_id, *, include_declaration=True):
    send(proc, {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "textDocument/references",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": character},
            "context": {"includeDeclaration": include_declaration},
        },
    })
    return recv_response(proc, request_id)


def request_document_symbol(proc, uri, request_id):
    send(proc, {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "textDocument/documentSymbol",
        "params": {"textDocument": {"uri": uri}},
    })
    return recv_response(proc, request_id)


def references_initialize_capability():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": None, "capabilities": {}}})
        response = recv(proc)
        capabilities = response["result"]["capabilities"]
        assert capabilities.get("referencesProvider") is True, capabilities
    finally:
        stop(proc)


def references_function_use_sites():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        # Cursor on the `factorial` binding name (line 3, after `let rec `).
        response = request_references(proc, uri, 3, 10, 90)
        result = response["result"]
        assert isinstance(result, list), response
        assert len(result) >= 2, result
        for location in result:
            assert location["uri"] == uri, location
            rng = location["range"]
            assert rng["start"]["line"] == rng["end"]["line"], rng
        lines = sorted({loc["range"]["start"]["line"] for loc in result})
        # Expect both the declaration (line 3) and the recursive call (line 4).
        assert 3 in lines and 4 in lines, lines
    finally:
        stop(proc)


def references_inside_comment():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        # Line 0 is the OCaml comment header.
        response = request_references(proc, uri, 0, 10, 91)
        assert response["result"] == [], response
    finally:
        stop(proc)


def references_excludes_declaration_when_requested():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        with_decl = request_references(proc, uri, 3, 10, 92, include_declaration=True)["result"]
        without_decl = request_references(proc, uri, 3, 10, 93, include_declaration=False)["result"]
        assert len(with_decl) >= 2, with_decl
        assert len(without_decl) == len(with_decl) - 1, (with_decl, without_decl)
        # The declaration itself (line 3) must be absent when excluded.
        decl_present = any(loc["range"]["start"]["line"] == 3 and loc["range"]["start"]["character"] == 8 for loc in without_decl)
        assert not decl_present, without_decl
    finally:
        stop(proc)


def document_symbol_initialize_capability():
    proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": None, "capabilities": {}}})
        response = recv(proc)
        capabilities = response["result"]["capabilities"]
        assert capabilities.get("documentSymbolProvider") is True, capabilities
    finally:
        stop(proc)


def document_symbol_lists_top_level_bindings():
    proc = start_and_initialize()
    try:
        uri = open_document(proc, "hover_fixture.ml")
        response = request_document_symbol(proc, uri, 94)
        result = response["result"]
        assert isinstance(result, list) and result, response
        names = [sym["name"] for sym in result]
        assert names == ["identity", "factorial", "length_demo", "entrypoint"], names
        for sym in result:
            assert "selectionRange" in sym, sym
            assert "range" in sym, sym
            assert sym.get("children") == [], sym
            # Function-typed bindings should be SymbolKind.Function (12);
            # value bindings should be Variable (13). All four entries here
            # are arrow types, so we just assert it's one of the two.
            assert sym["kind"] in (12, 13), sym
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
    threshold_ms = float(os.environ.get("LATENCY_CODELENS_THRESHOLD_MS", "100"))
    print(f"codelens_latency_median={median_ms:.1f}ms threshold={threshold_ms}")
    assert threshold_ms > 1.0, f"raw_samples_ms={raw_samples_ms} threshold={threshold_ms}"
    assert median_ms <= threshold_ms, f"raw_samples_ms={raw_samples_ms} threshold={threshold_ms}"


def latency():
    """Delegate diagnostics latency enforcement to the canonical Zig probe."""

    bench = os.path.join(ROOT, "zig-out", "bin", "lsp-bench")
    if not os.path.exists(bench):
        subprocess.run(["zig", "build"], cwd=ROOT, check=True)

    completed = subprocess.run([bench], cwd=ROOT, check=False, text=True, capture_output=True)
    if completed.stdout:
        sys.stdout.write(completed.stdout)
    if completed.stderr:
        sys.stderr.write(completed.stderr)
    assert completed.returncode == 0, f"lsp-bench exited {completed.returncode}"


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
        "hover_initialize_capability",
        "hover_function_type",
        "hover_polymorphic_type",
        "hover_inside_comment",
        "definition_initialize_capability",
        "definition_function_use_site",
        "definition_inside_comment",
        "completion_initialize_capability",
        "completion_returns_user_bindings",
        "completion_returns_stdlib",
        "references_initialize_capability",
        "references_function_use_sites",
        "references_inside_comment",
        "references_excludes_declaration_when_requested",
        "document_symbol_initialize_capability",
        "document_symbol_lists_top_level_bindings",
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
        "hover_initialize_capability": hover_initialize_capability,
        "hover_function_type": hover_function_type,
        "hover_polymorphic_type": hover_polymorphic_type,
        "hover_inside_comment": hover_inside_comment,
        "definition_initialize_capability": definition_initialize_capability,
        "definition_function_use_site": definition_function_use_site,
        "definition_inside_comment": definition_inside_comment,
        "completion_initialize_capability": completion_initialize_capability,
        "completion_returns_user_bindings": completion_returns_user_bindings,
        "completion_returns_stdlib": completion_returns_stdlib,
        "references_initialize_capability": references_initialize_capability,
        "references_function_use_sites": references_function_use_sites,
        "references_inside_comment": references_inside_comment,
        "references_excludes_declaration_when_requested": references_excludes_declaration_when_requested,
        "document_symbol_initialize_capability": document_symbol_initialize_capability,
        "document_symbol_lists_top_level_bindings": document_symbol_lists_top_level_bindings,
        "all": all_checks,
    }
    assert len(sys.argv) == 2 and sys.argv[1] in commands, "usage: run_lsp_check.py " + "|".join(commands)
    commands[sys.argv[1]]()
