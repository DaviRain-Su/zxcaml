# Source maps / 源映射

> **Languages / 语言**: [English](../source-map.md) · **简体中文**

> **Route note / 路由说明：** 英文原文 [`../source-map.md`](../source-map.md)
> 仍是完整 schema 与实现说明；本页同步当前 `.map` / `.so` 逆向定位契约。

## 当前状态

- BPF 构建会生成确定性的 `.map` sidecar。
- 若可用 `llvm-objcopy`，`.so` 还会嵌入 `.zxcaml.srcmap` section。
- `omlz unmap --map` 与 `omlz unmap --so` 是面向开发者的反查入口。

## 常用命令

```sh
omlz unmap --map out/hackathon_greet.map --pc 0x80
omlz unmap --so out/hackathon_greet.so --pc 0x80
```

## Toolchain 事实

- `SOLANA_ZIG` 未设置、空值或 `1` 时，默认走直接 `solana-zig build-lib` 路径。
- `SOLANA_ZIG=0` 不是受支持模式。
- 缺少 `llvm-objcopy` 时，sidecar `.map` 仍会生成，只是 `.so` 不嵌入节段。

## 相关文档

- [Wire compatibility](./wire-compat.md)
- [Diagnostics](./diagnostics.md)
