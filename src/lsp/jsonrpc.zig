//! JSON-RPC framing scaffold for `omlz-lsp`.
//!
//! Layout follows `mission-internal/p9-investigation/report.md` §3: keep the
//! hand-written LSP server under `src/lsp/`, with Content-Length framing in a
//! focused module. The actual reader/writer implementation lands in F-LSP-2.

/// LSP base protocol framing header name.
pub const content_length_header = "Content-Length";
