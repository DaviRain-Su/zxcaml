# omlz-lsp / 语言服务器

> **Languages / 语言**: [English](../lsp.md) · **简体中文**

> **Route note / 路由说明：** 英文原文 [`../lsp.md`](../lsp.md) 保留完整协议细节；
> 本页同步当前安装方式、支持的方法和编辑器接入要点。

## 当前状态

- `omlz-lsp` 是 P9 封版后的 stdio JSON-RPC 语言服务器入口。
- 通过 `zig build` 安装到 `zig-out/bin/omlz-lsp`。
- 当前支持诊断推送、hover、definition、completion、references、document symbols 与 CodeLens 测试执行。

## 安装

```sh
./init.sh
zig build
./zig-out/bin/omlz-lsp --version
```

## 支持的方法

- `initialize`
- `textDocument/didOpen`
- `textDocument/didChange`
- `textDocument/hover`
- `textDocument/definition`
- `textDocument/completion`
- `textDocument/references`
- `textDocument/documentSymbol`
- `shutdown`
- `exit`

## 关键事实

- 传输 framing 使用标准 `Content-Length` LSP 协议。
- 当前仍是 **full-document sync**，不是增量同步。
- 诊断底层仍通过 `omlz check --error-format=json` 取得。

## 相关文档

- [Diagnostics](./diagnostics.md)
- [omlz test](./13-omlz-test.md)
