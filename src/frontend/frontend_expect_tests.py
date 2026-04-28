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
        "(zxcaml-cir 0.7 (module (type_decl (name color) (params) "
        "(variants ((Red (payload_types)) (Green (payload_types)) "
        "(Blue (payload_types)))))))\n",
    ),
    (
        "type decl sexp - parameterized option",
        "type 'a option = None | Some of 'a\n",
        "(zxcaml-cir 0.7 (module (type_decl (name option) (params 'a) "
        "(variants ((None (payload_types)) "
        "(Some (payload_types (type-var 'a))))))))\n",
    ),
    (
        "type decl sexp - recursive tree",
        "type 'a tree = Leaf | Node of 'a tree * 'a tree\n",
        "(zxcaml-cir 0.7 (module (type_decl (name tree) (params 'a) "
        "(recursive true) (variants ((Leaf (payload_types)) "
        "(Node (payload_types (recursive-ref tree (type-var 'a)) "
        "(recursive-ref tree (type-var 'a)))))))))\n",
    ),
    (
        "user adt constructor expression",
        "type color = Red | Green | Blue\nlet entrypoint _ = Red\n",
        "(zxcaml-cir 0.7 (module (type_decl (name color) (params) "
        "(variants ((Red (payload_types)) (Green (payload_types)) "
        "(Blue (payload_types))))) (let entrypoint (lambda (_) (ctor Red)))))\n",
    ),
    (
        "user adt constructor pattern",
        (
            "type color = Red | Green | Blue\n"
            "let entrypoint c = match c with Red -> 1 | Green -> 2 | Blue -> 3\n"
        ),
        "(zxcaml-cir 0.7 (module (type_decl (name color) (params) "
        "(variants ((Red (payload_types)) (Green (payload_types)) "
        "(Blue (payload_types))))) (let entrypoint (lambda (c) "
        "(match (var c) (case (ctor Red) (const-int 1)) "
        "(case (ctor Green) (const-int 2)) "
        "(case (ctor Blue) (const-int 3)))))))\n",
    ),
    (
        "nested builtin and user adt constructor expression",
        "type tree = Leaf of int\nlet entrypoint _ = Some (Leaf 42)\n",
        "(zxcaml-cir 0.7 (module (type_decl (name tree) (params) "
        "(variants ((Leaf (payload_types (type-ref int)))))) "
        "(let entrypoint (lambda (_) (ctor Some (ctor Leaf (const-int 42)))))))\n",
    ),
    (
        "nested constructor pattern",
        (
            "type ('a, 'b) either = Left of 'a | Right of 'b\n"
            "let entrypoint x = match x with Some (Left v) -> v | Some _ -> 0 | None -> 0\n"
        ),
        "(zxcaml-cir 0.7 (module (type_decl (name either) (params 'a 'b) "
        "(variants ((Left (payload_types (type-var 'a))) "
        "(Right (payload_types (type-var 'b)))))) "
        "(let entrypoint (lambda (x) (match (var x) "
        "(case (ctor Some (ctor Left (var v))) (var v)) "
        "(case (ctor Some _) (const-int 0)) "
        "(case (ctor None) (const-int 0)))))))\n",
    ),
    (
        "guarded match arm",
        "let entrypoint x = match x with Some v when v > 10 -> 1 | Some _ -> 2 | None -> 3\n",
        "(zxcaml-cir 0.7 (module (let entrypoint (lambda (x) "
        "(match (var x) "
        "(case (ctor Some (var v)) (when_guard (prim \">\" (var v) (const-int 10)) (const-int 1))) "
        "(case (ctor Some _) (const-int 2)) "
        "(case (ctor None) (const-int 3)))))))\n",
    ),
    (
        "tuple construction",
        "let entrypoint _ = (1, true, 42)\n",
        "(zxcaml-cir 0.7 (module (let entrypoint (lambda (_) "
        "(tuple (items (const-int 1) (ctor true) (const-int 42)))))))\n",
    ),
    (
        "tuple projection",
        "let entrypoint _ = let t = (1, 2) in fst t\n",
        "(zxcaml-cir 0.7 (module (let entrypoint (lambda (_) "
        "(let t (tuple (items (const-int 1) (const-int 2))) "
        "(tuple_project (var t) (index 0)))))))\n",
    ),
    (
        "tuple type declaration",
        "type pair = int * bool\nlet entrypoint _ = 0\n",
        "(zxcaml-cir 0.7 (module "
        "(tuple_type_decl (name pair) (params) "
        "(items (type-ref int) (type-ref bool))) "
        "(let entrypoint (lambda (_) (const-int 0)))))\n",
    ),
    (
        "record construction",
        "type person = { name : string; age : int }\n"
        "let entrypoint _ = { name = \"alice\"; age = 30 }\n",
        "(zxcaml-cir 0.7 (module "
        "(record_type_decl (name person) (params) "
        "(fields ((name (type-ref string)) (age (type-ref int))))) "
        "(let entrypoint (lambda (_) "
        "(record (fields ((name (const-string \"alice\")) (age (const-int 30)))))))))\n",
    ),
    (
        "record field access",
        "type person = { name : string; age : int }\n"
        "let entrypoint _ = let r = { name = \"alice\"; age = 30 } in r.name\n",
        "(zxcaml-cir 0.7 (module "
        "(record_type_decl (name person) (params) "
        "(fields ((name (type-ref string)) (age (type-ref int))))) "
        "(let entrypoint (lambda (_) "
        "(let r (record (fields ((name (const-string \"alice\")) (age (const-int 30))))) "
        "(field_access (var r) name))))))\n",
    ),
    (
        "record functional update",
        "type person = { name : string; age : int }\n"
        "let entrypoint _ = let r = { name = \"alice\"; age = 30 } in { r with age = 31 }\n",
        "(zxcaml-cir 0.7 (module "
        "(record_type_decl (name person) (params) "
        "(fields ((name (type-ref string)) (age (type-ref int))))) "
        "(let entrypoint (lambda (_) "
        "(let r (record (fields ((name (const-string \"alice\")) (age (const-int 30))))) "
        "(record_update (var r) (fields ((age (const-int 31))))))))))\n",
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
