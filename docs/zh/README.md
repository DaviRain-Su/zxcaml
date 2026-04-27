# ZxCaml

> **Languages / 语言**: [English](../../README.md) · **简体中文**

> 一个带有 **Zig / BPF 后端** 的 **OCaml 方言**。
> 我们 **不** 发明新语言。源文件用标准的 `.ml` 后缀。
> 我们替换的是 *后端*，不是 *前端*。

---

## TL;DR

```text
.ml 源码
   │
   ▼
[ ocamlc -bin-annot ]    ◀── 上游 OCaml，作为库使用，绝不 fork
   │  .cmt (Typedtree)
   ▼
[ zxc-frontend (小段 OCaml 胶水) ]
   │  .cir.sexp  (有版本的 wire 格式)
   ▼
[ omlz (Zig)  : ANF → Core IR → ArenaStrategy → Lowered IR → Zig 代码生成 ]
   │  .zig
   ▼
[ zig build-lib -target bpfel-freestanding -femit-llvm-bc ]
   │  .bc (LLVM bitcode)
   ▼
[ sbpf-linker --cpu v2 --export entrypoint ]    ◀── v3 可选（ADR-013）
   │
   ▼
Solana BPF .so
```

- 前端：**上游 OCaml `compiler-libs`**（不 fork、不重写）。见 ADR-009 / ADR-010。
- 前端以下所有部分的宿主语言：**Zig 0.16**。
- 源语言：**OCaml**（子集，逐步扩大）。
- 主要目标平台：**Solana BPF**（`bpfel-freestanding`）。
- 内存模型（P1）：**arena，完全推断，对用户隐藏**。
- Core IR 形态：**ANF**（A-Normal Form），带类型，带 layout 标注。
- CLI 二进制名：**`omlz`**（OCaml on Zig）。
- 构建驱动：单一 **`build.zig`** 同时编排 OCaml 前端桥接和 Zig 管线（ADR-011）。

---

## 这个项目为什么存在

OCaml 有优雅的前端（HM 类型系统、ADT、模式匹配、模块），还有久经考验的类型系统。
它**缺**的是面向**资源受限、确定性执行**环境（比如 Solana BPF）的后端故事 ——
那种环境里 OCaml runtime（GC、boxed float、异常）根本跑不起来。

ZxCaml 保留 OCaml 语言、复用它的心智模型，但把程序导入一条新的管线，
通过 Zig 产出扁平、无 GC、能上 BPF 的代码。

我们**刻意不**去 fork 任何 OCaml 编译器发行版（上游 OCaml 或 OxCaml）。
而是把上游 `compiler-libs` 当成库来用，做 parser 和类型检查；
从 `Typedtree` 之后，所有东西都是我们自己的。
推理过程在
[`docs/alternatives-considered.md`](../alternatives-considered.md)（英文）/
[`alternatives-considered.md`](./alternatives-considered.md)（中文），
锁定在 ADR-009 / ADR-010。

---

## Native 执行是顺带免费的

因为每个 ZxCaml 程序按构造都是合法 OCaml（ADR-001），
而且 `omlz` 本来就要求开发者机器上有一套可用的 OCaml 工具链（ADR-010），
所以 **同一份 `.ml` 文件** 能用两条路径编译并运行：

```
一份 .ml 文件
  ├── ocaml / dune  →  native x86_64 / arm64 二进制   （本地测试、fuzzing、REPL）
  └── omlz          →  Solana BPF .so                 （部署）
```

这意味着 **ZxCaml 不需要一个专门的 x86 后端** 也能给你原生执行能力。
装 `ocaml`（你为了 `omlz` 已经装了）或者装 OxCaml，
然后用 `dune exec` 跑同一份文件。
两条路径产生相同结果；这是由确定性不变量（ADR-008）保证的。

更长的讨论 —— OxCaml 和本项目是什么关系、为什么还是不 fork ——
见 [`oxcaml-relationship.md`](./oxcaml-relationship.md)。

---

## 项目状态

**规划 / 设计阶段。** 还没有编译器代码。
当前 repo 里只有 [`docs/`](../) 下的设计文档（英文）和 [`docs/zh/`](./)（中文）。

具体实现会由一套独立的任务系统驱动；这个 repo 是关于 *要做什么* 的真理来源。

---

## 文档（按顺序读）

| # | 文档 | 锁定了什么 |
|---|---|---|
| 00 | [概览](./00-overview.md) | 愿景、范围、三盆冷水（避免的陷阱） |
| 01 | [架构](./01-architecture.md) | 管线、分层 IR、扩展点 |
| 02 | [语法](./02-grammar.md) | P1 接受的 OCaml 子集 |
| 03 | [Core IR](./03-core-ir.md) | ANF IR 数据模型，核心契约 |
| 04 | [内存模型](./04-memory-model.md) | P1 仅 arena，未来扩展用 region 描述符 |
| 05 | [后端](./05-backends.md) | Zig 代码生成、树遍历解释器、后端 trait |
| 06 | [BPF 目标](./06-bpf-target.md) | 到 Solana `.so` 的工具链链路（zig + sbpf-linker） |
| 07 | [仓库布局](./07-repo-layout.md) | 目录契约，谁拥有什么 |
| 08 | [路线图](./08-roadmap.md) | P1–P7 各阶段和 P1 内部步骤 |
| 09 | [决策（ADR）](./09-decisions.md) | 锁定的决策，附带理由 |
| 10 | [前端桥接](./10-frontend-bridge.md) | OCaml `compiler-libs` → sexp → Zig |
| —  | [备选方案对比](./alternatives-considered.md) | 为什么不自写、为什么不 fork OxCaml |
| —  | [OxCaml 关系](./oxcaml-relationship.md) | OxCaml 是什么，"用 OxCaml" 的四种解读，该选哪种 |
| —  | [zignocchio 关系](./zignocchio-relationship.md) | 我们读的 Zig→Solana SDK，学到了什么、没复制什么（ADR-014） |

> 所有中文文档都是英文版的对照翻译，结构完全一致；
> 真理来源是英文版。如果两边出现冲突，以英文版为准。

---

## 一句话总结

> **借用 OCaml 的前端，扔掉它的 runtime，通过 Zig 落到 BPF。**
>
> 借用 ≠ fork。我们把 `compiler-libs` 当库调用，**绝不**改它。
