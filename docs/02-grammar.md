# 02 — Grammar (OCaml subset for P1)

## 1. Position

ZxCaml accepts a **strict subset of OCaml**. Anything written in
ZxCaml is valid OCaml; the converse does not hold.

**We do not define our own grammar.** Per ADR-010, the grammar is
whatever the upstream OCaml compiler accepts; ZxCaml restricts the
*Typedtree* (post type-checking), not the surface syntax. The
authoritative subset list is in
[`10-frontend-bridge.md` §4](./10-frontend-bridge.md), expressed in
terms of `Typedtree` constructors.

This document remains as a **human-readable** description of what
"the subset" looks like at the surface level, and to enumerate
which keywords are reserved-but-rejected for friendlier error
messages. It is **not** the source of truth; the source of truth is
`10-frontend-bridge.md` §4.

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

## 4. Grammar (EBNF, illustrative — non-authoritative)

The grammar below is a **descriptive** sketch of the subset; it is
useful for orientation but is not what the compiler enforces.
Enforcement happens at the `Typedtree` level (see
`10-frontend-bridge.md` §4). The OCaml compiler itself implements
the actual parser.

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

Two layers exist:

1. **Pure syntax errors** are reported by the upstream OCaml
   compiler (via `zxc-frontend`). `omlz` re-renders them in its
   own diagnostic style but does not re-author them.
   ```
   error: Syntax error
     --> foo.ml:5:14
   ```
2. **Subset violations** are detected by `zxc-frontend` walking
   the `Typedtree`. They look like:
   ```
   error[P1-UNSUPPORTED]: `try ... with` is not supported in P1
     --> foo.ml:12:3
     note: ZxCaml accepts a subset of OCaml; this construct is
           planned for a later phase, see docs/08-roadmap.md
   ```

Both classes are emitted as JSON by `zxc-frontend` (`--json-diag`)
and rendered uniformly by `omlz`.

## 8. Compatibility check

Subset drift is **structurally impossible** under ADR-010: the
upstream OCaml compiler is the parser/type-checker, so anything
`omlz` accepts is by construction valid OCaml. No separate sanity
oracle is required.

What CI still does verify:

```sh
# Every example and stdlib file must type-check against the
# pinned OCaml version (already implied by the omlz build).
for f in stdlib/*.ml examples/*.ml; do
    omlz check "$f"
done
```

If `omlz check` succeeds, the input is by definition valid OCaml.
