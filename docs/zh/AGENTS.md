# AGENTS.md — ZxCaml 的 Agent 指南

> **Languages / 语言**: [English](../../AGENTS.md) · **简体中文**

这是编码 Agent（Claude Code、Codex、Cursor 等）的入口文档。
它负责路由到权威文档，而不是复制其内容——当本文件与所链接的文档冲突时，
以链接的文档为准。

## 这是什么项目

ZxCaml 是一个带有 **Zig/BPF 后端**的 **OCaml 方言**。我们不 fork、不重写
OCaml：解析与类型检查由上游 `compiler-libs` 完成，Typedtree 之后的一切由
我们负责。主要目标是 Solana BPF/SBF；原生二进制以及实验性的 WASM/NEAR
目标共享同一条管线。CLI 二进制名为 `omlz`。

一行版管线：

`.ml` → `ocamlc -bin-annot`（`.cmt`）→ `zxc-frontend`（sexp wire `1.5`）→
`omlz`（ANF Core IR → 常量折叠/DCE/内联 → region 推断 + arena 降级 →
Zig codegen | 树遍历解释器）→ `solana-zig build-lib` → `.so`

## 构建与测试命令

以下就是 CI 运行的命令。测试与脚本都假定 **cwd 为仓库根目录**
（契约：[docs/07-repo-layout.md](./07-repo-layout.md)）。

```sh
./init.sh
zig build
zig build test --summary none
cargo test --manifest-path tests/Cargo.toml
./scripts/check_examples_corpus.sh
./scripts/check_docs_sync.sh
zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```

- `./init.sh` — 工具链安装（Zig 0.16.0、opam 安装的 OCaml 5.2.x、Rust，
  可选 solana-zig）。与 CI 使用同一脚本。
- `zig build test` — 单元测试、golden Core-IR 快照、UI/诊断测试、
  确定性属性测试（解释器 ≡ 原生）、格式化器 golden、LSP 与 CLI 测试。
- `cargo test --manifest-path tests/Cargo.toml` — Mollusk SVM 集成测试；
  依赖 `zig build test` 产出的 `.so` 工件。
- 最后一行是 BPF 冒烟测试；需要 `PATH` 中有 `solana-zig`
  （或设置 `SOLANA_ZIG`，见下文"坑点"）。
- Surfpool 验收（按需开启，需要本地 validator）：
  `SOLANA_BPF=1 SOLANA_RPC_PORT=8899 tests/solana/hello/invoke.sh`

## 管线地图

| 阶段 | 位置 |
|---|---|
| OCaml 前端胶水（子集检查、sexp 输出） | `src/frontend/`（OCaml） |
| Sexp wire 解析器 + Typedtree 镜像 | `src/frontend_bridge/` |
| ANF Core IR 与优化（`const_fold`、`dce`、`inline`、`static_report`、`no_alloc`） | `src/core/` |
| Region 推断 + arena 降级（LIR） | `src/lower/` |
| Zig codegen / 树遍历解释器 | `src/backend/` |
| 构建编排（前端子进程、BPF/WASM/NEAR 驱动、IDL、source map、doctor） | `src/driver/` |
| CLI 子命令实现 | `src/omlz/` |
| LSP 服务器（`omlz-lsp`） | `src/lsp/` |
| 目标注册表 / 能力矩阵 / 预检 | `src/target/` |
| 诊断类型 + 渲染 | `src/util/` |
| 运行时（arena、Solana 系统调用、CPI、SPL 适配器） | `runtime/zig/` |
| 内置 OCaml stdlib 表面 | `stdlib/` |
| Vendored Solana SDK（**禁止编辑**） | `vendor/solana-program-sdk-zig/` |
| 示例程序 + 清单 | `examples/` |
| Zig/Rust/LSP/golden/验收测试 | `tests/` |
| 仅存放生成产物（可安全删除） | `out/`、`zig-out/` |

## 不变量——绝不可破坏

- **确定性**：对每个示例，解释器输出 ≡ 原生 codegen 输出。由
  `zig build test` 中的属性测试强制。（ADR-008）
- **每个 ZxCaml 程序都是合法 OCaml**：我们接受严格子集；绝不添加上游
  OCaml 会拒绝的语法。（ADR-001）
- **Arena-only 内存**：无 GC、无 free；原生入口 arena 32 KiB，BPF 上
  3 KiB。见 [docs/04-memory-model.md](./04-memory-model.md)。
- **Wire 格式版本化**（当前 `1.5`）：前端↔Zig 的 sexp 格式变更必须遵循
  [docs/wire-compat.md](./wire-compat.md)（增量式升版、留有文档）。
- **双语文档门禁**：`./scripts/check_docs_sync.sh` 强制中英文配对。任何
  **新增的 `docs/*.md` 必须在该脚本中归类**（mirrored/basic/routed/
  historical）并提供 `docs/zh/` 对应文件，否则 CI 失败。根目录的 Agent
  文件也在其中注册。
- **示例清单**：`examples/` 由 `examples/ml-layout-manifest.tsv` 锁定；
  增删 `.ml` 文件必须同步更新清单（`./scripts/check_examples_corpus.sh`
  把关），README/路线图中的示例计数会对照文件系统校验。
- **已封板的阶段**：P1–P9 与 [docs/08-roadmap.md](./08-roadmap.md) 中的
  R-slice 已经关闭。不要重开已封板的范围；新工作要有自己的计划文档
  （模式参照：[docs/20-solana-dx-api-polish-plan.md](./20-solana-dx-api-polish-plan.md)）。

## 坑点（Gotchas）

- **`SOLANA_ZIG`**：未设置/空/`"1"` → 从 `PATH` 查找 `solana-zig`；其他
  值按命令/路径原样使用；`"0"` 会被拒绝。
- **`SOLANA_BPF=1`** 控制本地 validator 验收测试的开关；未设置则跳过
  （CI 按需开启，macOS runner 上不跑）。
- **`llvm-objcopy` 是可选的**：缺失时跳过 `.zxcaml.srcmap` 嵌入
  （sidecar `.map` 仍然可用）。会探测 Homebrew LLVM 与标准路径。
- **Zig 0.16 API**：本代码库使用 `std.Io` 时代的 API。不要套用 0.15
  之前的模式（旧 ArrayList 初始化、旧 Writer 等）。
- **CHANGELOG** 遵循 Keep-a-Changelog，按 slice 分节；只记录用户可见的
  变更。
- **`mission-internal/`** 存放内部工作笔记（侦察报告、审计、待办）——
  不是用户指南，不受文档门禁扫描。
- 生成的 Zig/运行时工件位于 `out/` 下；绝不手工编辑。

## 文档路由表

| 需求 | 阅读 |
|---|---|
| 目录契约与归属 | [docs/07-repo-layout.md](./07-repo-layout.md) |
| 架构与 IR 分层 | [docs/01-architecture.md](./01-architecture.md) |
| 接受的 OCaml 子集 | [docs/02-grammar.md](./02-grammar.md) |
| Core IR（ANF）契约 | [docs/03-core-ir.md](./03-core-ir.md) |
| 内存模型（arena/region） | [docs/04-memory-model.md](./04-memory-model.md) |
| 后端（codegen、解释器） | [docs/05-backends.md](./05-backends.md) |
| Solana BPF 目标与工具链 | [docs/06-bpf-target.md](./06-bpf-target.md) |
| 状态与路线图 | [docs/08-roadmap.md](./08-roadmap.md) |
| ADR 索引（已锁定决策） | [docs/09-decisions.md](./09-decisions.md) |
| 前端桥与 wire 格式 | [docs/10-frontend-bridge.md](./10-frontend-bridge.md)、[docs/wire-compat.md](./wire-compat.md) |
| Solana 账户/CPI/SPL/no_alloc/IDL | [docs/11-solana-p3.md](./11-solana-p3.md) |
| 公共运行时 API 表面 | [docs/runtime-api.md](./runtime-api.md) |
| `omlz test`（属性测试） | [docs/13-omlz-test.md](./13-omlz-test.md) |
| 诊断格式 | [docs/diagnostics.md](./diagnostics.md) |
| LSP 服务器与编辑器配置 | [docs/lsp.md](./lsp.md) |
| Source map 与 `omlz unmap` | [docs/source-map.md](./source-map.md) |
| 工具链安装与排障 | [INSTALLING.md](./INSTALLING.md) |
