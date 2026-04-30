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
        "(zxcaml-cir 1.0 (module (type_decl (name color) (params) "
        "(variants ((Red (payload_types)) (Green (payload_types)) "
        "(Blue (payload_types)))))))\n",
    ),
    (
        "type decl sexp - parameterized option",
        "type 'a option = None | Some of 'a\n",
        "(zxcaml-cir 1.0 (module (type_decl (name option) (params 'a) "
        "(variants ((None (payload_types)) "
        "(Some (payload_types (type-var 'a))))))))\n",
    ),
    (
        "type decl sexp - recursive tree",
        "type 'a tree = Leaf | Node of 'a tree * 'a tree\n",
        "(zxcaml-cir 1.0 (module (type_decl (name tree) (params 'a) "
        "(recursive true) (variants ((Leaf (payload_types)) "
        "(Node (payload_types (recursive-ref tree (type-var 'a)) "
        "(recursive-ref tree (type-var 'a)))))))))\n",
    ),
    (
        "user adt constructor expression",
        "type color = Red | Green | Blue\nlet entrypoint _ = Red\n",
        "(zxcaml-cir 1.0 (module (type_decl (name color) (params) "
        "(variants ((Red (payload_types)) (Green (payload_types)) "
        "(Blue (payload_types))))) (let entrypoint (lambda (_) (ctor Red)))))\n",
    ),
    (
        "user adt constructor pattern",
        (
            "type color = Red | Green | Blue\n"
            "let entrypoint c = match c with Red -> 1 | Green -> 2 | Blue -> 3\n"
        ),
        "(zxcaml-cir 1.0 (module (type_decl (name color) (params) "
        "(variants ((Red (payload_types)) (Green (payload_types)) "
        "(Blue (payload_types))))) (let entrypoint (lambda (c) "
        "(match (var c) (case (ctor Red) (const-int 1)) "
        "(case (ctor Green) (const-int 2)) "
        "(case (ctor Blue) (const-int 3)))))))\n",
    ),
    (
        "nested builtin and user adt constructor expression",
        "type tree = Leaf of int\nlet entrypoint _ = Some (Leaf 42)\n",
        "(zxcaml-cir 1.0 (module (type_decl (name tree) (params) "
        "(variants ((Leaf (payload_types (type-ref int)))))) "
        "(let entrypoint (lambda (_) (ctor Some (ctor Leaf (const-int 42)))))))\n",
    ),
    (
        "nested constructor pattern",
        (
            "type ('a, 'b) either = Left of 'a | Right of 'b\n"
            "let entrypoint x = match x with Some (Left v) -> v | Some _ -> 0 | None -> 0\n"
        ),
        "(zxcaml-cir 1.0 (module (type_decl (name either) (params 'a 'b) "
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
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (x) "
        "(match (var x) "
        "(case (ctor Some (var v)) (when_guard (prim \">\" (var v) (const-int 10)) (const-int 1))) "
        "(case (ctor Some _) (const-int 2)) "
        "(case (ctor None) (const-int 3)))))))\n",
    ),
    (
        "integer literal pattern",
        "let entrypoint x = match x with 0 -> 10 | 1 -> 11 | _ -> 12\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (x) "
        "(match (var x) "
        "(case (const-pattern (const-int 0)) (const-int 10)) "
        "(case (const-pattern (const-int 1)) (const-int 11)) "
        "(case _ (const-int 12)))))))\n",
    ),
    (
        "string literal pattern",
        'let entrypoint s = match s with "hello" -> 1 | _ -> 0\n',
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (s) "
        "(match (var s) "
        '(case (const-pattern (const-string "hello")) (const-int 1)) '
        "(case _ (const-int 0)))))))\n",
    ),
    (
        "char literal pattern",
        "let entrypoint c = match c with 'a' -> 1 | _ -> 0\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (c) "
        "(match (var c) "
        "(case (const-pattern (const-char 97)) (const-int 1)) "
        "(case _ (const-int 0)))))))\n",
    ),
    (
        "or pattern literals",
        "let entrypoint x = match x with 0 | 1 | 2 -> 1 | _ -> 0\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (x) "
        "(match (var x) "
        "(case (or-pattern (const-pattern (const-int 0)) "
        "(const-pattern (const-int 1)) (const-pattern (const-int 2))) "
        "(const-int 1)) "
        "(case _ (const-int 0)))))))\n",
    ),
    (
        "or pattern with shared binding",
        "type t = A of int | B of int\nlet entrypoint x = match x with A n | B n -> n\n",
        "(zxcaml-cir 1.0 (module (type_decl (name t) (params) "
        "(variants ((A (payload_types (type-ref int))) "
        "(B (payload_types (type-ref int)))))) "
        "(let entrypoint (lambda (x) (match (var x) "
        "(case (or-pattern (ctor A (var n)) (ctor B (var n))) (var n)))))))\n",
    ),
    (
        "tuple alias pattern",
        "let entrypoint pair = match pair with (a, _) as whole -> a\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (pair) "
        "(match (var pair) "
        "(case (alias-pattern (tuple_pattern (var a) _) whole) (var a)))))))\n",
    ),
    (
        "nested alias pattern",
        "let entrypoint x = match x with Some (n as m) -> n + m | None -> 0\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (x) "
        "(match (var x) "
        "(case (ctor Some (alias-pattern (var n) m)) "
        "(prim \"+\" (var n) (var m))) "
        "(case (ctor None) (const-int 0)))))))\n",
    ),
    (
        "sequence expression desugars to let wildcard",
        'let entrypoint _ = Syscall.sol_log "one"; 2\n',
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        '(let _ (app (var Syscall.sol_log) (const-string "one")) '
        "(const-int 2))))))\n",
    ),
    (
        "if then without else desugars to unit else",
        'let entrypoint _ = if true then Syscall.sol_log "hit"\n',
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        '(if (ctor true) (app (var Syscall.sol_log) (const-string "hit")) '
        '(ctor "()"))))))\n',
    ),
    (
        "function cases desugar to lambda match",
        "let entrypoint x = (function Some v -> v | None -> 0) x\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (x) "
        "(app (lambda (param) (match (var param) "
        "(case (ctor Some (var v)) (var v)) "
        "(case (ctor None) (const-int 0)))) (var x))))))\n",
    ),
    (
        "multi argument function returning closure",
        "let make_op a b = fun x -> (x + a) * b\n",
        "(zxcaml-cir 1.0 (module (let make_op "
        "(lambda (a b) (lambda (x) "
        "(prim \"*\" (prim \"+\" (var x) (var a)) (var b)))))))\n",
    ),
    (
        "qualified stdlib module function reference",
        "let entrypoint _ = List.map (fun x -> x + 1) [1; 2; 3]\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        "(app (var List.map) (lambda (x) (prim \"+\" (var x) (const-int 1))) "
        "(ctor \"::\" (const-int 1) (ctor \"::\" (const-int 2) "
        "(ctor \"::\" (const-int 3) (ctor \"[]\")))))))))\n",
    ),
    (
        "stdlib Option.value uses bundled unlabeled signature",
        "let entrypoint _ = Option.value (Some 7) 3\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        "(app (var Option.value) (ctor Some (const-int 7)) (const-int 3))))))\n",
    ),
    (
        "stdlib Result.ok uses bundled function",
        "let entrypoint _ = Result.ok (Ok 7)\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        "(app (var Result.ok) (ctor Ok (const-int 7)))))))\n",
    ),
    (
        "stdlib Result.error uses bundled function",
        "let entrypoint _ = Result.error (Error 3)\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        "(app (var Result.error) (ctor Error (const-int 3)))))))\n",
    ),
    (
        "stdlib String.length uses bundled function",
        'let entrypoint _ = String.length "hello"\n',
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        '(app (var String.length) (const-string "hello"))))))\n',
    ),
    (
        "stdlib String.get uses bundled function",
        'let entrypoint _ = String.get "hello" 1\n',
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        '(app (var String.get) (const-string "hello") (const-int 1))))))\n',
    ),
    (
        "stdlib String.sub uses bundled function",
        'let entrypoint _ = String.sub "hello" 1 3\n',
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        '(app (var String.sub) (const-string "hello") (const-int 1) '
        "(const-int 3))))))\n",
    ),
    (
        "string concatenation operator uses bundled function",
        'let entrypoint _ = "hello" ^ " world"\n',
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        '(app (var "^") (const-string "hello") (const-string " world"))))))\n',
    ),
    (
        "stdlib Char.code lowers char literal to int",
        "let entrypoint _ = Char.code 'a'\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        "(app (var Char.code) (const-int 97))))))\n",
    ),
    (
        "stdlib Char.chr uses bundled function",
        "let entrypoint _ = Char.chr 97\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        "(app (var Char.chr) (const-int 97))))))\n",
    ),
    (
        "char comparison lowers char literals to ints",
        "let entrypoint _ = 'a' < 'b'\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        '(prim "<" (const-int 97) (const-int 98))))))\n',
    ),
    (
        "tuple construction",
        "let entrypoint _ = (1, true, 42)\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        "(tuple (items (const-int 1) (ctor true) (const-int 42)))))))\n",
    ),
    (
        "tuple projection",
        "let entrypoint _ = let t = (1, 2) in fst t\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        "(let t (tuple (items (const-int 1) (const-int 2))) "
        "(tuple_project (var t) (index 0)))))))\n",
    ),
    (
        "tuple type declaration",
        "type pair = int * bool\nlet entrypoint _ = 0\n",
        "(zxcaml-cir 1.0 (module "
        "(tuple_type_decl (name pair) (params) "
        "(items (type-ref int) (type-ref bool))) "
        "(let entrypoint (lambda (_) (const-int 0)))))\n",
    ),
    (
        "record construction",
        "type person = { name : string; age : int }\n"
        "let entrypoint _ = { name = \"alice\"; age = 30 }\n",
        "(zxcaml-cir 1.0 (module "
        "(record_type_decl (name person) (params) "
        "(fields ((name (type-ref string)) (age (type-ref int))))) "
        "(let entrypoint (lambda (_) "
        "(record (fields ((name (const-string \"alice\")) (age (const-int 30)))))))))\n",
    ),
    (
        "record account attribute sexp",
        "type counter = { count : int } [@@account]\nlet entrypoint _ = 0\n",
        "(zxcaml-cir 1.0 (module "
        "(record_type_decl (name counter) (params) "
        "(fields ((count (type-ref int)))) (account_attr)) "
        "(let entrypoint (lambda (_) (const-int 0)))))\n",
    ),
    (
        "record field access",
        "type person = { name : string; age : int }\n"
        "let entrypoint _ = let r = { name = \"alice\"; age = 30 } in r.name\n",
        "(zxcaml-cir 1.0 (module "
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
        "(zxcaml-cir 1.0 (module "
        "(record_type_decl (name person) (params) "
        "(fields ((name (type-ref string)) (age (type-ref int))))) "
        "(let entrypoint (lambda (_) "
        "(let r (record (fields ((name (const-string \"alice\")) (age (const-int 30))))) "
        "(record_update (var r) (fields ((age (const-int 31))))))))))\n",
    ),
    (
        "builtin account field access emits account record type",
        "let entrypoint account = account.lamports\n",
        "(zxcaml-cir 1.0 (module "
        "(record_type_decl (name account) (params) "
        "(fields ((key (type-ref bytes)) (lamports (type-ref int)) "
        "(data (type-ref bytes)) (owner (type-ref bytes)) "
        "(is_signer (type-ref bool)) (is_writable (type-ref bool)) "
        "(executable (type-ref bool))))) "
        "(let entrypoint (lambda (account) "
        "(field_access (var account) lamports)))))\n",
    ),
    (
        "account type reference in user record emits account type",
        "type holder = { account : account }\nlet entrypoint holder = holder.account.lamports\n",
        "(zxcaml-cir 1.0 (module "
        "(record_type_decl (name account) (params) "
        "(fields ((key (type-ref bytes)) (lamports (type-ref int)) "
        "(data (type-ref bytes)) (owner (type-ref bytes)) "
        "(is_signer (type-ref bool)) (is_writable (type-ref bool)) "
        "(executable (type-ref bool))))) "
        "(record_type_decl (name holder) (params) "
        "(fields ((account (type-ref account))))) "
        "(let entrypoint (lambda (holder) "
        "(field_access (field_access (var holder) account) lamports)))))\n",
    ),
    (
        "syscall function reference",
        "let entrypoint message = Syscall.sol_log message\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (message) "
        "(app (var Syscall.sol_log) (var message))))))\n",
    ),
    (
        "external declaration sexp",
        'external sol_log : bytes -> unit = "sol_log_"\n',
        '(zxcaml-cir 1.0 (module (external (name "sol_log") '
        '(type (arrow bytes unit)) (symbol "sol_log_"))))\n',
    ),
    (
        "multiple external declarations sexp",
        (
            'external sol_log : string -> unit = "sol_log_"\n'
            'external sol_log_64 : int -> int -> int -> int -> int -> unit = "sol_log_64_"\n'
        ),
        '(zxcaml-cir 1.0 (module (external (name "sol_log") '
        '(type (arrow string unit)) (symbol "sol_log_")) '
        '(external (name "sol_log_64") '
        '(type (arrow int (arrow int (arrow int (arrow int (arrow int unit)))))) '
        '(symbol "sol_log_64_"))))\n',
    ),
    (
        "pubkey hex literal emits raw bytes",
        "let entrypoint _ = Pubkey.of_hex "
        '"4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60"\n',
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        '(const-string "ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\\\]^_`")))))\n',
    ),
    (
        "zero argument syscall unit application",
        "let entrypoint _ = Syscall.sol_remaining_compute_units ()\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        "(app (var Syscall.sol_remaining_compute_units) (ctor \"()\"))))))\n",
    ),
    (
        "clock syscall field access emits clock record type",
        "let entrypoint _ = (Syscall.sol_get_clock_sysvar ()).slot\n",
        "(zxcaml-cir 1.0 (module "
        "(record_type_decl (name clock) (params) "
        "(fields ((slot (type-ref int)) (epoch_start_timestamp (type-ref int)) "
        "(epoch (type-ref int)) (leader_schedule_epoch (type-ref int)) "
        "(unix_timestamp (type-ref int))))) "
        "(let entrypoint (lambda (_) "
        "(field_access (app (var Syscall.sol_get_clock_sysvar) (ctor \"()\")) slot)))))\n",
    ),
    (
        "builtin account_meta type reference emits account_meta record type",
        "type holder = { meta : account_meta }\nlet entrypoint holder = holder.meta.pubkey\n",
        "(zxcaml-cir 1.0 (module "
        "(record_type_decl (name account_meta) (params) "
        "(fields ((pubkey (type-ref bytes)) (is_writable (type-ref bool)) "
        "(is_signer (type-ref bool))))) "
        "(record_type_decl (name holder) (params) "
        "(fields ((meta (type-ref account_meta))))) "
        "(let entrypoint (lambda (holder) "
        "(field_access (field_access (var holder) meta) pubkey)))))\n",
    ),
    (
        "builtin instruction field access emits instruction and account_meta types",
        "let entrypoint ix = ix.program_id\n",
        "(zxcaml-cir 1.0 (module "
        "(record_type_decl (name account_meta) (params) "
        "(fields ((pubkey (type-ref bytes)) (is_writable (type-ref bool)) "
        "(is_signer (type-ref bool))))) "
        "(record_type_decl (name instruction) (params) "
        "(fields ((program_id (type-ref bytes)) "
        "(accounts (type-ref array (type-ref account_meta))) "
        "(data (type-ref bytes))))) "
        "(let entrypoint (lambda (ix) (field_access (var ix) program_id)))))\n",
    ),
    (
        "cpi invoke function reference",
        "let entrypoint ix = invoke ix\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (ix) "
        "(app (var invoke) (var ix))))))\n",
    ),
    (
        "cpi invoke_signed function reference",
        "let entrypoint ix seeds = invoke_signed ix seeds\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (ix seeds) "
        "(app (var invoke_signed) (var ix) (var seeds))))))\n",
    ),
    (
        "cpi create_program_address function reference",
        "let entrypoint seeds program_id = create_program_address seeds program_id\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (seeds program_id) "
        "(app (var create_program_address) (var seeds) (var program_id))))))\n",
    ),
    (
        "cpi try_find_program_address function reference",
        "let entrypoint seeds program_id = try_find_program_address seeds program_id\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (seeds program_id) "
        "(app (var try_find_program_address) (var seeds) (var program_id))))))\n",
    ),
    (
        "error type reference emits structured error record type",
        "type holder = { err : error }\nlet entrypoint holder = holder.err.code\n",
        "(zxcaml-cir 1.0 (module "
        "(record_type_decl (name error) (params) "
        "(fields ((program_id_index (type-ref int)) (code (type-ref int))))) "
        "(record_type_decl (name holder) (params) "
        "(fields ((err (type-ref error))))) "
        "(let entrypoint (lambda (holder) "
        "(field_access (field_access (var holder) err) code)))))\n",
    ),
    (
        "structured error make and return encoding",
        "let entrypoint _ = let err = Error.make 0x12 0x34 in Error.encode err\n",
        "(zxcaml-cir 1.0 (module "
        "(record_type_decl (name error) (params) "
        "(fields ((program_id_index (type-ref int)) (code (type-ref int))))) "
        "(let entrypoint (lambda (_) "
        "(let err (record (fields ((program_id_index (const-int 18)) (code (const-int 52))))) "
        "(prim \"+\" (prim \"*\" (field_access (var err) program_id_index) (const-int 256)) "
        "(field_access (var err) code)))))))\n",
    ),
    (
        "structured error direct encoding",
        "let entrypoint _ = Error.encode_code 0x12 0x34\n",
        "(zxcaml-cir 1.0 (module (let entrypoint (lambda (_) "
        "(prim \"+\" (prim \"*\" (const-int 18) (const-int 256)) (const-int 52))))))\n",
    ),
]


TOO_MANY_ERROR_CONSTRUCTORS = (
    "type error = "
    + " | ".join(f"E{i}" for i in range(257))
    + "\nlet entrypoint _ = 0\n"
)


REJECT_CASES: list[tuple[str, str, str]] = [
    (
        "error code rejects values above 255",
        "let entrypoint _ = Error.encode_code 0 256\n",
        "program-specific error codes must be integer values in the 0-255 range",
    ),
    (
        "error enum rejects payload constructors",
        "type error = Bad of int\nlet entrypoint _ = 0\n",
        "program-specific error enum constructors must not carry payloads",
    ),
    (
        "error enum rejects more than 256 constructors",
        TOO_MANY_ERROR_CONSTRUCTORS,
        "program-specific error enums may define at most 256 codes",
    ),
    (
        "pubkey hex rejects non literal",
        "let entrypoint hex = Pubkey.of_hex hex\n",
        "Pubkey.of_hex requires a hex string literal argument",
    ),
    (
        "pubkey hex rejects wrong length",
        'let entrypoint _ = Pubkey.of_hex "00"\n',
        "Pubkey.of_hex requires exactly 64 hexadecimal characters",
    ),
    (
        "pubkey hex rejects non hex characters",
        'let entrypoint _ = Pubkey.of_hex "000000000000000000000000000000000000000000000000000000000000000g"\n',
        "Pubkey.of_hex requires only hexadecimal characters",
    ),
    (
        "external rejects undefined type",
        'external bad : missing_type -> unit = "bad_symbol"\n',
        'Unbound type constructor \\"missing_type\\"',
    ),
    (
        "external rejects missing symbol string",
        "external bad : int -> unit\n",
        "Syntax error",
    ),
    (
        "external rejects empty symbol",
        'external bad : int -> unit = ""\n',
        "external declarations require a non-empty symbol string",
    ),
    (
        "or pattern rejects incompatible bindings",
        "let entrypoint x = match x with Some a | None -> a\n",
        'Variable \\"a\\" must occur on both sides of this \\"|\\" pattern',
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


def run_reject_case(
    tmp_dir: pathlib.Path, name: str, source: str, expected_message: str
) -> bool:
    path = tmp_dir / (name.replace(" ", "_").replace("-", "_") + ".ml")
    path.write_text(source, encoding="utf-8")

    result = subprocess.run(
        [str(FRONTEND_BIN), "--emit=sexp", str(path)],
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode == 0:
        print(f"FAIL {name}: frontend unexpectedly succeeded", file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        return False
    if expected_message not in result.stderr:
        print(f"FAIL {name}: stderr mismatch", file=sys.stderr)
        print(f"expected substring: {expected_message!r}", file=sys.stderr)
        print(f"actual stderr:       {result.stderr!r}", file=sys.stderr)
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
        passed.extend(run_reject_case(tmp_dir, *case) for case in REJECT_CASES)
    return 0 if all(passed) else 1


if __name__ == "__main__":
    raise SystemExit(main())
