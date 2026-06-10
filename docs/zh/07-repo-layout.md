# 07 — 仓库布局

> **Languages / 语言**: [English](../07-repo-layout.md) · **简体中文**

这份文档记录的是 CLI/build 拆分、runtime 布局归一化，以及 examples/tests
重组之后的**当前**仓库契约。历史上的旧路径草图仍保留在 git 历史中，但下面这些路径
才是文档、验证器和 generated-code shim 应视为 canonical 的表面。

## 1. 顶层

```text
ZxCaml/
├── README.md / INSTALLING.md       -- 用户入口文档
├── build.zig / build.zig.zon       -- 单一 Zig build driver 与依赖 pin
├── src/                            -- 编译器、CLI、LSP、frontend bridge
├── runtime/zig/                    -- runtime core、Solana support、SDK adapter、program port
├── stdlib/                         -- bundled OCaml stdlib surface
├── examples/                       -- 用户 `.ml` 示例，以及 `examples/tests/` 的 OCaml-native 测试语料
├── tests/                          -- Zig、Rust/Mollusk、LSP、UI、golden、Surfpool harness 验证
├── scripts/                        -- validator、artifact 检查、demo 自动化
├── docs/                           -- 英文文档
├── docs/zh/                        -- 中文文档与 routed counterpart
├── vendor/                         -- vendored 依赖（包括 `solana-program-sdk-zig`）
├── out/                            -- 生成的 Zig/runtime/source-map 产物
└── .github/workflows/              -- CI 入口
```

### 1.1 单一 OCaml ↔ Zig 接缝

仓库仍只有一道跨语言边界：

- `src/frontend/` —— OCaml `compiler-libs` 胶水（`zxc-frontend`）
- `src/frontend_bridge/` —— Zig 侧 wire parser / Typedtree mirror

这条接缝之上是面向 upstream OCaml 的前端工作；接缝之下是 Zig 负责的 lowering、
runtime、build orchestration 和 developer tooling。

## 2. `src/` —— 编译器、CLI、LSP

```text
src/
├── main.zig              -- 顶层 `omlz` 入口与命令接线
├── build_lock.zig        -- build 输出协调 / 串行化 helper
├── frontend/             -- OCaml bridge、formatter frontend、wire emitter
├── frontend_bridge/      -- sexp lexer/parser + Typedtree mirror
├── core/                 -- Core IR、ANF lowering、pretty-printer
├── lower/                -- Lowered IR + lowering strategy
├── backend/              -- interpreter + Zig codegen
├── driver/               -- build/run/BPF/source-map orchestration
├── omlz/                 -- CLI 子命令实现族
├── lsp/                  -- `omlz-lsp` 实现
└── util/                 -- 共享编译器工具
```

重要边界：

- `src/main.zig` 是稳定的 CLI executable root。
- `src/omlz/` 拥有子命令行为；公共命令名和 help surface 需要保持稳定。
- `src/driver/` 拥有 build/native/BPF/source-map orchestration。
- `src/lsp/` 拥有 stdio JSON-RPC server 与 benchmark helper。

## 3. `runtime/zig/` —— runtime core、Solana support、adapter、port

```text
runtime/zig/
├── arena.zig / panic.zig / prelude.zig / core.zig
├── account.zig / cpi.zig / syscalls.zig / sysvar.zig / spl_token.zig / bs58.zig
├── bpf_entry.zig / native_entry.zig / entry_context.zig
├── sdk/                  -- SDK-backed adapter root 与 import-smoke surface
├── programs/             -- 面向 Solana fixture/example 的 program-port helper
├── root.zig / shims.zig / solana.zig
└── *_tests.zig / import_matrix.zig / host runner
```

职责刻意拆开：

- **runtime core：** arena、panic、prelude、entry shim
- **Solana support：** accounts、syscalls、sysvars、CPI、SPL Token、Bs58
- **SDK adapter：** `runtime/zig/sdk/**` 把 runtime / generated import 对接到
  vendored `solana-program-sdk-zig` 表面
- **program port：** `runtime/zig/programs/**` 存放示例/fixture 使用的 helper entrypoint

生成产物会从这棵树复制或 embed 内容；public/generated import path 必须保持稳定，
或与所有消费者一起原子更新。

## 4. `stdlib/`

`stdlib/core.ml` 与 `stdlib/generators.ml` 仍是 canonical 的 bundled OCaml
surface。它们必须同时满足：

- 能被 `zxc-frontend` 使用的上游 OCaml 工具链接受；
- 能被 `omlz` 当前子集接受。

`stdlib/` 只承载表层代码，不直接 import Zig runtime 文件。

## 5. `examples/`

```text
examples/
├── README.md             -- 示例目录索引 / 分类
├── *.ml                  -- 95 个用户可见示例与 fixture 程序
├── tests/                -- `omlz test` 默认发现根
└── ml-layout-manifest.tsv
```

当前示例族包括：

- core subset / stdlib smoke 示例
- Solana account / syscall / sysvar / CPI / SPL / ATA / vault / DAO 流程
- diagnostics / formatting / mutable-state / fixed-point demo
- hackathon 与 comparison fixture

`examples/tests/*.ml` 是 `omlz test` 的默认 OCaml-native 语料。
故意失败的诊断 fixture 仍是 `examples/m0_unsupported.ml`，在 pass-only corpus
loop 中应继续排除。

多文件程序（ADR-016）= 一个入口 `.ml` 加同目录的依赖文件——顶层 `open Foo`
解析为入口文件旁边的 `foo.ml`。canonical 样例是 `examples/multifile_*` 三件套。

## 6. `tests/`

```text
tests/
├── Cargo.toml / *_test.rs         -- Rust/Mollusk 集成测试套件
├── bpf_test_support.rs            -- 共享 Rust BPF build/load helper
├── equivalence_test_support.rs    -- 共享 interpreter/native 等价性 helper
├── cli/ / lsp/ / golden/ / ui/    -- Zig 与 tooling 定向验证资产
├── idl/ / inline/ / property/     -- 聚焦型编译器/runtime 套件
└── solana/                        -- Surfpool-backed deploy/invoke harness
```

关键契约：

- `tests/Cargo.toml` 是稳定的 Rust 入口。
- `tests/solana/**` 是稳定的 Surfpool/localnet harness surface。
- `tests/ui/**`、`tests/golden/**`、`tests/lsp/**` 都是 baseline 资产；移动时必须与 harness 一起同改。

## 7. `scripts/`

`scripts/` 是公共自动化表面，不只是实现细节。重要入口包括：

- `check_examples_corpus.sh`
- `check_examples_layout.py`
- `check_docs_sync.sh`
- `characterize_build_artifacts.sh`
- `check_no_obsolete_runtime_surfaces.sh`
- `check_vendored_sdk_paths.sh`
- `check_vendored_sdk_secrets.sh`
- `demo/**`

这些命令被 `services.yaml`、CI、文档和 mission validator 引用，因此 repo-root
调用行为必须稳定。

## 8. 文档、demo 与生成产物

- `docs/` 与 `docs/zh/` 是 current-state 文档表面；active guidance 必须维持双语路由。
- `scripts/demo/**` 是 canonical 的 hackathon/demo 自动化表面。
- `demo.sh` 是 repo-root 轻量 demo wrapper。
- `out/` 是 emitted Zig、runtime copy、source map 等生成产物的规范落点。

## 9. 约定

- **Surfpool 是唯一活跃的本地 Solana backend。** 当前文档和 harness 不应再把任何旧 validator 工作流当作 live path。
- **Vendor 路径是输入，不是重构目标。** 正常仓库整理工作不应编辑 `vendor/solana-program-sdk-zig/**`。
- **保持 repo-root 命令稳定。** `zig build`、`cargo test --manifest-path tests/Cargo.toml`、`./scripts/check_examples_corpus.sh`、`./scripts/check_docs_sync.sh` 都是兼容面。
- **生成代码留在 `out/`。** 除非显式 regeneration flow 需要，否则 emitted artifact 不应溢出到 `src/`、`runtime/zig/` 或示例/测试 fixture 目录。
