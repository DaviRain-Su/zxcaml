# 08 — 路线图

> **Languages / 语言**: [English](../08-roadmap.md) · **简体中文**

## 1. 各阶段

| 阶段 | 主题 | 完成标志 |
|---|---|---|
| **P1** | MVP：OCaml 子集 → BPF `.o` | `examples/solana_hello.ml` 部署成功并返回 0 |
| P2 | ADT 完整化 | 嵌套模式、记录更新、基础的 result-as-exception |
| P3 | Solana 形态子集 | `account` 类型、no-alloc 分析、syscall 绑定、真实 Anchor 风格程序 |
| P4 | 区域推断 | 逃逸分析、`Region::Region(id)`、可选栈分配 |
| P5 | 生态接入 | Zig FFI 声明、更大的原生 stdlib 子集 |
| P6（可选） | 自举 | 把 `src/core/anf.zig`（及伙伴）用我们的子集重写 |
| P7（可选） | 形式化 | Core IR 语义、面向 LLM / verifier 的接口 |

阶段不按时间盒，按范围盒。

## 2. Phase 1 — MVP

### 2.1 范围（必须）

- `zxc-frontend`（OCaml 胶水）：驱动 `compiler-libs`，遍历 `Typedtree`，
  强制 P1 子集（`10-frontend-bridge.md` §4），发出 `.cir.sexp`。
- `frontend_bridge`（Zig）：parse `.cir.sexp` 到 `ttree` 镜像。
- ANF lowering 到 Core IR，附 `Layout` 标注。
- `ArenaStrategy` lowering 到 Lowered IR。
- `ZigBackend` 发 `.zig` 源码。
- 树遍历解释器消费 Core IR。
- Runtime：`arena.zig`、`panic.zig`、`prelude.zig`、`bpf_entry.zig`。
- Stdlib：`option`、`result`、`list`。
- CLI：`omlz check / build / run`（见 §2.3）。
- 确定性属性：example 语料上 解释器 ≡ Zig 后端。
- 验收：`solana_hello.ml` 在 `solana-test-validator` 上部署成功并返回 `0`。

我们刻意 **不** 把"自己写 lexer / parser / HM"放进 P1。
按 ADR-010，那部分由上游 OCaml 完成。

### 2.2 范围之外（必须不做）

- functor / 在普通 `let` 之外的模块语法
- GADT、多态变体、effect
- 可变性、异常、引用
- LSP / formatter / debugger
- IDL / Anchor / CPI / 入口之外的 syscall
- 多文件模块（一个 `.ml` 源 + 内置 stdlib）
- 把"非 BPF 平台"作为交付物

### 2.3 CLI 接口

```
omlz check <file>                  -- parse + 类型检查，发出诊断
omlz check --emit=core-ir <file>   -- 打印 Core IR 到 stdout（golden 测试）
omlz run   <file>                  -- 前端 → 解释器；打印结果
omlz build <file>
            [--target=bpf|native]  -- 默认：bpf
            [--backend=zig|...]    -- 默认：zig
            [-o <path>]            -- 输出 object/exe
            [--arena-bytes=N]      -- runtime arena 大小
            [--keep-zig]           -- 在 out/ 下保留生成的 .zig
omlz version
```

### 2.4 内部里程碑（建议的 PR 边界）

```
P1.0  骨架               build.zig（Zig 0.16）同时驱动 OCaml 和 Zig 步骤；
                         `omlz --version`；arena util；diagnostics util。
P1.1  zxc-frontend MVP   能加载 .cmt 并输出 "ok" 的最小 OCaml 程序；
                         通过 build.zig + ocamlfind 接入。
P1.2  子集 walker        `zxc_subset.ml` 拒绝所有 §4 白名单之外的 Typedtree
                         节点，并附带位置。
P1.3  Sexp 序列化器      接受子集的 `.cir.sexp`，版本 0.1。
P1.4  Sexp parser (Zig)  `frontend_bridge` 把 0.1 解析进 `ttree`。
P1.5  ANF lowering       ttree → Core IR + Layout 字段。
P1.6  IR pretty-printer  在 `omlz check --emit=core-ir` 上做 golden 测试。
P1.7  解释器             `omlz run hello.ml` 输出 Some 1。
P1.8  ArenaStrategy      Lowered IR。
P1.9  ZigBackend         生成 native 下 `zig build-exe` 能接受的 `.zig`。
P1.10 Runtime + 入口     BPF shim、arena、panic。
P1.11 BPF driver         `omlz build --target=bpf` 产出 .o。
P1.12 Solana 骨架        在 solana-test-validator 上部署 + 调用。
P1.13 确定性套件         解释器 ≡ Zig native ≡ Zig BPF（在适用范围内）。
```

形态相比上一稿有变：原本的 P1.1–P1.4 是"Lexer / Parser / Name resolution /
Type inference"，全用 Zig 写。按 ADR-010，那些现在是上游 OCaml + 一小段胶水。

### 2.5 P1 验收语料

```
examples/hello.ml             - 列表 head、ADT、match
examples/option_chain.ml      - 串联 Option.map / Option.bind
examples/result_basic.ml      - Result 构造与模式
examples/list_sum.ml          - 列表递归求和
examples/solana_hello.ml      - BPF entrypoint 返回 0
```

前四个走解释器和 Zig 后端（native）。最后一个走 Zig BPF 和 `solana-test-validator`。

## 3. Phase 2 — ADT 完整化

- `match` 嵌套模式。
- 记录更新语法 `{ r with x = 1 }`。
- 基于 `result` 的错误传播 helper（无异常）。
- decision-tree match 编译。
- 更大的 stdlib：`Option.map / bind / get_or`、`Result.map / bind`、
  `List.map / filter / fold / length / rev / append`。
- 在 `examples/` 下加非平凡程序。

## 4. Phase 3 — Solana 形态子集

- `account` 类型：BPF account 输入字节的带类型视图。
- `no_alloc` attribute 和一道分析，证明某函数不在 arena 上分配。
- syscall 绑定：`sol_log`、`sol_get_clock_sysvar`、基础 CPI 签名。
- 一个真实 example：小型 SPL-Token 风格的 transfer 程序。
- IDL 发出 stub（一次性 JSON，尚未兼容 Anchor）。

## 5. Phase 4 — 区域推断

- 在 IR 中引入 `Region::Region(id)`。
- Core IR 上的逃逸分析 pass。
- `RegionStrategy`（仍基于 arena，但 per region）。
- 对可证明不逃逸的局部做可选栈分配。
- P4 不引入用户面的语法变更；这纯粹是优化。

## 6. Phase 5 — 生态接入

- 绑定到 Zig 函数的 `external` 声明。
- 把 Zig 包 vendor 成 `omlz` 依赖的工具链。
- 更大的原生 stdlib（`Map`、`Set`、基础 crypto wrapper）。
- Anchor 风格的 IDL 发出。

## 7. Phase 6 — 自举（可选）

- 用我们的子集重写 `src/core/anf.zig` 和 `src/core/pretty.zig`。
- 把重写后的代码穿过 `omlz`，把产出 object 链回编译器自身。
- 这是 dogfood 门槛；项目不必通过它就能交付。

## 8. Phase 7 — 形式化（可选）

- Core IR 的小步语义（论文或 Lean / Coq）。
- 给 LLM / verifier 用的 Core IR 接口
  （S-expression 序列化？确定性 JSON？）。
- 属性测试：Core IR 与 Lowered IR 之间的 refinement。

## 8a. Phase PX — 多目标扩展（可选，有门槛）

**状态：** 未排期。不在主路径上。
本阶段存在的唯一目的，是给"那其它目标呢？"这个问题一个明确的形态，
免得它渗透到更早的阶段里。

### 上下文

因为 Zig 后端发的是 `.zig` 源码，Zig 工具链在原理上能 lower 到它支持的任何目标
（`aarch64`、`x86_64`、`riscv*`、`wasm32`、`nvptx*`、`amdgcn` …… 详见
`06-bpf-target.md` §10 的完整列表和配套冷水）。

这 **并不** 等于那些目标被支持。
PX 就是把一个目标从"工具链技术上能到"切换到"ZxCaml 支持"的那道门。

### 激活门槛

PX 仅在某个具体目标 **同时满足** 下述四条时激活：

1. **有具体用例**，写下来，至少有一个 champion 会真的用产出。
2. **有 owner**，负责这个目标的 runtime shim 工作
   （entrypoint、panic、内存方案、与用户代码的调用约定）。
3. **BPF 形态的语言约束适配这个用例**，
   或者把松绑作为新 ADR 提出
   （比如"WASM 目标可以用宿主 allocator 代替单 arena"）。
4. **同一次变更里加入一条 CI lane 和一个验收 example。**

四条少一条，目标就不进。投机性的多目标支持是漏洞，不是特性。

### 可能的候选（仅举例，未承诺）

- **`wasm32-freestanding`** —— 浏览器内 Solana 程序模拟器。
  门槛：用户是谁？什么工具消费输出？
- **`x86_64-linux`** —— 想要原生速度和 crash dump 的 fuzzing / 属性测试骨架。
  门槛：得有真实的 fuzzing 骨架，不是"如果有就好了"。
- **`riscv64-linux` / 嵌入式 BPF（Linux 内核 eBPF）** ——
  在 Solana BPF 之外，但相邻。
  门槛：有个具体的 eBPF 程序需要交付。

### 注意：x86 / arm native **不是** PX 候选

如果你的目标是"我想在 x86 / arm 上跑我的 ZxCaml 程序做本地测试或 fuzzing"，
你**不需要** PX —— 因为每个 ZxCaml 程序按构造都是合法 OCaml 程序（ADR-001），
而开发者机器为了 `omlz` 的前端桥接（ADR-010）已经装了 OCaml 工具链。
直接用 `ocaml`（或 OxCaml）编同一份 `.ml` 然后运行即可。
详见 README 里 "Native 执行是顺带免费的" 一节，以及
`docs/oxcaml-relationship.md` 的完整讨论。

PX 留给的目标是那些**不**适用上面这个技巧的：
也就是说，今天上游 OCaml 和 `omlz` 都不会产出可运行二进制，
而又有人有具体理由让 `omlz` 去产一个。

### PX **不是** 什么

- 不是"支持每一个 Zig 目标"。工具链广度不等于 ZxCaml 广度。
- 不是"把语言变成通用语言"。
  BPF 形态的约束（无 GC、无 syscall、无线程、无异常）继续成立，
  除非有 ADR 明确按目标松绑。
- 不是 P1 / P2 / P3 的交付物。
  它特意放在主编号阶段之后，并且本身可选。

### 与既有阶段的关系

PX **不阻塞任何更早的阶段**。
P1–P5 按计划进行，BPF 是唯一被验证的目标。
PX 存在的意义是：当真正的第二个目标出现时，它通过定义好的流程进入项目，
而不是有机地稀释项目焦点。

## 9. 反目标（每个 phase 都不能违反）

- 我们绝不在产出里接受 OCaml C runtime。
- 我们绝不采纳需要 GC 的特性。
- 我们绝不 fork OCaml 编译器（ADR-009）。
- 我们绝不悄悄漂出 OCaml 子集；
  ADR-010 让漂移在结构上不可能 ——
  上游编译器就是 parser / 类型检查器。
- 我们 **不** 依赖任何 `opam` 包，**除了** OCaml 发行版自带的
  `compiler-libs.common`。前端胶水的第三方 opam 依赖数量是零。
