# 20 — Solana DX/API polish 规划

> **Languages / 语言**: [English](../20-solana-dx-api-polish-plan.md) · **简体中文**

> **状态：** 仅限规划的下一优先级脚手架。本文档**不会**直接实现新的
> runtime、compiler 或 SDK 行为。

在仓库结构整理和双语文档同步完成之后，下一步有意识的产品规划动作是一个
**面向 Solana 的 DX/API polish** slice。这份计划刻意保持狭义：它固定当前
编译器/runtime 事实，只为后续小范围功能准备方向，让现有 Solana surface
更容易使用、验证和维护。

## 范围与非目标

- 范围只限于当前 Solana 路径上的**开发者体验与公开 API 打磨**。
- 规划继续锚定现有 **SDK-backed** runtime surface，以及直连
  `SOLANA_ZIG` / `solana-zig build-lib` 的 BPF 流程。
- 本计划**不是**新 compiler phase、runtime rewrite、多链交付、内存模型改造，
  也不是一个宽泛的大功能打包入口。
- P1-P9 与 R11-R14 等已封存工作继续保持关闭；除非未来 feature 以明确边界
  重新打开某个狭义 Solana-facing slice。

## 后续工作必须继承的规范前提

- **BPF 构建模式：** 保持 [`06-bpf-target.md`](./06-bpf-target.md) 中描述的当前
  直连 `SOLANA_ZIG` / `solana-zig build-lib` 路径。
- **Runtime surface：** 把 [`runtime-api.md`](./runtime-api.md) 视为公开 Zig
  runtime 兼容面。
- **Solana 语义与示例：** 继承 [`11-solana-p3.md`](./11-solana-p3.md) 中当前的
  account/syscall/CPI/SPL 指导。
- **路线图状态：** 继续以 [`08-roadmap.md`](./08-roadmap.md) 作为规范记录：
  P1-P9 已封存，而这轮 DX/API 工作是下一优先级。
- **文档对齐：** 英文和中文文档必须同步更新，并持续通过
  [`./scripts/check_docs_sync.sh`](../../scripts/check_docs_sync.sh)。
- **本地 Solana 验证：** 只使用 `127.0.0.1:8899` / `127.0.0.1:8900` 上的
  **Surfpool**；不要把旧的 `solana-test-validator` 流程重新写回当前有效指导。

## 未来实现 slice 的聚焦方向

| 方向 | DX/API 打磨目标 | 未来可能产物 |
|---|---|---|
| Entrypoint ergonomics | 在不改动当前 ABI 的前提下，让 SDK-backed entrypoint 预期更容易理解和使用。 | 小范围 helper 清理、更清晰的 docs snippet、定向 harness fixture。 |
| Account / meta helpers | 对齐 `Account.*`、`account` 与 `account_meta` 的命名/示例，让常见 authority/writable 流程更易发现。 | 聚焦的命名/文档整理，加上定向 examples/tests。 |
| Syscall / CPI / PDA helpers | 降低 syscall、CPI、PDA seeds 与 return-data helper 的命名、示例覆盖和调用形态理解成本。 | 示例刷新与定向 helper 验证。 |
| SDK-backed imports | 让 Solana-facing surface 的规范 import root 与 generated shim 预期对贡献者更直观。 | 指向稳定 import root 的文档/示例。 |
| Surfpool UX | 改善本地 build/deploy/invoke 循环，让失败更快定位到命令、路径或 account fixture。 | 带范围约束的 harness/文档整理。 |
| Diagnostics 与文档示例 | 为常见 Solana entrypoint/account/helper 误用补充更清晰的报错示例和整理后的 snippet。 | 绑定单一狭义 surface 的 UI/example/docs 补充。 |

上表所有内容目前都仍然只是**规划**；只有未来独立实现 feature 携带各自范围与
验证证据落地后，才算真正进入实现。

## 未来实现必须满足的验收门槛

1. **文档对齐门槛：** 英文与中文文档必须同步更新、互链保持正确，并通过
   `./scripts/check_docs_sync.sh`。
2. **定向 examples/tests 门槛：** 每个 slice 都必须为自己改动的那一小块
   Solana-facing surface 增补或更新聚焦的 example、UI test、Zig test，
   或 Mollusk/Surfpool fixture。
3. **Surfpool 验证门槛：** 本地 Solana 验证必须继续走现有 Surfpool harness，
   使用 `127.0.0.1:8899` / `127.0.0.1:8900`。
4. **无回归门槛：** 后续 slice 必须保持现有验证底线为绿：

   ```sh
   zig build
   zig build test --summary none
   cargo test --manifest-path tests/Cargo.toml
   ./scripts/check_examples_corpus.sh
   ./scripts/check_docs_sync.sh
   ```

5. **规范链接门槛：** 路线图与计划中的链接必须继续指向当前 BPF build 文档、
   Solana 指南、runtime API 文档，以及 DX 路线图条目。

## 明确的防止范围蔓延约束

- **不要**把这份计划变成新 compiler phase 的总 backlog。
- **不要**借它去安排探索性的
  [函数式多链路线图](./19-functional-multichain-roadmap.md)。
- **不要**把它理解成 runtime rewrite、allocator 变更，或修改
  `vendor/solana-program-sdk-zig/` 的许可。
- **不要**切换当前有效的本地节点故事；Surfpool 仍然是唯一活动路径。

任何声称承接这份计划的未来工作，都必须证明自己直接改善了 **Solana 开发者体验
或 API 易用性**，并且严格落在上面的门槛之内。
