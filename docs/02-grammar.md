# 02 — Grammar (OCaml subset for P1)

> **Languages / 语言**: **English** · [简体中文](./zh/02-grammar.md)

## 1. Position

ZxCaml accepts a **strict subset of OCaml**. Anything accepted by
ZxCaml is parsed and type-checked by upstream OCaml first; ZxCaml
then rejects unsupported `Typedtree` nodes.

As built in P1, the user-program subset is intentionally small:
**top-level `let` declarations plus expressions over integers,
strings, functions, `let`, `if`, `match`, applications, primitive
integer/comparison operators, and the bundled `option` / `result` /
`list` constructors.** User-defined `type` declarations, records, tuples,
modules, exceptions, mutation, arrays, objects, and labels are rejected.

The authoritative implementation is `src/frontend/zxc_subset.ml`; the
wire contract emitted by the accepted subset is
`src/frontend/zxc_sexp_format.md` (currently `0.4`). This document is
only the human-readable surface summary.

File extension is `.ml`. There is no `.mli` support in P1.

## 2. Lexical rules

Lexing is OCaml's lexer. The P1 subset consumes only:

- decimal `int` literals (`0`, `42`, `-1`), represented as signed
  64-bit integers below the frontend;
- string literals, mainly for diagnostics and small examples;
- identifiers accepted by OCaml;
- constructor names from the bundled stdlib: `None`, `Some`, `Ok`,
  `Error`, `[]`, and `::`.

Direct boolean literals are not a separate frontend special case in P1;
comparisons produce the internal bool ADT consumed by `if`.

## 3. Surface forms accepted in P1

```ocaml
(* top-level declarations: one binding per let group *)
let x = 1
let rec fact n = if n <= 1 then 1 else n * fact (n - 1)

(* expressions *)
let entrypoint _input =
  let xs = [1; 2; 3] in
  match xs with
  | [] -> 0
  | x :: _ -> x
```

Accepted expression classes:

| Surface form | Notes |
|---|---|
| `let x = e` / `let rec f x = e` | top-level and nested; no `and` groups |
| `fun x -> e` / function-sugar lets | exactly one parameter per lambda after desugaring |
| variable reference | identifiers resolved by OCaml before serialisation |
| integer and string constants | other constants rejected |
| function application | unlabeled, fully-applied arguments only |
| `if c then a else b` | `else` is required |
| `match e with ...` | no guards; arms evaluated top-to-bottom |
| constructors | `None`, `Some`, `Ok`, `Error`, `[]`, `::` only |
| primitive ops | `+`, `-`, `*`, `/`, `mod`, `=`, `<>`, `<`, `<=`, `>`, `>=` |

Accepted patterns:

| Pattern | Notes |
|---|---|
| `_` | wildcard |
| `x` | variable binder |
| `None`, `Some x`, `Ok x`, `Error e`, `[]`, `x :: xs` | constructor patterns with simple wildcard/variable payloads in P1 |

Nested constructor patterns such as `Some (Some x)` and guarded arms
(`when`) are P2+.

## 4. Reserved but rejected in P1

The OCaml parser may accept the syntax, but the subset walker rejects
these forms with location-aware diagnostics:

```text
type  module  sig  struct  functor  open  include
exception  try  raise
mutable  ref  while  for  do  done
class  object  method  inherit  initializer
lazy  assert  external  when
records  tuples  arrays  labelled arguments  optional arguments
```

## 5. Standard library types visible to P1 programs

The bundled stdlib (`stdlib/core.ml`) defines:

```ocaml
type 'a option = None | Some of 'a
type ('a, 'e) result = Ok of 'a | Error of 'e
type 'a list = [] | (::) of 'a * 'a list
```

User programs may construct and match these values. They may not yet
introduce their own ADTs; that is P2+ roadmap work.

## 6. Diagnostics for rejected OCaml constructs

Two layers exist:

1. **Syntax/type errors** are reported by upstream `ocamlc`, captured
   by `zxc-frontend`, and emitted as the same flat JSON diagnostic
   shape used for subset errors.
2. **Subset violations** are detected by `zxc-frontend` walking the
   `Typedtree` and include the unsupported node kind plus a hint when
   one is known.

Rendered by `omlz`, a subset violation looks like:

```text
foo.ml:1:0: error: Tstr_type is not supported in the current ZxCaml subset; expected top-level `let` declarations ...
```

## 7. Compatibility check

Because `omlz` obtains its input from upstream OCaml `compiler-libs`,
accepted programs are valid OCaml by construction. CI still checks the
examples corpus through `omlz check`; the diagnostic fixture
`examples/m0_unsupported.ml` is intentionally skipped by that corpus
loop because it is expected to fail.
