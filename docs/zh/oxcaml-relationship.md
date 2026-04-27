# ZxCaml ↔ OxCaml —— 关系与复用策略

> **Languages / 语言**: [English](../oxcaml-relationship.md) · **简体中文**

本文档存在的原因：
"我们能不能直接用 OxCaml 来支持 x86 / 其它目标？"
这个问题合理、会反复被问，且基于几个混在一起的假设。
把答案钉死一次，省得项目反复重审。

短版在 §6。要看为什么，读 §1–§5。

---

## 1. OxCaml 是什么

`oxcaml/oxcaml`（原名 `ocaml-flambda/flambda-backend`）是
**Jane Street** 主要维护的 OCaml 编译器生产 fork。
**它不是实验沙盒**；它驱动 Jane Street 内部的交易基础设施。

具体上，OxCaml 出货：

| 组件 | 做什么 | 上游 OCaml 有吗？ |
|---|---|---|
| **Flambda 2** | 高级优化器：跨函数 inlining、unbox、specialization | 没有（上游有 Flambda 1，明显弱很多） |
| **Cfg backend** | 现代低级后端：基于 control-flow-graph 的 IR、寄存器分配、指令调度 | 没有（上游用更旧的 Linear IR） |
| **Modes (`local` / `global`)** | 类型层标注：值的逃逸行为；不逃逸的可以栈分配 | 没有 |
| **Modes (`unique` / `shared`)** | 类型层标注：唯一所有权，可原地修改 | 没有 |
| **Layouts (`value` / `float64` / `bits64` / …)** | 类型层标注：类型的运行时布局，可表达 unboxed 值 | 没有 |
| **OCaml 5 base** | 跟随上游 OCaml 5.2；定期 rebase | （上游就是源头） |

OxCaml 的目标平台是 **`x86_64-linux`、`aarch64-linux`、
`aarch64-darwin`**（以及部分 `x86-darwin`）。
它**不**针对 BPF、WASM 或任何 Solana 形态目标，**也不打算针对**。

## 2. OxCaml 为什么存在

OxCaml 存在的原因是 Jane Street 有一个具体、可测量的需求：

> 让 OCaml 跑得够快、够确定、内存够紧，
> 以至于亚毫秒级交易系统的延迟尾巴不会被 GC pause 毁掉。

他们的痛点和 OxCaml 的回答：

| 痛点 | 回答 |
|---|---|
| GC pause 杀延迟 | `local` mode → 栈分配，不给 GC 增压 |
| boxed float 浪费内存 | `float64` Layout → 在寄存器里不 box |
| 上游 `ocamlopt` 太保守 | Flambda 2 → 激进的跨函数优化器 |
| OCaml 5 multicore 还嫩 | `unique` / `shared` mode → 类型化的并发不变量 |
| 老式代码生成器 | Cfg backend → 现代寄存器分配、指令调度 |

所以当有人问"OxCaml 是不是比上游 OCaml 更快、更好？"，诚实的回答是：

> **是的，对 Jane Street 在意的工作负载来说是。**
> 这些收益在 x86_64 交易代码上是真实可测的。
> 它们**不是**对 OCaml 这门语言的通用改进；
> 它们是对 OCaml 在某一类 CPU 上、某一类程序上的行为的针对性改进。

## 3. 这个问题被问错了形

一个自然的问题 —— 也是本文档存在的理由 —— 是：

> "如果想让 ZxCaml 支持 x86（或其它目标），能不能直接拿 OxCaml 当参考 / 基础？"

这个问题里有一个隐含假设站不住。
"用 OxCaml" 不是单一动作，而是 **四种**截然不同的事，代价差异巨大。

## 4. "用 OxCaml" 的四种解读

### 方式 A —— Fork OxCaml，在它的 x86 / arm 后端旁边加 BPF 后端

```
fork oxcaml/oxcaml
  → 在 backend/amd64/、backend/arm64/ 旁边加 backend/bpf/
  → OxCaml 就能产 x86 + arm + BPF
```

- **结论：永久拒绝。**
- 这正是 ADR-009 禁止的路径。
- 代价：永久 rebase 一个 37k commits、970 branches、还在活跃开发的编译器。
- 不适用的"收益"：Flambda 2 / Cfg / modes 全部围绕 OCaml runtime（GC、异常、
  OCaml ABI、boxed 表示）构建。BPF 上这些都没有，所以优化不迁移。
- 结论：全成本，几乎零收益。

### 方式 B —— 读 OxCaml 源码学思路，在 ZxCaml 里重写小块

```
读 oxcaml/backend/cfg/* 和 middle_end/flambda2/*
  → 理解技术（Cfg IR、regalloc、unbox）
  → 在 ZxCaml 自己的管线里重写我们真正需要的部分
  → 不 fork、不 vendor、不 rebase
```

- **结论：合法，需要时（且仅在需要时）推荐。**
- 这是"OxCaml 当参考材料"，不是"OxCaml 当代码源"。
- 在 **P3 之后** 才有用，且仅当出现某个 BPF 相关的具体优化需求、
  显而易见的方法不够用时。
- P1–P3 阶段，这一切**不需要**。信任 `zig` 的 LLVM 优化器；
  对我们这个 IR 形态，它绰绰有余。
- Flambda 2 周边的论文和设计文档本身就是好入口；通常不需要读源码。

### 方式 C —— 当 PX 为某个新目标（wasm32、x86_64-linux …）激活时，借鉴 OxCaml 在该目标上的做法

```
ZxCaml P1–P5 按计划交付（仅 BPF）。
PX 为某目标激活，比如 wasm32，且有真实用例。
  → 看 OxCaml 怎么把 Lambda 映射到那个目标的 ABI
  → 把 *做法*（不是代码）抄进 ZxCaml 的管线
```

- **结论：场景性有用，但比看上去小得多。**
- OxCaml 的 x86 / arm 代码生成器和 OCaml ABI 深度绑定：
  `caml_call_gc` 调用约定、tagged 指针、异常表、boxed-float 规则。
  **这些在 ZxCaml 上一个都不适用。**
- 我们 *能* 学到的东西是通用技术：
  寄存器分配策略、指令调度、basic-block 布局。
  但这些恰恰是 `zig` 的 LLVM 后端**已经免费给我们做了的**。
  OxCaml 在这件事上对 ZxCaml 是平推。
- 对非 x86 目标（wasm32、riscv …），OxCaml 帮助更小，因为它本来就不针对这些。

### 方式 D —— 用上游 OCaml（和/或 OxCaml）把同一份 `.ml` 直接编 native，与 `omlz` 编 BPF 并行

```
一份 .ml 源文件
  ├── ocaml / dune                → x86_64 / arm64 native 二进制
  │                                  （快速本地测试、fuzzing、REPL）
  └── omlz                         → BPF .o
                                     （部署到 Solana）
```

- **结论：免费、推荐、ADR-001 已经隐含支持。**
- 因为 ZxCaml 是 OCaml 严格子集（ADR-001），
  我们接受的每个 `.ml` 按定义都是合法 OCaml 程序。
- 所以上游 OCaml 编译器**已经免费**给开发者机器产出 native 二进制 ——
  ZxCaml 根本不需要 x86 后端。
- 这是"我想我的 Solana 程序也能在 x86 上跑做测试"这个需求最干净的答案：
  **装 `ocaml`**（按 ADR-010，`omlz` 本来就要它）然后跑同一份文件。
- 装 OxCaml 代替上游 OCaml 也一样行，因为 OxCaml 本身是 OCaml 5.2 的超集。

## 5. 把意图映射到推荐路径

如果你的真实意图是 **A**，请走右侧。

| 真实意图 | 推荐路径 |
|---|---|
| "我想我的 ZxCaml 程序也能在 x86 上跑做本地测试" | **D**（免费；装 `ocaml`） |
| "我想 ZxCaml 的 BPF 输出有更激进的优化" | **B**，但只在 P3 之后、有具体瓶颈时 |
| "我想 ZxCaml 把 wasm32 / x86_64-linux 当作真实目标支持" | PX 阶段（`08-roadmap.md` §8a）。OxCaml 在这件事上基本帮不上忙。 |
| "我想 fork OxCaml 加 BPF" | **没有路径。** ADR-009 还在。重读 `alternatives-considered.md` 方案 C。 |
| "我就是喜欢 OxCaml 的论文" | 读它们。它们好。但它们不是 fork 的依据。 |

## 6. 短版总结

- OxCaml 是 Jane Street 为他们 x86 / arm 交易系统打造的 **生产 OCaml fork**。
  在**那些工作负载上**，它比上游更快更紧 —— 靠的是 Flambda 2、Cfg 后端、
  mode 系统、Layouts。
- OxCaml **已经**支持 x86_64 和 arm64；没人需要"给它加 x86 支持"。
- OxCaml **不**针对 BPF，**也不会**针对 BPF，
  且它的优化依赖 BPF 不满足的假设。
- 从 ZxCaml 视角，正确使用 OxCaml 的方式是
  **当参考材料**（方式 B）和**当开发者本地 OCaml 工具链的可选替换**（方式 D）。
  Fork 它（方式 A）被 ADR-009 拒绝。
  借用它的目标后端（方式 C）大多无关，因为我们走 `zig` 的 LLVM。
- 对"我想要我的 ZxCaml 程序的 x86 native 二进制"，答案是：
  装 `ocaml`（或 `oxcaml`），然后 `dune exec`。
  ZxCaml 不需要长出 x86 后端就能让这件事工作。

## 7. 这份文档何时应当被修订

仅在以下条件成立时打开本文档并修订：

1. OxCaml 出了一个**真的**能迁移到 BPF 的特性
   （比如扁平内存 IR、no-runtime mode、freestanding target 选项）。
   这时按新特性重新评估 **方式 B**。
2. ZxCaml 撞上了一个 `zig` 的 LLVM 后端没法消除的 BPF 性能上限，
   下一步显而易见就是 ZxCaml 自己的优化器。
   这时 **方式 B** 变得可执行。
3. OxCaml 原生支持的某个目标变成了 PX 候选
   （比如 x86_64-linux ZxCaml 二进制有了开发测试以外的具体用例）。
   这时**仅针对那个具体目标**重新评估 **方式 C**。

Fork OxCaml（方式 A）**不在**重审清单里。
要重审它必须先 supersede ADR-009，而对那一条的标准答案是不。
