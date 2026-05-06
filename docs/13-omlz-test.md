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

## Property Testing

`let%test_prop` extends the same `omlz test` loop with generated examples.
It is for algebraic laws, round-trip checks, parser-style invariants, and
small pure helpers where one hand-written `let%test_unit` case is too narrow.
A property remains ordinary OCaml source.
The upstream OCaml frontend still parses and type-checks the file.
The ZxCaml runner only adds generator sampling, repeated execution, shrinking,
and reporter fields that make a failing seed reproducible.
Use Mollusk when the behavior depends on Solana accounts or BPF loader rules.
Use `let%test_prop` when the behavior is pure enough to run through the
interpreter many times in a fast local loop.

The accepted surface form is:

```ocaml
let%test_prop "name" generator = fun x -> property_expr
```

The binding must be at module top level.
The name must be a non-empty string literal.
The expression between the name and `=` is the generator.
The right-hand side is normally a one-argument `fun` returning `bool`.
A `true` result passes that generated case.
A `false` result is treated like an assertion failure.
A body that explicitly calls `assert` may also fail by raising the normal
`ZXCAML_PANIC:assert_failure` path.
The pre-scan rejects unknown `let%...` extensions, missing names, missing
generators, and nested property bindings with the same diagnostic renderer used
by `omlz check`.
Comments are tracked before scanning, so commented-out property text is ignored.

A minimal property can define its own generator as a seed transformer:

```ocaml
let int seed = (seed, seed + 1)

let%test_prop "add commutative" int = fun x ->
  x + 7 = 7 + x
```

The generator receives the current seed and returns `(sample, next_seed)`.
`omlz test` threads the returned seed into the next sample.
Passing `--seed` therefore makes the whole sample stream deterministic.
The runner prints the chosen seed in JSON output and uses it when reporting a
failed property.
If no seed is supplied, the default is the current monotonic time.
Use an explicit seed in CI and in bug reports.

Property bodies also support a pair pattern for generators that produce tuples:

```ocaml
let int seed = (seed, seed + 1)
let pair = Generators.tuple2 int int

let%test_prop "pair addition symmetry" pair = fun (x, y) ->
  x + y = y + x
```

Internally the pre-scan rewrites a pair pattern into `fst` / `snd` bindings.
Tuple patterns currently support exactly two identifiers.
For larger structures, bind a single value and destructure it inside the body.
Keeping the pattern simple makes source locations and shrunk examples easier to
report.

The bundled generator API lives in `stdlib/generators.ml` as module
`Generators`.
Its core type is:

```ocaml
type seed = int64
type 'a generator = seed -> 'a * seed
```

The shipped combinators are:

| API | What it samples |
|---|---|
| `Generators.int_range ~low ~high` | inclusive integer range |
| `Generators.bool` | booleans |
| `Generators.string_of_len ~len` | printable ASCII strings of exact length |
| `Generators.list_of gen max_len` | lists with length `0..max_len` |
| `Generators.option_of gen` | `None` or `Some sample` |
| `Generators.tuple2 left right` | pairs sampled left-to-right |
| `Generators.map f gen` | transformed samples |
| `Generators.filter pred gen` | samples satisfying `pred`, with a retry budget |

The PRNG is a deterministic 64-bit linear congruential generator.
The same seed, generator expression, and case order produce the same stream.
`filter` has a finite retry budget so an impossible predicate fails loudly
instead of hanging the test process.
Combinators are ordinary OCaml values, so helper generators can be named,
composed, and shared across `let%test_prop` bindings.

Shrinking tries to replace the first failing sample with a smaller failing one.
The stdlib exposes paired shrinkers for the generator families:
`shrink_int`, `shrink_bool`, `shrink_string`, `shrink_list`,
`shrink_option`, `shrink_tuple2`, `shrink_map`, and `shrink_filter`.
The public helper `Generators.shrink_to_minimal` walks candidates until no
smaller failing value is found.
The runner also applies its built-in integer shrink path when the property
sample type is `int`.
It tries `0` and then binary-search-style candidates toward zero.
The shrink loop is bounded by `100` steps.
If the minimal value cannot be found within that budget, the stdlib helper
raises `Generators.shrink: budget exhausted` rather than looping forever.

Run properties with the same subcommand as unit tests:

```sh
zig-out/bin/omlz test --num-cases 100 --seed 42 examples/tests/prop_int_add.ml
```

`--num-cases N` controls how many samples each property receives.
The default is `100`.
`N` must be positive; invalid values are invocation errors and exit `2`.
`--seed N` fixes the first seed used by the property runner.
The seed is a signed decimal integer in the CLI parser.
The next seed comes from the generator result, not from the runner itself.
`--filter SUBSTR` still filters by the human-readable property name.
Explicit files still replace the default `examples/tests/*.ml` scan.

Cargo-style output marks properties with a `prop_` prefix and shows case count:

```text
running 1 tests
test examples/tests/prop_int_add.ml::prop_add commutative ... ok (10 cases)
test result: ok. 1 passed; 0 failed; finished in 0ms
```

A failure reports the source location, the executed case count, and the shrunk
counterexample:

```text
test /tmp/prop_int_add_fail.ml::prop_broken overflow assertion ... FAILED (10 cases)
  /tmp/prop_int_add_fail.ml:13:21: ZXCAML_PANIC:assert_failure; FAILED after 1 tests; shrunk to: 0 (in 1 shrink steps)
test result: FAILED. 0 passed; 1 failed; finished in 0ms
```

The same run with `--format=json` emits JSON Lines.
For property cases, each test object includes `kind:"prop"`, `num_cases`, and
`seed`.
Failing property objects additionally include `message`, `line`, `col`,
`shrunk_steps`, and `counterexample`.
The final summary object keeps the existing `type`, `status`, `total`,
`passed`, `failed`, and `elapsed_ms` fields.
Tooling should parse JSON Lines instead of scraping the cargo text.

The default corpus now includes three passing property demos:
`examples/tests/prop_list_rev.ml`, `examples/tests/prop_string_concat.ml`, and
`examples/tests/prop_int_add.ml`.
There is also `examples/tests/prop_int_add.fail.ml.template` for demos and
regression notes.
Templates are not scanned by the default `*.ml` discovery rule.
Copy a template to a temporary `.ml` file when you want to show a failure and a
shrunk counterexample.

This feature is intentionally smaller than QuickCheck or Hypothesis.
Like QuickCheck, it treats a property as a predicate over generated samples and
prints a replay seed when a case fails.
Like both QuickCheck and Hypothesis, it tries to shrink failing examples before
reporting them.
Unlike QuickCheck, ZxCaml does not infer generators from types.
You pass the generator expression explicitly in the `let%test_prop` header.
Unlike Hypothesis, ZxCaml does not maintain an example database, adaptive search
strategy, or coverage-guided exploration.
The design goal is a deterministic, dependency-free runner that fits the
existing OCaml frontend and interpreter pipeline.

Recommended practice:

- Keep generators small enough that `100` cases finish quickly.
- Commit explicit seeds only when reproducing a known failure.
- Prefer generated values that exercise pure helper logic before BPF builds.
- Use pair properties for simple relations and destructure larger values inside
  the body.
- Use JSON output for editors, CI annotations, and automated triage.
- Keep `.fail.ml.template` files out of the default scan by preserving the
  `.template` suffix.
- Escalate Solana account-state invariants to Mollusk instead of forcing them
  into property tests.
