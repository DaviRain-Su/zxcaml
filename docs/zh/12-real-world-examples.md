# 12 — 真实示例路由

> **Languages / 语言**: [English](../12-real-world-examples.md) · **简体中文**

> **Route note / 路由说明：** 详细的逐示例映射矩阵仍以英文页
> [`../12-real-world-examples.md`](../12-real-world-examples.md) 为准；本页同步该文档的范围、验证面和当前结论。

## 范围

- 该文档覆盖 `examples/*.ml` 中受 zignocchio 启发的 Solana 示例。
- 它描述的是 **映射关系**，不是把 Zig SDK 逐行翻译为 OCaml。
- 当前验证面仍是 `examples/`、`tests/*_test.rs`、`tests/solana/**` 与 `docs/11-solana-p3.md`。

## 当前结论

- 示例继续保持为普通 `.ml` 文件。
- 运行时重逻辑通过 `runtime/zig/**` 与 codegen 识别的 helper/externals 承接。
- 这些示例的本地 Solana 路径现在以 **Surfpool harness** 为准，而不是旧的 `solana-test-validator` 工作流。

## 相关入口

- [Examples README](../../examples/README.md)
- [Solana P3 指南](./11-solana-p3.md)
- [zignocchio 关系](./zignocchio-relationship.md)
