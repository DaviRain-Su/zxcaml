# 07 — Repo layout

> **Languages / 语言**: **English** · [简体中文](./zh/07-repo-layout.md)

## 1. Top-level

```text
ZxCaml/
├── README.md
├── docs/                       -- design docs (this directory)
├── build.zig                   -- single build driver (ADR-011)
├── build.zig.zon               -- pinned to Zig 0.16
├── src/
│   ├── frontend/               -- OCaml glue (zxc-frontend)
│   │   ├── zxc_frontend.ml
│   │   ├── zxc_subset.ml
│   │   ├── zxc_sexp.ml
│   │   └── zxc_sexp_format.md  -- the wire contract
│   ├── frontend_bridge/        -- Zig sexp consumer
│   │   ├── sexp_lexer.zig
│   │   ├── sexp_parser.zig
│   │   └── ttree.zig           -- Zig mirror of accepted Typedtree subset
│   ├── core/                   -- Core IR (ANF, Layout)
│   ├── lower/                  -- ArenaStrategy (P1)
│   ├── backend/                -- ZigBackend, Interpreter, stubs
│   ├── driver/                 -- CLI pipeline, BPF wiring
│   ├── util/                   -- arena, diagnostics, interner
│   ├── main.zig                -- omlz entry point
│   └── root.zig                -- library re-exports for tests
├── runtime/
│   └── zig/                    -- runtime helpers linked into user programs
├── stdlib/
│   └── core.ml                 -- option / result / list (real OCaml; subset)
├── examples/                   -- acceptance corpus + smoke fixtures
│   ├── hello.ml
│   ├── option_chain.ml
│   ├── result_basic.ml
│   ├── list_sum.ml
│   ├── enum_adt.ml / tree_adt.ml
│   ├── nested_pattern.ml / guard_match.ml
│   ├── tuple_basic.ml / record_person.ml
│   ├── stdlib_list.ml / closure_adt.ml
│   └── solana_hello.ml         -- BPF acceptance program
├── tests/
│   ├── ui/                     -- end-to-end .ml → expected output
│   ├── golden/                 -- Core IR + sexp snapshot tests
│   └── solana/                 -- solana-test-validator integration
└── .github/workflows/          -- CI
```

### 1.1 Two-language boundary

The repo contains exactly one inter-language boundary, at
`src/frontend/` (OCaml) ↔ `src/frontend_bridge/` (Zig). Both
sides are small. There is no other OCaml in the repo and no
other inter-language seam. Build orchestration is in
`build.zig`, which invokes `ocamlfind` to compile the OCaml side
(see `09-decisions.md` ADR-011).

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
├── frontend/                   -- OCaml-side glue (compiled to native binary)
│   ├── zxc_frontend.ml         -- main; drives compiler-libs
│   ├── zxc_subset.ml           -- Typedtree subset whitelist + walker
│   ├── zxc_sexp.ml             -- S-expression serialiser
│   └── zxc_sexp_format.md      -- the versioned wire contract
│
├── frontend_bridge/            -- Zig consumer of the sexp
│   ├── sexp_lexer.zig
│   ├── sexp_parser.zig
│   └── ttree.zig               -- Zig mirror of accepted Typedtree subset
│
├── core/
│   ├── ir.zig                  -- Core IR data model (CONTRACT)
│   ├── layout.zig              -- Region / Repr / Layout (EXTENSION POINT)
│   ├── anf.zig                 -- ttree → Core IR
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
│   ├── ocaml_stub.zig          -- compile-only stub (NOT the frontend; see frontend/)
│   └── llvm_stub.zig           -- compile-only stub
│
└── driver/
    ├── pipeline.zig            -- spawns zxc-frontend, drives the rest
    ├── build.zig               -- invokes ZigBackend, then `zig build-lib` + `sbpf-linker`
    └── bpf.zig                 -- BPF target wiring
```

`src/syntax/` and `src/types/` from the previous draft are gone.
Their responsibilities now live in `src/frontend/` (OCaml) and
`src/frontend_bridge/` (Zig) respectively. This is the concrete
realisation of ADR-010.

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
├── option_chain.ml             -- Option.map / Option.bind acceptance
├── result_basic.ml             -- Result construction and pattern matching
├── list_sum.ml                 -- recursive sum over a list
├── enum_adt.ml                 -- user-defined enum ADT
├── option_adt.ml / tree_adt.ml -- parameterized and recursive ADTs
├── nested_pattern.ml           -- nested constructor patterns
├── guard_match.ml              -- guarded match arms + decision-tree dispatch
├── tuple_basic.ml              -- tuple construction/destructuring and ADT payloads
├── record_person.ml            -- records, field access, functional update
├── stdlib_list.ml              -- expanded List functions with closures
├── closure_adt.ml              -- closures capturing ADT values
├── solana_hello.ml             -- canonical BPF acceptance program
├── factorial.ml                -- recursion smoke test
├── arith_wrap.ml               -- i64 wrap semantics smoke test
├── div_zero.ml                 -- stable division-by-zero panic marker
└── m0_unsupported.ml           -- intentional negative diagnostic fixture
```

`examples/` is also a regression suite. Corpus loops must skip
`m0_unsupported.ml`, which is expected to fail.

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
    ├── hello/                  -- canonical BPF acceptance harness
    │   ├── solana_hello.ml
    │   ├── invoke.sh           -- shells solana-test-validator + deploy
    │   └── expected_output.txt -- stable final lines from invoke.sh
    └── closures/               -- P2 BPF closure acceptance harness
        └── invoke.sh
```

The `tests/solana/` harness is opt-in (slow, requires the Solana
toolchain) and not run on every commit. Run it only with
`SOLANA_BPF=1 tests/solana/hello/invoke.sh`; without that environment
variable the script prints a skip message and exits successfully. P1
acceptance is gated on it.


## 7. `.github/workflows/`

The CI surface remains `.github/workflows/ci.yml` on `push` to `main` and on pull
requests. The workflow runs on `macos-latest` and `ubuntu-latest`, calls
the same root `./init.sh` used locally, then runs:

```text
zig build
zig build test
zig-out/bin/omlz check examples/*.ml   # skipping m0_unsupported.ml
tests/solana/hello/invoke.sh          # when SOLANA_BPF=1
```

P2 uses the same build/test commands as P1. The examples corpus loop is
glob-based, so new P2 examples are checked without structural CI changes. The
Solana BPF harness remains opt-in by environment variable; closure acceptance
can be run locally with `SOLANA_BPF=1 tests/solana/closures/invoke.sh`.

## 8. Conventions

- **No git submodules.** Vendor or fetch via `build.zig.zon`.
- **No code generation outside `out/`.** Generated `.zig` files
  never land in `src/`.
- **No mutable state in `src/util/`.** Everything is per-compilation.
- **Tests live with the area they test**, except for end-to-end suites
  under `tests/`.
