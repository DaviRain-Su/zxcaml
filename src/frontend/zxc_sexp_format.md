# ZxCaml frontend S-expression wire format

`zxc-frontend --emit=sexp <input.ml>` emits exactly one S-expression on
stdout. The current default wire is `1.6`. The grammar below records the
historical `0.5` base (user-authored ADT type declarations over the P1
expression/match nodes), followed by additive notes for the later `1.x` wire
bumps, including the current `1.5` ref-cell shapes.

## Grammar

```text
module       ::= "(" "zxcaml-cir" "0.5" "(" "module" decl* ")" ")"
decl         ::= let_decl | type_decl
let_decl     ::= "(" "let" ident expr ")"
type_decl    ::= "(" "type_decl" "(" "name" ident ")"
                "(" "params" ident* ")"
                ["(" "recursive" "true" ")"]
                "(" "variants" "(" variant* ")" ")" ")"
variant      ::= "(" ident "(" "payload_types" type_expr* ")" ")"
type_expr    ::= "(" "type-var" ident ")"
               | "(" "type-ref" ident type_expr* ")"
               | "(" "recursive-ref" ident type_expr* ")"
               | "(" "tuple-type" type_expr+ ")"
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
(zxcaml-cir 0.5 (module (let entrypoint (lambda (_) (const-int 0)))))
```

For a top-level value referenced from a function:

```ocaml
let x = 1
let entrypoint _input = x
```

the frontend prints:

```text
(zxcaml-cir 0.5 (module (let x (const-int 1)) (let entrypoint (lambda (_) (var x)))))
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
(zxcaml-cir 0.5 (module (let entrypoint (lambda (_) (let x (const-int 5) (let y (const-int 7) (var x)))))))
```

For `None`:

```ocaml
let value = None
```

the frontend prints:

```text
(zxcaml-cir 0.5 (module (let value (ctor None))))
```

For `Some 1`:

```ocaml
let value = Some 1
```

the frontend prints:

```text
(zxcaml-cir 0.5 (module (let value (ctor Some (const-int 1)))))
```

For `Ok 0`:

```ocaml
let value = Ok 0
```

the frontend prints:

```text
(zxcaml-cir 0.5 (module (let value (ctor Ok (const-int 0)))))
```

For `Error "oops"`:

```ocaml
let value = Error "oops"
```

the frontend prints:

```text
(zxcaml-cir 0.5 (module (let value (ctor Error (const-string "oops")))))
```

For the list literal `[1; 2]`:

```ocaml
let value = [1; 2]
```

the frontend prints:

```text
(zxcaml-cir 0.5 (module (let value (ctor "::" (const-int 1) (ctor "::" (const-int 2) (ctor "[]"))))))
```

For wildcard let-bindings:

```ocaml
let entrypoint _input =
  let _ = Some 1 in
  0
```

the frontend prints:

```text
(zxcaml-cir 0.5 (module (let entrypoint (lambda (_) (let _ (ctor Some (const-int 1)) (const-int 0))))))
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
(zxcaml-cir 0.5 (module (let entrypoint (lambda (_) (match (ctor Some (const-int 1)) (case (ctor Some (var x)) (var x)) (case (ctor None) (const-int 0)))))))
```

For a wildcard arm:

```ocaml
let entrypoint _ =
  match None with
  | _ -> 0
```

the frontend prints:

```text
(zxcaml-cir 0.5 (module (let entrypoint (lambda (_) (match (ctor None) (case _ (const-int 0)))))))
```

For a variable-binding arm:

```ocaml
let entrypoint _ =
  match Some 7 with
  | value -> 1
```

the frontend prints:

```text
(zxcaml-cir 0.5 (module (let entrypoint (lambda (_) (match (ctor Some (const-int 7)) (case (var value) (const-int 1)))))))
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

Versions `0.1`, `0.2`, `0.3`, and `0.4` are deliberately deprecated by the OCaml
frontend once F25 lands: new `zxc-frontend` binaries emit `0.5`. Downstream consumers
should reject older versions with an upgrade hint rather than silently treating
them as equivalent, because `0.5` adds user-authored ADT type declarations.

The wire major has since advanced through `1.0`, `1.1`, `1.2`, `1.3`, `1.4`,
and (as of R10) `1.5`. See `docs/wire-compat.md` for the binding
cross-version compatibility matrix. In summary:

- `1.5` (current default): adds `ref` cell sexps (`ref-make`, `ref-get`,
  `ref-set`) for ADR-015 option C. See the "Wire 1.5 — ref cells" section
  below.
- `1.4`: prior wire major; `1.5` is a strict additive extension.
- `1.3`: lambda and `let rec` parameters carry an inferred per-parameter
  OCaml type as `(name (ty <type-expr>))`. Unresolved types use the
  `(any)` sentinel.
- `1.2`: optional `(loc ...)` location metadata on expression nodes; lambda
  params stay as bare-atom names. The current `1.5` reader still accepts
  `1.2` sexps.
- `1.1` and earlier: legacy compatibility window kept alive via
  `omlz check --wire=1.1` / `--wire=1.2` for one mission's deprecation
  cycle.

## Wire 1.5 — ref cells

ADR-015 option C (R10) introduces three sexp shapes for OCaml `ref`
cells. Element type metadata is carried as an inline `(ty <type-expr>)`
annotation on the `ref-make` form so consumers can reject unsupported
element types at sexp parse time.

```text
ref_make_expr ::= "(" "ref-make" "(" "ty" type_expr ")" expr ")"
ref_get_expr  ::= "(" "ref-get" expr ")"
ref_set_expr  ::= "(" "ref-set" expr expr ")"
```

The accepted element types are `(type-ref int)` and `(type-ref bool)`;
other `type_expr` shapes are rejected by the subset walker with
`E0013` ("this `ref` element type is not part of the ZxCaml subset
(R10)").

Examples:

```ocaml
let entrypoint _ =
  let r = ref 10 in
  let _ = r := 25 in
  !r
```

emits (with locations elided for brevity):

```text
(zxcaml-cir 1.5 (module (let entrypoint
  (lambda ((_ (ty (type-ref unit))))
    (let r (ref-make (ty (type-ref int)) (const-int 10))
      (let _ (ref-set (var r) (const-int 25))
        (ref-get (var r))))))))
```

`ref-make` is the single allocation site (one slot per call); `no_alloc`
flags it as `DX2-NOALLOC`. `ref-get` and `ref-set` are allocation-free
load/store operations.

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
