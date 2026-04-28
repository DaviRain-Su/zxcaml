# 03 — Core IR

> **Languages / 语言**: **English** · [简体中文](./zh/03-core-ir.md)

The Core IR is the **only stable contract** in this compiler. The
as-built P1 contract is the data model in `src/core/ir.zig`, with layout
choices in `src/core/layout.zig`. This document describes that concrete
model, not the larger P2+ shape.

## 1. Properties

| Property | P1 as-built value |
|---|---|
| Form | ANF-oriented expression tree; the lowering pass keeps complex work let-bound where the current subset needs it |
| Typing | every expression node carries a resolved `Ty` |
| Layout | every value-producing node that codegen needs carries a `Layout` |
| Purity | no mutation, no exceptions, no effects in P1 |
| Names | byte-string names from the frontend; codegen sanitizes them for Zig |
| Source positions | frontend diagnostics carry locations; Core IR source spans are not populated in P1 |

The current Zig model does **not** split atoms and RHS values into
separate `Atom` / `RhsValue` variants. Instead, expression variants hold
pointers to child `Expr` values and the ANF/lowering passes enforce the
subset's evaluation discipline.

## 2. Data model (`src/core/ir.zig`)

```text
Module := { decls : Decl list }

Decl :=
  | Let of Let

Let := {
  name   : string,
  value  : Expr,
  ty     : Ty,
  layout : Layout,
  is_rec : bool,
}

Lambda := { params : Param list, body : Expr, ty : Ty, layout : Layout }
Param  := { name : string, ty : Ty }

Expr :=
  | Lambda   of Lambda
  | Constant of Constant
  | App      of { callee : Expr, args : Expr list, ty : Ty, layout : Layout }
  | Let      of { name : string, value : Expr, body : Expr,
                  ty : Ty, layout : Layout, is_rec : bool }
  | If       of { cond : Expr, then_branch : Expr, else_branch : Expr,
                  ty : Ty, layout : Layout }
  | Prim     of { op : PrimOp, args : Expr list, ty : Ty, layout : Layout }
  | Var      of { name : string, ty : Ty, layout : Layout }
  | Ctor     of { name : string, args : Expr list, ty : Ty, layout : Layout }
  | Match    of { scrutinee : Expr, arms : Arm list, ty : Ty, layout : Layout }

Constant :=
  | Int    of i64
  | String of string

PrimOp := Add | Sub | Mul | Div | Mod | Eq | Ne | Lt | Le | Gt | Ge

Arm := { pattern : Pattern, body : Expr }

Pattern :=
  | Wildcard
  | Var  of { name : string, ty : Ty, layout : Layout }
  | Ctor of { name : string, args : Pattern list }

Ty :=
  | Int | Bool | Unit | String
  | Adt   of { name : string, params : Ty list }
  | Arrow of { params : Ty list, ret : Ty }
```

P1 deliberately has no Core IR variants for user-defined type
declarations, records, tuples, arrays, source spans, or a module-level
`TypeEnv`. Those are P2+ expansions and must be added to all consumers
in the same commit when they land.

## 3. Constructor and pattern subset

The frontend emits only the bundled constructor names:

```text
None | Some | Ok | Error | [] | ::
```

Nullary constructors such as `None` and `[]` use
`Static/TaggedImmediate`. Payload constructors such as `Some x`, `Ok x`,
`Error e`, and `x :: xs` use `Arena/Boxed`.

`Pattern` is recursive in the Zig type, but the P1 frontend only emits
wildcards, variables, and constructor patterns over the whitelisted
constructors; nested constructor patterns are a P2 feature.

## 4. Layout assignment (`src/core/layout.zig`)

```text
Region := Arena | Static | Stack
Repr   := Flat | Boxed | TaggedImmediate
Layout := { region : Region, repr : Repr }
```

Default P1 rules:

| Value class | Layout |
|---|---|
| integer constants | `Static / Flat` |
| unit values and unit-typed lambda params | `Static / Flat` |
| top-level lambdas | `Arena / Flat` |
| first-class closure records | `Arena / Boxed` |
| strings | `Static / Boxed` |
| nullary constructors | `Static / TaggedImmediate` |
| payload constructors / aggregates | `Arena / Boxed` |

`Stack` exists as a reserved extension point but is not selected by a
real P1 escape-analysis pass.

## 5. ANF and lowering rules

The ANF pass maps the `ttree` mirror into this Core IR, preserving the
source order of `let` and `match` evaluation. The current subset relies
on these rules:

- top-level declarations become `Decl.Let`;
- nested `let` and `let rec` become `Expr.Let` with `is_rec` set;
- functions become `Expr.Lambda` and applications become `Expr.App`;
- arithmetic/comparison operators become `Expr.Prim`;
- `if` conditions consume bool ADT values produced by comparisons;
- constructors and matches preserve option/result/list source order;
- match arms are tested top-to-bottom, first match wins.

The Lowered IR (`src/lower/lir.zig`) then makes the arena-threaded
calling convention explicit and adds closure-call/direct-call
information for codegen.

## 6. Pretty-printing and IR snapshots

The Core IR pretty-printer must remain deterministic because golden
tests snapshot its output. Use:

```sh
zig-out/bin/omlz check --emit=core-ir foo.ml
```

The printed form is intentionally human-readable and not a parser input.

## 7. Stability commitment

- Adding a variant to `Expr`, `Pattern`, `PrimOp`, `Ty`, `Region`, or
  `Repr` is a contract change. Update `anf`, `lower`, `interp`,
  `zig_codegen`, `pretty`, golden tests, and this document together.
- Changing the meaning of an existing variant is breaking and requires
  an ADR or ADR addendum.
- The current absence of records, tuples, source spans, and type-env
  declarations is intentional as-built P1 scope, not an omission.

## 8. What Core IR does **not** carry in P1

- source-level comments or formatting trivia;
- frontend source spans on every node;
- user type declarations or a general type environment;
- optimisation hints beyond `Layout`;
- backend-specific names after Zig identifier sanitisation.
