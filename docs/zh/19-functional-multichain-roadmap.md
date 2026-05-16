# 19 — 函数式多链路线图

> **Languages / 语言**: [English](../19-functional-multichain-roadmap.md) · **简体中文**

> **Status / 状态：** exploratory planning only / 仅为探索性规划。

> **Route note / 路由说明：** 英文原文 [`../19-functional-multichain-roadmap.md`](../19-functional-multichain-roadmap.md)
> 是完整规划稿；本页同步它的范围边界、激活门槛与反目标。

## 规划定位

- 这是未来可选方向，不是当前已承诺阶段。
- 任何实现工作都仍需经过 `08-roadmap.md` 中的激活门槛与单独 ADR。
- 当前验证目标仍是 **Solana SBF + SDK-backed runtime + Surfpool 本地验证**。

## 核心论点

- 可移植的是 **业务逻辑层**，不是链运行时本身。
- 链适配层（Solana、WASM、EVM 等）必须显式区分入口、存储、调用、错误与编码语义。
- 该方向不应被解读为“Zig 能编到的目标都已经支持”。

## 激活门槛

未来某个目标要成为正式支持目标，至少需要：

1. 具体用例与 owner；
2. entrypoint / panic / memory / 调用约定；
3. target-specific runtime/host adapter 文档；
4. 真实 VM 或 canonical VM 上可运行的 acceptance 示例；
5. CI 覆盖；
6. 对不可用 API 的清晰诊断；
7. 便携部分与 target-specific 部分的清晰文档。

## 反目标

- 不宣称“所有 Zig target 自动支持”；
- 不宣称“一个 artifact 可不经修改部署到所有链”；
- 不把形式化验证宣传成自动获得的属性；
- 不借此重新打开已封存的 P1–P9 编译器范围。
