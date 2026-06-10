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
- Loads at most the top-level `open Foo` dependency closure of the
  entry file (§2.5, ADR-016); there is no package or `dune`-style
  project model.

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
zxc-frontend --emit=sexp <input.ml>

  Exit codes:
    0   success, sexp written to stdout
    1   subset violation or OCaml syntax/type error (flat JSON diagnostic on stderr)
    3   argument, I/O, or internal error
```

`omlz` always passes `--json-diag` so it can render diagnostics
uniformly.

### 2.5 Multi-file closure resolution (ADR-016)

Top-level `open Foo` in user code pulls a sibling file into the build
(full contract:
[`21-multifile-modules-plan.md`](./21-multifile-modules-plan.md)):

- **Discovery.** Before invoking `ocamlc`, the frontend parses the
  entry file untyped (`Parse.implementation`) and scans top-level
  `open M` items. `M` resolves to `<entry_dir>/<uncapitalized M>.ml`
  (`open Vault_types` → `vault_types.ml`); discovery recurses through
  dependencies.
- **Compilation.** Dependencies compile in topological order into a
  shared temp directory as `<name>.cmo` / `.cmt`; the entry file
  compiles last with the same `-I <deps>` flag.
- **Join.** Each `.cmt`'s Typedtree is converted through one shared
  subset environment, declarations concatenate into a single module
  (entry last), resolved top-level opens are skipped, and one joined
  sexp is emitted.
- **Flat namespace.** Emitted names are unqualified; duplicate
  top-level names across the closure are rejected (E0102) instead of
  mangled, and `Foo.x` references to a user module emit plain `x`.
- **Dependency edges are `open` only.** `Foo.x` without `open Foo` is
  not a dependency edge (`ocamlc` reports an unbound module);
  `include` and nested/local opens stay rejected.
- **Pre-`ocamlc` diagnostics.** E0100 (unresolvable `open`), E0101
  (`open` cycle), and E0103 (`open` of a bundled stdlib module, or a
  user file shadowing one) are emitted before `ocamlc` runs.

The wire stays **`1.7`**: every `(loc <file> <line> <col> <end_line>
<end_col>)` node already carries a file atom, so multi-file span
attribution needs no new wire shape, and a program with no user
`open` produces a byte-identical sexp to single-file output.

## 3. Wire format: `.cir.sexp`

The serialised form is an S-expression because:

- It is unambiguous, line-based, and trivial to parse from Zig.
- It is whitespace-tolerant, easy to diff, easy to golden-test.
- It maps cleanly to the algebraic shape of the `Typedtree`
  subset.


### 3.1 Top-level shape

The current wire grammar is sexp **version `1.7`**. The header carries the
version so `omlz` can reject stale frontend output with an upgrade hint:

```text
;; locations elided for readability
(zxcaml-cir 1.7
  (module
    (type_decl (name color) (params)
      (variants ((Red (payload_types))
                 (Green (payload_types))
                 (Blue (payload_types)))))
    (record_type_decl (name person) (params)
      (fields ((name (type-ref string)) (age (type-ref int)))))
    (let entrypoint
      (lambda ((_input (ty (type-ref unit))))
        (let alice (record (fields ((name (const-string "alice"))
                                    (age (const-int 30)))))
          (match (tuple (items (ctor Red) (field_access (var alice) age)))
            (case (tuple_pattern (ctor Red) (var n)) (var n))))))))
```

Wire-format history:

| Version | Added surface |
|---|---|
| `0.4` | P1 expressions: `let`, `lambda`, `var`, literals, constructors, `app`, `prim`, `if`, `match`, `case` |
| `0.5` | user-defined variant `type_decl` nodes |
| `0.6` | nested pattern payloads and `when_guard` nodes |
| `0.7` | tuple nodes, tuple patterns/projection, record type declarations, record expressions, field access, record update, record patterns |
| `0.8` | account/syscall references for Solana-shaped programs |
| `0.9` | CPI-shaped type references and function applications |
| `1.0` | external declarations, instruction-data/account attributes, and P4/P5 Solana/IDL metadata |
| `1.1` | mutual-recursion groups and erased type aliases |
| `1.2` | per-node source locations for DX2 diagnostics, LSP, and source maps |
| `1.3` | typed lambda / `let rec` parameters with `(any)` fallback |
| `1.4` | array / loop-era additive surface before refs |
| `1.5` | `ref-make`, `ref-get`, and `ref-set` for arena-backed ref cells |
| `1.6` | `(located ...)` wrappers on inner expressions for expression-level diagnostics and source maps |
| `1.7` | annotated-parameter `ty!` markers so explicit `(p : ty)` annotations beat parameter heuristics |

Diagnostics carry locations separately on stderr; ordinary comments and
formatting trivia are not serialized.

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
  literals, sequence, loops, arrays, and ref cells.
- Patterns covered by the subset.
- For every node: source span (`(span 12 5 18)` = file_id, line,
  col) and resolved `ty`.

Out:

- Doc comments, ordinary comments, formatting trivia.
- Internal compiler annotations beyond span and `ty`.
- Any node from a feature outside the subset (those are rejected
  upstream of serialisation).


## 4. The accepted subset (current surface)

The **definitive** list of `Typedtree` constructors accepted by the current
`zxc-frontend` is the implementation in `src/frontend/zxc_subset.ml`. This
section summarizes the as-built current surface.

### 4.1 Top-level

Accepted:

- `Tstr_value` for accepted value bindings, including mutually recursive
  groups.
- `Tstr_type` for subset variant, tuple-alias, record, and erased type-alias
  declarations.
- `Tstr_primitive` for typed `external name : type = "zig_symbol"`
  declarations.

Rejected: modules, module types, classes, opens/includes, exceptions,
attributes, recursive modules, and private/constraint-heavy types.

### 4.2 Expressions

Accepted:

- `Texp_ident`
- `Texp_constant` for `Const_int` and `Const_string`
- `Texp_function` for the supported lambda/function-sugar forms
- `Texp_let` with exactly one binding, recursive or non-recursive
- `Texp_apply` for unlabeled applications, whitelisted primops, `fst`/`snd`,
  and stdlib-qualified calls such as `List.map`
- `Texp_ifthenelse` with an `else` branch
- `Texp_match`, including `case.c_guard` expressions
- `Texp_construct` for bundled and user-defined ADT constructors
- `Texp_tuple`
- `Texp_record` for construction and functional update
- `Texp_field` for record field access
- `Texp_sequence` where it desugars to ordered Core IR effects
- `Texp_assert` for supported assertion expressions
- ADR-015 mutable primitives: `Texp_array`, `Array.get`, `Array.length`,
  `Array.set`, literal-size `Array.make`, `ref`, `!`, `:=`, and native
  `for` / `while` desugaring where their narrow element/loop constraints hold

Rejected: objects, polymorphic variants, `letop`, local opens/modules, `try`,
`lazy`, labels/optional arguments outside the whitelist, general mutable
record-field writes, unsupported ref element types, and array forms outside the
R9 `int`-array subset, with dedicated diagnostics where available.

Whitelisted primops:

```text
+  -  *  /  mod  bitwise ops  =  <>  <  <=  >  >=
```

### 4.3 Patterns

Accepted:

- `Tpat_any` (`_`)
- `Tpat_var`
- `Tpat_construct` for bundled and user-defined constructors, including
  nested constructor payloads
- `Tpat_tuple`
- `Tpat_record`
- literal constant patterns where supported
- or-patterns and alias patterns where the bindings are valid

Rejected: lazy patterns, polymorphic variants, exception patterns, and
mutation-related patterns.

### 4.4 Types

User-authored subset type declarations are accepted. The type language covers
variables, named references, tuple type payloads, array/ref type references,
variant declarations, tuple aliases, record declarations, and erased type aliases. External declaration
types use the same subset type language. GADTs, private types, record
constructor payloads inside variants, and type constraints remain rejected.

## 5. Diagnostics

Format on stderr (with `--json-diag`):

```json
{"severity":"error","code":"P2-UNSUPPORTED",
 "feature":"Texp_try",
 "loc":{"file":"foo.ml","line":12,"col":3,"end_line":12,"end_col":18},
 "message":"`try ... with` is not supported in the current ZxCaml subset"}
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

- Multi-file closure resolution beyond the §2.5 summary (see
  [`21-multifile-modules-plan.md`](./21-multifile-modules-plan.md)).
- `.mli` signatures (future work; ADR-016 covers `.ml` opens only).
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
