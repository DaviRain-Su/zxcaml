# ZxCaml frontend S-expression wire format v0.4

`zxc-frontend --emit=sexp <input.ml>` emits exactly one S-expression on
stdout. Version `0.4` widens the M1 format with basic pattern matching over
values and match patterns for wildcard, variable binding, and the whitelisted
option/result/list constructors.

## Grammar

```text
module       ::= "(" "zxcaml-cir" "0.4" "(" "module" decl* ")" ")"
decl         ::= "(" "let" ident expr ")"
expr         ::= const_int | const_string | var | lambda | let_expr | ctor | match_expr
const_int    ::= "(" "const-int" integer ")"
const_string ::= "(" "const-string" quoted-string ")"
var          ::= "(" "var" ident ")"
lambda       ::= "(" "lambda" "(" "_" ")" expr ")"
let_expr     ::= "(" "let" ident expr expr ")"
ctor         ::= "(" "ctor" ctor_name expr* ")"
match_expr   ::= "(" "match" value_expr case+ ")"
case         ::= "(" "case" pattern expr ")"
pattern      ::= "_" | "(" "var" ident ")" | "(" "ctor" ctor_name pattern* ")"
value_expr   ::= const_int | var | "(" "ctor" ctor_name value_expr* ")"
ctor_name    ::= "None" | "Some" | "Ok" | "Error" | "[]" | "::"
ident        ::= atom | quoted-string
integer      ::= OCaml Const_int rendered in decimal
quoted-string ::= OCaml string literal syntax
```

Whitespace may appear between nodes.  Atoms currently use OCaml value names
when they are safe S-expression atoms; other names are quoted as strings.
Constructor names are emitted verbatim using the OCaml constructor identifier;
list constructor names are quoted as needed by the atom syntax (for example
`"[]"` and `"::"`).

## Examples

For:

```ocaml
let entrypoint _input = 0
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let entrypoint (lambda (_) (const-int 0)))))
```

For a top-level value referenced from a function:

```ocaml
let x = 1
let entrypoint _input = x
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let x (const-int 1)) (let entrypoint (lambda (_) (var x)))))
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
(zxcaml-cir 0.4 (module (let entrypoint (lambda (_) (let x (const-int 5) (let y (const-int 7) (var x)))))))
```

For `None`:

```ocaml
let value = None
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let value (ctor None))))
```

For `Some 1`:

```ocaml
let value = Some 1
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let value (ctor Some (const-int 1)))))
```

For `Ok 0`:

```ocaml
let value = Ok 0
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let value (ctor Ok (const-int 0)))))
```

For `Error "oops"`:

```ocaml
let value = Error "oops"
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let value (ctor Error (const-string "oops")))))
```

For the list literal `[1; 2]`:

```ocaml
let value = [1; 2]
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let value (ctor "::" (const-int 1) (ctor "::" (const-int 2) (ctor "[]"))))))
```

For wildcard let-bindings:

```ocaml
let entrypoint _input =
  let _ = Some 1 in
  0
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let entrypoint (lambda (_) (let _ (ctor Some (const-int 1)) (const-int 0))))))
```

For a `Some` arm and a `None` arm:

```ocaml
let entrypoint _ =
  match Some 1 with
  | Some x -> x
  | None -> 0
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let entrypoint (lambda (_) (match (ctor Some (const-int 1)) (case (ctor Some (var x)) (var x)) (case (ctor None) (const-int 0)))))))
```

For a wildcard arm:

```ocaml
let entrypoint _ =
  match None with
  | _ -> 0
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let entrypoint (lambda (_) (match (ctor None) (case _ (const-int 0)))))))
```

For a variable-binding arm:

```ocaml
let entrypoint _ =
  match Some 7 with
  | value -> 1
```

the frontend prints:

```text
(zxcaml-cir 0.4 (module (let entrypoint (lambda (_) (match (ctor Some (const-int 7)) (case (var value) (const-int 1)))))))
```

For list pattern matching:

```ocaml
let head xs =
  match xs with
  | [] -> None
  | x :: _ -> Some x
```

the match arms include the built-in list constructors:

```text
(match (var xs) (case (ctor "[]") (ctor None)) (case (ctor "::" (var x) _) (ctor Some (var x))))
```

## Version compatibility

Versions `0.1`, `0.2`, and `0.3` are deliberately deprecated by the OCaml
frontend once F11 lands: new `zxc-frontend` binaries emit `0.4`. Downstream consumers
should reject older versions with an upgrade hint rather than silently treating
them as equivalent, because `0.4` adds match expressions and pattern nodes.

## Diagnostic schema

Unsupported programs exit non-zero and write one JSON object per line on
stderr. Diagnostics are deliberately hand-serialized by the OCaml frontend
without a JSON library. The required fields are:

```text
{
  "file": string,
  "line": integer,      // 1-indexed
  "col": integer,       // 0-indexed
  "severity": "error" | "warn" | "info",
  "message": string,
  "node_kind": string?, // Typedtree node name, when applicable
  "hint": string?       // optional remediation text
}
```

Example:

```json
{"file":"examples/m0_unsupported.ml","line":1,"col":8,"severity":"error","message":"mutation (ref) is not supported in P1","node_kind":"Texp_apply","hint":"ZxCaml P1 is arena-only and does not support OCaml refs or mutable updates"}
```

Syntax and type errors reported by upstream `ocamlc` are converted into the
same line-delimited JSON shape, using `node_kind: "ocamlc"`.
