# 03 — Core IR

The Core IR is the **only stable contract** in this compiler.
Everything else (Surface AST, Typed AST, Lowered IR, backends) is
internal and may be rewritten freely. If you change Core IR, you are
changing the project.

## 1. Properties

| Property | Value |
|---|---|
| Form | A-Normal Form (ANF) |
| Typing | every node carries a fully resolved `Ty` |
| Layout | every allocation-bearing node carries a `Layout` |
| Purity | no side effects in P1 (no mutation, no exceptions) |
| Names | every binder is alpha-renamed to a unique `Symbol` |
| Source positions | every node carries a `Span` for diagnostics |

ANF discipline:

- Every actual computation is named via `let`.
- Every operand of an application, primitive op, or constructor is
  an **atom** (variable or literal).
- Control flow constructs (`match`, `if`) take an atom as scrutinee.

## 2. Data model (language-neutral pseudocode)

```text
Symbol  : interned identifier with unique id
Span    : { file_id : u32, lo : u32, hi : u32 }

Ty :=
  | TyVar    of TyVarId
  | TyInt
  | TyBool
  | TyUnit
  | TyString
  | TyTuple  of Ty list
  | TyArrow  of Ty list * Ty       -- multi-arg arrow, curried at frontend
  | TyAdt    of AdtId * Ty list    -- 'a list, ('a,'e) result, ...
  | TyRecord of RecordId * Ty list

Region :=
  | Arena                          -- P1: the only legal value
  | Static                         -- compile-time constants
  | Stack                          -- non-escaping locals (optional in P1)
  -- future: Rc | Gc | Region(id)

Repr :=
  | Flat                           -- inline by value
  | Boxed                          -- pointer to region
  | TaggedImmediate                -- small int, bool, unit, nullary ctor

Layout := { region : Region, repr : Repr }

Atom :=
  | AVar of Symbol * Ty
  | ALit of Literal * Ty

Literal :=
  | LInt    of i64
  | LBool   of bool
  | LUnit
  | LString of string_id           -- interned, lives in `Static`

Param := { name : Symbol, ty : Ty }

Pattern :=
  | PWild
  | PVar     of Symbol * Ty
  | PInt     of i64
  | PBool    of bool
  | PUnit
  | PTuple   of Pattern list
  | PCtor    of AdtId * VariantId * Pattern list
  | PRecord  of RecordId * (FieldId * Pattern) list

Arm := { pattern : Pattern, body : Expr, span : Span }

PrimOp :=
  | IAdd | ISub | IMul | IDiv | IMod
  | IEq  | INe  | ILt  | ILe  | IGt | IGe
  | BAnd | BOr  | BNot
  | StrEq                          -- stdlib-only, P1 internal
  -- future: bitwise ops, syscalls

Expr :=
  | EAtom    of Atom
  | ELet     of { name : Symbol, ty : Ty, value : RhsValue,
                  body : Expr, span : Span }
  | EMatch   of { scrut : Atom, arms : Arm list, ty : Ty, span : Span }
  | EIf      of { cond  : Atom, then_ : Expr, else_ : Expr,
                  ty : Ty, span : Span }

RhsValue :=
  | RAtom   of Atom
  | RApp    of { fun_ : Atom, args : Atom list, ret_ty : Ty }
  | RPrim   of { op : PrimOp, args : Atom list, ret_ty : Ty }
  | RLam    of { params : Param list, body : Expr,
                 ret_ty : Ty, layout : Layout, free_vars : Symbol list }
  | RCtor   of { adt : AdtId, variant : VariantId,
                 args : Atom list, ty : Ty, layout : Layout }
  | RRecord of { record : RecordId, fields : (FieldId * Atom) list,
                 ty : Ty, layout : Layout }
  | RProj   of { record : RecordId, field : FieldId, of_ : Atom, ty : Ty }
  | RTuple  of { elems : Atom list, ty : Ty, layout : Layout }

TopDecl :=
  | TLet  of { name : Symbol, ty : Ty, value : Expr,
               is_rec : bool, span : Span }
  | TType of AdtDecl | RecordDecl

Module := { decls : TopDecl list, type_env : TypeEnv, source : SourceMap }
```

Notes:

- `RApp.fun_` is an atom, so the *callee* itself is named-and-let-bound
  by the ANF pass when it is a complex expression.
- `RLam.free_vars` is the closure's capture list, computed during ANF
  and consumed by the `LoweringStrategy`.
- `RProj` / `RRecord` carry `RecordId` so the backend can compute
  field offsets without re-typing.

## 3. ANF transformation rules

Given a Typed AST expression `e`, lowering to Core IR follows the
standard ANF rules:

```
[[ x ]]            = EAtom (AVar x)
[[ k ]]            = EAtom (ALit k)
[[ e1 e2 ]]        = let x1 = [[e1]] in
                     let x2 = [[e2]] in
                     let r  = RApp(x1, [x2]) in
                     EAtom r
[[ if c then a else b ]]
                   = let xc = [[c]] in
                     EIf(xc, [[a]], [[b]])
[[ match e with arms ]]
                   = let xs = [[e]] in
                     EMatch(xs, arms_lowered)
[[ fun p -> body ]]= let f = RLam([p], [[body]], ...) in EAtom f
[[ let x = e1 in e2 ]]
                   = ELet(x, [[e1 as RhsValue]], [[e2]])
[[ Ctor(args) ]]   = let xs = [[args]] in
                     let c  = RCtor(... xs ...) in EAtom c
```

Multi-argument constructors and primops are flattened — arguments are
emitted as a sequence of `let`-binders, then the operation consumes
all of them as atoms.

## 4. Layout assignment (P1 rules)

The ANF lowering pass assigns a `Layout` to every `RLam`, `RCtor`,
`RRecord`, and `RTuple`. P1 rules:

1. `LInt`, `LBool`, `LUnit`, and nullary constructors get
   `{ region = Static, repr = TaggedImmediate }`.
2. `LString` gets `{ region = Static, repr = Boxed }`.
3. Everything else gets `{ region = Arena, repr = Boxed }`.
4. (Optional, P1.5) If escape analysis can prove a value does not
   leave its lexical scope, it may be re-tagged to
   `{ region = Stack, repr = Boxed }`. Disabled by default in P1.

The user never sees these annotations. The annotation exists so that
P4 region inference can replace rule 3 without touching anything else.

## 5. Type environment

Type information accompanies the Core IR module so backends do not
re-do inference:

```text
TypeEnv := {
  adts    : map<AdtId, AdtDecl>            -- variants, layout hints
  records : map<RecordId, RecordDecl>      -- fields, offsets resolved later
  globals : map<Symbol, Ty>                -- top-level value types
}

AdtDecl := {
  name     : string,
  params   : TyVarId list,
  variants : VariantDecl list,
  source   : Span,
}

VariantDecl := {
  id       : VariantId,
  name     : string,
  payload  : Ty list,                      -- empty = nullary
}
```

Field offsets and discriminator encodings are computed by the
backend, not stored in `TypeEnv`. This is intentional: different
backends may pick different encodings (e.g., the BPF backend uses
flat struct offsets, the interpreter uses boxed enums).

## 6. Pretty-printing and IR snapshots

A Core IR pretty-printer is mandatory. It must:

- Be deterministic (stable order of fields, no addresses).
- Round-trip *informally*: the printed form is human-readable but is
  not parsed back. Tests use it for golden-file comparisons.

Recommended surface:

```
omlz check --emit=core-ir foo.ml > foo.core.txt
```

Snapshot format (illustrative):

```
module foo
  type 'a option = | None | Some of 'a
  let head : list<'a> -> option<'a> =
    fun (xs : list<'a>) ->
      match xs with
      | [] -> let r = Ctor(option,None) [@layout Static/TaggedImm]
              in r
      | (::)(x, _) -> let r = Ctor(option,Some, x) [@layout Arena/Boxed]
                      in r
```

## 7. Stability commitment

- Adding a new variant to `Expr`, `RhsValue`, `Pattern`, `PrimOp`,
  `Region`, or `Repr` is a **minor** change. Backends must handle
  unknown variants by returning a structured error, not by panicking.
- Changing the meaning of an existing variant is a **breaking**
  change and must update all backends in the same commit.
- The ANF discipline (rule: every operand is an atom) is **never**
  relaxed. If you find yourself wanting to put a complex expression
  in argument position, add a let-binding instead.

## 8. What Core IR does **not** carry

- No source-level comments or trivia. Diagnostics use `Span` to fetch
  them from the Surface AST.
- No types of intermediate ANF temporaries beyond the `Ty` field on
  the atom itself. The Core IR is not a typechecker scratchpad.
- No optimisation hints. P1 trusts the Zig backend's optimiser.
