#!/usr/bin/env python3
"""Capture a 30-round omlz LSP latency baseline JSON."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


WARMUP = 5
ROUNDS = 30
DEFAULT_P50_MS = 350
DEFAULT_P99_MS = 800


def env_threshold(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        print(f"error: {name} must be an unsigned millisecond value", file=sys.stderr)
        return default


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    output_path = repo_root / "mission-internal" / "lsp-bench-baseline.json"
    command = [
        str(repo_root / "zig-out" / "bin" / "omlz"),
        "lsp-bench",
        "--rounds",
        str(ROUNDS),
        "--warmup",
        str(WARMUP),
        "--json",
    ]

    completed = subprocess.run(
        command,
        cwd=repo_root,
        text=True,
        capture_output=True,
        check=False,
    )

    if completed.stderr:
        print(completed.stderr, file=sys.stderr, end="")

    try:
        raw = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        print(f"error: failed to parse omlz lsp-bench JSON output: {exc}", file=sys.stderr)
        if completed.stdout:
            print(completed.stdout, file=sys.stderr, end="")
        return completed.returncode if completed.returncode != 0 else 1

    p50_threshold = env_threshold("ZXCAML_LSP_LATENCY_P50_MS", DEFAULT_P50_MS)
    p99_threshold = env_threshold("ZXCAML_LSP_LATENCY_P99_MS", DEFAULT_P99_MS)
    passed = raw["p50_ms"] < p50_threshold and raw["p99_ms"] < p99_threshold

    baseline = {
        "timestamp": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "host": subprocess.check_output(["uname", "-a"], text=True).strip(),
        "warmup": WARMUP,
        "rounds": ROUNDS,
        "samples_ms": raw["samples_ms"],
        "p50_ms": raw["p50_ms"],
        "p99_ms": raw["p99_ms"],
        "min_ms": raw["min_ms"],
        "max_ms": raw["max_ms"],
        "passed": passed,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(baseline, indent=2, sort_keys=False) + "\n")
    print(f"wrote {output_path.relative_to(repo_root)}")

    if not passed:
        if raw["p50_ms"] >= p50_threshold:
            print(f"FAIL: p50={raw['p50_ms']} exceeds threshold {p50_threshold}", file=sys.stderr)
        if raw["p99_ms"] >= p99_threshold:
            print(f"FAIL: p99={raw['p99_ms']} exceeds threshold {p99_threshold}", file=sys.stderr)
        return 1

    if completed.returncode != 0:
        return completed.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
