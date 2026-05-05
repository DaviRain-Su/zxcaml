//! Minimal LSP protocol method names for the `omlz-lsp` scaffold.
//!
//! `mission-internal/p9-investigation/report.md` §3 chooses a hand-written Zig
//! stdio JSON-RPC server. This file reserves the protocol surface for the
//! subsequent F-LSP-* handlers without implementing the LSP loop yet.

pub const server_name = "omlz-lsp";

pub const Method = enum {
    initialize,
    initialized,
    shutdown,
    exit,
    textDocument_didOpen,
    textDocument_didChange,
    textDocument_publishDiagnostics,
};
