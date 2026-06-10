# 20 — 函数式多链架构 ADR

> **Languages / 语言**: [English](../20-functional-multichain-architecture-adr.md) · **简体中文**

> **Status / 状态：** Accepted / 已接受（architecture-only，纯架构决策）。

> **Route note / 路由说明：** 英文原文 [`../20-functional-multichain-architecture-adr.md`](../20-functional-multichain-architecture-adr.md)
> 是完整的 ADR 正文；本页同步它的范围边界与决策要点。

## 决策定位

- 覆盖 MTF-0 目标契约、MTF-1 通用 WASM、MTF-2 NEAR 无存储适配器、
  MTF-3 可移植合约核心 API、MTF-4 EVM/Yul MVP、MTF-5 验证抽取 profile、
  MTF-6 其他适配器预留的**架构层**决策。
- 该 slice 为 **architecture-only**：不新增编译目标、运行时适配器、CLI
  旗标、生成产物、validator 通道、CI 行为，也不对 WASM/NEAR/EVM/形式化
  验证作出任何支持承诺。
- ZxCaml 仍是以 `.ml` 为规范输入、复用上游 OCaml `compiler-libs` 作前端
  的 OCaml 子集编译器；当前验证目标仍是 Solana SBF。
- 任何实现工作都必须经过 [`08-roadmap.md`](./08-roadmap.md) 中的激活门槛，
  与 [`19-functional-multichain-roadmap.md`](./19-functional-multichain-roadmap.md)
  的探索性规划相区分。
