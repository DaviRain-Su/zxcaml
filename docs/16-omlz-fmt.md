# 16 — omlz fmt formatter

> **Languages / 语言**: **English** · [简体中文](./zh/16-omlz-fmt.md)
>
> **Scope:** the canonical `omlz fmt` formatter, its CLI contract, editor-facing
> LSP formatting methods, and the bytewise idempotency guarantee shipped in
> Milestone M-FMT.
>
> **See also:** [`docs/lsp.md`](./lsp.md),
> [`docs/diagnostics.md`](./diagnostics.md),
> [`tests/omlz_fmt_subcommand_test.zig`](../tests/omlz_fmt_subcommand_test.zig),
> [`tests/omlz_fmt_golden_test.zig`](../tests/omlz_fmt_golden_test.zig), and
> [`runtime/lsp/test_harness.py`](../runtime/lsp/test_harness.py).

## 1. Position

`omlz fmt` formats ordinary ZxCaml `.ml` source.
It is a developer-experience surface, not a new language feature.
It does not change parsing, type checking, Core IR, lowering, codegen, or runtime behavior.
The formatter core lives in `src/frontend/fmt.zig`.
The CLI wrapper lives in `src/omlz/fmt.zig`.
The LSP integration lives in `src/lsp/lsp_main.zig`.
The formatter core landed in commit `40a9e22`.
The CLI subcommand landed in commit `72a0b1a`.
The golden idempotency corpus landed in commit `50e5346`.
The LSP formatting methods landed in commit `09b1a7d`.
The same input bytes produce the same formatted output bytes.
The output is intentionally stable and easy to review.
The formatter favors canonical whitespace over preserving every local style choice.
The formatter preserves comments as author-written text.
The formatter is a fixed point: formatting formatted output must not change it again.
That fixed-point rule is the shared contract for editors and CI.

## 2. Design goals

Keep `.ml` source as the only source language.
Use one formatter core for CLI and LSP surfaces.
Avoid editor-specific formatting behavior.
Use two-space indentation everywhere.
Emit spaces for indentation, never tabs.
Strip trailing horizontal whitespace.
Always write a final newline.
Keep top-level declarations visually predictable.
Do not reorder declarations.
Do not rename identifiers.
Do not normalize text inside comments.
Do not insert semantic code that was not present in source.
Make file, directory, stdin, and editor formatting share the same rules.
Make formatter failures safe: CLI reports an error, LSP returns no edits.
Keep the implementation small enough to run in process in `omlz-lsp`.
Prefer a conservative project style over a large configuration surface.

## 3. Formatter model

The core formatter is line-oriented and token-stream based.
It tokenizes identifiers, numbers, strings, chars, comments, operators, and punctuation.
It preserves string literal bytes.
It preserves char literal bytes.
It preserves comment body bytes.
It trims spaces, tabs, and carriage returns from the right side of each line.
It preserves blank lines while processing the document.
At the end, it removes trailing whitespace from the whole output.
It then appends exactly one newline.
The core formatter does not run the OCaml frontend by itself.
The CLI validates files and stdin through the frontend boundary before formatting.
The LSP path uses a lightweight structural malformed-input check before returning edits.
This split lets the CLI show compiler diagnostics while keeping editor formatting fast.
The current formatter is not a full OCaml AST pretty-printer.
It is AST-faithful in the sense that it does not intentionally change program meaning.
More precisely, it is conservative token-stream canonicalization.

## 4. Canonical layout rules

Indentation is two spaces per level.
Tabs are not emitted for indentation.
Top-level `let` starts at column zero.
Top-level `let rec` starts at column zero.
Top-level `let%test_unit` and `let%test_prop` start at column zero.
Top-level `type` starts at column zero.
Top-level `external` starts at column zero.
A top-level declaration ending in `=` increases following indentation by two spaces.
A line containing `match` can increase following indentation by two spaces.
A `match ... with` line increases following indentation by two spaces.
A match arm beginning with `|` keeps the current match-arm indentation.
A line beginning with `in` dedents by two spaces when possible.
A line beginning with `else` dedents by two spaces when possible.
A line ending in `then` increases following indentation by two spaces.
A line ending in `else` increases following indentation by two spaces.
A line ending in `=` increases following indentation by two spaces.
Short `let ... in ...` chains stay on one line when they fit.
If a `let ... in ...` chain would exceed 100 columns, it breaks before `in`.
Function application stays on one line when it fits within 100 columns including indentation.
Long applications wrap at word boundaries.
Continuation lines use current indentation plus two spaces.

## 5. Token spacing rules

Operators are surrounded by spaces.
The formatter writes `x + y`, not `x+y`.
The formatter writes `a = b`, not `a=b`.
The formatter writes `x -> y`, not `x->y`.
Commas and semicolons do not receive a leading space.
Commas and semicolons receive a following space when another token follows.
Closing delimiters `)`, `]`, and `}` do not receive a leading space.
Opening delimiters `(`, `[`, and `{` can receive a leading space after non-punctuation tokens.
Field-selection dots do not receive surrounding spaces.
Identifiers next to identifiers receive one separating space.
Numbers next to identifiers receive one separating space when tokenization requires it.
Comments force a separating space around the comment token.
Inline comments are attached after formatted code with one separating space.
The comment text itself remains verbatim.
String escapes remain verbatim.
Character escapes remain verbatim.
The formatter does not reflow docstrings.
The formatter does not align columns in tables or records.
The formatter does not attempt semantic parenthesis minimization.
Parentheses remain source tokens.

## 6. Comments and attributes

Block comments are preserved as opaque text.
Nested comment delimiters are recognized while scanning.
Lines that begin inside a multi-line comment are emitted verbatim after right-trim.
A line starting with `(*` is emitted verbatim after right-trim.
An inline `(* ... *)` comment is split from code only when it appears outside strings and chars.
The code before the inline comment is token-formatted.
The inline comment bytes are then reattached.
The formatter does not wrap long comments.
The formatter does not normalize whitespace inside comments.
The formatter does not translate comments.
Attributes shaped as `let%...` are preserved as top-level starts.
`let%test_unit` is formatted without losing the percent attribute.
`let%test_prop` is formatted without losing the percent attribute.
The golden corpus includes `let_test_unit` coverage.
The inline tests include a `let%test_prop` preservation case.
When comment layout matters, format once and review the diff.
When comments contain code examples, do not expect nested formatting inside the comment.

## 7. CLI quickstart

Build the tool first.

```sh
./init.sh
zig build
```

Format one file to stdout without changing it.

```sh
./zig-out/bin/omlz fmt examples/solana_hello.ml
```

Check whether one file is already formatted.

```sh
./zig-out/bin/omlz fmt --check examples/solana_hello.ml
```

Rewrite files in place.

```sh
./zig-out/bin/omlz fmt --write examples/solana_hello.ml
```

Read source from stdin and print formatted source to stdout.

```sh
printf 'let x=1\n' | ./zig-out/bin/omlz fmt --stdin
```

Use JSON summaries for tooling.

```sh
./zig-out/bin/omlz fmt --check --format=json examples/solana_hello.ml
```

## 8. CLI options

`--check` compares formatted output with input bytes.
`--check` exits `0` when every input is already formatted.
`--check` exits `1` when any input would change.
`--check` prints changed paths to stderr in text mode.
`--write` rewrites changed file inputs in place.
`--write` exits `0` when all writes succeed.
`--stdin` reads a single source document from standard input.
`--stdin` writes formatted text to stdout in text mode.
`--stdin` cannot be combined with positional paths.
`--stdin` cannot be combined with `--check`.
`--stdin` cannot be combined with `--write`.
`--format=text` is the default text-oriented output mode.
`--format=json` emits one JSON object per processed input.
The JSON object includes `path`, `changed`, `original_bytes`, and `formatted_bytes`.
`--no-color` disables ANSI color when frontend validation reports diagnostics.
A positional file input formats that file.
A positional directory input recurses over `*.ml` files.
Directory results are sorted lexicographically before processing.
Unsupported options exit `2`.
Malformed OCaml input exits `2` in the CLI because frontend validation fails.
Missing files exit `2`.

## 9. Exit codes and automation

Exit code `0` means the command completed successfully.
For default file mode, `0` means formatted text was printed.
For `--write`, `0` means writes completed or no writes were needed.
For `--stdin`, `0` means stdin was formatted successfully.
For `--check`, `0` means no input would be changed.
Exit code `1` is reserved for `--check` finding reformattable input.
Exit code `1` is not used for parse errors.
Exit code `2` means usage, file, or frontend validation failure.
CI should run `omlz fmt --check` and treat `1` as a style failure.
CI should treat `2` as a tool or source validity failure.
Pre-commit hooks should prefer `--write` for a developer-owned working tree.
Bots should prefer `--check --format=json` when they need machine-readable summaries.
Shell scripts should not parse human diagnostics when JSON summaries are available.
When checking directories, pass the directory path and let `omlz fmt` recurse over `.ml` files.
When checking generated files, format after generation and compare bytes once.

## 10. Idempotency guarantee

The formatter promises bytewise idempotency.
The required equation is `format(format(source)) == format(source)`.
The guarantee is about bytes, not visual similarity alone.
The formatter always writes one final newline, so the fixed point includes that newline.
The formatter strips trailing whitespace before reaching the fixed point.
The formatter has inline double-apply tests in `src/frontend/fmt.zig`.
The formatter has ten golden snapshot pairs under `tests/golden/fmt/`.
The golden test formats each `*.input.ml` file and compares it to `*.expected.ml`.
The same golden test formats each `*.expected.ml` file and expects no byte change.
The ten cases cover simple lets.
The ten cases cover let-in chains.
The ten cases cover match expressions.
The ten cases cover mutual recursion.
The ten cases cover `let%test_unit`.
The ten cases cover comments.
The ten cases cover deeply nested expressions.
The ten cases cover multi-argument functions.
The ten cases cover record patterns.
The ten cases cover string escapes.
Editors rely on this guarantee to avoid repeated format churn.
CI relies on this guarantee to keep `--check` stable.

## 11. LSP integration

`omlz-lsp` supports `textDocument/formatting`.
`omlz-lsp` supports `textDocument/rangeFormatting`.
The server advertises document formatting provider capability during `initialize`.
The server advertises document range formatting provider capability during `initialize`.
Formatting uses the in-memory document opened through `didOpen` or updated through `didChange`.
Formatting does not fork `omlz fmt`.
Formatting calls the shared `src/frontend/fmt.zig` core in process.
Full-document formatting returns an empty edit list when the document is unchanged.
Full-document formatting returns one `TextEdit` replacing the full document when the document changes.
Range formatting parses the requested LSP range.
Range formatting formats only the selected byte span.
Range formatting returns an empty edit list for invalid ranges.
Range formatting returns an empty edit list for malformed selected text.
Range formatting removes the formatter-added final newline when the original selection had no line break.
Malformed full-document formatting returns an empty edit list rather than a JSON-RPC error.
The runtime harness checks whole-document formatting.
The runtime harness checks range formatting.
The runtime harness checks malformed formatting.
The runtime harness checks median formatting latency over five measured rounds.
The FMT latency budget is p50 at or below 30 ms for files up to 500 LOC.

## 12. Editor usage

Use the same `omlz-lsp` binary documented in [`docs/lsp.md`](./lsp.md).
Editors should send standard LSP formatting requests.
Editors should pass `tabSize = 2` and `insertSpaces = true` for clarity.
The formatter currently ignores editor-specific style options and uses canonical rules.
That behavior is intentional so all editors produce the same bytes.
Use format-on-save for whole documents.
Use range formatting for focused cleanup during edits.
Do not expect range formatting to reindent surrounding unselected context.
Do not expect LSP formatting to show compiler diagnostics.
Diagnostics still arrive through `publishDiagnostics` after document sync.
If a document is syntactically malformed, diagnostics may report the problem while formatting returns no edits.
If an editor receives an empty edit list, it should leave the buffer unchanged.
If a selection does not include its trailing newline, range formatting preserves that shape.
For repository-wide cleanup, use the CLI instead of manually opening every file.

## 13. Philosophy: rustfmt, prettier, and ZxCaml

`rustfmt` is a compiler-adjacent formatter for one language ecosystem.
`prettier` is a broad syntax-tree printer for many web formats.
`omlz fmt` borrows the fixed-point expectation from both.
Like `rustfmt`, it aims to be boring enough that teams stop debating whitespace.
Like `rustfmt`, it is shipped with the toolchain rather than as a separate style package.
Like `prettier`, it favors a small number of consistent layout choices.
Unlike `prettier`, it is not trying to support many unrelated languages.
Unlike `prettier`, it does not expose a large style configuration surface.
Unlike `rustfmt`, it does not yet perform a deep AST rewrite of every construct.
ZxCaml's priority is deterministic formatting for the accepted OCaml subset.
The formatter is intentionally conservative around comments and partial ranges.
The 100-column rule is a wrapping trigger, not a promise that every output line is shorter than 100 columns.
The two-space indent is canonical and not configurable.
The formatter keeps OCaml source recognizable to OCaml developers.
The formatter avoids Solana-specific layout conventions.
The formatter is best understood as a project style contract.
The project style contract is enforced by `omlz fmt --check`.
The editor style contract is delivered by `textDocument/formatting`.

## 14. Common pitfalls

Do not combine `--check` and `--write`.
The CLI rejects that combination with exit code `2`.
Do not combine `--stdin` with positional files.
The CLI rejects that combination with exit code `2`.
Do not expect `--stdin --check` to work.
Use a temporary file or direct file mode for check workflows.
Do not expect the core formatter alone to validate OCaml syntax.
The CLI validates syntax before formatting.
The LSP path returns no formatting edits for structurally malformed text.
Do not expect comments to be reflowed.
Long comments stay long.
Do not expect alignment of record fields or table-like comments.
The formatter normalizes spacing, indentation, and wrapping, not semantic alignment.
Do not expect editor options to change indentation width.
Two spaces are always used.
Do not expect range formatting to fix surrounding lines.
Only the selected span is replaced.
Do not expect directory formatting to include non-`.ml` files.
Only files ending in `.ml` are collected.
Do not treat a `--check` exit code of `1` as a compiler error.
It means formatting would change the file.

## 15. Review checklist

Run `zig build` before invoking the installed CLI in a fresh checkout.
Run `omlz fmt --check` on files you touched before committing source changes.
Use `--format=json` when a bot needs byte counts or changed flags.
Use `--no-color` when collecting deterministic parse diagnostics from the formatter CLI.
Review comment-heavy diffs manually.
Review generated `.ml` files after changing generators.
Prefer whole-document formatting before range formatting in large refactors.
Use range formatting for small editor selections.
Check that a second formatter run produces no diff.
If a second run changes bytes, file a bug against the idempotency contract.
If LSP formatting returns no edits on valid unformatted source, compare the same source through `omlz fmt`.
If CLI formatting succeeds but LSP formatting does not, inspect structural malformed-input checks and LSP ranges.
If `--check` exits `2`, fix parse errors or missing paths before investigating style.
If `--check` exits `1`, run `--write` or inspect stdout from default mode.
Keep formatter changes in focused commits so style churn is easy to review.
Do not mix formatter-only rewrites with semantic compiler work unless a feature explicitly requires it.
