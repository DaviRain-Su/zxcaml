# 18 — 定点数学

> **Languages / 语言**: [English](../18-fixed-point.md) · **简体中文**

> **Route note / 路由说明：** 英文原文 [`../18-fixed-point.md`](../18-fixed-point.md)
> 保留完整 API 细节；本页同步当前表示、约束与验证面。

## 当前状态

- `Fixed.t` 仍是基于 `int` 的六位小数定点表示。
- 该表面是纯 OCaml stdlib 能力，不新增 runtime 表示或 wire 节点。
- `Amount` helper 继续服务于 Solana / DeFi 风格 quote、fee、premium 计算。

## 关键事实

- `Fixed.scale = 1000000`
- `1000000` 表示 `1.0`
- 乘除仍受当前 `int` / BPF 安全范围约束

## 验证面

- `stdlib/core_tests.ml`
- `examples/tests/fixed_test.ml`
- `examples/fixed_amm_quote.ml`
