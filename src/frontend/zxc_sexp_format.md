# ZxCaml frontend S-expression wire format v0.1

`zxc-frontend --emit=sexp <input.ml>` emits exactly one S-expression on
stdout.  Version `0.1` is the M0 bootstrap format and intentionally supports
only one shape: top-level `let` declarations whose right-hand side is a
one-argument function returning an integer constant.

## Grammar

```text
module      ::= "(" "zxcaml-cir" "0.1" "(" "module" decl* ")" ")"
decl        ::= "(" "let" ident lambda ")"
lambda      ::= "(" "lambda" "(" "_" ")" const_int ")"
const_int   ::= "(" "const-int" integer ")"
ident       ::= atom | quoted-string
integer     ::= OCaml Const_int rendered in decimal
```

Whitespace may appear between nodes.  Atoms currently use OCaml value names
when they are safe S-expression atoms; other names are quoted as strings.

## Example

For:

```ocaml
let entrypoint _input = 0
```

the frontend prints:

```text
(zxcaml-cir 0.1 (module (let entrypoint (lambda (_) (const-int 0)))))
```

## Diagnostic schema

Unsupported M0 programs exit non-zero and write one JSON object per line on
stderr:

```json
{"severity":"error","code":"M0-UNSUPPORTED","message":"...","node_kind":"Texp_apply","loc":{"file":"examples/m0_unsupported.ml","line":1,"col":8,"end_line":1,"end_col":13}}
```

Locations are 1-indexed lines and 0-indexed columns, matching OCaml
`Lexing.position` (`pos_cnum - pos_bol`).
