# 09 — 架构决策记录（ADR）

> **Languages / 语言**: [English](../09-decisions.md) · **简体中文**

格式：简短、有日期、不可变。新增 ADR 用追加的方式；老的不要改 ——
要改就用新条目 supersede。

---

## ADR-001 —— ZxCaml 是 OCaml 方言，不是新语言

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

早期草案倾向于做一门"带新 `.zxc` 后缀的 ML 系新语言"。
项目作者拒绝了这个方向，因为它属于范围扩张：项目目标不是发明语言，
而是给一门已存在语言做一个新后端。

### 决策

- 源语言是 **OCaml**（它的严格子集）。
- 源文件后缀 `.ml`。
- 不引入新关键字、新运算符、新句法。
- 一个被 ZxCaml 接受的程序也必须能被参考实现的 OCaml 编译器接受
  （只要本机有 `ocaml`，CI 把它当作正确性参考）。

### 后果

- 前端规范全盘借用 OCaml；我们只描述自己接受的 *子集*。
- "把生态走 OCaml 后端"**不是**目标 ——
  复用 OCaml 库需要复刻 OCaml runtime 表示，我们刻意不做。
- CLI 二进制名为 `omlz`（OCaml on Zig）。repo 名仍为 `ZxCaml`。

---

## ADR-002 —— 编译器宿主语言为 Zig 0.16

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

编译器总得用某种语言写。候选：Rust、OCaml、Zig。

### 决策

- 编译器用 **Zig** 写，版本锁 **0.16**。
- 在 `build.zig.zon` 里通过 `minimum_zig_version = "0.16.0"` pin 版本。
- 我们对接的是 0.16 的 build API（`b.addExecutable` 用 `root_module`、
  `b.addTest` 用 `root_module`、zon 里的 `paths`）。

### 理由

- runtime helper 和代码生成器本来就要 Zig。
- 编译器 + runtime + 生成代码用同一种语言，工具链占地最小。
- Zig 的 arena allocator 与编译器管理 AST/IR 的天然方式很匹配。

### 已知代价

- Zig 里没有成熟 parser-generator，parser 要手写。
- 宿主语言里没有原生 ADT/模式语法；AST/IR 类型用 tagged union + 手动 switch。
- 没有 `derive(Debug)` 这类设施；pretty-printer 全靠手写。
- 标准库在 minor 之间还在演进；每个 phase 锁一个版本。

---

## ADR-003 —— Phase 1 端到端出 BPF `.o`

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

更稳的 P1 是"发到 Zig 源码、能 native build"就停。
那样把项目最高风险的部分（BPF 工具链链路）推后，但也意味着它更晚被验证。

### 决策

P1 包含端到端 BPF 链路：

- `omlz build --target=bpf` 调 `zig build-obj -target bpfel-freestanding`。
- 产出 `.o` 能被 `solana-test-validator` 加载。
- 验收门槛是一份能跑的 `examples/solana_hello.ml`。

### 范围纪律

为让这件事可控，P1 **只**覆盖：

- entrypoint shim
- 返回值为 `0`
- 不带 syscall、不解析 account、不 CPI

其它 Solana 形态全部 P3。

---

## ADR-004 —— Core IR 是 ANF、带类型、带 layout

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

考虑过的 Core IR 形态：

- **ANF**：简单、规整、被广泛理解；ML 系生产编译器常用。
- **CPS**：在控制流变换和 effect handler 上很强；学习曲线陡，IR 体积更大。
- **Typed tree**：最小，但把优化重复推到每个后端。

### 决策

Core IR 是 **ANF**，带类型（每个节点都有 `Ty`），带 `Layout` 描述符
（用于会引发分配的节点）。

### 理由

- ANF 是 ML 系编译器的标准（OCaml 的 Lambda → Cmm 管线本质上是带壳 ANF；
  MLton、GHC 等也类似）。
- ANF 让 ABI 感知的 lowering 直接：后端看到的是一连串扁平 `let` 操作。
- `Layout` 字段是区域推断和替换内存模型的向前兼容钩子（见 ADR-006）。

### 后果

- continuation 风格的变换（effect handler、复杂控制流）若真要做，需要额外基础设施。
  这是可接受的，因为它们明确不在范围内。

---

## ADR-005 —— P1 内存模型隐藏，全 arena

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

考虑过：

- 隐藏 / 全推断（用户写普通 OCaml）。
- 类型层 region 标注（如 `'a @region`）。
- 完全手动（用户选 `arena` / `rc` / 等等）。

### 决策

P1 隐藏内存模型。用户写普通 OCaml；编译器在所有地方选择 arena 分配，
立即值和字符串字面量除外。

### 理由

- 区域推断、所有权分析、引用计数都是深度 PL 研究问题；P1 阶段做任何一个都太冒险。
- 隐藏的单 arena 已经能轻松通过 P1 的 BPF 验收测试。
- 未来阶段可以把这个 arena 细化成 per-region arena，不会改变用户面的语言。

### 向前兼容

Core IR 上的 `Layout` 描述符（ADR-004）是扩展点。P4 会加新的 `Region` 变体和
推断 pass；Core IR 形态不需要变。

---

## ADR-006 —— OCaml 后端从主路径删除

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

一个看起来很自然的想法是：
"把我们的子集编到 OCaml 字节码 / native，白嫖 opam 库。"
这件事重新评估后被拒绝。

### 决策

主路径上 **没有** OCaml 后端。

仅保留一个仅编译占位 `src/backend/ocaml_stub.zig`，让 backend trait 自洽。
它返回 `error.NotImplemented`。

### 理由

- OCaml 库依赖 runtime 表示
  （tagged 指针、boxed float、GC、异常、ctypes），不仅是语言。
- 重新实现 OCaml runtime = "变成 OCaml"，这不是项目目标。
- 我们通过"做 OCaml 严格子集"（ADR-001）实现前端复用，
  而**不是**通过把流走 OCaml 后端。

### 后果

- 生态复用走两条路：用我们的子集写原生 stdlib + Zig FFI（P5）。
- OCaml 仍可在 **离线** 阶段作为子集正确性参考。

---

## ADR-007 —— 单一 arena 贯穿每个函数

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

P1 的分配纪律必须定义清楚。

### 决策

每个发出的函数都以 `arena: *Arena` 为隐式首参。
BPF 入口 shim 从静态 buffer 创建 arena 并向下传递。
分配始终走这个 arena。

### 理由

- 推理生命周期很简单：什么都不会逃出程序。
- 重置很简单：程序退出时丢掉 arena。
- 避免全局状态，对 BPF 和确定性都是敌对的。

### 后果

- 程序无法分配超过 arena buffer 的内存；buffer 大小通过 CLI flag
  （`--arena-bytes`，默认 32 KiB）。
- 多 arena 方案（per region、per call）属于 P4 细化，
  不需要 Core IR 变化。

---

## ADR-008 —— 解释器与 Zig 后端的等价是硬不变量

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

解释器和 Zig 后端可能在细节上分歧（整数溢出、模式匹配顺序、除法语义）。
没人做检查的话，这种分歧会悄悄发生。

### 决策

属性测试套件把所有 example 同时穿过解释器和 Zig 后端（native 构建），
diff 可观察输出。任何分歧都是 P0 bug。

### 理由

- 解释器存在的根本理由就是当语义参考；后端如果不一致，错的就是后端。
- 这能立刻抓到整数语义类回归。

### 后果

- 一些语义决定（整数绕回、除法语义）固定在 `05-backends.md`。
- BPF 输出无法在值层面 diff，但返回码可以；这是 BPF 验收测试。

---

## ADR-009 —— **不** fork OxCaml（或任何 OCaml 编译器发行版）

**日期：** 2026-04-27
**状态：** 已采纳
**Supersedes：** 无。强化 ADR-006。

### 上下文

OxCaml（`oxcaml/oxcaml`，原名 `flambda-backend`）是 Jane Street 的 OCaml
编译器 fork。它包含一个完整的 OCaml 5.2 编译器、重设计的 Cfg 后端、
Flambda 2 优化器、`mode` / `local` / `unique` 系统、Layouts 特性，
还有 OxCaml 的 C runtime。仓库 ~37k commits、~970 branch、~87% OCaml + ~9% C，
持续 rebase 到上游 OCaml。

一个看起来很合理的策略是：*"fork oxcaml，在它的 Cfg 后端旁边加一个 BPF 后端，
免费继承 Jane Street 所有优化。"*
我们仔细重新评估并 **拒绝** 了这条路。

### 决策

- 我们 **不** fork OxCaml。
- 我们 **不** fork 上游 OCaml。
- 我们 **不** 把任何 OCaml 编译器源码 vendor 进 repo。

### 理由

1. **OxCaml 的优化全部假设 OCaml runtime 存在。**
   Flambda 2 的 unbox 依赖 unbox 路径上不调 `caml_call_gc`；
   Cfg 后端发的调用约定匹配 OCaml ABI；
   `local` / unique mode 区分栈和 GC heap 分配，这里的"GC heap"是 OCaml 的 GC。
   这些前提在 Solana BPF 上一个都不成立 ——
   BPF 没有 GC、没有异常、没有线程、没有 `caml_call_gc`、没有 OCaml 形态的 ABI。
   所以这些优化**不迁移**；fork 只是继承"我们用不上的代码 + 必须维护的负担"。
2. **OxCaml 自己的后端不针对 BPF。**
   要在 OxCaml 内加 BPF 目标，是对上游有敌意的补丁：要和现有 Cfg 后端共存、
   绕过 `caml_call_gc`、stub 掉异常和线程、随包带一个并行迷你 runtime。
   这一切上游都不会接，所以 fork 的发散度只增不减。
3. **维护一个 37k commits 的活跃编译器 fork 是全职团队工作量。**
   Jane Street 有团队，我们没有。不 rebase 的 fork 变成死代码；
   持续 rebase 的 fork 会消耗项目大部分工程预算去解冲突。
4. **前端复用目标不需要 fork。**
   见 ADR-010：上游 OCaml 的 `compiler-libs` 加上 `-bin-annot`（`.cmt`）导出，
   已经能给我们一棵完整类型检查后的 `Typedtree`。我们消费这棵树即可。

### 不 fork 我们失去什么

- 我们 **不会** 拿到 Flambda 2 的优化。
  → BPF 上信任 `zig` 自带的基于 LLVM 的优化器。
- 我们 **不会** 拿到 OxCaml 的 `mode` / `local` 系统。
  → 我们 Core IR 上的 `Layout` 字段（ADR-004）是另一种、更小的、契合区域故事
  （ADR-005）的机制。
- 我们 **不会** 拿到 unboxed Layouts（`float64`、`bits64` 等）。
  → P1 可接受；P4+ 时如果 BPF 目标上发现它确实重要，再重新评估。

### 我们保留什么

OxCaml 的设计思想（Layouts、modes、Flambda 2 的 IR）是
**参考材料**，不是需要导入的代码。我们可以读他们的代码、读他们的论文；
我们 **不** 把他们的源码搬进来。

---

## ADR-010 —— 用上游 OCaml `compiler-libs` 作为前端

**日期：** 2026-04-27
**状态：** 已采纳
**Supersedes：** ADR-002 的部分内容 ——
编译器不再是"全 Zig"；它是 **OCaml 前端桥 + Zig 后端**。

### 上下文

ADR-009 排除了 fork 任何 OCaml 编译器。ADR-001 锁死了 OCaml 语法 / 语义。
所以我们必须从某处获取用户 `.ml` 的 parse + 类型检查后表示。

考虑过：

- **A.** 用 Zig 手写 lexer + parser + HM。最大独立性，最多代码，子集漂移风险最大。
- **B.** 调上游 OCaml 编译器的 `compiler-libs` 拿到 `Typedtree`，消费它。
  不 fork、OCaml 胶水极小、子集内语言保真度完美。
- **C.** Fork OxCaml（已被 ADR-009 拒绝）。

### 决策

采纳 **方案 B**：一段小的 OCaml 胶水程序驱动 `compiler-libs` 类型检查用户 `.ml`，
把结果以序列化 `Typedtree`（S-expression，格式定义在
`docs/10-frontend-bridge.md`）发出。Zig 编译器读这个序列化结果，从这里继续。

### 架构影响

```
.ml
 ↓        zxc-frontend（OCaml，~几百行）
ocamlc -bin-annot   →   .cmt（Typedtree）   →   sexp dump
 ↓
zxc-frontend-bridge（Zig）  读 sexp，构造我们的 Typed AST 镜像
 ↓
ANF lowering → Core IR → ArenaStrategy → Lowered IR → Zig codegen
 ↓
zig build-obj -target bpfel-freestanding
 ↓
Solana BPF .o
```

Core IR 仍然是稳定契约（ADR-004 不变）。
**Core IR 上层** 改了：Surface AST 现在是 OCaml 的 `Typedtree`，
不是手写 AST。

### 理由

- **不写 parser、不维护 parser。** OCaml 的 lexer 和 parser 是参考实现，
  我们不可能不小心漂离。
- **不写类型系统、不维护类型系统。** OCaml 的 HM + ADT（以及未来想要的模块）
  全免费拿到。
- **强制子集变得简单。** OCaml 胶水用真正的编译器先类型检查，
  再遍历 `Typedtree`，拒绝不支持的节点 —— 给出精确诊断。零意外不兼容。
- **工具复用。** 编辑器支持、`merlin`、`ocamlformat` 在用户 `.ml` 上原封不动地工作。

### 后果

- 一个工作的 `ocaml` 工具链（`ocamlc`、`ocamlfind`）是 `omlz` 的
  **build-time** 依赖。它**不是**编译出来的 BPF 程序的运行时依赖
  （那些程序与 OCaml 无关）。
- 编译器现在是双语：一段小的 OCaml 前端胶水，加上既有的 Zig 管线。
  构建编排见 ADR-011。
- `Typedtree` API 是 `compiler-libs` 的一部分，跨主版本**不**保证稳定。
  我们每个 phase 锁一个 OCaml 版本，并在本 ADR 的修订记录里写升级路径。
- 我们失去了"单二进制、无 OCaml 依赖"的分发选项。这可以接受：
  构建 Solana 程序的开发者本就需要工具链；运行已部署 BPF 程序的终端用户什么都不需要。

### Pin 的版本（P1）

- OCaml：**5.2.x**（与 OxCaml base 一致；opam 上广泛可用）。
- 匹配发行版自带的 `compiler-libs.common`。
- Zig：**0.16.x**（不变，ADR-002 仍生效）。

---

## ADR-011 —— `build.zig` 是唯一 build driver；不引入 `dune`

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

ADR-010 给项目带来一个 OCaml 组件。OCaml 代码的天然构建工具是 `dune`。
采纳 `dune` 意味着两套并存的构建系统（前端胶水用 `dune`，
其它一切用 `build.zig`）外加一个 coordinator。

### 决策

`build.zig` 是这个 repo 里 **唯一** 的 build driver。

OCaml 前端胶水通过 `build.zig` 里 `b.addSystemCommand` 调用
`ocamlfind ocamlopt` 直接构建。不 check in `dune-project` 文件。

### 理由

- **一个项目，一个构建入口。** `zig build` 是开发者契约。
- **OCaml 胶水很小。** 一个可执行、一份二进制；用不上 `dune` 的多包机制。
- **opam 依赖足迹只到 `compiler-libs`。** 引入 `dune` 会把一个我们其它地方
  都不需要的次工具链拉进来。
- **CI 简单。** 一步 `zig build`，结束。

### 后果

- OCaml 胶水必须自包含：除了 `compiler-libs`（OCaml 发行版自带）之外，
  不允许第三方 `opam` 包。
- 如果有一天 OCaml 胶水超过几个文件，本决策必须重审。
  这一点**明确绑定到范围**：如果前端胶水演化成"真正的 OCaml 代码"，
  我们会重审，但只能通过 supersede 本 ADR 来改。
- 编辑器 / LSP 配置可能需要一个非常小的 `.merlin` 或目录级 `dune` shim ——
  那种 shim **不**是构建的一部分。可以接受，
  只要 `zig build` 仍是权威。

### 构建流程

```
zig build
  ├─ step: ocaml-frontend
  │    invokes: ocamlfind ocamlopt -package compiler-libs.common \
  │             -linkpkg src/frontend/zxc_frontend.ml \
  │             -o build/zxc-frontend
  ├─ step: omlz (Zig 可执行)
  │    依赖：ocaml-frontend（二进制被 copy/embed）
  └─ step: install
       把两个二进制都放到 zig-out/bin/
```

`omlz` 在处理 `.ml` 输入时，运行时把 `zxc-frontend` 当子进程调起。
