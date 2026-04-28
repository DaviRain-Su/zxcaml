#!/usr/bin/env python3
"""Snapshot-style tests for zxc-frontend S-expression emission.

The frontend build deliberately avoids dune/ppx dependencies, so this small
expect harness invokes the built binary directly and compares stdout against
checked-in snapshots.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
FRONTEND_BIN = pathlib.Path(
    os.environ.get("ZXC_FRONTEND_BIN", REPO_ROOT / "zig-out/bin/zxc-frontend")
)


CASES: list[tuple[str, str, str]] = [
    (
        "type decl sexp - enum",
        "type color = Red | Green | Blue\n",
        "(zxcaml-cir 0.5 (module (type_decl (name color) (params) "
        "(variants ((Red (payload_types)) (Green (payload_types)) "
        "(Blue (payload_types)))))))\n",
    ),
    (
        "type decl sexp - parameterized option",
        "type 'a option = None | Some of 'a\n",
        "(zxcaml-cir 0.5 (module (type_decl (name option) (params 'a) "
        "(variants ((None (payload_types)) "
        "(Some (payload_types (type-var 'a))))))))\n",
    ),
    (
        "type decl sexp - recursive tree",
        "type 'a tree = Leaf | Node of 'a tree * 'a tree\n",
        "(zxcaml-cir 0.5 (module (type_decl (name tree) (params 'a) "
        "(recursive true) (variants ((Leaf (payload_types)) "
        "(Node (payload_types (recursive-ref tree (type-var 'a)) "
        "(recursive-ref tree (type-var 'a)))))))))\n",
    ),
]


def run_case(tmp_dir: pathlib.Path, name: str, source: str, expected: str) -> bool:
    path = tmp_dir / (name.replace(" ", "_").replace("-", "_") + ".ml")
    path.write_text(source, encoding="utf-8")

    result = subprocess.run(
        [str(FRONTEND_BIN), "--emit=sexp", str(path)],
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        print(f"FAIL {name}: frontend exited {result.returncode}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        return False
    if result.stdout != expected:
        print(f"FAIL {name}: stdout mismatch", file=sys.stderr)
        print(f"expected: {expected!r}", file=sys.stderr)
        print(f"actual:   {result.stdout!r}", file=sys.stderr)
        return False
    print(f"PASS {name}")
    return True


def main() -> int:
    if not FRONTEND_BIN.exists():
        print(f"missing frontend binary: {FRONTEND_BIN}", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="zxcaml-frontend-expect-") as tmp:
        tmp_dir = pathlib.Path(tmp)
        passed = [run_case(tmp_dir, *case) for case in CASES]
    return 0 if all(passed) else 1


if __name__ == "__main__":
    raise SystemExit(main())
