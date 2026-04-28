# 05 — Backends

> **Languages / 语言**: **English** · [简体中文](./zh/05-backends.md)

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

- `OCamlBackend`      — placeholder. Note: the subset oracle role
  this slot used to claim has been removed because ADR-010 makes
  drift impossible by construction; the upstream OCaml compiler is
  *already* on the main path as the frontend.
- `LlvmBackend`       — placeholder.

## 2. ZigBackend

### 2.1 Inputs

`Lowered IR` produced by `ArenaStrategy`. The backend is **not**
allowed to read upstream `Typedtree`, the sexp wire format, the
Zig `ttree` mirror, or Core IR directly.

### 2.2 Output

A single `.zig` source file plus a `build.zig` snippet that drives
the toolchain for the requested target. For `--target=bpf` the
chain is `zig build-lib -target bpfel-freestanding -femit-llvm-bc`
followed by `sbpf-linker --cpu v2 --export entrypoint`, producing
`program.so` (see `06-bpf-target.md` §2 / §6, ADR-012, ADR-013).

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
| `TyAdt` (all-nullary) | `enum(uN)` / tagged-immediate helper |
| `TyAdt` (with payload) | `union(enum)` helper in `runtime/zig/prelude.zig` |
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
arithmetic. Division and modulus use small runtime helpers around
`@divTrunc` and `@rem` so the zero-divisor panic path and the
`min_int / -1` edge case are shared across targets. The exact pinned
semantics are part of the determinism contract in §6.

### 2.6 Naming

Generated identifiers are prefixed `omlz_` to avoid collisions with
the runtime. Source-level identifiers are sanitized into Zig-safe names. P1 does not yet
carry a separate `Symbol` id in Core IR, so examples avoid ambiguous emitted
name collisions.

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

### Pinned integer semantics (ADR-008 / F14)

ZxCaml `int` is deliberately pinned to **signed 64-bit `i64`** in P1.
This diverges from upstream OCaml on 64-bit hosts, where `int` is a
63-bit immediate (`max_int = 4611686018427387903`). In ZxCaml,
`max_int = 9223372036854775807` and `min_int = -9223372036854775808`.

The interpreter and ZigBackend must be byte-identical on these rules:

- `+`, `-`, and `*` wrap on overflow exactly like Zig `+%`, `-%`, and
  `*%` (`max_int + 1 = min_int`, `min_int - 1 = max_int`,
  `min_int * -1 = min_int`).
- `/` truncates toward zero. `min_int / -1` is pinned to `min_int` so
  this overflow edge also wraps instead of backend-trapping.
- `mod` uses Zig/OCaml-style remainder semantics. `min_int mod -1` is
  pinned to `0`.
- Division or modulus by zero is a user-program panic with the stable
  marker `ZXCAML_PANIC:division_by_zero`; the interpreter prints the
  marker and exits non-zero, and generated hosted binaries print the
  same marker before exiting non-zero. BPF/freestanding builds use the
  no-return panic path in `runtime/zig/panic.zig`.
