# ZxCaml frontend S-expression wire format v0.2

`zxc-frontend --emit=sexp <input.ml>` emits exactly one S-expression on
stdout.  Version `0.2` is the first M1 widening of the bootstrap format.  It
supports top-level `let` declarations whose right-hand side is an integer
constant, a one-argument function, an identifier, or a non-recursive nested
`let` expression composed from those same expression forms.

## Grammar

```text
module      ::= "(" "zxcaml-cir" "0.2" "(" "module" decl* ")" ")"
decl        ::= "(" "let" ident expr ")"
expr        ::= const_int | var | lambda | let_expr
const_int   ::= "(" "const-int" integer ")"
var         ::= "(" "var" ident ")"
lambda      ::= "(" "lambda" "(" "_" ")" expr ")"
let_expr    ::= "(" "let" ident expr expr ")"
ident       ::= atom | quoted-string
integer     ::= OCaml Const_int rendered in decimal
```

Whitespace may appear between nodes.  Atoms currently use OCaml value names
when they are safe S-expression atoms; other names are quoted as strings.

## Examples

For:

```ocaml
let entrypoint _input = 0
```

the frontend prints:

```text
(zxcaml-cir 0.2 (module (let entrypoint (lambda (_) (const-int 0)))))
```

For a top-level value referenced from a function:

```ocaml
let x = 1
let entrypoint _input = x
```

the frontend prints:

```text
(zxcaml-cir 0.2 (module (let x (const-int 1)) (let entrypoint (lambda (_) (var x)))))
```

For nested lets:

```ocaml
let entrypoint _input =
  let x = 5 in
  let y = 7 in
  x
```

the frontend prints:

```text
(zxcaml-cir 0.2 (module (let entrypoint (lambda (_) (let x (const-int 5) (let y (const-int 7) (var x)))))))
```

## Version compatibility

Version `0.1` is deliberately deprecated by the OCaml frontend once F09 lands:
new `zxc-frontend` binaries emit `0.2`.  Downstream consumers should reject
`0.1` with an upgrade hint rather than silently treating it as equivalent,
because `0.2` adds new expression nodes (`var` and nested `let`) and permits
non-lambda top-level bindings.

## Diagnostic schema

Unsupported programs exit non-zero and write one JSON object per line on
stderr:

```json
{"severity":"error","code":"M0-UNSUPPORTED","message":"...","node_kind":"Texp_apply","loc":{"file":"examples/m0_unsupported.ml","line":1,"col":8,"end_line":1,"end_col":13}}
```

Locations are 1-indexed lines and 0-indexed columns, matching OCaml
`Lexing.position` (`pos_cnum - pos_bol`).
