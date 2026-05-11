# 08 — 路线图

> **Languages / 语言**: [English](../08-roadmap.md) · **简体中文**

这份路线图现在把已经封存的编译器阶段、演示/运营工作，以及未来可选方向分开说明。面向用户文档的当前规范事实是：frontend bridge 接受 sexp wire 格式 `1.2`，examples 语料包含 60 个 `.ml` 程序，Mollusk SVM 套件包含 27 个集成测试，并且 P1-P9 都已经在 [`CHANGELOG.md`](../../CHANGELOG.md) 中封存。
Real-world Examples Batch 3 补齐了 `spl_burn`、`spl_close_account` 和 `spl_revoke` 这三个 SPL Token primitive 示例。
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

## 未来 / 可选

下面的内容保留给已封存 P1-P9 编译器范围之外、也不属于 P8 之后 hackathon/demo 工作的可选方向。

### BPF 工具链迁移（可选）

- 将 `sbpf-linker` 作为 legacy 兜底保留，但优先推进 `SOLANA_ZIG` 一步直连路径。
- 在 Linux 及 macOS 上都达到同等级 CI/验收验证后，逐步把直连路径提升为默认行为，并下调 legacy 依赖要求。

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
