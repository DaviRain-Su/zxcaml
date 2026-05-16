# 13 — `let%test_unit` 与 `omlz test`

> **Languages / 语言**: [English](../13-omlz-test.md) · **简体中文**

> **Route note / 路由说明：** 英文原文 [`../13-omlz-test.md`](../13-omlz-test.md)
> 保留完整语法、属性测试与 JSON 输出细节；本页同步当前命令入口和行为契约。

## 当前状态

- `omlz test` 负责运行 `let%test_unit` 与 `let%test_prop`。
- 默认测试发现根是 `examples/tests/*.ml`。
- LSP CodeLens 仍通过 `omlz test --filter ... --format=json FILE` 触发单测运行。

## 常用命令

```sh
zig-out/bin/omlz test
zig-out/bin/omlz test --filter list_ops
zig-out/bin/omlz test --format=json examples/tests/list_ops.ml
zig-out/bin/omlz test --num-cases 100 --seed 42 examples/tests/prop_int_add.ml
```

## 关键事实

- 退出码：`0` 全部通过，`1` 测试失败，`2` 调用/环境错误。
- `--format=json` 输出 JSON Lines。
- 该层用于纯 OCaml 逻辑与快速反馈，不替代 Mollusk 或 Surfpool 验收。

## 相关文档

- [LSP](./lsp.md)
- [Diagnostics](./diagnostics.md)