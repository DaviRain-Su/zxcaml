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

## ADR-003 —— Phase 1 端到端出 BPF `.so`

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

更稳的 P1 是"发到 Zig 源码、能 native build"就停。
那样把项目最高风险的部分（BPF 工具链链路）推后，但也意味着它更晚被验证。

### 决策

P1 包含端到端 BPF 链路：

- `omlz build --target=bpf` 先调
  `zig build-lib -target bpfel-freestanding -femit-llvm-bc=…`，
  再调 `sbpf-linker --cpu v2 --export entrypoint`（默认；
  `v3` 为可选，按 ADR-013 Revised 2026-04-27）。
- 产出 `.so` 能被 `solana-test-validator` 加载。
- 验收门槛是一份能跑的 `examples/solana_hello.ml`。

> **2026-04-27 修订** 以反映对照 `DaviRain-Su/zignocchio` 验证后的真实工具链形态。
> 早期写的 "`zig build-obj`、`.o`" 是规划期的近似；
> 真正能跑通的链路文档化在 `06-bpf-target.md` §2，
> 并由 ADR-012 / ADR-013 / ADR-014 钉住。

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
zig build-lib -target bpfel-freestanding -femit-llvm-bc
 ↓
sbpf-linker --cpu v2 --export entrypoint    （或 --cpu v3 可选；ADR-013）
 ↓
Solana BPF .so
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

---

## ADR-012 —— `sbpf-linker` 是 build-time 依赖，版本钉死

**日期：** 2026-04-27
**状态：** 已采纳
**Supersedes：** ADR-003 / `06-bpf-target.md` 早期草稿里那个隐含
"光跑 `zig build-obj` 就能出 Solana 可加载产物"的假设。

### 上下文

在准备 spike β（BPF 工具链验证）的 preflight 时，我们对照了
正在工作的 Zig→Solana SDK：`github.com/DaviRain-Su/zignocchio`。
被验证过的工具链是两步，不是一步：

1. `zig build-lib … -femit-llvm-bc` 出 LLVM bitcode。
2. `sbpf-linker --cpu v2 --export entrypoint` 出 Solana loader 接受的
   SBPFv2 ELF `.so`（`v3` 为可选，详见 ADR-013 Revised 2026-04-27）。

标准 `lld` 产出的 `.so` Solana loader 不接受：
Solana 的 ELF 布局、SBPF 指令集版本（SBPFv0/v1/v2/v3）、
入口符号 export 语义都和通用 eBPF 不一样。
`sbpf-linker` 就是这座桥。

`sbpf-linker` 维护在 `github.com/blueshift-gg/sbpf-linker`，
crates.io 上以 `sbpf-linker` 名字发布。

### 决策

- `sbpf-linker` 是 `omlz` 的 **build-time 依赖**。
  产 BPF 产物时必须；**运行**已部署 BPF 程序时不必。
- P1 的 pinned 版本是 **`sbpf-linker 0.1.8`**（crates.io），
  如果只是 bug-fix 必须升到更新版本，备选是 pin 到 `master` 上的
  某个具体 commit。
- `omlz` 的 `build.zig` **不**安装 `sbpf-linker`，只要求
  `PATH` 上有这个二进制；找不到时打印诊断 + 安装指引。
- CI 用 `cargo install sbpf-linker --version 0.1.8` 装；
  必要时也可以 `cargo install --git
  https://github.com/blueshift-gg/sbpf-linker --rev <sha>`。

### 理由

- 我们没有能力自己写一个懂 Solana 的 BPF linker。
  2026-04 唯一可行的答案就是 `sbpf-linker`，
  且它的维护态势够（活跃 commit、有 crate 发布、被其它 Solana
  工具链使用）。
- pin 一个 *版本*（外加 commit fallback）让构建可重复，
  并把"何时升级"集中到一个 ADR 修订上。
- 不放进 `build.zig` 的安装路径，省掉 `cargo` bootstrap 的兔子洞；
  `zig build` 仍是唯一 driver（ADR-011），
  `cargo install` 是开发者一次性 setup —— 与装 `solana-cli` 同级。

### 后果

- `omlz` 的安装文档列出四个先决条件：
  `zig 0.16.x`、`ocaml 5.2.x`（带 `compiler-libs`）、
  `sbpf-linker`（pinned）、`solana-cli`。
- 升级 `sbpf-linker` 需要：
  (a) 跑一遍 CI；
  (b) 重跑 BPF 验收测试；
  (c) 在本 ADR 加一条修订记录写新版本号。
  不允许"沉默地跟着 `master` 漂"。
- 如果哪天 `sbpf-linker` 与我们生成的 bitcode 出现兼容问题：
  按 P0 处理 —— 上报上游、回退到上一个能用的版本，
  并评估是不是该改的是我们 bitcode 的形态。

### 2026-04-27 修订 —— macOS 下需要 LLVM 20 dlopen 前置条件

Spike β（`docs/preflight-results-spike-beta.md`）发现，在 stock macOS 上
pinned 的 `sbpf-linker 0.1.8` 在运行时会 panic：

```
sbpf-linker: unable to find LLVM shared lib
```

除非通过 `DYLD_FALLBACK_LIBRARY_PATH` 暴露一个 LLVM 20 的动态库。
原因：

- `sbpf-linker 0.1.8` 依赖 `aya-rustc-llvm-proxy 0.10.0`，后者
  `dlopen` `LD_LIBRARY_PATH`、`DYLD_FALLBACK_LIBRARY_PATH`
  以及 `PATH` 邻近 `lib/` 目录里第一个找到的 `libLLVM*`。
- stock macOS + Homebrew 默认这些路径里都没有 `libLLVM.dylib`；
  Homebrew Rust 链接的是 `llvm@21` 的 `libLLVM.dylib`，
  但 `sbpf-linker 0.1.8` 是按 LLVM 20 ABI 编出来的。

**macOS workaround**（要用 `sbpf-linker 0.1.8` 必须做）：

```sh
brew install llvm@20
export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix llvm@20)/lib"
```

**Linux 备注**：大多数发行版自带 `libLLVM-20.so`，系统 linker 能找到；
若没有，把 `LD_LIBRARY_PATH=/path/to/llvm-20/lib` 指过去即可。

这个依赖来自 `aya-rustc-llvm-proxy`，**不在我们控制范围内**。
若未来 `sbpf-linker` 把 LLVM 静态链接进去，就会取消这一依赖；
届时本修订条目随之更新。

`sbpf-linker = 0.1.8` 的 pin 不变；只是文档化的前置条件多了一条。
`06-bpf-target.md` §6 现在带了 macOS prereq 段落，
§8 故障表新增对应一行。

---

## ADR-013 —— Solana SBF 版本在 P1 锁为 `v3`

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

Solana 的 BPF 方言有版本：

- **SBPFv0** —— 最初的版本，限制极多（无 call、无 shift……）。已 legacy。
- **SBPFv1 / v2** —— 中间态；指令更广，但 loader 仍有限制。
- **SBPFv3** —— 2026 年新程序的默认；支持 LLVM 一般会发的指令。

`sbpf-linker` 暴露 `--cpu v0|v1|v2|v3`。zignocchio 用的是 `--cpu v3`。

### 决策

P1 把 SBPF 版本锁在 **`v3`**。

- `omlz build --target=bpf` 永远调 `sbpf-linker --cpu v3`。
- 必须跑在更老 runtime 上的程序（2026 年很罕见，但 legacy chain 上有）
  **不在** P1 范围。

### 理由

- v3 是 `solana-test-validator` 和现代 mainnet loader 的默认接受版本。
- 老版本对指令做了限制，LLVM 不加 target 特定选项不会守这些限制；
  锁 v3 避免和工具链对着干。
- 一个版本 → 一套验收测试 → 一套预期行为。

### 后果

- P1 编出来的程序跑不了老 SBPF runtime。已知，已接受。
- 如果未来某 phase 需要 multi-version 支持，
  CLI flag `--sbpf-version` 留给那一刻用。

### 2026-04-27 修订 —— 默认 `v2`，`v3` 改为可选

Spike β（`docs/preflight-results-spike-beta.md`）端到端验证了 BPF 工具链
（对照 `DaviRain-Su/zignocchio`）。读 zignocchio 的 `build.zig` 和
`AGENTS.md` 时发现 ADR-013 当初读错了一件事：
**zignocchio 用的是 `--cpu v2`**，不是 `--cpu v3`。
`build.zig` 里相关注释原文：

> `v2: No 32-bit jumps (Solana sBPF compatible)`

我们用 `--cpu v2` 构建出的 `hello.so` 被 `solana-test-validator` 3.1.12
接受、跑通（107 compute units，`status: Ok`）。
v2 是当前 mainnet validator 的默认接受版本；
v3 引入了更新的特性（如 static syscalls），需要 feature gate 激活，
目前并不被普遍接受。

因此本 ADR 修订如下：

- **默认 SBPF 目标是 `v2`。** `omlz build --target=bpf` 调
  `sbpf-linker --cpu v2 --export entrypoint`。
- **`v3` 作为可选路径保留。** CLI flag `--sbpf-version=v3`
  （或等价环境变量）允许明确需要 v3 特性的用户选择它。
  P1 只 ship v2，v3 不进 P1 验收测试；v3 路径只是保留，未验证。
- 上面 v3 的原文按 ADR 约定保留为历史记录；
  此 addendum 是当前权威表述。

同步级联（已在同一变更集内完成）：`06-bpf-target.md`、
`zignocchio-relationship.md`、`01-architecture.md`、`README.md`，
以及对应的中文镜像，全部把 `--cpu v3` / `SBPFv3` 改为
`--cpu v2` / `SBPFv2`（在文档语境合适处注明 `v3` 为可选）。

---

## ADR-014 —— 把 `zignocchio` 当灵感参考（Way A），不导入它的代码

**日期：** 2026-04-27
**状态：** 已采纳

### 上下文

`github.com/DaviRain-Su/zignocchio` 是一个能跑通的
Zig→Solana SBF SDK。它的覆盖面与 ZxCaml 未来 `runtime/` 需要的
显著重叠：arena allocator、BPF entrypoint deserializer、
syscall 绑定（MurmurHash3-32 dispatch）、AccountInfo 解析、
PDA / CPI helper、litesvm/surfpool/mollusk 测试集成。

"使用 zignocchio"考虑了四种策略：

- **A.** 当灵感读它，ZxCaml 自己写自己的 runtime。
- **B.** 当 `git submodule` / `build.zig.zon` 依赖；
  生成代码调它的 SDK。
- **C.** vendor 几个关键文件（entrypoint / syscalls / allocator）
  到 `runtime/zig/`，附 attribution。
- **D.** fork 它，作为 ZxCaml 风格的子项目维护。

### 决策

采纳 **Way A**：zignocchio 是 **灵感参考**。
我们可以自由阅读它的源码；**不导入** 它的代码到本仓库。

这与 ADR-009 对 OxCaml 的姿态完全一致。

### 理由

- **与项目其它"不 fork、不 vendor"决策一致。**
  ADR-009 拒绝 fork OxCaml，理由同样适用：
  fork 或 vendor 等于承担非自有代码的维护责任。
- **license 卫生。** 导入代码自带 license 义务；
  "读思路、自己写"没有。
- **范围解耦。** zignocchio 的定位是给 Solana 开发者用的 Zig SDK。
  ZxCaml 是一个编译器，碰巧生成代码也需要那一层 SDK 表面。
  把两者耦合就是把我们的 roadmap 耦合到他们的。
- **要保持 fresh 的表面更小。** vendored 副本会过期；
  submodule pin 要求我们追踪 upstream。
  "读思路"维护成本是 0 —— 需要思路时再读。

### 这条 ADR 允许什么

- 阅读 zignocchio 源码，学习 SBPF（默认 v2，v3 可选）entrypoint 的正确写法。
- 用我们自己的命名、错误处理、arena 所有权语义，
  独立重新得到它的设计（BumpAllocator → 我们的 `arena.zig`、
  syscall MurmurHash3-32 helper → 我们 P3 的
  `runtime/zig/syscalls.zig`）。
- 把它作为某个非显然技巧的来源加以引用
  （比如 `06-bpf-target.md` §4 的 const-array workaround）。

### 这条 ADR 禁止什么

- 把 zignocchio 的源码文件 copy-paste 到 `runtime/zig/`
  或本仓库其它任何地方。
- 把 zignocchio 加为 build 依赖（submodule、zon、vendor 目录）。
- 在 ZxCaml 组织下 fork 它。

### 关系总览

| 来源 | 我们的姿态 | ADR |
|---|---|---|
| OCaml `compiler-libs` | build-time 当库用 | ADR-010 |
| OxCaml | 仅作为灵感阅读 | ADR-009 |
| zignocchio | 仅作为灵感阅读 | ADR-014 |
| `sbpf-linker` | build-time 工具依赖，pin 死 | ADR-012 |
| `solana-cli` | 开发者工具依赖 | （隐含） |

### 后果

- 到 P3，ZxCaml 的 `runtime/zig/` 会含有看起来 *与 zignocchio 的部分非常相似*
  的代码。这是预期：Solana BPF 输入缓冲区只有一种正确的反序列化方式，
  bump allocator 也只有一种顺手的写法。趋同演化没问题；copy-paste 不行。
- 关于"我们从读 zignocchio 学到了什么、它如何塑造了 P1"的较长叙事，
  见 `docs/zignocchio-relationship.md`。
