# 05 — Backends

## 1. Backend trait (conceptual)

A backend consumes `Lowered IR` (or, for the interpreter, `Core IR`
directly) and produces *something*. The trait is the same shape in
both cases.

```text
Backend:
  name              : string
  target_triple()   : string                     -- informational
  emit_module(m)    : EmitResult
  link(parts...)    : LinkResult                 -- backend-specific

  -- diagnostics surface
  pretty_emit(m)    : string                     -- always available
```

Returned objects are POD; backends are stateless w.r.t. each call.

P1 ships:

- `ZigBackend`        — main path, produces `.zig` source.
- `Interpreter`       — dev-only, executes Core IR.

P1 stubs (signatures only, must compile, must return "not
implemented" diagnostics if invoked):

- `OCamlBackend`      — sanity oracle for the stdlib subset.
- `LlvmBackend`       — placeholder.

## 2. ZigBackend

### 2.1 Inputs

`Lowered IR` produced by `ArenaStrategy`. The backend is **not**
allowed to read Surface or Typed AST.

### 2.2 Output

A single `.zig` source file plus a `build.zig` snippet that drives
`zig build-obj` for the requested target.

```text
out/
├── program.zig         -- generated user code
├── runtime.zig         -- copy of runtime/zig/* needed at link time
└── build.zig           -- minimal driver, generated
```

### 2.3 Mapping

| Core IR / Lowered IR | Zig output |
|---|---|
| `TyInt` | `i64` (BPF ABI), `i64` for native |
| `TyBool` | `bool` |
| `TyUnit` | `void` (or `u0`, internal choice) |
| `TyString` | `[]const u8` (read-only slice) |
| `TyTuple` | anonymous `struct` |
| `TyAdt` (all-nullary) | `enum(uN)` |
| `TyAdt` (with payload) | `struct { tag: uN, payload: union(enum) {...} }` |
| `TyRecord` | `struct { ... }` |
| `RLam` | top-level `fn` + heap-allocated capture struct |
| `RApp` | direct `fn` call (known callee) or indirect through closure |
| `RCtor` | struct literal placed in arena |
| `RProj` | `obj.*.field` |
| `EMatch` | `switch` on the discriminator + per-arm bindings |
| `EIf` | `if (cond) ... else ...` |
| `RPrim IAdd / ...` | Zig native operators (with wrap semantics decided per op; see §2.5) |

### 2.4 Arena threading

Every emitted function takes `arena: *Arena` as its first parameter.
The entrypoint shim (`runtime/zig/bpf_entry.zig`) creates an arena
from a static buffer and calls user `main` with it.

### 2.5 Integer semantics

P1 emits `i64` and uses Zig's `+%`, `-%`, `*%` (wrapping) for
arithmetic. OCaml's standard integers are wrap-around on overflow,
which matches `+%` semantics. Division and modulus map to `@divTrunc`
and `@rem` to keep behaviour consistent with OCaml's `/` and `mod`.

### 2.6 Naming

Generated identifiers are prefixed `omlz_` to avoid collisions with
the runtime. Source-level identifiers are mangled with their
`Symbol` id to handle shadowing.

### 2.7 What it does **not** do

- No optimisation passes. Trust `zig` (`-O ReleaseSmall` for BPF).
- No incremental output. Whole module per invocation.
- No source-mapping debug info in P1.

## 3. Interpreter

### 3.1 Purpose

- Drive `omlz run` for fast iteration.
- Serve as a semantic oracle in tests: the same program executed by
  the interpreter and by the Zig backend must produce the same
  observable result.

### 3.2 Inputs

`Core IR` directly — the interpreter does not consume Lowered IR.
This means the interpreter is **independent** of the lowering
strategy and tests can isolate "frontend bugs" from "backend bugs".

### 3.3 Implementation sketch

- A tagged-union `Value` type in the host (Zig).
- Closures are pairs `(env, body)` allocated in a host arena.
- Pattern matching is a recursive walk; no compile-down to
  decision trees in P1.
- ADTs are represented as `{ tag, payload: []Value }`.

### 3.4 Limitations

- Recursive functions: stack-bounded by host stack.
- Strings: read-only, no concatenation (matches P1 stdlib).
- I/O: only `print` to stdout (interpreter-only, not a stdlib
  function — exposed via a CLI flag).

## 4. Stub backends

`OCamlBackend` and `LlvmBackend` are present **only** so that the
backend trait is exercised by more than one implementor and the
extension point is provably useful. They:

- Implement the trait signatures.
- Return `error.NotImplemented` (or the host equivalent) from
  `emit_module`.
- Are excluded from the default build but are present in the trait
  switch `omlz build --backend=...`.

## 5. Backend selection

CLI:

```
omlz build foo.ml --backend=zig --target=bpf
omlz build foo.ml --backend=zig --target=native      # incidental, unsupported
omlz run   foo.ml                                     # always interpreter
```

Driver logic:

1. Parse, type-check, lower to Core IR.
2. If `run`: hand Core IR to `Interpreter`, print result.
3. If `build`:
   a. Apply `ArenaStrategy` → Lowered IR.
   b. Hand Lowered IR to selected backend.
   c. Backend emits artefacts; driver invokes external tools (`zig`).

## 6. Determinism requirement

For any program in the P1 subset and any input:

```
Interpreter(P)  ≡  ZigBackend(P)  (mod observable outputs)
```

This is an **enforced invariant**, checked by a property suite that
runs a corpus of `.ml` files through both and diffs the results.
Failures are P0 bugs.
