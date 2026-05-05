# omlz-lsp

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

## Limitations

- Diagnostics only: no hover, completion, definition, rename, code actions, or
  pull-diagnostics provider.
- Full-document sync only; incremental `didChange` payloads are out of scope.
- Fork-per-request by design: every `didOpen`/`didChange` writes a temporary
  `.ml` file and runs `omlz check --error-format=json`.
- Expected steady-state latency is about 80 ms for small files, as measured and
  accepted in `mission-internal/p9-investigation/report.md` §3.
