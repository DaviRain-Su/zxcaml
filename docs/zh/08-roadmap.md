# 08 — 路线图

> **Languages / 语言**: [English](../08-roadmap.md) · **简体中文**

这份路线图现在把已经封存的编译器阶段、演示/运营工作，以及未来可选方向分开说明。面向用户文档的当前规范事实是：frontend bridge 接受 sexp wire 格式 `1.5`，examples 语料包含 98 个 `.ml` 程序，Mollusk SVM 套件包含 44 个 Rust 集成测试文件（66 个 Rust test case），并且 P1-P9 都已经在 [`CHANGELOG.md`](../../CHANGELOG.md) 中封存。
Real-world Examples Batch 3 补齐了 `spl_burn`、`spl_close_account` 和 `spl_revoke` 这三个 SPL Token primitive 示例。R13 已作为 account-guard 产品打磨 slice 收束：`Account.*` helper、`account_guard`、IDL signer/writable/error metadata，以及 UI 误用诊断都已有测试和文档覆盖。
Zig runtime 公契面见 [`docs/zh/runtime-api.md`](./runtime-api.md)。

## 已完成阶段（P1–P9）

| 阶段 | 状态 | 一句话摘要 | Changelog 引用 |
|---|---|---|---|
| P1 | ✅ | MVP OCaml 子集到 Solana BPF：`omlz` 骨架、OCaml frontend bridge、Core IR、解释器、native 构建路径，以及 BPF `.so` 构建路径。 | [`[P1]`](../../CHANGELOG.md#p1-mvp-ocaml-subset-to-solana-bpf---2026-04-28) |
| P2 | ✅ | 子集扩展与 match 优化：用户 ADT、嵌套/guarded pattern、tuple、record、stdlib 扩展，以及加固后的 BPF closure。 | [`[P2]`](../../CHANGELOG.md#p2-subset-expansion-and-match-optimization---2026-04-29) |
| P3 | ✅ | Solana 形态子集：零拷贝 account 视图、syscall、CPI helper、SPL-Token 支持、`omlz check --no-alloc` 与 IDL 输出。 | [`[P3]`](../../CHANGELOG.md#p3-solana-shaped-subset---2026-04-29) |
| P4 | ✅ | Mollusk 验收与 instruction data：交易输入 dispatch、进程内 SVM 测试，以及 Pubkey helper 的易用性改进。 | [`[P4]`](../../CHANGELOG.md#p4-mollusk-acceptance-and-instruction-data---2026-04-30) |
| P5 | ✅ | 生态接入：类型化 `external` 声明、Zig runtime 绑定、Anchor 兼容 IDL、Map/Set 与 crypto wrapper。 | [`[P5]`](../../CHANGELOG.md#p5-ecosystem-reach---2026-04-30) |
| P6 | ✅ | Region inference：逃逸分析、符合条件局部值的 stack-region codegen，以及 region allocation 示例。 | [`[P6]`](../../CHANGELOG.md#p6-region-inference---2026-04-30) |
| P7 | ✅ | OCaml 子集扩展：更多 surface desugar、更丰富的 pattern、string/char 支持，以及更宽的 stdlib 工具面。 | [`[P7]`](../../CHANGELOG.md#p7-ocaml-subset-expansion---2026-04-30) |
| P8 | ✅ | 编译器优化：常量折叠、死代码删除、自递归尾调用优化、函数内联，以及 mutual recursion groups。 | [`[P8]`](../../CHANGELOG.md#p8-compiler-optimizations---2026-05-01) |
| P9 | ✅ sealed | 开发者体验：rustc-style diagnostics、wire `1.2` location plumbing、`omlz-lsp`，以及带 `omlz unmap` 的确定性 source maps。 | [`[P9 Developer Experience]`](../../CHANGELOG.md#p9-developer-experience---2026-05-05) |

阶段在这里不是按时间盒划分，而是按范围划定。只有当对应的 changelog section 已经存在，一个阶段才会进入这张已完成表。

### P9 — 开发者体验 ✅ sealed

P9 已作为一轮产品级开发者体验改进封存，包含四个 milestone：

- **DX1 — rustc-style diagnostics：** human diagnostics 现在带源码片段和 caret span，同时提供 `--error-format=human|json|oneline`，分别服务终端、工具和 CI。
- **DX2 — wire 1.2 location plumbing：** frontend sexp 与 Core IR 保留 OCaml 位置，让 no_alloc、region 和 subset 错误能回指原始 `.ml` span。
- **LSP — `omlz-lsp`：** stdio language server 使用 LSP JSON-RPC，为编辑器客户端推送 diagnostics。
- **SRCMAP — source maps：** BPF 构建会生成确定性的 `.map` sidecar，嵌入 `.zxcaml.srcmap`，并通过 `omlz unmap` 把 program counter 映射回 OCaml 源位置。

## Hackathon 工作（P8 之后）

- 已冻结的 hackathon package 由 [`docs/hackathon/README.md`](../hackathon/README.md) 建索引：timeline、双语 demo scripts、shot list、Colosseum submission copy、Anchor comparison artifacts、Slidev recording checklist，以及相关 demo script 链接。
- 一键复现入口是从仓库根目录运行 `make demo`；同一个 hackathon 索引也指向 `make demo-clean` 以及 `scripts/demo/` 下的组件脚本。
- 当前 demo 叙事的公开落地页是 [`https://zxcaml.pages.dev/`](https://zxcaml.pages.dev/)。它呈现 P1-P9 的编译器状态和 P8 之后的 hackathon 资产，但不会把 demo 包装成新的编译器阶段。

## Phase 19–21 收尾 ledger

Phase 19、Phase 20 与 Phase 21 的运营/文档收尾工作已经封存。它们没有重新打开
P1-P9 的编译器范围；主要任务是加固 formatter 覆盖、刷新 Factory wiki，并关闭
fmt corpus 扩张暴露出的 lex-wart 债务。

| Milestone | 状态 | Seal marker / tag | 完成时间 | 说明 |
|---|---|---|---|---|
| M-WIKI-2 | ✅ sealed | `post-lspfix3-baseline` + Factory wiki run [`a114e5ee`](https://app.factory.ai/wiki/a114e5ee-acef-458a-bcb7-91c1f95c1c7a) | 2026-05-07 | 把云端 wiki 刷新到 Phase 18 / M-LSPFIX-3 baseline。 |
| M-FMT-3 | ✅ sealed | `post-fmt3-baseline` | 2026-05-07 | 在保持 formatter 源码锁定的前提下，把 `omlz fmt` corpus 扩到 20 个 golden 轨道。 |
| M-LSPFIX-3 | ✅ sealed | `post-lspfix3-baseline` | 2026-05-07 | 移除了旧的 Python latency assertion 路径，并恢复严格并行 no-regress 验证。 |
| M-FMT-FIXES | ✅ sealed | `post-fmt-fixes-baseline` | 2026-05-08 | 修复 polymorphic type-variable、labelled/optional argument 和 PPX-local formatter lex wart。 |
| M-WIKI-3 | ✅ sealed | `post-fmt-fixes-baseline` + Factory wiki run [`52ce54d4`](https://app.factory.ai/wiki/52ce54d4-145a-4bc1-b530-bd947c501564) | 2026-05-07 | 把云端 wiki 刷新到 Phase 19 + Phase 20 内容。 |
| M-FMT-DEEPNESTED | ✅ sealed | `post-fmt-deepnested-baseline` | 2026-05-08 | 落地通用 `) word` spacing 规则，并重新捕获唯一 `deeply_nested` golden 变化。 |

### 已关闭的技术债

- **TD-FMT-LEX-WARTS — ✅ closed/resolved** 于 `post-fmt-fixes-baseline`
  （2026-05-08）关闭。Phase 19 formatter scout 发现的四个 lex-level wart
  已全部修复并体现在 fmt golden corpus 中；Phase 21 的
  `post-fmt-deepnested-baseline` 又封存了最终的通用 `) word` spacing 跟进。

## R-series 产品打磨 ledger

| Slice | 状态 | 完成时间 | 说明 |
|---|---|---:|---|
| R11 — Fixed-point math surface | ✅ sealed | 2026-05-15 | 加入 deterministic `Fixed` / `Amount` helper、`fixed_amm_quote`、测试和双语文档。 |
| R12 — Mutable state hardening | ✅ sealed | 2026-05-15 | 通过 stress coverage 加固解释器/native/BPF 上的 `int array`、`for` / `while`、`int` / `bool` ref。 |
| R13 — Solana account guard polish | ✅ sealed | 2026-05-15 | 加入 `Account` guard/read helper、`account_guard`、Mollusk 覆盖、IDL metadata/error 输出、UI 误用诊断和双语文档。 |
| R14 — IDL error metadata polish | ✅ sealed | 2026-05-15 | 为 `error_` 常量加入派生的人类可读 `msg` 字段，并刷新 IDL/文档覆盖。 |

## 未来 / 可选

下面的内容保留给已封存 P1-P9 编译器范围之外、也不属于 P8 之后 hackathon/demo 工作的可选方向。

### 文档 / 流程卫生（当前维护面）

- 双语文档同步与 drift prevention 已纳入常规维护面。
- `./scripts/check_docs_sync.sh` 是强制验证器；English/中文路由、Surfpool 术语和路径事实漂移都视为 blocker。
- 这类工作属于流程卫生，不重新打开已封存的 P1-P9 编译器范围。

### 下一优先级：Solana DX/API polish 规划

- 在重新打开更大范围的 runtime/compiler 工作之前，下一步明确优先级是
  [`20-solana-dx-api-polish-plan.md`](./20-solana-dx-api-polish-plan.md) 这份
  **planning-only 的 Solana DX/API polish scaffold**。
- 这份计划聚焦 entrypoint ergonomics、account/meta helper naming、
  syscall/CPI/PDA 示例、SDK-backed import discoverability、Surfpool UX，
  以及 diagnostics/docs 示例。
- 它也明确排除了新的 compiler phase、多链排期和 runtime rewrite，避免范围
  蔓延成不受控的大功能。

### BPF 工具链迁移（可选）

- 当前处于默认直连状态：`SOLANA_ZIG` 未设置/空（或 `1`）时走直接 `solana-zig`，这是当前正式路径。
- `sbpf-linker` 不再是默认要求；仅保留其历史兼容说明。
- 当前阶段只做迁移对齐（文档/测试/CI），不做默认策略的重大声明改动。

### 语言子集差距提案

- ADR-015 已部分落地，并且现在有 R12 stress coverage 覆盖受控 `int` array、`for` / `while` loop，以及 `int` / `bool` ref；动态/泛型 array、更宽 ref 类型和跨函数/闭包 aliasing 仍是后续项。ADR-017 的 deterministic-number 方向现在已有初版六位小数 `Fixed` / `Amount` stdlib surface；更完整 fixed-point/decimal 设计仍是未来工作。R13 已作为 Solana account-guard polish slice 封存。ADR-016（多文件模块，前端 `open Foo`）仍保留为提案。

### PX — 多目标扩展（可选，有门槛）

**状态：** 未排期。不在关键路径上。本阶段存在的唯一目的，是给“那其它目标呢？”这个问题一个明确形态，避免它渗透到更早阶段。

#### 上下文

因为 Zig backend 发出的是 `.zig` 源码，Zig 工具链原则上可以 lower 到它支持的任何目标（`aarch64`、`x86_64`、`riscv*`、`wasm32`、`nvptx*`、`amdgcn` 等；长列表和配套冷水见 `06-bpf-target.md` §10）。

这**不**等于那些目标已经被支持。PX 的角色，是把某个目标从“工具链技术上能到达”推进到“ZxCaml 正式支持它”。

#### 激活门槛

PX 只在某个具体目标**同时满足**下面四条时激活：

1. **存在具体用例**，并且该用例被写下来，至少有一位 champion 会实际使用产出。
2. **存在 owner**，负责该目标的 runtime shim 工作（entrypoint、panic、内存方案、到用户代码的 calling convention）。
3. **BPF 形态的语言约束适合该用例**；或者有人以新 ADR 的形式提出放宽约束（例如“WASM 目标可以使用宿主 allocator，而不是单一 arena”）。
4. **同一次变更加入 CI lane 和验收 example。**

四条缺一不可。缺任何一条，目标都留在门外。投机式多目标支持是泄漏，不是功能。

#### 可能候选（仅举例，未承诺）

- **`wasm32-freestanding`** —— 用于浏览器内 Solana 程序模拟器。门槛：用户是谁？什么工具会消费这个输出？
- **`x86_64-linux`** —— 给希望获得 native 速度和 crash dump 的 fuzzing / property testing harness。门槛：真实存在的 fuzzing harness，而不是“有的话挺好”。
- **`riscv64-linux` / embedded BPF（Linux kernel eBPF）** —— 不属于 Solana BPF flavor，但相邻。门槛：有人需要交付一个具体 eBPF 程序。

#### 注意：x86 / arm native **不是** PX 候选

如果你的目标是“我想在 x86 / arm 上运行 ZxCaml 程序做本地测试或 fuzzing”，你**不需要** PX。因为每个 ZxCaml 程序按构造都是合法 OCaml 程序（ADR-001），而开发者机器为了 `omlz` 的 frontend bridge（ADR-010）已经装有 OCaml 工具链。直接用 `ocaml`（或 OxCaml）编译同一份 `.ml` 并运行即可。完整讨论见 README 的 “Native execution comes for free” 一节，以及 `docs/oxcaml-relationship.md`。

PX 留给那些不适用上述技巧的目标：也就是今天上游 OCaml 和 `omlz` 都不会产出可运行二进制，而又有人有具体理由让 `omlz` 产出一个的场景。

#### PX **不是** 什么

- 不是“支持所有 Zig 目标”。工具链覆盖广度并不等于 ZxCaml 支持广度。
- 不是“把语言变成通用语言”。除非 ADR 明确按目标放宽，否则 BPF 形态约束（无 GC、无 syscall、无线程、无异常）继续成立。
- 不是已封存 P1-P9 交付集合的一部分。它被刻意放在主编号阶段之后，并且自身也是可选项。

#### 与既有阶段的关系

PX **不阻塞任何更早阶段**。P1-P9 已经以 BPF 作为唯一验证目标封存。PX 的意义是：当真正的第二个目标出现时，它通过定义好的流程进入项目，而不是自然生长、逐步模糊项目焦点。

### 自举（原 P6，可选）

- 用我们的子集重写 `src/core/anf.zig` 和 `src/core/pretty.zig`。
- 让重写后的代码穿过 `omlz`，并把产出的 object 链回编译器自身。
- 这是 dogfooding 门槛；项目不需要通过它才能交付。

### 形式化（原 P7，可选）

- Core IR 的小步语义（论文或 Lean / Coq）。
- 给 LLM / verifier 消费的 Core IR 表面（S-expression serialisation？确定性 JSON？）。
- 属性测试：Core IR 与 Lowered IR 之间的 refinement。

### 反目标（全部属于未来工作）

- 我们绝不在编译产物中接受 OCaml C runtime。
- 我们绝不采纳需要 GC 的特性。
- 我们绝不 fork OCaml 编译器（ADR-009）。
- 我们绝不悄悄漂出 OCaml 子集；ADR-010 让漂移在结构上不可能，因为上游编译器就是 parser/type-checker。
- 我们**不**依赖 OCaml 发行版自带 `compiler-libs.common` 之外的 `opam` 包。frontend bridge 的第三方 `opam` 依赖数量是零。
