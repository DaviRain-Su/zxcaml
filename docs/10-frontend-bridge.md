# 10 — Frontend bridge (OCaml `compiler-libs` → Zig)

> **Languages / 语言**: **English** · [简体中文](./zh/10-frontend-bridge.md)

This document specifies how `omlz` obtains a fully type-checked
representation of a `.ml` source file without forking or
re-implementing OCaml. It is the practical realisation of ADR-010.

## 1. Position

```text
.ml source
   │
   ▼
[ ocamlc -bin-annot ]                        (vendored: nothing; uses system ocaml)
   │
   ▼
.cmt + .cmti                                 (binary Typedtree)
   │
   ▼
[ zxc-frontend (OCaml, ~few hundred LOC) ]   (built once by build.zig)
   │
   ▼
.cir.sexp                                    (S-expression Typedtree subset)
   │
   ▼
[ omlz (Zig) ]                               (reads the sexp)
   │
   ▼
Typed AST (Zig mirror)  →  ANF  →  Core IR  →  …
```

The OCaml side is a **small, read-only consumer** of `compiler-libs`.
It does not extend the OCaml compiler, does not patch it, does not
fork it.

## 2. The OCaml component: `zxc-frontend`

### 2.1 Responsibilities

1. Drive `Compile.implementation` (or equivalent in the matching
   `compiler-libs`) on the user's `.ml`, producing a
   `Typedtree.structure`.
2. Walk the `Typedtree` and **reject** any construct outside the
   accepted subset (see §4) with a precise diagnostic.
3. Serialise the surviving subset to a stable S-expression format
   (see §3).
4. Emit diagnostics on stderr in a uniform shape that `omlz`
   forwards to the user.

### 2.2 Non-responsibilities

- Does not generate code.
- Does not perform ANF or any IR lowering. ANF is Zig-side.
- Does not load multiple files; one `.ml` per invocation in P1.
  Module support is a P3 concern (see roadmap).

### 2.3 Source location and build

```text
src/frontend/zxc_frontend.ml         -- the program
src/frontend/zxc_subset.ml           -- the subset whitelist + walker
src/frontend/zxc_sexp.ml             -- serialiser
```

Built by `build.zig` via `ocamlfind ocamlopt -package
compiler-libs.common -linkpkg ...` (see ADR-011). Output binary:
`build/zxc-frontend`.

### 2.4 CLI of `zxc-frontend`

```text
zxc-frontend <input.ml> [--out <path>] [--json-diag]

  Exit codes:
    0   success, sexp written to stdout (or --out)
    1   subset violation (diagnostic on stderr)
    2   OCaml type error (diagnostic on stderr)
    3   I/O or internal error
```

`omlz` always passes `--json-diag` so it can render diagnostics
uniformly.

## 3. Wire format: `.cir.sexp`

The serialised form is an S-expression because:

- It is unambiguous, line-based, and trivial to parse from Zig.
- It is whitespace-tolerant, easy to diff, easy to golden-test.
- It maps cleanly to the algebraic shape of the `Typedtree`
  subset.

### 3.1 Top-level shape

```text
(module
  (source "examples/hello.ml")
  (ocaml-version "5.2.0")
  (zxc-frontend-version "0.1")
  (types
    (adt option (params 'a)
      (variants
        (None)
        (Some 'a)))
    ...
    )
  (decls
    (let head
      (ty (arrow (list 'a) (option 'a)))
      (rec false)
      (body
        (fun (param xs (ty (list 'a)))
          (match (var xs)
            (case (pat (ctor [])) (body (ctor None)))
            (case (pat (ctor :: x _))
                  (body (ctor Some (var x))))))))))
```

### 3.2 Stability commitment

- The wire format is versioned. The header carries
  `zxc-frontend-version`; `omlz` rejects mismatched majors.
- New keywords are additive at the **end** of a node's children;
  Zig parses leniently.
- Removing or repurposing a keyword is a major bump.

A formal grammar of the sexp lives in
`src/frontend/zxc_sexp_format.md` and is the wire contract.

### 3.3 What is and is not in the sexp

In:

- Type declarations (variants, records, type aliases) limited to
  the subset.
- Top-level `let` bindings (recursive groups preserved).
- Expressions covered by the subset: `let`, `fun`, `match`, `if`,
  applications, constructors, records, projections, tuples,
  literals.
- Patterns covered by the subset.
- For every node: source span (`(span 12 5 18)` = file_id, line,
  col) and resolved `ty`.

Out:

- Doc comments, ordinary comments, formatting trivia.
- Internal compiler annotations beyond span and `ty`.
- Any node from a feature outside the subset (those are rejected
  upstream of serialisation).

## 4. The accepted subset (P1)

The **definitive** list of `Typedtree` constructors accepted by
`zxc-frontend` in P1. Anything not on this list produces a
"feature not supported in P1" diagnostic.

### 4.1 Top-level

- `Tstr_value` (a `let` group, recursive or not)
- `Tstr_type Trec_not | Trec_first | Trec_next` (type
  declarations)

Rejected: `Tstr_module`, `Tstr_modtype`, `Tstr_class`, `Tstr_open`,
`Tstr_include`, `Tstr_exception`, `Tstr_primitive` (`external`),
`Tstr_attribute`, `Tstr_recmodule`.

### 4.2 Expressions

- `Texp_ident`
- `Texp_constant` (only `Const_int`, `Const_string`)
- `Texp_let` (recursive or not)
- `Texp_function` / `Texp_apply`
- `Texp_match` (no exception cases; no `when` guards in P1)
- `Texp_tuple`
- `Texp_construct`
- `Texp_record` (no `with` update in P1; a P2 feature)
- `Texp_field`
- `Texp_ifthenelse`
- `Texp_sequence` rejected → users should use `let _ =`

Rejected (with diagnostics): `Texp_try`, `Texp_assert`,
`Texp_lazy`, `Texp_object`, `Texp_pack`, `Texp_letmodule`,
`Texp_open`, `Texp_extension_constructor`, `Texp_setfield`,
`Texp_array`, `Texp_while`, `Texp_for`, `Texp_send`, `Texp_new`,
`Texp_override`, `Texp_letop` (`let*`).

### 4.3 Patterns

- `Tpat_any` (`_`)
- `Tpat_var`
- `Tpat_constant` (int, bool via construct)
- `Tpat_tuple`
- `Tpat_construct`
- `Tpat_record`
- `Tpat_or`

Rejected: `Tpat_alias` (P2 candidate), `Tpat_array`, `Tpat_lazy`,
`Tpat_variant` (polymorphic variants), `Tpat_exception`.

### 4.4 Types

- `Ttyp_var`, `Ttyp_arrow`, `Ttyp_tuple`, `Ttyp_constr`
- ADT declarations with named variants, optionally with payloads
- Record declarations

Rejected: `Ttyp_object`, `Ttyp_class`, `Ttyp_alias` with effects,
`Ttyp_poly` beyond rank-1, polymorphic variants, GADTs.

## 5. Diagnostics

Format on stderr (with `--json-diag`):

```json
{"severity":"error","code":"P1-UNSUPPORTED",
 "feature":"Texp_try",
 "loc":{"file":"foo.ml","line":12,"col":3,"end_line":12,"end_col":18},
 "message":"`try ... with` is not supported in P1; see roadmap §4"}
```

`omlz` consumes these and re-renders them in its own style.

## 6. The Zig consumer: `frontend_bridge`

### 6.1 Module location

```text
src/frontend_bridge/
├── sexp_lexer.zig
├── sexp_parser.zig
└── ttree.zig            -- Zig mirror of the accepted Typedtree subset
```

### 6.2 Responsibilities

1. Spawn `zxc-frontend` as a subprocess (path resolved by
   `build.zig` and embedded into `omlz` at compile time).
2. Read its stdout (or `--out` file) into memory.
3. Parse the sexp into `ttree.Module`.
4. Hand `ttree.Module` to the existing ANF lowering pass; from
   here, the rest of the pipeline is unchanged.

### 6.3 What it is **not**

- Not a type checker. Trust `ty` annotations from the sexp.
- Not a name resolver. Bindings already carry unique paths.
- Not a parser of OCaml source. Only of the sexp wire format.

## 7. Versioning and OCaml upgrades

- One OCaml minor version per project phase.
- `zxc-frontend` is built against the system OCaml; `build.zig`
  detects the version and gates compatibility.
- An incompatible OCaml minor (e.g., 5.2 → 5.3) is handled by:
  1. Updating `src/frontend/zxc_frontend.ml` to the new
     `compiler-libs` API.
  2. Bumping `zxc-frontend-version` if the sexp shape changes.
  3. Updating ADR-010 with the new pin.

## 8. Why not Lambda IR

`Lambda` (OCaml's internal IR after Typedtree) is more lowered and
closer to ANF, which would save us work. We do not use it because:

- The `Lambda` IR is **explicitly internal** and changes between
  patch releases.
- It encodes assumptions about the OCaml C runtime
  (`caml_call_gc`, allocation tags, field offsets) that we do not
  want to inherit.
- `Typedtree` is high-level enough that subset enforcement is
  obvious; `Lambda` would force us to *reverse-engineer* what the
  compiler did.

This matches ADR-010's reasoning: we want OCaml's *frontend*, not
its backend or its runtime model.

## 9. What this document does **not** cover

- Multi-file modules (P3).
- `.mli` signatures (P3+).
- Functor support (out of scope per ADR-001).
- Anything that requires reading OCaml's C runtime layout.

## 10. Known pitfalls (from Spike α, 2026-04-27)

These are concrete `compiler-libs` API hazards observed while
building the Spike α reader. They will bite the future P1
frontend-bridge implementer; they are documented here as a
navigation aid, not a tutorial. The empirical context for each
item is preserved in `docs/preflight-results.md`.

### 10.1 Top-level `let` is `Tstr_value`, not `Texp_let`

A user-written top-level `let f x = …` lands in
`structure_item.str_desc = Tstr_value (…)`, **not** in
`Texp_let`. Only nested / in-expression `let`s surface as
`Texp_let`. The subset enforcer must therefore walk **both**
`structure_item.str_desc` and `expression.exp_desc`. Implication:
the iterator is a structure-level walker (`Tast_iterator.iterator`
with `structure_item` and `expr` overrides), not an expression-only
walker. Missing this produces an enforcer that silently accepts
top-level bindings without checking their bodies.

### 10.2 `-bin-annot` is **not** the dune default for executables

`dune (library …)` passes `-bin-annot` automatically; `dune
(executable …)` does **not**. Per ADR-011, `omlz` invokes
`ocamlc` directly via `build.zig` rather than going through
`dune`, so we are responsible for the flag ourselves. The
`ocamlc` invocation in the OCaml step (see ADR-011's build flow
sketch and `docs/06-bpf-target.md` toolchain) **must include
`-bin-annot`** explicitly, otherwise no `.cmt` is emitted and
`zxc-frontend` has nothing to read. Add `-bin-annot` to the
`ocamlc` command line wherever the OCaml compile step is
documented or implemented.

### 10.3 `Printtyp.type_expr` writes through process-global state

Pretty-printing an OCaml type via `Printtyp.type_expr` mutates a
**process-wide** environment (the printing-environment path
table). It is fine for short-lived single-shot processes — which
`zxc-frontend` is, per ADR-010 / ADR-011 — but a long-lived
OCaml process that pretty-prints types repeatedly will leak
identity and produce surprising output across calls. If the
bridge ever grows into a daemon, callers must snapshot the
environment via `Printtyp.wrap_printing_env` (or equivalent)
around each pretty-print. Keep this in mind before considering
any "long-lived OCaml frontend daemon" optimisation.

### 10.4 `Cmt_format.cmt_modname` is `Misc.modname`, currently a private alias for `string`

In OCaml 5.2.x, `Cmt_format.cmt_modname` has type
`Misc.modname`, which is a private alias for `string` reachable
via `(_ :> string)` coercion. The coercion compiles cleanly today
but **may break** if a future OCaml release makes `Misc.modname`
abstract. Recommendation: centralise the coercion in a single
helper (e.g. `let modname_to_string : Misc.modname -> string =
fun s -> (s :> string)`) so a future upgrade is a one-line
fix rather than a scattered find-and-replace across the bridge.
