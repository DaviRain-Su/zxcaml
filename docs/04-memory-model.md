# 04 — Memory model

> **Languages / 语言**: **English** · [简体中文](./zh/04-memory-model.md)

## 1. Position

ZxCaml started in Phase 1 with **one** base memory model:

> A single arena per program, allocated up-front, used for every
> heap value. No GC, no reference counting, no per-value lifetime.
> The user does **not** see the model — they write OCaml.

The `Layout` field on Core IR allocations is a **compiler-facing
descriptor**, not a user-facing knob. Sealed P6 uses it for region inference
and stack placement of non-escaping locals. RC/ownership regimes remain
optional research outside the sealed P4-P8 phases.

## 2. Why arena?

For a Solana BPF program:

- The execution model is bounded and deterministic.
- The total live memory is small (kilobytes, not megabytes).
- There is no thread of long-running mutation; programs are
  request/response shaped.
- Anything dynamic must be cheap to allocate and trivially
  reclaimable.

A bump arena fits perfectly: O(1) allocation, zero per-object
overhead, and reclamation is "drop the arena" at program end.


## 3. The single-arena rule

As built, `runtime/zig/arena.zig` exposes a small caller-owned bump
arena:

```zig
pub const Arena = struct {
    buffer: []u8,
    offset: usize,

    pub fn fromStaticBuffer(buf: []u8) Arena
    pub fn alloc(self: *Arena, comptime T: type, count: usize) ![]T
    pub fn reset(self: *Arena) void
};
```

The arena does **not** own memory. The BPF entry shim provides a static
byte buffer, constructs `Arena.fromStaticBuffer(&buf)`, and compiled
functions receive `arena: *Arena` as an implicit first parameter. `alloc`
performs checked size arithmetic, alignment via `std.mem.alignForward`,
and returns `error.OutOfMemory` when the static buffer is exhausted.
`reset` rewinds the bump cursor at program exit.

## 4. What goes where

| Value class | Region | Repr |
|---|---|---|
| integer constants | Static | Flat |
| unit values / unit parameters | Static | Flat |
| nullary constructors (`None`, `[]`) | Static | TaggedImmediate |
| string literals | Static | Boxed (pointer to read-only data) |
| payload constructors / list cons cells | Arena | Boxed |
| top-level lambdas | Arena | Flat |
| first-class closure records | Arena | Boxed |
| `ref` cells (int / bool, ADR-015 R10) | Arena | Boxed (single-slot) |
| proven non-escaping lowered values | Stack | Boxed |

These rules live in `Typed AST → Core IR` lowering (see
`03-core-ir.md` §4). They are the **only** knob the frontend
controls.

## 5. ADT and aggregate representation

For an ADT with `n` variants:

- If all variants are nullary: encode as a small integer
  (`u8`/`u16`), `TaggedImmediate`.
- Otherwise: a flat struct
  ```
  struct {
    tag: uN,                         // discriminator
    payload: union { v0_struct, v1_struct, ... },
  }
  ```
  pointed to by a `Boxed` pointer into the arena.

The backend chooses the discriminator width. The interpreter is
allowed to use a tagged-union representation native to the host
language and is not bound by these encodings.


## 6. Closure and recursion representation

The current pipeline has three as-built cases:

1. **Top-level functions** lower to direct Zig helper functions using the
   arena-threaded calling convention.
2. **Nested recursive functions that do not escape** are lowered as direct
   helper functions with captured values threaded as extra parameters.
3. **First-class closures** are represented in Lowered IR as arena-backed
   closure records with explicit capture storage and typed closure-call
   metadata. P2 hardened the BPF path so closure examples no longer rely on
   unsupported code-pointer relocations; closure acceptance lives under
   `tests/solana/closures/` and the examples corpus includes closure + ADT
   and stdlib higher-order cases.

The user still sees none of this machinery; they write ordinary `let` /
`let rec` / `fun` OCaml subset code.

## 7. Strings

Strings started as read-only literals plus equality/length support. The sealed
P7/P8 compiler surface now also covers string operations such as concatenation,
`String.length`, `String.get`, and `String.sub`, while still avoiding a general
OCaml runtime or GC. Formatting remains intentionally narrow for BPF-bound
programs.

## 8. What is **not** allowed

- Mutation of values via mutable record fields outside the
  `AccountFieldSet` Solana surface.
  - ADR-015 R9.2 lifts the array exception: `int` arrays accept in-place
    writes via `Array.set` / `a.(i) <- v`, and `Array.make N init` (with
    literal `N`) returns a writable arena slice. The storage is still
    arena-owned and never escapes the per-call lifetime.
  - ADR-015 R10 lifts a `ref`-cell exception: single-cell `ref` of `int`
    and `bool` is accepted. Ref cells are arena-allocated: each `ref e`
    reserves a single slot in the arena; reads (`!r`) and writes
    (`r := v`) compile to direct pointer ops with no GC or RC. `ref` of
    unsupported element types (string, record, list, polymorphic)
    remains rejected with `E0013`.
- Exceptions (no `try` / `raise`).
- Recursion that allocates without bound (allowed; see §9).
- Any allocation outside the arena.

## 9. Stack / recursion budget

BPF imposes a fixed call stack. The frontend cannot statically
bound recursion in P1, so:

- The Zig backend emits Zig functions; `zig`'s own stack analysis
  applies.
- The runtime arena is sized at compile time. Native entry programs keep a
  32 KiB arena; BPF entry programs use a 3 KiB stack-bounded arena so the
  loader entrypoint remains below SBF's 4 KiB per-frame limit.
- Stack overflow inside a BPF program is reported by Solana, not
  by us.

The sealed P3 Solana work introduced `omlz check --no-alloc`, a conservative
analysis for hot paths that verifies a Core IR graph has no arena-allocation
sites.

## 10. Forward compatibility

The path from "P1 single arena" to sealed P6 region inference was:

1. Keep the `Layout` field on every allocation. ✅
2. Add escape analysis that identifies non-escaping local values. ✅
3. Refine lowering/codegen so stack-eligible locals avoid arena allocation. ✅
4. Preserve the Core IR contract while backends consume the refined layout. ✅

A possible optional path to ownership / RC remains:

1. Introduce `Region::Rc` and a borrow / move analysis.
2. Update lowering to emit `inc_ref` / `dec_ref` calls around
   `Boxed` values whose region is `Rc`.
3. Backend gains an `Rc` runtime helper; existing `Arena` paths
   are untouched.

In both cases, the Core IR variant set grows; existing code paths
do not change.

## 11. What this document does **not** specify

- The exact byte layout of records and ADTs (the backend chooses).
- The arena's allocation strategy (bump? slab? page-aligned?). The
  P1 default is single-bump from a statically-sized buffer.
- Multi-threading, concurrency, or pinning. Out of scope.
