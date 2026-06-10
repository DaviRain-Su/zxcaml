# Diagnostics / 诊断

> **Languages / 语言**: [English](../diagnostics.md) · **简体中文**

> **Route note / 路由说明：** 英文原文 [`../diagnostics.md`](../diagnostics.md)
> 仍是完整细节页；本页同步记录当前对外承诺的诊断格式、关键标志与兼容事实。

## 当前状态

- 默认诊断格式是 **rustc-style human renderer**。
- `omlz check`、`omlz build`、`omlz idl`、`omlz run` 共享同一套错误格式开关。
- 当前 wire 默认值是 `1.7`，兼容旧的 additive 读者窗口。

## 关键命令

```sh
omlz check tests/golden/dx1_json_format.ml
omlz check --error-format=oneline tests/golden/dx1_json_format.ml
omlz check --error-format=json tests/golden/dx1_json_format.ml
NO_COLOR=1 omlz check --color=never path/to/file.ml
```

## 关键开关

- `--error-format=human|json|oneline`
- `--color=auto|always|never`
- `NO_COLOR=1`

## 兼容事实

- JSON 输出是 **JSON Lines**，不是 JSON 数组。
- `code` 字段是可选的；已有稳定错误码与兼容别名并存。
- `E0200` 仍用于 `--report` 参数非法的情况。
- `DX2-NOALLOC` / `DX2-REGION` 分别用于 `--no-alloc` 分配证明失败与 region
  推断失败；wire 1.6 起 caret 精确指向违规表达式，两者均可用
  `omlz check --explain <CODE>` 查看解释。

## 相关文档

- [LSP](./lsp.md)
- [Wire compatibility](./wire-compat.md)
- [Source maps](./source-map.md)
