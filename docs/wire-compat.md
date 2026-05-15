# Wire Compatibility

DX2 bumps the frontend bridge wire from `1.1` to `1.2` so location-aware
S-expressions can carry `(loc <file> <line> <col> <end_line> <end_col>)`
annotations into the Zig bridge. See `docs/diagnostics.md` for the full
diagnostics-facing schema and `mission-internal/p9-investigation/report.md` §2
for the implementation rationale.

`omlz check --wire=1.1 ...` is a deprecated one-mission compatibility window
that forwards `--wire=1.1` to `zxc-frontend` and emits the old location-free
shape. The current `1.5` reader still accepts `1.1`/`1.2` compatibility sexps and treats missing locations
as `Loc.unknown`.

## Wire 1.3 — typed lambda parameters

R8 bumps the frontend bridge wire from `1.2` to `1.3` so the OCaml frontend
can publish a per-parameter inferred type for every `lambda` and `let rec`
binding. Each parameter is now emitted as `(name (ty <type-expr>))` instead
of the bare atom shape that 1.2 used. Unknown/polymorphic types fall back
to the `(any)` sentinel which the bridge maps to `null`, and the Core IR
lowerer falls back to its existing structural heuristics in that case.

The current `1.5` reader still accepts `1.2`/`1.3` sexps; legacy bare-atom params parse as
"untyped" and follow the original heuristic-only path. `omlz check --wire=1.2
...` (and `--wire=1.1`) remain available as one-mission compatibility windows
that re-emit the older shapes.

## Wire 1.4 — arrays and loops

R9 advances the additive wire surface for ADR-015 array/loop work. It carries
`int`-array literals and explicit array get/length/set/make nodes, plus the
loop-era desugarings used by the frontend. These shapes remain accepted by the
current `1.5` reader.

## Wire 1.5 — ref cells

R10 advances the frontend bridge wire to `1.5` to carry the three new
`ref`-cell sexp shapes introduced by ADR-015 option C:

- `(ref-make (ty <type-expr>) <init-expr>)` — allocates a single arena
  slot of element type `<type-expr>` (accepted: `(type-ref int)`,
  `(type-ref bool)`) and initialises it.
- `(ref-get <r-expr>)` — dereferences a ref cell (`!r`).
- `(ref-set <r-expr> <val-expr>)` — writes into a ref cell (`r := v`).

The `1.5` reader is a strict additive extension of `1.4`: every prior
wire shape continues to parse. Wire 1.5 is the new default. See
`src/frontend/zxc_sexp_format.md` for the canonical sexp grammar and
worked examples. `--no-alloc` rejects `ref-make` with `DX2-NOALLOC`;
`ref-get` / `ref-set` are allocation-free.
