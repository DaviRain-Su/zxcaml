# omlz-lsp

> **Languages / 语言**: **English** · [简体中文](./zh/lsp.md)

`omlz-lsp` is the P9 language-server entry point for editor diagnostics.
It follows the Zig stdio JSON-RPC design selected in
`mission-internal/p9-investigation/report.md` §3: editor clients speak LSP over
stdin/stdout, and the server forks `omlz check --error-format=json` for each
document sync request.

## Supported methods

The server intentionally implements the minimum LSP 3.17 surface needed for
push diagnostics:

- `initialize` returns `textDocumentSync = 1` (Full sync) and `serverInfo` for
  `omlz-lsp`.
- `initialized` is accepted as a no-op notification.
- `textDocument/didOpen` stores the full document text and publishes
  `textDocument/publishDiagnostics`.
- `textDocument/didChange` replaces the stored full document text and publishes
  fresh diagnostics.
- `textDocument/hover` returns the rendered OCaml type of the identifier under
  the cursor as a markdown code block, or `null` for whitespace, comments, and
  unknown identifiers (see "Hover" below).
- `textDocument/definition` returns a `Location` pointing at the binding site
  of the identifier under the cursor, or `null` for whitespace, comments, and
  identifiers that are not top-level `let` / `let rec` bindings (see "Goto
  Definition" below).
- `textDocument/completion` returns a `CompletionList` containing the
  document's top-level `let` bindings and a static bundled-stdlib whitelist
  (see "Completion" below).
- `textDocument/references` returns a list of `Location` entries for every
  same-file occurrence of the identifier under the cursor (see "References"
  below).
- `textDocument/documentSymbol` returns a `DocumentSymbol[]` outline of the
  top-level `let` / `let rec` bindings in the document (see "Document
  Symbols" below).
- `shutdown` returns a JSON-RPC `null` result.
- `exit` terminates the process, with exit code `0` after `shutdown`.

## Framing

`omlz-lsp` uses the standard LSP base protocol framing:

```text
Content-Length: <byte-count>\r\n
\r\n
<UTF-8 JSON-RPC body>
```

`Content-Length` is counted in bytes, not characters. The server reads and
writes one JSON-RPC message per frame and does not require a `Content-Type`
header.

## Install

Build the repository and use the installed binary:

```sh
./init.sh
zig build
./zig-out/bin/omlz-lsp --version
```

The language-server path is `zig-out/bin/omlz-lsp` from the repository root.
Use an absolute path when wiring editors outside the repo.

### VS Code

```jsonc
// settings.json for a generic LSP client extension
{
  "zxcaml.languageServer.command": "/absolute/path/to/ZxCaml/zig-out/bin/omlz-lsp",
  "zxcaml.languageServer.filetypes": ["ocaml"]
}
```

### Helix

```toml
# ~/.config/helix/languages.toml
[[language]]
name = "ocaml"
language-servers = ["omlz-lsp"]

[language-server.omlz-lsp]
command = "/absolute/path/to/ZxCaml/zig-out/bin/omlz-lsp"
```

### nvim

```lua
-- init.lua with nvim-lspconfig available
vim.api.nvim_create_autocmd("FileType", {
  pattern = "ocaml",
  callback = function()
    vim.lsp.start({
      name = "omlz-lsp",
      cmd = { "/absolute/path/to/ZxCaml/zig-out/bin/omlz-lsp" },
      root_dir = vim.fs.root(0, { "build.zig", ".git" }),
    })
  end,
})
```

## Hover

`textDocument/hover` answers with the rendered OCaml type of the identifier
under the cursor. The server picks the smallest identifier span containing the
LSP `(line, character)` position (LSP positions are 0-based; the underlying
Core IR is 1-based and the bridge does the conversion). The response shape is

```jsonc
{
  "contents": { "kind": "markdown", "value": "```ocaml\nint -> int\n```" },
  "range": { "start": {...}, "end": {...} }
}
```

For positions inside comments, whitespace, numeric literals, or unresolved
identifiers (for example inside a parse-broken region) the server returns
`null` rather than an error, as the LSP spec recommends.

Hover reuses the per-URI Core IR cache that the server builds on demand. The
first hover request for a document URI runs a one-shot `omlz check
--emit=core-ir-with-loc` invocation, parses the resulting sexp, and stores a
`name -> rendered_type` table keyed by the exact document text. Subsequent
hovers on the same text are answered directly from that cache. The cache is
invalidated whenever the document text changes via `didOpen` or `didChange`.

This pass resolves identifiers at the granularity of top-level `let` and
`let-rec` bindings; nested let bindings and arbitrary sub-expression hovers
are not surfaced. The server capability is advertised as `hoverProvider:
true` in the `initialize` response.

## Goto Definition

`textDocument/definition` reuses the same per-URI Core IR cache as hover.
After picking the identifier under the cursor with the same shared
`wordAtPosition` helper, the server looks the name up via
`hover.findSymbol`. When the entry's binding-name range is known, the
response is a single LSP `Location` whose `uri` matches the request and
whose `range` covers just the binding name (the `X` in `let X = ...`), not
the full body. Whitespace, comments, numeric literals, and identifiers that
are not top-level bindings return `result: null`. The server capability is
advertised as `definitionProvider: true` in the `initialize` response. As
with hover, this pass only resolves top-level `let` / `let rec` bindings in
the current document; nested let bindings, lambda parameters, and cross-file
modules are not surfaced.

## Completion

`textDocument/completion` returns an LSP `CompletionList` with
`isIncomplete: false`. The capability is advertised in `initialize` as
`completionProvider: { triggerCharacters: ["."] }` so editors trigger the
provider on `.` for module-qualified access while still permitting manual
invocation anywhere.

The first cut returns two groups of items, with no type-driven filtering or
prefix matching — clients perform that filtering themselves:

1. **User-defined top-level bindings.** Every top-level `let` / `let rec`
   binding parsed out of the current document by the shared hover symbol
   table appears as a `CompletionItem`. The `label` is the binding name, the
   `detail` is the rendered OCaml-style type from hover, and the `kind` is
   `Function` (`3`) when the rendered type contains `->` and `Value` (`12`)
   otherwise. The completion handler reuses the hover Core IR cache and
   builds one on demand if it is missing; it never forks an extra `omlz
   check` purely for completion.
2. **Bundled stdlib whitelist.** A static list defined in
   `src/lsp/completion_stdlib.zig` enumerates every module path advertised in
   the README "Stdlib" bullet plus the `Bytes`, `Sysvar`, and `Cpi` surfaces
   the runtime exposes. Items are labelled `Module.fn` (for example
   `List.length`, `Option.is_some`, `Pubkey.zero`). The `kind` is `Function`
   (`3`) for callables and `Constant` (`13`) for nullary helpers such as
   `Pubkey.zero` and `Pubkey.token_program`. `detail` is a one-line
   OCaml-style signature where known, falling back to the module path for
   `external`-backed Cpi helpers whose type is not statically rendered.

Items shipped today: `List` (16), `Option` (7), `Result` (6), `Fun` (3),
`Map` (8), `Set` (9), `String` (3), `Char` (2), `Crypto` (4), `Pubkey` (3),
`Bytes` (8), `Sysvar` (6), and `Cpi` (5) — 80 stdlib entries in total. Type-
driven filtering by the expected expression context is out of scope; the
provider always returns the full union for the editor to filter client-side.

## References

`textDocument/references` reuses the same hover symbol table to validate the
identifier under the cursor. Once the cursor word has been resolved to a
known top-level binding, the server scans the document text for every
stand-alone occurrence of that exact identifier — preceded and followed by a
non-identifier byte, and outside of `(* ... *)` comments and `"..."` /
`'.'` literals. The response is a `Location[]` whose `uri` matches the
request and whose `range` covers just the matched identifier. When the
request omits `context.includeDeclaration` the server defaults to `true`;
passing `false` filters out the binding-name occurrence itself. Cursors that
land in comments, on whitespace, or on identifiers that are not top-level
bindings return `[]` (an empty array). Cross-file references are out of
scope: the scan is strictly same-file, mirroring the existing hover and
definition behavior. The capability is advertised as `referencesProvider:
true` in the `initialize` response.

## Document Symbols

`textDocument/documentSymbol` returns an outline of the document's top-level
`let` / `let rec` bindings as a `DocumentSymbol[]`. Each entry uses the
binding name as `name`, the hover-rendered type as `detail`, and
`SymbolKind.Function` (`12`) when the rendered type contains `->` /
`SymbolKind.Variable` (`13`) otherwise. The `selectionRange` covers just the
binding name; the `range` is a best-effort extent from the binding name up
to the next top-level binding head (or end of file), without parsing the
body. `children` is always `[]` because nested scopes are not surfaced.
Entries are returned in source order. The handler reuses the per-URI hover
Core IR cache and builds one on demand; it never spawns an extra `omlz
check`. The capability is advertised as `documentSymbolProvider: true` in
the `initialize` response.

## Limitations

- Diagnostics, identifier hover, top-level goto-definition, basic identifier
  completion, same-file references, and a top-level document outline only:
  no rename, code actions, cross-file references, or pull-diagnostics
  provider.
- Full-document sync only; incremental `didChange` payloads are out of scope.
- Fork-per-request by design: every `didOpen`/`didChange` writes a temporary
  `.ml` file and runs `omlz check --error-format=json`.
- Expected steady-state latency is about 80 ms for small files, as measured and
  accepted in `mission-internal/p9-investigation/report.md` §3.

## Resilience

The M-LSP-FIX hardening keeps the original P9 latency budget intact while
making the harness less sensitive to cold-start noise. The latency probe now
runs one warm-up `didOpen` first, waits for its `publishDiagnostics`, and then
discards that timing. That sample absorbs fork, dynamic-loader, and filesystem
setup costs that are not representative of steady-state editor feedback.

After the warm-up, the harness records five measured samples. It sorts only
those five measured values and reports the p50 median, so the single middle
value defines the pass/fail result. The threshold remains `median_ms <= 200`;
the fix is to measure the same target more robustly, not to relax the target.
When the assertion fails, the harness keeps enough raw timing data to show the
full six-sample story: one warm-up plus five measured requests.

Temporary-file handling is also now scoped by process. Each server writes under
a per-pid subdirectory:

```text
/tmp/omlz_lsp_<pid>/<request-id>.ml
```

This replaces the older flat `/tmp/omlz_lsp_<pid>_<id>.ml` shape. The directory
name makes ownership obvious, lets one server clean its own request files as a
group, and avoids matching unrelated LSP work from another running process by
accident.

There is still a cross-pid stale-cleanup path for crash recovery. On server
startup, `omlz-lsp` scans `/tmp/omlz_lsp_*`, extracts the pid from matching
directories, and probes that owner with `kill(pid, 0)`. Live pids are left
alone; dead-pid directories are removed recursively so a killed server cannot
poison the next harness run.

The Python harness performs the same stale-pid sweep before it launches the
server. That pre-run cleanup is deliberately redundant with server startup:
the harness protects local test assertions, and the server protects editor
invocations outside the harness. Together they make `/tmp/omlz_lsp_*` safe
across ordinary shutdown, assertion failures, and abrupt process death.
