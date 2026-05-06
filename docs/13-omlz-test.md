# 13 — `let%test_unit` and `omlz test`

> **Languages / 语言**: **English**
>
> **Scope:** OCaml-native unit tests in `.ml` files, the `omlz test` runner,
> and LSP CodeLens one-test execution.
>
> **See also:** [`docs/lsp.md`](./lsp.md),
> [`docs/diagnostics.md`](./diagnostics.md), and
> [`examples/tests/`](../examples/tests/).

## 1. Position

`let%test_unit` gives ZxCaml a fast OCaml-native test loop.
It is deliberately smaller than the Mollusk acceptance layer.
It is for pure helper logic, syntax-sensitive examples, and editor feedback.
It is not a property-test framework.
It is not a new module system.
A test remains ordinary OCaml source.
The upstream OCaml frontend still parses and type-checks the file.
ZxCaml still lowers through Core IR, ANF, optimization, and the interpreter.
The test layer adds only discovery, selection, reporting, and exit codes.
The default corpus is [`examples/tests/`](../examples/tests/).

## 2. Syntax

The only accepted form is:

```ocaml
let%test_unit "name" = expr
```

The binding must be at module top level.
The name must be a string literal.
The body must evaluate to `unit`.
Most bodies end in one or more `assert` expressions.
Example:

```ocaml
let triple x = x * 3
let%test_unit "triple works" =
  assert (triple 4 = 12)
```

A multi-line body is just an ordinary OCaml expression.

```ocaml
let%test_unit "list reverse" =
  let xs = [ 1; 2; 3 ] in
  assert (List.rev xs = [ 3; 2; 1 ])
```

Unknown `let%...` extensions are rejected.
Missing string names are rejected.
Nested `let%test_unit` bindings are rejected.
Those errors use the same rustc-style diagnostic renderer as `omlz check`.

## 3. Semantics

The frontend pre-scan rewrites each test into a hidden unit thunk.
Conceptually, this source:

```ocaml
let%test_unit "adds" = assert (1 + 1 = 2)
```

is compiled as if it had a generated shape like:

```ocaml
let __otest_unit_0__ _ : unit = assert (1 + 1 = 2)
let __otest_registry__ : (string * (unit -> unit)) list =
  [ ("adds", __otest_unit_0__) ]
```

The generated thunk has type `unit -> unit`.
The registry is a list of `(string * thunk)` pairs.
`omlz test` discovers `__otest_registry__` after Core IR lowering.
For each selected case, the runner synthesizes an `entrypoint`.
That entrypoint calls exactly one thunk and returns zero on success.
If the thunk returns normally, the test passes.
If an `assert` panics through the interpreter, the test fails.
This is why the first version is assert-driven.
No extra assertion library is required.

## 4. Discovery

With no file arguments, the runner scans:

```sh
examples/tests/*.ml
```

Only files ending in `.ml` are included.
The default file list is sorted lexicographically.
Explicit `FILE...` arguments replace the default scan.

```sh
zig-out/bin/omlz test examples/tests/list_ops.ml
```

Multiple explicit files are accepted.

```sh
zig-out/bin/omlz test examples/tests/list_ops.ml examples/tests/pda_helpers.ml
```

A missing explicit file is a setup error.
A file without a registry contributes zero tests.
The runner does not recursively scan arbitrary directories.
Pass files explicitly when tests live outside `examples/tests/`.

## 5. Filtering

`--filter SUBSTR` keeps tests whose names contain `SUBSTR`.
The match is byte-wise, case-sensitive, and substring-based.
Filtering happens after each registry is discovered.

```sh
zig-out/bin/omlz test --filter list_ops
```

The LSP uses the same path for one-test execution.
A CodeLens click forks:

```sh
zig-out/bin/omlz test --filter "selected name" --format=json FILE
```

Prefer clear and unique test names.
If two names match the same substring, both can run.

## 6. Reporter formats

The default reporter is cargo-style text.
It begins with:

```text
running N tests
```

Each passing test prints:

```text
test path/to/file.ml::test name ... ok
```

Each failing test prints:

```text
test path/to/file.ml::test name ... FAILED
  path/to/file.ml:line:col: assertion failed
```

The summary line is:

```text
test result: ok. P passed; F failed; finished in 0ms
```

Tooling should use JSON Lines:

```sh
zig-out/bin/omlz test --format=json
```

Each test object includes `type`, `file`, `name`, `status`, and `elapsed_ms`.
Failing objects also include `message`, `line`, and `col`.
The summary object includes `type`, `status`, `total`, `passed`, `failed`, and `elapsed_ms`.
The LSP consumes this JSON stream.

## 7. Exit codes

`0` means every selected test passed.
`1` means the runner completed and at least one selected test failed.
`2` means invocation or setup failed.
Unsupported flags return `2`.
Missing explicit files return `2`.
Frontend preparation failures return `2`.
An empty default scan is successful: zero tests and zero failures.
Use `1` for CI test failures.
Use `2` for command-line or environment problems.

## 8. Color and `NO_COLOR`

Cargo output uses color only when stdout is a TTY.
Pass `--no-color` to disable color.
Set `NO_COLOR=1` to disable color through the environment.
That environment also affects frontend diagnostics run by the test command.
JSON Lines output is color-free.
Prefer `--format=json --no-color` for scripts and editors.

## 9. LSP CodeLens

`omlz-lsp` advertises `textDocument/codeLens`.
For each visible `let%test_unit "name"`, the server returns a lens over the string name.
Before execution, the title is:

```text
▶ Run test "name"
```

The command is `omlz.runTest`.
The arguments are the document URI and the test name.
During execution, the server streams lines through `$/omlz.testOutput`.
It also mirrors them through `window/logMessage`.
A passing run changes the lens title to `✓ name`.
A failing run sends `window/showMessage` and changes the title to `✗ name (line N)`.
Lens collection scans in-memory text and does not run the frontend.
The actual run forks `omlz test --filter --format=json`.
The CodeLens latency harness measures five requests after warm-up.
The current p50 budget is ≤ 100 ms.

## 10. Common pitfalls

Keep tests at top level.
Use a string literal name.
Make names specific if you rely on `--filter`.
Keep bodies deterministic.
Use `omlz test` for pure logic and fast feedback.
Use Mollusk for Solana account and BPF behavior.
Use `--format=json` when another program parses output.
Use `--no-color` or `NO_COLOR=1` for plain logs.
Pass explicit files outside `examples/tests/`.
One parser trap is fixed: comments are safe.
This is valid and ignored by the pre-scan:

```ocaml
(* let%test_unit "not a real test" = assert false *)
```

The frontend tracks OCaml comment depth before looking for tests.
F-OT-FIX-COMMENT added that behavior.

## 11. Demo corpus

The default corpus currently has three `.ml` files.
`examples/tests/list_ops.ml` covers length, reverse, and map helpers.
`examples/tests/arith_overflow.ml` covers integer wraparound examples.
`examples/tests/pda_helpers.ml` covers pure PDA/pubkey helper logic.
Together they contain eight passing `let%test_unit` cases.
The `.fail.ml.template` file is for demo recording only.
It is not part of the default scan.

## 12. Layering

`let%test_unit` complements the existing test stack.
Use it before BPF builds when you want fast local confidence.
Use `zig build test` for Zig compiler and runtime unit tests.
Use Mollusk for Solana execution semantics.
Use CodeLens when the desired loop is "run the test under the cursor".
