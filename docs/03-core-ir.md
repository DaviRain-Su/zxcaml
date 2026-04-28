# 03 — Core IR

> **Languages / 语言**: **English** · [简体中文](./zh/03-core-ir.md)

The Core IR is the **only stable contract** in this compiler. The current
as-built contract is the data model in `src/core/ir.zig`, with layout choices
in `src/core/layout.zig` and type declarations in `src/core/types.zig`.

## 1. Properties

| Property | Current as-built value |
|---|---|
| Form | ANF-oriented expression tree; complex work is kept let-bound where lowering/codegen need it |
| Typing | every expression node carries a resolved `Ty` |
| Layout | every value-producing node that codegen needs carries a `Layout` |
| Purity | no exceptions or mutation expressions; records use functional update |
| Names | byte-string names from the frontend; codegen sanitizes them for Zig |
| Source positions | frontend diagnostics carry locations; Core IR source spans are not populated yet |

The Zig model does **not** split atoms and RHS values into separate `Atom` /
`RhsValue` variants. Expression variants hold pointers to child `Expr` values,
and ANF/lowering passes enforce the evaluation discipline.

## 2. Data model (`src/core/ir.zig`)

```text
Module := {
  decls             : Decl list,
  type_decls        : VariantType list,
  tuple_type_decls  : TupleType list,
  record_type_decls : RecordType list,
}

Decl :=
  | Let of Let

Let := { name, value, ty, layout, is_rec }

Expr :=
  | Lambda       of { params, body, ty, layout }
  | Constant     of { Int i64 | String string, ty, layout }
  | App          of { callee, args, ty, layout }
  | Let          of { name, value, body, ty, layout, is_rec }
  | If           of { cond, then_branch, else_branch, ty, layout }
  | Prim         of { op, args, ty, layout }
  | Var          of { name, ty, layout }
  | Ctor         of { name, args, tag, type_name?, ty, layout }
  | Match        of { scrutinee, arms, ty, layout }
  | Tuple        of { items, ty, layout }
  | TupleProj    of { tuple_expr, index, ty, layout }
  | Record       of { fields, ty, layout }
  | RecordField  of { record_expr, field_name, ty, layout }
  | RecordUpdate of { base_expr, fields, ty, layout }

Arm := { pattern : Pattern, guard : Expr option, body : Expr }

Pattern :=
  | Wildcard
  | Var    of { name, ty, layout }
  | Ctor   of { name, args, tag, type_name? }
  | Tuple  of Pattern list
  | Record of { name, pattern } list

Ty :=
  | Int | Bool | Unit | String
  | Var    of string
  | Adt    of { name, params }
  | Tuple  of Ty list
  | Record of { name, params }
  | Arrow  of { params, ret }
```

`VariantType`, `TupleType`, and `RecordType` live in `src/core/types.zig` and
are attached to `Module` so downstream phases can resolve constructor tags,
record fields, concrete type parameters, and generated Zig names.

## 3. Constructors, records, tuples, and patterns

The frontend emits bundled stdlib constructors and user-defined constructors.
`Ctor` stores both source constructor name and resolved tag/type metadata when
available. Nullary constructors use tagged-immediate/static layouts; payload
constructors and recursive ADT payloads use arena-backed representations.

Patterns are recursive. P2 relies on this for nested constructor patterns,
tuple patterns, record patterns, wildcard defaults, and guarded arms. Guards
are stored on `Arm.guard`; a false guard falls through to the next candidate arm.

## 4. Layout assignment (`src/core/layout.zig`)

```text
Region := Arena | Static | Stack
Repr   := Flat | Boxed | TaggedImmediate
Layout := { region : Region, repr : Repr }
```

Current default rules:

| Value class | Layout |
|---|---|
| integer constants, booleans, unit values | `Static / Flat` or target-equivalent immediate |
| top-level lambdas | `Arena / Flat` |
| first-class closure records | `Arena / Boxed` |
| strings | `Static / Boxed` |
| nullary constructors | `Static / TaggedImmediate` |
| payload constructors / lists / recursive ADT payloads | `Arena / Boxed` |
| tuples and records | lowered as product values; codegen may keep non-escaping packs stack-shaped |

`Stack` exists as an extension point and for obvious non-escaping lowered
values; the user never chooses regions explicitly.

## 5. ANF and lowering rules

The ANF pass maps the `ttree` mirror into Core IR, preserving source order of
`let`, `match`, tuple/record construction, and record update evaluation. The
current rules include:

- top-level declarations become `Decl.Let` and module type declaration tables;
- nested `let` / `let rec` become `Expr.Let` with `is_rec` set;
- functions become `Expr.Lambda` and applications become `Expr.App`;
- arithmetic/comparison operators become `Expr.Prim`;
- constructors, tuple packs, record packs, field access, and updates become
  their corresponding Core variants;
- guarded/nested matches keep their recursive `Pattern` trees and optional
  guard expressions.

Lowered IR (`src/lower/lir.zig`) then makes the arena-threaded calling
convention explicit and adds closure-call/direct-call information for codegen.

## 6. Pretty-printing and IR snapshots

The Core IR pretty-printer must remain deterministic because golden tests
snapshot its output. Use:

```sh
zig-out/bin/omlz check --emit=core-ir foo.ml
```

The printed form is intentionally human-readable and not a parser input.

## 7. Stability commitment

- Adding a variant to `Expr`, `Pattern`, `PrimOp`, `Ty`, `Region`, or `Repr`
  is a contract change. Update `anf`, `lower`, `interp`, `zig_codegen`,
  `pretty`, golden tests, and this document together.
- Changing the meaning of an existing variant is breaking and requires an ADR
  or ADR addendum.
- Wire-format version bumps that affect Core IR shape must be reflected here
  when the as-built pipeline lands.

## 8. What Core IR does **not** carry yet

- source-level comments or formatting trivia;
- frontend source spans on every node;
- optimisation hints beyond `Layout`;
- backend-specific names after Zig identifier sanitisation.
