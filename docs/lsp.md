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
