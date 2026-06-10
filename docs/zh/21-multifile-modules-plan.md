# 21 — 多文件模块实现计划（ADR-016）

> **Languages / 语言**: [English](../21-multifile-modules-plan.md) · **简体中文**

> **状态：** ADR-016 选项 B 的实现计划。本文档在代码落地前钉死 as-built
> 范围；不重开已封板的 P1-P9 / R-slice 工作。

ADR-016（[`09-decisions.md`](./09-decisions.md)）接受了 frontend 级
`open Foo` 多文件支持：OCaml frontend 对依赖闭包做类型检查，拼接
Typedtree，输出单一 sexp。本计划记录实现契约，以及 ADR 文本（写于
2026-05-12，早于 wire `1.6`）与当前仓库实况之间的差异。

## 与 ADR 文本的差异

| ADR-016 表述 | as-built 决定 | 原因 |
|---|---|---|
| "Wire 格式（minor）bump 以携带 `file_id`" | **不 bump wire；保持 `1.6`。** | Wire `1.6` 的每个 `(loc file line col end_line end_col)` 节点已携带文件名；诊断（`src/util/diag.zig`）、source map（`src/driver/srcmap.zig` 的 `ml_file`）、`omlz unmap` 都已是 per-file。多文件归属无需新 shape。 |
| "`--entry` / `--root` CLI 标志" | **不加新标志。** 现有位置参数即 entry；项目根 = entry 文件所在目录。 | 为同一输入提供第二种命名方式只增表面不增能力。 |
| "Mollusk 套件……移除既有重复 helper" | 本切片落地一组新的多文件示例三件套 + Mollusk 测试；改写已封板的单文件示例延后。 | 重写封板语料只搅动 golden 而无 DX 收益；去重标准对后续工作生效。 |

## 解析与拼接语义

- **R1 — 发现。** 调用 `ocamlc` 之前，frontend 用 `compiler-libs` 的
  `Parse.implementation` 解析 entry 文件，扫描顶层 `open M`。`M` 解析为
  `<entry_dir>/<首字母小写的 M>.ml`（`open Vault_types` →
  `vault_types.ml`）。发现过程对依赖递归。发现阶段的解析失败被忽略；语法
  错误由 `ocamlc` 走既有路径报告。
- **R2 — 保留名。** `open M` 中 `M` 为捆绑 stdlib 模块名（`Core`、
  `Generators`，以及内建模块面：`Account`、`AccountMeta`、`Pubkey`、
  `Crypto`、`Sysvar`、`Fixed`、`Amount` 等）时拒绝（E0103）；用户文件
  与这些名字同名也拒绝。stdlib 保持自动 open 与特殊处理。
- **R3 — 编译。** 依赖按拓扑序编译进共享临时目录，输出为 `<name>.cmo`
  使模块名与文件名一致（`ocamlc -bin-annot -I <stdlib> -I <deps>
  -open Core -open Generators -c`）。entry 最后编译，带同样的
  `-I <deps>`。每个文件产出自己的 `.cmt`。
- **R4 — 拼接。** 各 `.cmt` 的 Typedtree 按拓扑序经单一共享 subset 环境
  转换（依赖中声明的 ADT/record 在后续文件中可解析），声明拼接为单一
  module，entry 在最后。已解析的顶层 `Tstr_open` 在转换时跳过；其余
  保持今天的 subset 规则。
- **R5 — 扁平命名空间。** 输出名不带限定。闭包内重复的顶层
  值/类型/构造器名被拒绝（E0102）而非 mangle，sexp shape 与单文件输出
  字节一致。对用户模块的限定引用 `Foo.x` 输出为裸 `x`。
- **R6 — 依赖边仅由 `open` 建立。** 不写 `open Foo` 而用 `Foo.x` 不构成
  依赖边；`ocamlc` 报 unbound module。`include`、嵌套/局部 open、依赖
  文件中的 `let%test` 块均不在范围内。
- **R7 — 单文件程序不变。** 没有用户 `open` 的程序产出与今天字节一致的
  sexp。确定性（ADR-008）扩展到多文件：拓扑序为 DFS 后序，遵循 `open`
  的源码顺序。

## 新诊断

| 码 | 含义 |
|---|---|
| `E0100` | `open M` 无法解析到 `<entry_dir>/<m>.ml` |
| `E0101` | `open` 依赖环（消息列出环路径） |
| `E0102` | 文件闭包内顶层名重复 |
| `E0103` | `open` 捆绑 stdlib 模块，或用户文件与其同名 |

四个码全部注册进 `src/util/diag_explain.zig`、frontend 镜像测试与
[`diagnostics.md`](./diagnostics.md)。

## 实现切片

1. **S1 frontend 驱动** — `src/frontend/zxc_frontend.ml` 中的发现、解析、
   环检测、拓扑多 `.cmt` 编译。
2. **S2 subset 拼接** — `src/frontend/zxc_subset.ml` 中的共享环境转换、
   `Tstr_open` 跳过、用户模块路径解析、重复检测。
3. **S3 工具链** — E010x explain 条目；审计 `src/build_lock.zig` 输入
   哈希与 LSP 兄弟文件诊断发布。
4. **S4 验证** — UI fixture（解析 / 缺失 / 环 / 重复 / 保留名）、
   `examples/` 多文件示例三件套 + manifest 更新、Mollusk 共享类型测试、
   三件套的确定性验证。
5. **S5 文档收尾** — `02-grammar.md`、`10-frontend-bridge.md`、
   `07-repo-layout.md`、`wire-compat.md` 注记、`diagnostics.md`、ADR-016
   补遗（Proposed → 按 as-built 接受）、README/roadmap 计数、中文镜像、
   CHANGELOG。

## 验收门

1. 按上方差异表修订后的 ADR-016 标准，全部可验证为绿。
2. 既有 no-regress 底线：

   ```sh
   zig build
   zig build test --summary none
   cargo test --manifest-path tests/Cargo.toml
   ./scripts/check_examples_corpus.sh
   ./scripts/check_docs_sync.sh
   ```

3. 单文件 sexp 输出保持字节一致（golden 快照除有意新增 fixture 外不变）。

## 防蔓延护栏

- 不引入 `dune`、不做 `.cmi` 缓存、不做增量编译（ADR-011 不动）。
- 不 bump wire、不改 Core IR、不改 codegen。
- 不做 name mangling；E0102 维持扁平命名空间的诚实性，直到跨文件
  遮蔽出现真实需求。
