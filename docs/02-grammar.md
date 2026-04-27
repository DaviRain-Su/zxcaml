# 02 — Grammar (OCaml subset for P1)

## 1. Position

ZxCaml accepts a **strict subset of OCaml**. Anything written in
ZxCaml is valid OCaml; the converse does not hold. We use this
property to type-check the stdlib with the real OCaml compiler as a
sanity oracle.

File extension is `.ml`. There is **no** `.mli` in P1; signatures may
appear inline as type annotations.

## 2. Lexical rules

Identical to OCaml's lexical specification, restricted to:

- ASCII source only (UTF-8 string literals are allowed but not
  identifier characters).
- Comments: `(* ... *)`, nestable.
- Numeric literals: decimal `int` (`0`, `42`, `-1`), no `Int64.t`,
  no float in P1.
- Boolean literals: `true`, `false`.
- String literals: standard double-quoted, with `\n \r \t \\ \"`
  escapes only. **Used for diagnostics / stdlib only in P1; runtime
  string ops are not exposed.**
- Char literals: not in P1.
- Identifiers: lowercase-leading (values), uppercase-leading
  (constructors and module names — module names are reserved but
  module syntax is P3).

## 3. Reserved keywords accepted in P1

```
let  rec  and  in  fun  function
match  with  if  then  else
type  of
true  false
```

Reserved but **rejected** in P1 (parser must produce a clear "not
yet supported" diagnostic, not a syntax error):

```
module  sig  struct  functor  open  include
exception  try  raise
mutable  ref  while  for  do  done
class  object  method  inherit  initializer
lazy  assert
external
when
```

## 4. Grammar (EBNF, P1)

The non-terminals below define **exactly** what the P1 parser
accepts. Future phases extend this grammar, but never break it.

```ebnf
program        ::= { top_item } EOF

top_item       ::= type_decl
                 | let_binding

(* ───── type declarations ───── *)

type_decl      ::= "type" [ type_params ] LIDENT "=" type_rhs

type_params    ::= "'" LIDENT
                 | "(" "'" LIDENT { "," "'" LIDENT } ")"

type_rhs       ::= variant_rhs
                 | record_rhs
                 | type_expr                      (* alias *)

variant_rhs    ::= [ "|" ] variant_case { "|" variant_case }
variant_case   ::= UIDENT [ "of" type_expr_tuple ]

record_rhs     ::= "{" field_decl { ";" field_decl } [ ";" ] "}"
field_decl     ::= LIDENT ":" type_expr

(* ───── type expressions ───── *)

type_expr      ::= type_expr_tuple

type_expr_tuple::= type_expr_arrow { "*" type_expr_arrow }

type_expr_arrow::= type_expr_app { "->" type_expr_app }   (* right-assoc *)

type_expr_app  ::= type_atom { type_atom }                (* postfix application: 'a list *)

type_atom      ::= "'" LIDENT
                 | LIDENT                                 (* type constructor *)
                 | "(" type_expr ")"

(* ───── value declarations ───── *)

let_binding    ::= "let" [ "rec" ] binding_chain
binding_chain  ::= binding { "and" binding }
binding        ::= pattern { param } [ ":" type_expr ] "=" expr
                                                          (* function sugar:
                                                             let f x y = e
                                                             ≡ let f = fun x -> fun y -> e *)

param          ::= simple_pattern

(* ───── expressions ───── *)

expr           ::= "let" [ "rec" ] binding_chain "in" expr
                 | "fun" param { param } "->" expr
                 | "function" match_arms
                 | "if" expr "then" expr [ "else" expr ]
                 | "match" expr "with" match_arms
                 | infix_expr

match_arms     ::= [ "|" ] match_arm { "|" match_arm }
match_arm      ::= pattern [ "when" expr ]   (* P1: rejects "when" with diagnostic *)
                   "->" expr

infix_expr     ::= app_expr { binop app_expr }

binop          ::= "+" | "-" | "*" | "/" | "mod"
                 | "=" | "<>" | "<" | "<=" | ">" | ">="
                 | "&&" | "||"
                 | "::"                                   (* list cons *)

app_expr       ::= simple_expr { simple_expr }            (* left-assoc juxtaposition *)

simple_expr    ::= LIDENT
                 | UIDENT [ simple_expr ]                 (* constructor application *)
                 | INT_LIT
                 | "true" | "false"
                 | STRING_LIT
                 | "(" ")"                                (* unit *)
                 | "(" expr { "," expr } ")"              (* parenthesised / tuple *)
                 | "[" [ expr { ";" expr } [ ";" ] ] "]"  (* list literal *)
                 | "{" record_field_init { ";" record_field_init } [ ";" ] "}"
                 | simple_expr "." LIDENT                 (* record projection *)

record_field_init ::= LIDENT "=" expr

(* ───── patterns ───── *)

pattern        ::= or_pattern
or_pattern     ::= cons_pattern { "|" cons_pattern }
cons_pattern   ::= app_pattern { "::" app_pattern }       (* right-assoc *)
app_pattern    ::= UIDENT [ simple_pattern ]
                 | simple_pattern

simple_pattern ::= "_"
                 | LIDENT                                 (* binder *)
                 | UIDENT                                 (* nullary ctor *)
                 | INT_LIT
                 | "true" | "false"
                 | "(" ")"
                 | "(" pattern { "," pattern } ")"
                 | "[" [ pattern { ";" pattern } [ ";" ] ] "]"
                 | "{" field_pattern { ";" field_pattern } [ ";" ] "}"

field_pattern  ::= LIDENT [ "=" pattern ]
```

## 5. Operator precedence (P1)

From lowest to highest:

| Level | Operators | Associativity |
|---|---|---|
| 1 | `||` | right |
| 2 | `&&` | right |
| 3 | `=`, `<>`, `<`, `<=`, `>`, `>=` | left |
| 4 | `::` | right |
| 5 | `+`, `-` | left |
| 6 | `*`, `/`, `mod` | left |
| 7 | function application | left |
| 8 | `.field` | postfix |

Implementation: Pratt parser with the table above.

## 6. Standard library types visible to P1 user programs

Defined in `stdlib/core.ml` (written in this very subset, see
`07-repo-layout.md`):

```ocaml
type 'a option = None | Some of 'a
type ('a, 'e) result = Ok of 'a | Error of 'e
type 'a list = []  | (::) of 'a * 'a list
```

`list` uses the OCaml built-in syntax sugar `[1; 2; 3]` and `x :: xs`,
which the parser desugars to constructor applications during AST
construction.

## 7. Diagnostics for rejected OCaml constructs

When the parser encounters a reserved-but-rejected keyword from §3,
it must emit a diagnostic of the form:

```
error: feature not supported in P1: `module`
  --> foo.ml:12:1
  note: ZxCaml accepts a subset of OCaml; this construct is planned
        for a later phase, see docs/08-roadmap.md
```

Plain syntax errors keep OCaml-style reporting:

```
error: expected `->`, found `=`
  --> foo.ml:5:14
```

## 8. Compatibility check (sanity oracle)

The stdlib and example programs MUST also type-check under the real
`ocaml` compiler when it is available locally. CI step (post-P1):

```sh
ocamlfind ocamlc -i stdlib/core.ml > /dev/null
```

This guarantees we have not silently drifted out of the OCaml subset.
