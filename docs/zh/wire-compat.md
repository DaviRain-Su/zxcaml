# Wire compatibility / Wire 兼容性

> **Languages / 语言**: [English](../wire-compat.md) · **简体中文**

> **Route note / 路由说明：** 英文原文 [`../wire-compat.md`](../wire-compat.md)
> 保留完整 additive 演进细节；本页同步当前默认 wire 版本与兼容窗口。

## 当前状态

- 默认 frontend wire 版本是 **`1.6`**。
- 读取器仍接受 `1.1` / `1.2` / `1.3` / `1.4` 的兼容形态。
- 缺失 `loc`、typed lambda 参数或 `ref-*` 节点时，仍按兼容模式处理。

## 版本摘要

- **1.2**：加入 source locations。
- **1.3**：加入 typed lambda parameters。
- **1.4**：加入数组与 loop 相关 additive 形态。
- **1.5**：加入 `ref-make` / `ref-get` / `ref-set`。
- **1.6**：内层表达式带 `(located ...)` 包装，诊断与 source map 达到表达式级；`--wire=1.5` 为兼容窗口。

## 关键事实

- `omlz check --wire=1.1` 与 `--wire=1.2` 仅用于兼容窗口。
- `--no-alloc` 会拒绝 `ref-make` 这类分配点。
- 规范 grammar 仍以 `src/frontend/zxc_sexp_format.md` 为准。

## 相关文档

- [Diagnostics](./diagnostics.md)
- [Source maps](./source-map.md)
