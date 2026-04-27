# 07 — Repo layout

## 1. Top-level

```text
ZxCaml/
├── README.md
├── docs/                       -- design docs (this directory)
├── build.zig                   -- compiler build script
├── build.zig.zon               -- pinned to Zig 0.16
├── src/                        -- compiler source (Zig)
├── runtime/
│   └── zig/                    -- runtime helpers linked into user programs
├── stdlib/
│   └── core.ml                 -- option / result / list, written in our subset
├── examples/
│   ├── hello.ml                -- interpreter + Zig backend smoke test
│   └── solana_hello.ml         -- BPF acceptance program
├── tests/
│   ├── ui/                     -- end-to-end .ml → expected output
│   ├── golden/                 -- Core IR snapshot tests
│   └── solana/                 -- solana-test-validator integration
└── .github/workflows/          -- CI (post-P1)
```

## 2. `src/` (the compiler)

```text
src/
├── main.zig                    -- CLI entry: omlz check/build/run
├── root.zig                    -- library re-exports for tests
│
├── util/
│   ├── arena.zig               -- compiler-internal arena (NOT user-facing)
│   ├── diag.zig                -- diagnostics with spans
│   └── intern.zig              -- string / symbol interner
│
├── syntax/
│   ├── token.zig
│   ├── lexer.zig
│   ├── parser.zig              -- hand-written, recursive descent + Pratt
│   └── ast.zig                 -- Surface AST
│
├── types/
│   ├── ty.zig                  -- Ty representation
│   ├── env.zig                 -- TypeEnv
│   ├── unify.zig               -- union-find unification
│   └── infer.zig               -- HM inference + ADT
│
├── core/
│   ├── ir.zig                  -- Core IR data model (CONTRACT)
│   ├── layout.zig              -- Region / Repr / Layout (EXTENSION POINT)
│   ├── anf.zig                 -- Typed AST → Core IR
│   └── pretty.zig              -- IR pretty-printer (golden tests)
│
├── lower/
│   ├── strategy.zig            -- LoweringStrategy interface (EXTENSION POINT)
│   ├── lir.zig                 -- Lowered IR
│   └── arena.zig               -- ArenaStrategy (P1 only impl)
│
├── backend/
│   ├── api.zig                 -- Backend interface (EXTENSION POINT)
│   ├── zig_codegen.zig         -- ZigBackend
│   ├── interp.zig              -- tree-walk interpreter
│   ├── ocaml_stub.zig          -- compile-only stub
│   └── llvm_stub.zig           -- compile-only stub
│
└── driver/
    ├── pipeline.zig            -- frontend pipeline (parse → typecheck → ANF)
    ├── build.zig               -- invokes ZigBackend, then `zig build-obj`
    └── bpf.zig                 -- BPF target wiring
```

### 2.1 Files marked **EXTENSION POINT**

These are the only places that future phases (P3+ memory models, P5+
backends) are expected to extend. Touching anything else to add a new
backend or memory model is a smell.

- `src/core/layout.zig`
- `src/lower/strategy.zig`
- `src/backend/api.zig`

### 2.2 Files marked **CONTRACT**

The Core IR data model is the project's stable contract. Changes
here must update **all** consumers (anf, lower, interp, zig_codegen,
pretty) in the same change.

- `src/core/ir.zig`

## 3. `runtime/zig/`

```text
runtime/zig/
├── arena.zig                   -- bump allocator
├── panic.zig                   -- BPF-safe panic
├── prelude.zig                 -- list cons / tuple helpers / wrap arith
└── bpf_entry.zig               -- entrypoint shim for Solana
```

These files are **copied** (or `@embedFile`'d) into the generated
output, not statically linked from the compiler. They are user-program
artefacts.

## 4. `stdlib/`

```text
stdlib/
└── core.ml                     -- option, result, list, basic combinators
```

Rules for `stdlib/`:

- Must parse with `omlz`.
- Must also parse with the real `ocaml` compiler when present (CI gate).
- May not import anything from `runtime/zig/`. The compiler injects
  the runtime; stdlib is pure surface code.

## 5. `examples/`

```text
examples/
├── hello.ml                    -- list head + Some/None demo
└── solana_hello.ml             -- minimal BPF entrypoint
```

`examples/` is also a regression suite: if any example fails to
compile, P1 is broken.

## 6. `tests/`

```text
tests/
├── ui/                         -- end-to-end: .ml file + .expected stdout
│   ├── hello.ml
│   └── hello.expected
├── golden/                     -- IR snapshot tests
│   ├── hello.ml
│   └── hello.core.snapshot
└── solana/
    ├── hello/                  -- the BPF acceptance harness
    │   ├── solana_hello.ml
    │   └── invoke.sh           -- shells solana-test-validator + deploy
```

The `tests/solana/` harness is opt-in (slow, requires the Solana
toolchain) and not run on every commit. P1 acceptance is gated on it.

## 7. `.github/workflows/` (post-P1, illustrative)

```text
ci.yml:
  - matrix: zig 0.16.x
  - steps:
      - zig build
      - zig build test
      - omlz check examples/*.ml
      - tests/ui/run.sh
      - tests/golden/run.sh
      - (optional) tests/solana/hello/invoke.sh
```

## 8. Conventions

- **No git submodules.** Vendor or fetch via `build.zig.zon`.
- **No code generation outside `out/`.** Generated `.zig` files
  never land in `src/`.
- **No mutable state in `src/util/`.** Everything is per-compilation.
- **Tests live with the area they test**, except for end-to-end suites
  under `tests/`.
