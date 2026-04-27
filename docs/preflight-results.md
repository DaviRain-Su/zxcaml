# Preflight results

Status of P1 frontend feasibility spikes for ZxCaml. This document is
the canonical artefact recording whether the assumptions baked into
ADR‑010 and `docs/10-frontend-bridge.md` survive contact with reality.

## Spike α — OCaml `compiler-libs` Typedtree extraction

### Environment

| Item | Observed |
|---|---|
| OS | macOS 26.4.1 (darwin 25.4.0), arm64 |
| Homebrew | 5.1.6 |
| opam | 2.5.1 |
| OCaml | 5.2.1 (`ocaml-base-compiler.5.2.1`, switch `zxcaml-spike`) |
| dune | 3.17.0 |
| ocamlfind | 1.9.6 |
| `compiler-libs.common` | 5.2.1 (ships with the compiler, no extra opam package) |

The switch was created with:

```sh
opam switch create zxcaml-spike 5.2.1
opam install -y dune
```

### What we built

Under `spike/ocaml-cmt-read/`:

- `hello.ml` — a 9‑line program exercising top‑level `let`, in‑expression
  `let`, `match` against an `option`, an `if/then/else`, and a function
  application.
- `reader.ml` — a ~120‑line Typedtree walker built on
  `Tast_iterator.default_iterator` with two overrides (`expr` and
  `pat`). Pattern handling uses a GADT `match` to cover both the
  `value` and `computation` pattern categories without `Obj.magic`.
- `dune` / `dune-project` — declare two executables; `hello` is built
  with `(modes byte)` and `-bin-annot` so dune emits the `.cmt`.

The reader takes a `.cmt` path on the command line, prints the
modname, then for every expression and pattern node prints
`[KIND] Constructor : <type> @ file:line:col`.

### Acceptance results

| # | Criterion | Result |
|---|---|---|
| 1 | opam installed; OCaml 5.2.x present | **PASS** — `5.2.1` |
| 2 | `dune build` succeeds without warnings | **PASS** — clean build, no diagnostics |
| 3 | reader prints constructor + type + location for every node | **PASS** — see verbatim output below |
| 4 | only `compiler-libs.common` used; no `Obj.magic` | **PASS** — `(libraries compiler-libs.common)` is the only library, source contains no `Obj.magic` |
| 5 | this document exists | **PASS** |
| 6 | Chinese mirror exists at `docs/zh/preflight-results.md` | **PASS** |
| 7 | committed and pushed to `origin/main` | **PASS** (see commit referenced in body) |

### Reader output (verbatim)

Captured via `dune exec ./reader.exe -- _build/default/.hello.eobjs/byte/dune__exe__Hello.cmt`:

```
# cmt: _build/default/.hello.eobjs/byte/dune__exe__Hello.cmt  (modname=Dune__exe__Hello)
[PAT ] Tpat_var               : int option -> string @ hello.ml:5:4
[EXPR] Texp_function          : int option -> string @ hello.ml:5:13
[PAT ] Tpat_alias             : int option @ hello.ml:5:14
[PAT ] Tpat_any               : int option @ hello.ml:5:14
[EXPR] Texp_match             : string @ hello.ml:6:2
[EXPR] Texp_ident             : int option @ hello.ml:6:8
[PAT ] Tpat_value             : int option @ hello.ml:7:4
[PAT ] Tpat_construct         : int option @ hello.ml:7:4
[EXPR] Texp_constant          : string @ hello.ml:7:12
[PAT ] Tpat_value             : int option @ hello.ml:8:4
[PAT ] Tpat_construct         : int option @ hello.ml:8:4
[PAT ] Tpat_var               : int @ hello.ml:8:9
[EXPR] Texp_let               : string @ hello.ml:9:6
[PAT ] Tpat_var               : int @ hello.ml:9:10
[EXPR] Texp_apply             : int @ hello.ml:9:20
[EXPR] Texp_ident             : int -> int -> int @ hello.ml:9:22
[EXPR] Texp_ident             : int @ hello.ml:9:20
[EXPR] Texp_ident             : int @ hello.ml:9:24
[EXPR] Texp_ifthenelse        : string @ hello.ml:10:6
[EXPR] Texp_apply             : bool @ hello.ml:10:9
[EXPR] Texp_ident             : int -> int -> bool @ hello.ml:10:17
[EXPR] Texp_ident             : int @ hello.ml:10:9
[EXPR] Texp_constant          : int @ hello.ml:10:19
[EXPR] Texp_constant          : string @ hello.ml:10:26
[EXPR] Texp_constant          : string @ hello.ml:10:42
[PAT ] Tpat_any               : string @ hello.ml:12:4
[EXPR] Texp_apply             : string @ hello.ml:12:8
[EXPR] Texp_ident             : int option -> string @ hello.ml:12:8
[EXPR] Texp_construct         : int option @ hello.ml:12:17
[EXPR] Texp_constant          : int @ hello.ml:12:23
```

Notes on the trace:

- All required constructor families show up: `Texp_let`,
  `Texp_function`, `Texp_match`, `Texp_apply`, `Texp_ident`,
  `Texp_constant`, `Texp_construct`, `Texp_ifthenelse`, plus the
  pattern side `Tpat_var`, `Tpat_alias`, `Tpat_any`, `Tpat_value`,
  `Tpat_construct`.
- Resolved types are concrete: `int option -> string`, `int -> int -> bool`,
  `string`, `int`, `bool`, `int option`. No unsolved type variables
  appear because we walked an `Implementation` after the type checker
  finished.
- Locations are 0‑indexed columns relative to the start of the line
  (i.e. `pos_cnum - pos_bol`). Lines are 1‑indexed.

### API surprises / friction

Honest list, even though nothing here forced a redesign:

1. **`Tpat_var` for the function name (line 5:4).** A top‑level
   `let f x = …` produces a `Tstr_value` whose binding has a
   `Tpat_var` pattern; this `Tpat_var`'s `pat_type` is the *function
   type* (`int option -> string`), not the type of the bound name in
   isolation. This is correct and useful, but easy to misread. The
   future ZxCaml frontend should be aware.
2. **Top‑level `let` is `Tstr_value`, not `Texp_let`.** Only inner
   lets surface as `Texp_let`. Our spike only finds one because we
   added `let doubled = n + n` inside the `Some` branch. The frontend
   will need to handle both `structure_item.Tstr_value` and the
   in‑expression `Texp_let`; the iterator already does this — we just
   have to walk both.
3. **GADT‑typed patterns.** `pattern_desc` is indexed by
   `value | computation`. `Tast_iterator.iterator.pat` already abstracts
   over the index with `'k . iterator -> 'k general_pattern -> unit`,
   so a single override works, but we had to write the `pat` callback
   with an explicit `(type k)` annotation. This is an OCaml syntactic
   wart, not a semantic problem.
4. **`Cmt_format.cmt_modname` is of type `Misc.modname`, not `string`.**
   In 5.2.1 it is a private alias for `string` reachable via
   `(_ :> string)` coercion. If ZxCaml later upgrades to a compiler
   release where `modname` becomes abstract, the coercion may need to
   change to a named accessor. Low risk, but worth flagging.
5. **`-bin-annot` and dune.** Dune's `(executable …)` stanza does *not*
   pass `-bin-annot` by default for the *executable* compilation unit
   in the same module layout we used. We had to add
   `(flags (:standard -bin-annot))`. For library targets this would
   already be on. Documented in the `dune` file inside the spike.
6. **`Printtyp.type_expr` writes through a global state.** It works
   here because we are single‑threaded and short‑lived. The real
   frontend will want `Printtyp.{wrap_printing_env, with_constraint}`
   or to snapshot the env before printing. Not blocking.

No `Obj.magic`, no private modules, no `compiler-libs.optcomp`
dependency, no patches against the compiler. Everything is in
`compiler-libs.common`.

### Verdict

**PROCEED.**

OCaml 5.2.1's `compiler-libs.common` cleanly delivers a fully
type‑checked `Typedtree` from a `.cmt` file. `Tast_iterator` provides
exactly the open‑recursion shape ZxCaml's planned `zxc-frontend` will
use. Type expressions, source locations, and constructor identities
are all accessible without resorting to `Obj.magic`, private modules,
or compiler patches. The friction items above are documentation
hazards, not architectural ones.

The P1 strategy described in `docs/10-frontend-bridge.md` is sound on
this evidence. Spike β (BPF toolchain) and downstream frontend work
(F00–F06) can begin against ADR‑010 as written.

### Recommended ADR / doc revisions

These are *recommendations only*; this spike does **not** enact any
doc changes outside of the two preflight results files.

1. **ADR‑010 / doc 10 — pin can stay at "OCaml 5.2.x".** No reason
   to tighten to `=5.2.1` exactly. No reason to relax to `>= 5.2`
   either; we have not tested 5.3 here.
2. **Doc 10 should mention the `-bin-annot` dune flag explicitly**
   when the frontend's build system is described. A one‑line note
   `(flags (:standard -bin-annot))` saves the next implementer ten
   minutes.
3. **Doc 10 (or a new note) should mention that top‑level `let`s
   land in `Tstr_value`**, so the subset enforcer must walk
   `structure_item`s, not only `expression`s.
4. **No new ADR needed for `Tast_iterator`.** The choice is internal
   to the frontend; it can be revisited later if needed.

No new risks beyond `docs/10-frontend-bridge.md` were discovered.
