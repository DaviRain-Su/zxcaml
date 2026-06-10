# 22 — 泛型数组计划

> **Languages / 语言**: [English](../22-generic-arrays-plan.md) · **简体中文**

> **Status / 状态：** ADR-015 数组后续工作的规划脚手架。本文档本身不改变编译
> 器行为；下面每个切片都作为独立变更落地，带各自的范围与验证证据。

## 为什么是现在

R9（ADR-015 option B）把数组钉死在 `int` 元素。后来的三个变更移除了当初的
全部障碍：

- 解释器的数组值已不再是 `[]i64` 而是泛型值（随 PDA 切片落地——
  `bytes array` 的 seeds 已经在跑）；
- 元组类型在生成的 Zig 中驻留为命名结构体，复合元素类型跨函数边界有了稳定
  的名义身份；
- wire 的 `array-lit` 形态自 R9 起就带元素类型槽位（`(ty (type-ref int))`）
  ——放宽槽位允许的内容是 wire `1.7` 内的增量变更。

剩下的工作只是解除前端子集检查器与 ANF/codegen 数组路径上的 `int`-only
门。

## 范围

两个切片，按序：

1. **切片 1 —— 类标量元素：** `bool`、`string`/`bytes` 元素类型，覆盖
   `[| ... |]`、`Array.get`、`Array.set`、`Array.length`、字面量尺寸
   `Array.make` 与 `Array.of_list`。复用既有 flat/boxed 值布局，不需要新
   类型机制。
2. **切片 2 —— 复合元素：** record 与 tuple 元素类型，依托元组驻留与既有
   record 类型声明。动机用例是 `account_meta array`（今天 CPI metas 只能
   经 `Array.of_list` 构造）。

## 非目标（反蔓延）

- **动态尺寸 `Array.make`** 不在本计划内（内部漏斗中单列为 A2）；尺寸仍须
  是非负 int 字面量，动态形态保持 E0019。
- 不加 `Array.init`、`Array.map`、切片或新的 stdlib 数组组合子。
- 不做多态（`'a array`）声明——每个使用点的元素类型必须具体。
- 不改 arena-only 内存模型与 `no_alloc` 契约语义：数组仍是 arena 分配；
  只放宽元素类型门。
- 不升 wire 版本：元素类型槽位早已存在；前端只是不再强行写入
  `(type-ref int)`。

## 实现地图

| 层 | 现状 | 变更 |
|---|---|---|
| `src/frontend/zxc_subset.ml` | E0019 家族拒绝非 `int` 元素类型 | 按切片放行元素类型白名单；发射真实元素类型 |
| `src/core/anf/expr_lowering.zig`（`lowerArrayLit`/`Get`/`Set`/`Make`） | 硬编码 `.Int` 元素类型 | 从 wire 的 `ty` 槽位推导元素类型 |
| `src/backend/zig_codegen` 数组发射 | `i64` slice 与辅助 | 经 `zigTypeName` 渲染元素类型（复合走驻留名） |
| `src/backend/interp.zig` | 泛型 `[]Value` 数组（已落地） | 只需扩展元素强制检查 |
| `src/core/no_alloc.zig` / `static_report` | int 数组分配类 | 按元素类型分类；消息保持表达式级精度 |
| 诊断 | E0019 覆盖所有非 int 形态 | E0019 收窄到仍拒绝的形态；`--explain` 文本同步 |

## 验收门禁（每切片）

1. 示例：每切片至少一个新示例（登记清单、计数同步），通过解释器≡原生确定
   性门禁与 BPF 构建；切片 2 增加 Mollusk 用例演练字面量构造的
   `account_meta array`。
2. UI fixture 钉住仍被拒绝的形态（动态尺寸、不支持的元素类型），span 保持
   表达式级精度。
3. 标准验证底线保持绿色：

   ```sh
   zig build
   zig build test --summary none
   cargo test --manifest-path tests/Cargo.toml
   ./scripts/check_examples_corpus.sh
   ./scripts/check_docs_sync.sh
   ```

4. Golden：既有 `.core.snapshot` 逐字节不变（int 数组保持当前降级原样）；
   新元素类型可新增 golden。
5. 文档：`docs/02-grammar.md` 与 E0019 条目随每个切片双语同步。
