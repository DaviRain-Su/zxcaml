# Wire Compatibility

> **Languages / 语言**: **English** · [简体中文](./zh/wire-compat.md)

DX2 bumps the frontend bridge wire from `1.1` to `1.2` so location-aware
S-expressions can carry `(loc <file> <line> <col> <end_line> <end_col>)`
annotations into the Zig bridge. See `docs/diagnostics.md` for the full
diagnostics-facing schema and `mission-internal/p9-investigation/report.md` §2
for the implementation rationale.

`omlz check --wire=1.1 ...` is a deprecated one-mission compatibility window
that forwards `--wire=1.1` to `zxc-frontend` and emits the old location-free
shape. The current `1.7` reader still accepts `1.1`/`1.2` compatibility sexps and treats missing locations
as `Loc.unknown`.

## Wire 1.3 — typed lambda parameters

R8 bumps the frontend bridge wire from `1.2` to `1.3` so the OCaml frontend
can publish a per-parameter inferred type for every `lambda` and `let rec`
binding. Each parameter is now emitted as `(name (ty <type-expr>))` instead
of the bare atom shape that 1.2 used. Unknown/polymorphic types fall back
to the `(any)` sentinel which the bridge maps to `null`, and the Core IR
lowerer falls back to its existing structural heuristics in that case.

The current `1.7` reader still accepts `1.2`/`1.3` sexps; legacy bare-atom params parse as
"untyped" and follow the original heuristic-only path. `omlz check --wire=1.2
...` (and `--wire=1.1`) remain available as one-mission compatibility windows
that re-emit the older shapes.

## Wire 1.4 — arrays and loops

R9 advances the additive wire surface for ADR-015 array/loop work. It carries
`int`-array literals and explicit array get/length/set/make nodes, plus the
loop-era desugarings used by the frontend. These shapes remain accepted by the
current `1.7` reader.

## Wire 1.5 — ref cells

R10 advances the frontend bridge wire to `1.5` to carry the three new
`ref`-cell sexp shapes introduced by ADR-015 option C:

- `(ref-make (ty <type-expr>) <init-expr>)` — allocates a single arena
  slot of element type `<type-expr>` (accepted: `(type-ref int)`,
  `(type-ref bool)`) and initialises it.
- `(ref-get <r-expr>)` — dereferences a ref cell (`!r`).
- `(ref-set <r-expr> <val-expr>)` — writes into a ref cell (`r := v`).

The `1.5` reader is a strict additive extension of `1.4`: every prior
wire shape continues to parse. See
`src/frontend/zxc_sexp_format.md` for the canonical sexp grammar and
worked examples. `--no-alloc` rejects `ref-make` with `DX2-NOALLOC`;
`ref-get` / `ref-set` are allocation-free.

## Wire 1.6 — expression-level locations

The frontend bridge wire advances to `1.6` so the OCaml frontend wraps
**inner expressions** in `(located (loc <file> <line> <col> <end_line>
<end_col>) <expr>)` — previously only top-level let bindings carried a
`located` wrapper. The Zig reader already accepted `located` at any
expression position, so ANF lowering now stamps expression-level
locations into Core IR: `--no-alloc` and region-inference diagnostics
point at the offending expression instead of the enclosing declaration,
and BPF source maps gain expression-granularity entries.

Synthetic (desugared) expressions and ghost locations stay unwrapped and
parse as `Loc.unknown`, exactly as before. The `1.6` reader was a strict
additive extension of `1.5`: every prior wire shape continues to parse.
`omlz check --wire=1.5 ...` remains the compatibility window that
re-emits the decl-only-located shape.

## Wire 1.7 — annotated parameters

The frontend bridge wire advances to `1.7` so explicitly annotated
lambda / `let rec` parameters are distinguishable from inferred ones:
a parameter written `(m : account_meta)` in the source emits as
`(m (ty! (type-ref account_meta)))` — the same arity as the wire 1.3
`(name (ty <type-expr>))` shape, with the distinct `ty!` tag. Unannotated
parameters keep the plain `ty` tag.

Motivation (CR-13): explicit annotations must beat the Core IR
parameter-classification heuristics. Previously a helper like
`let meta_flags (m : account_meta) = ... m.is_signer ... m.is_writable ...`
was reclassified as taking an entrypoint `account` (flags-only reads are
wire-indistinguishable from bare account params), breaking native/BPF
account-view layout. With the `ty!` marker, lowering uses the annotated
wire type directly; the heuristics now only govern unannotated
parameters (`_`-prefixed params stay `unit` and instruction-data names
stay `string`, both unchanged).

The `1.7` reader is a strict additive extension of `1.6`: every prior
wire shape continues to parse, and `ty` params follow the old
heuristic-priority path. Wire 1.7 is the new default; `omlz check
--wire=1.6 ...` is the one-mission compatibility window that re-emits
the plain-`ty` shape.

## ADR-016 — multi-file modules: no wire change

ADR-016 (frontend-level `open Foo` multi-file support) needed no wire bump:
the joined multi-file output is valid `1.7`. Every `(loc <file> <line> <col>
<end_line> <end_col>)` node already carries a file atom; the only observable
difference is that the `loc` file fields now vary per node within one sexp.
