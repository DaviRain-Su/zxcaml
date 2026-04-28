# 04 — Memory model

> **Languages / 语言**: **English** · [简体中文](./zh/04-memory-model.md)

## 1. Position

In Phase 1, ZxCaml has **one** memory model:

> A single arena per program, allocated up-front, used for every
> heap value. No GC, no reference counting, no per-value lifetime.
> The user does **not** see the model — they write OCaml.

The `Layout` field on Core IR allocations is a **forward-compatible
descriptor**, not a user-facing knob. It is there so that future
phases can introduce more sophisticated regimes (region inference,
RC, ownership) without re-architecting.

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
| reserved future non-escaping values | Stack | Boxed |

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

## 7. Strings (P1)

Strings exist only at the granularity of:

- string literals (interned, in `Static`),
- equality and length on strings (used by the interpreter and stdlib
  diagnostics).

There is **no** string concatenation, formatting, or allocation at
runtime in P1. This is intentional: strings are an attractive
nuisance for anything BPF-bound.

## 8. What is **not** allowed

- Mutation of any value (`ref`, mutable record fields, arrays).
- Exceptions (no `try` / `raise`).
- Recursion that allocates without bound (allowed; see §9).
- Any allocation outside the arena.

## 9. Stack / recursion budget

BPF imposes a fixed call stack. The frontend cannot statically
bound recursion in P1, so:

- The Zig backend emits Zig functions; `zig`'s own stack analysis
  applies.
- The runtime arena is sized at compile time via a build-time
  constant (default: 32 KiB; overridable via a CLI flag).
- Stack overflow inside a BPF program is reported by Solana, not
  by us.

P3 introduces an optional "no-allocation" attribute for hot paths
and runs an analysis to verify it.

## 10. Forward compatibility

The path from "P1 single arena" to "P4 region inference" is:

1. Keep the `Layout` field on every allocation. ✅ (already in P1)
2. Add `Region::Region(id)` and a region inference pass that
   refines `Arena` into specific regions.
3. Update `ArenaStrategy` (or add `RegionStrategy`) to emit per-region
   arenas instead of a single global one.
4. Backends consume the new region ids; no Core IR shape change.

The path to "P4+ ownership / RC":

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
