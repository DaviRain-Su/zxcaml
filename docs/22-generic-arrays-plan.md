# 22 — Generic arrays plan

> **Languages / 语言**: **English** · [简体中文](./zh/22-generic-arrays-plan.md)

> **Status:** Planning scaffold for the ADR-015 array follow-up. This document
> does not change compiler behavior by itself; each slice below lands as its
> own change with scope and validation evidence.

## Why now

R9 (ADR-015 option B) pinned arrays to `int` elements. Three later changes
removed the original blockers:

- the interpreter's array values are no longer `[]i64` but generic values
  (landed with the PDA slice — `bytes array` seeds already flow through it);
- tuple types are interned as named structs in generated Zig, so composite
  element types have stable nominal identity across function boundaries;
- the wire `array-lit` shape has carried an element-type slot
  (`(ty (type-ref int))`) since R9 — widening what the slot may contain is
  additive within wire `1.7`.

What remains is lifting the `int`-only gates in the frontend subset checker
and the ANF/codegen array paths.

## Scope

Two slices, in order:

1. **Slice 1 — scalar-ish elements:** `bool`, `string`/`bytes` element types
   for `[| ... |]`, `Array.get`, `Array.set`, `Array.length`, literal-size
   `Array.make`, and `Array.of_list`. These reuse existing flat/boxed value
   layouts and need no new type machinery.
2. **Slice 2 — composite elements:** record and tuple element types, leaning
   on tuple interning and the existing record type declarations.
   `account_meta array` is the motivating case (CPI metas are built today
   through `Array.of_list` only).

## Non-goals (anti-creep)

- **Dynamic-size `Array.make`** stays out (tracked separately as A2 in the
  internal funnel); sizes remain non-negative int literals, E0019 unchanged
  for dynamic shapes.
- No `Array.init`, `Array.map`, slicing, or new stdlib array combinators.
- No polymorphic (`'a array`) declarations — element types must be concrete
  at each use site.
- No change to the arena-only memory model or the `no_alloc` contract
  semantics: arrays remain arena allocations; only the element-type gate
  widens.
- No wire bump: the element-type slot already exists; the frontend simply
  stops forcing `(type-ref int)` into it.

## Implementation map

| Layer | Today | Change |
|---|---|---|
| `src/frontend/zxc_subset.ml` | rejects non-`int` element types around the E0019 family | gate per-slice element-type whitelist; emit the real element type |
| `src/core/anf/expr_lowering.zig` (`lowerArrayLit`/`Get`/`Set`/`Make`) | hardcodes `.Int` element ty | derive the element ty from the wire `ty` slot |
| `src/backend/zig_codegen` array emission | `i64` slices and helpers | render element types via `zigTypeName` (interned names for composites) |
| `src/backend/interp.zig` | generic `[]Value` arrays (already landed) | extend element coercion checks only |
| `src/core/no_alloc.zig` / `static_report` | int-array allocation class | classify per element type; messages stay expression-precise |
| Diagnostics | E0019 covers all non-int shapes | E0019 narrows to the still-rejected shapes; `--explain` text updated |

## Acceptance gates (per slice)

1. Examples: at least one new example per slice (registered in the manifest,
   counts bumped) passing the interpreter≡native determinism gate and a BPF
   build; slice 2 adds a Mollusk case exercising `account_meta array`
   construction via literals.
2. UI fixtures pin the still-rejected shapes (dynamic size, unsupported
   element types) with expression-precise spans.
3. The standard validator floor stays green:

   ```sh
   zig build
   zig build test --summary none
   cargo test --manifest-path tests/Cargo.toml
   ./scripts/check_examples_corpus.sh
   ./scripts/check_docs_sync.sh
   ```

4. Goldens: existing `.core.snapshot` files stay byte-identical (int arrays
   keep their exact current lowering); new goldens may be added for the new
   element types.
5. Docs: `docs/02-grammar.md` and the E0019 entry move bilingually with each
   slice.
