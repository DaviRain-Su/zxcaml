#!/usr/bin/env python3
"""Runtime LSP harness entrypoint.

The original M-LSP harness lives in tests/lsp/run_lsp_check.py and remains the
canonical source for initialize, diagnostics, lifecycle, latency, CodeLens, and
executeCommand scenarios. FMT4 extends this runtime-facing harness with:
- PASS formatting
- PASS rangeFormatting
- PASS formatting_malformed
- PASS formatting_latency
"""

import importlib.util
import os
import sys
import time


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HARNESS = os.path.join(ROOT, "tests", "lsp", "run_lsp_check.py")
FIXTURES = os.path.join(ROOT, "runtime", "lsp", "fixtures")


def load_base_harness():
    spec = importlib.util.spec_from_file_location("zxcaml_lsp_base_harness", HARNESS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BASE = load_base_harness()

BASE_COMMANDS = {
    "initialize": BASE.initialize,
    "didopen_parse_err": BASE.didopen_parse_err,
    "didopen_clean": BASE.didopen_clean,
    "didchange_roundtrip": BASE.didchange_roundtrip,
    "shutdown": BASE.shutdown,
    "latency": BASE.latency,
    "codelens": BASE.codelens,
    "codelens_zero": BASE.codelens_zero,
    "executecommand": BASE.executecommand,
    "executecommand_failure": BASE.executecommand_failure,
    "codelens_latency": BASE.codelens_latency,
}


def runtime_fixture_path(name):
    return os.path.join(FIXTURES, name)


def runtime_fixture_uri(name):
    return "file://" + runtime_fixture_path(name)


def read_runtime_fixture(name):
    with open(runtime_fixture_path(name), "r", encoding="utf-8") as f:
        return f.read()


def open_text(proc, uri, text, version=1):
    BASE.send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "ocaml", "version": version, "text": text}}})
    return BASE.recv_publish_diagnostics(proc, uri)


def request_formatting(proc, uri, request_id):
    BASE.send(proc, {"jsonrpc": "2.0", "id": request_id, "method": "textDocument/formatting", "params": {"textDocument": {"uri": uri}, "options": {"tabSize": 2, "insertSpaces": True}}})
    response = BASE.recv_response(proc, request_id)
    assert "error" not in response, response
    assert isinstance(response.get("result"), list), response
    return response["result"]


def request_range_formatting(proc, uri, request_id, rng):
    BASE.send(proc, {"jsonrpc": "2.0", "id": request_id, "method": "textDocument/rangeFormatting", "params": {"textDocument": {"uri": uri}, "range": rng, "options": {"tabSize": 2, "insertSpaces": True}}})
    response = BASE.recv_response(proc, request_id)
    assert "error" not in response, response
    assert isinstance(response.get("result"), list), response
    return response["result"]


def offset_for_position(text, position):
    line = position["line"]
    character = position["character"]
    offset = 0
    current_line = 0
    for chunk in text.splitlines(keepends=True):
        if current_line == line:
            return offset + character
        offset += len(chunk)
        current_line += 1
    assert current_line == line, (position, text)
    return offset + character


def apply_text_edits(text, edits):
    result = text
    ordered = sorted(edits, key=lambda edit: (edit["range"]["start"]["line"], edit["range"]["start"]["character"]), reverse=True)
    for edit in ordered:
        start = offset_for_position(result, edit["range"]["start"])
        end = offset_for_position(result, edit["range"]["end"])
        result = result[:start] + edit["newText"] + result[end:]
    return result


def formatting():
    proc = BASE.start_and_initialize()
    uri = runtime_fixture_uri("bad_formatting.ml")
    text = read_runtime_fixture("bad_formatting.ml")
    expected = (
        "let entrypoint x =\n"
        "  match x with\n"
        "    | Some y -> y\n"
        "    | None -> 0\n"
    )
    try:
        params = open_text(proc, uri, text)
        assert params["diagnostics"] == [], params
        edits = request_formatting(proc, uri, 60)
        assert edits, "expected formatting edits"
        assert apply_text_edits(text, edits) == expected, edits
    finally:
        BASE.stop(proc)


def rangeFormatting():
    proc = BASE.start_and_initialize()
    uri = "file://" + os.path.join(FIXTURES, "range_formatting.ml")
    text = "let entrypoint x=x+1\nlet untouched=3\n"
    expected = "let entrypoint x = x + 1\nlet untouched=3\n"
    rng = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": len("let entrypoint x=x+1")}}
    try:
        params = open_text(proc, uri, text)
        assert params["diagnostics"] == [], params
        edits = request_range_formatting(proc, uri, 61, rng)
        assert edits, "expected rangeFormatting edits"
        assert apply_text_edits(text, edits) == expected, edits
    finally:
        BASE.stop(proc)


def formatting_malformed():
    proc = BASE.start_and_initialize()
    uri = "file://" + os.path.join(FIXTURES, "malformed.ml")
    text = "let broken = \"unterminated\n"
    try:
        open_text(proc, uri, text)
        edits = request_formatting(proc, uri, 62)
        assert edits == [], edits
    finally:
        BASE.stop(proc)


def formatting_latency():
    proc = BASE.start_and_initialize()
    uri = "file://" + os.path.join(FIXTURES, "formatting_latency.ml")
    text = "".join(f"let helper_{i}= {i}+1\n" for i in range(499)) + "let entrypoint x=x\n"
    measured_ms = []
    try:
        params = open_text(proc, uri, text)
        assert params["diagnostics"] == [], params

        request_formatting(proc, uri, 63)
        for run in range(5):
            start = time.perf_counter()
            edits = request_formatting(proc, uri, 64 + run)
            measured_ms.append((time.perf_counter() - start) * 1000.0)
            assert edits, edits
    finally:
        BASE.stop(proc)

    median_ms = sorted(measured_ms)[len(measured_ms) // 2]
    print(f"formatting_latency_median={median_ms:.1f}ms")
    assert median_ms <= 30.0, f"raw_samples_ms={measured_ms}"


FORMAT_COMMANDS = {
    "formatting": formatting,
    "rangeFormatting": rangeFormatting,
    "formatting_malformed": formatting_malformed,
    "formatting_latency": formatting_latency,
}


def all_checks():
    for name, fn in BASE_COMMANDS.items():
        fn()
        print(f"PASS {name}")
    for name, fn in FORMAT_COMMANDS.items():
        fn()
        print(f"PASS {name}")


def main():
    os.chdir(ROOT)
    commands = dict(BASE_COMMANDS)
    commands.update(FORMAT_COMMANDS)
    commands["all"] = all_checks
    assert len(sys.argv) == 2 and sys.argv[1] in commands, "usage: test_harness.py " + "|".join(commands)
    commands[sys.argv[1]]()


if __name__ == "__main__":
    if len(sys.argv) == 1:
        sys.argv.append("all")
    main()
