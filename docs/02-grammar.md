# 02 — Grammar (OCaml subset through P2)

> **Languages / 语言**: **English** · [简体中文](./zh/02-grammar.md)

## 1. Position

ZxCaml accepts a **strict subset of OCaml**. Every accepted program is
parsed and type-checked by upstream OCaml first; ZxCaml then walks the
`Typedtree` and rejects nodes outside the current subset.

As built through P2, the user-program subset includes top-level `let` and
`type` declarations, integers, strings, booleans, functions, `let`, `if`,
`match`, applications, primitive integer/comparison operators,
user-defined ADTs, nested and guarded patterns, tuples, records, field
access, functional record update, and the bundled `Option`, `Result`, and
`List` stdlib surface.

The authoritative implementation is `src/frontend/zxc_subset.ml`; the
wire contract currently emitted by the frontend is sexp **version `0.7`**.
The checked-in `src/frontend/zxc_sexp_format.md` still needs the OCaml lane
to refresh its examples from older `0.5` text.

File extension is `.ml`. There is no `.mli` or multi-file module support in
P2.

## 2. Lexical rules

Lexing is OCaml's lexer. The current subset consumes:

- decimal `int` literals, represented as signed 64-bit integers below the
  frontend;
- string literals;
- boolean literals `true` and `false`;
- identifiers and constructor names accepted by OCaml;
- bundled stdlib constructors (`None`, `Some`, `Ok`, `Error`, `[]`, `::`) and
  user-defined ADT constructors introduced by accepted `type` declarations.

## 3. Surface forms accepted through P2

```ocaml
(* user-defined ADTs *)
type color = Red | Green | Blue
type 'a tree = Leaf of 'a | Node of 'a tree * 'a tree

(* records and tuples *)
type person = { name : string; age : int }

let entrypoint _input =
  let pair = (1, true) in
  let alice = { name = "alice"; age = 30 } in
  let older = { alice with age = alice.age + 1 } in
  match pair with
  | (n, keep) when keep -> n + older.age
  | _ -> 0
```

Accepted expression classes:

| Surface form | Notes |
|---|---|
| `let x = e` / `let rec f x = e` | top-level and nested; no multi-binding `and` groups |
| `fun x -> e` / function-sugar lets | curried multi-argument functions are represented as nested lambdas / multi-arg arrows |
| variable reference | identifiers resolved by OCaml before serialisation; stdlib paths such as `List.map` stay qualified |
| integer, string, boolean, and unit constants | other constants rejected |
| function application | unlabeled applications; partial/labeled/optional application is still out of scope |
| `if c then a else b` | `else` is required |
| `match e with ...` | supports nested constructor/tuple/record patterns and `when` guards |
| constructors | bundled stdlib constructors plus constructors from accepted user ADTs |
| tuples | construction, pattern destructuring, and `fst`/`snd` projection helpers |
| records | type declarations, construction, field access (`r.x`), pattern destructuring, and functional update (`{ r with x = v }`) |
| primitive ops | `+`, `-`, `*`, `/`, `mod`, `=`, `<>`, `<`, `<=`, `>`, `>=` |

Accepted patterns:

| Pattern | Notes |
|---|---|
| `_` | wildcard |
| `x` | variable binder |
| constructor patterns | nullary and payload constructors, including nested payload patterns |
| tuple patterns | fixed-arity tuple destructuring |
| record patterns | named fields, in any source order OCaml accepts |
| guarded arms | `pattern when expr -> body`; false guards fall through to later arms |

## 4. Type declarations accepted through P2

Accepted:

```ocaml
type color = Red | Green | Blue
type 'a option_like = Nothing | Just of 'a
type 'a tree = Leaf of 'a | Node of 'a tree * 'a tree
type point = { x : int; y : int }
type 'a box = { value : 'a }
type pair = int * bool
```

Restrictions:

- no GADTs, polymorphic variants, private types, type constraints, or module
  signatures;
- no record constructor payloads inside variant declarations;
- no mutation expressions (`r.x <- v`), even though record field mutability is
  visible in the OCaml `Typedtree`;
- recursive ADTs are supported for the P2 examples, but full general recursive
  type inference remains intentionally narrow.

## 5. Reserved but rejected

The OCaml parser may accept the syntax, but the subset walker rejects these
forms with location-aware diagnostics:

```text
module  sig  struct  functor  open  include
exception  try  raise
mutable writes  ref  while  for  do  done
class  object  method  inherit  initializer
lazy  assert  external
arrays  labelled arguments  optional arguments  local opens
```

## 6. Standard library visible to programs

The bundled stdlib (`stdlib/core.ml`) defines `Option`, `Result`, and `List`
modules. P2 includes common functions such as:

- `List.length`, `List.map`, `List.filter`, `List.fold_left`, `List.rev`,
  `List.append`, `List.hd`, `List.tl`;
- `Option.map`, `Option.bind`, `Option.value`, `Option.get`,
  `Option.is_none`, `Option.is_some`;
- `Result.map`, `Result.bind`, `Result.is_ok`, `Result.is_error`,
  `Result.ok`, `Result.error`.

These functions are ordinary OCaml subset code, type-checked by upstream
OCaml and compiled by the same pipeline as user programs.

## 7. Diagnostics for rejected OCaml constructs

Two layers exist:

1. **Syntax/type errors** are reported by upstream `ocamlc`, captured by
   `zxc-frontend`, and emitted as the same flat JSON diagnostic shape used
   for subset errors.
2. **Subset violations** are detected by `zxc-frontend` walking the
   `Typedtree` and include the unsupported node kind plus a hint when one is
   known.

Rendered by `omlz`, a subset violation looks like:

```text
foo.ml:1:0: error: Texp_try is not supported in the current ZxCaml subset; exceptions are out of scope
```

## 8. Compatibility check

Because `omlz` obtains its input from upstream OCaml `compiler-libs`, accepted
programs are valid OCaml by construction. CI checks the examples corpus
through `omlz check`; the diagnostic fixture `examples/m0_unsupported.ml` is
intentionally skipped by that corpus loop because it is expected to fail.
