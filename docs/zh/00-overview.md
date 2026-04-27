# 00 — 概览

> **Languages / 语言**: [English](../00-overview.md) · **简体中文**

## 1. ZxCaml 是什么

ZxCaml 是一个 **OCaml 方言的编译器**，后端通过 **Zig** 产出 Solana **BPF** 目标文件。

具体来说：

- **前端就是上游 OCaml 自身**，作为库使用（通过 `compiler-libs`）。
  我们不发明新语法，不写 parser，也不 fork 任何 OCaml 编译器。
  源文件用 `.ml`。详见 ADR-009 和 ADR-010。
- **后端是新的**。它面向一个扁平、无 GC 的执行模型，适合 Solana 程序。
- 两者之间的 **粘合层** 是一个带类型的 **Core IR**，形态为 **ANF**，
  这是各阶段之间唯一稳定的契约。

## 2. ZxCaml 不是什么

- **不是新语言。** 没有新关键字、没有新文件后缀。
  OCaml 没有的特性，ZxCaml 也没有。
- **不是 OCaml 的替代品。** 我们刻意只接受 OCaml 的 *子集*。
  Effect、GADT、第一类模块、`Obj.magic`、ctypes、官方 C runtime —— 全部排除。
- **不是 opam 消费者。** 现存的 opam 包**不能**直接拿来用，
  因为我们不复刻 OCaml 的 runtime representation。
  生态复用通过：
  1. 用我们的子集写一个小型原生标准库；
  2. 通过 **Zig FFI** 调系统 / 加密原语。
- **P1 阶段不是通用编译器。** P1 唯一的验证目标是 Solana BPF。
  原生二进制可能顺带能产出，但不是目标。

## 3. 项目命名

| 事物 | 名字 |
|---|---|
| 项目 / repo | `ZxCaml` |
| 源语言 | OCaml（子集） |
| 源文件后缀 | `.ml` |
| 编译器驱动二进制 | `omlz`（OCaml on Zig） |
| Core IR | "Core IR"（不起花哨名字；就是 typed ANF） |

## 4. 三盆冷水（设计约束）

把这些写下来，避免后来者再去重新踩坑。

### 4.0 我们 **不** fork OxCaml 或任何 OCaml 编译器

OxCaml（Jane Street 的 OCaml fork，原名 `flambda-backend`）带着 Flambda 2、
Cfg 后端、`mode` / `local` / `unique` 系统。乍一看，fork 它像是抄近道。

但**不是**抄近道。OxCaml 的优化全部假设 OCaml runtime 存在
（GC、异常、线程、OCaml ABI）。BPF 上这些都没有，所以这些优化**不迁移**。
fork 一个 37k commits、还在持续 rebase 的活跃编译器，
就为了加一个"主打无 OCaml runtime"的后端 —— 这个工作形态对本项目来说是错的。
这一点由 ADR-009 锁死。

前端复用走的是另一条路 —— 见 §4.0.5 和 ADR-010。

### 4.0.5 我们 **确实** 消费上游 OCaml `compiler-libs`

Parser 和类型检查交给上游 OCaml 编译器，由一段小型 OCaml 胶水程序
（`zxc-frontend`）作为库调用它。结果通过一个有版本的 S-expression 导出
（见 `docs/10-frontend-bridge.md`），由 Zig 管线消费。

这样我们拿到了 OCaml 的前端，但完全没有 OCaml 的 runtime。

### 4.1 OCaml 后端 **不是** 可行的生态桥

一个常见的诱惑是：*"把我们的子集编到 OCaml 的字节码 / native 后端，白嫖 opam 生态"*。

这条路失败的原因：OCaml 库依赖的不只是语法，还有 functor、多态变体、GADT、
effect、`Obj.magic`、ctypes 形式的 C stub，以及具体的 tagged-pointer / boxed-float
表示。把这些全都复刻一遍 = 重新实现一个 OCaml。

**结论：** OCaml 后端从主路径删除。生态复用通过：

- 用我们的子集写一个小的原生 stdlib；
- 通过 **Zig FFI** 调其它一切。

OCaml `ocaml` / `dune` 工具链仍可在 **离线** 阶段用作正确性参考
（比如人工验证 stdlib 是否仍是合法 OCaml）。

### 4.2 多后端 / 多内存模型 **设计上**留好接口，**P1 阶段**只实现一种

我们设计成 **trait 形状的扩展点**（lowering strategy、backend），
这样未来要加新内存模型（RC、GC、region）和新后端时不用重新设计。
**P1 阶段每个扩展点都只实现一个**：arena lowering、Zig 后端，外加一个开发用的
树遍历解释器。

### 4.3 "可插拔内存模型"是研究级难题

真正可插拔的内存模型（arena / RC / GC / stack-only）会牵动调用约定、
闭包表示、ADT 布局、类型系统。P1 只做 **一种**：
**arena，完全推断，对用户隐藏**。Core IR 上确实带 `Layout` 字段，但目前只允许
`Region::Arena`。这个字段的存在 —— 而非它的取值范围 —— 是 P4+ 区域 / 所有权工作的
扩展点。

## 5. 已锁定的 Phase 1 决策

| 决策 | 取值 |
|---|---|
| 前端策略 | **上游 OCaml `compiler-libs` 作为库**（不 fork） |
| OCaml 版本（P1） | **5.2.x**，每个 phase 锁一个版本 |
| 前端以下所有部分的宿主语言 | **Zig 0.16** |
| 源语言 | **OCaml 子集**（见 `02-grammar.md`） |
| 源文件后缀 | `.ml` |
| Core IR 形态 | **ANF**，带类型，带 layout |
| 内存模型对用户的可见性 | **隐藏**，完全推断，仅 arena |
| 主要目标平台 | **Solana BPF**（通过 Zig，`bpfel-freestanding`） |
| 构建驱动 | **单一 `build.zig`**（同时驱动 OCaml 和 Zig 步骤） |
| P1 终点 | 一个 `.ml` 程序产出的 `.o` 能在 `solana-test-validator` 上加载并返回 0 |

## 6. 范围之外（永远，或直到显式重新讨论）

- functor、第一类模块、GADT、多态变体
- effect handler（OCaml 5.x）
- OCaml C runtime、`Obj.magic`、ctypes
- 垃圾回收
- LSP、formatter、debugger
- 把"非 BPF 平台"作为目标（顺带能跑可以，不是目标）
