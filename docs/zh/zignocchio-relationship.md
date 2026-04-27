# ZxCaml ↔ zignocchio 关系

> **Languages / 语言**: [English](../zignocchio-relationship.md) · **简体中文**
>
> **状态：** 已采纳 · **日期：** 2026-04-27
> **关联：** ADR-014（"不导入"的正式决策）、
> ADR-012（`sbpf-linker`）、ADR-013（SBPF 版本 pin：默认 v2，v3 可选）、
> `06-bpf-target.md` §2（工具链链路）。

---

## 总结

`zignocchio`（`github.com/DaviRain-Su/zignocchio`，
fork 自 `vitorpy/zignocchio`）是一个能跑通的
**Zig → Solana SBF** SDK。它证明了我们计划用的工具链可以产出
Solana 能加载的程序，并且让我们意识到几条文档里写错了或没写的事。

ZxCaml **不**导入它的代码。我们对它的姿态与 ADR-009 对 OxCaml
完全一致：自由阅读，自己写。

```
                          ┌────────────────────────────────────┐
                          │  zignocchio                        │
                          │  Solana 开发者用的手写 Zig SDK     │
                          └─────────────┬──────────────────────┘
                                        │ 仅作为灵感
                                        │（不复制代码、不加 submodule）
                                        ▼
   .ml ──── omlz ────► .zig ──── zig+sbpf-linker ──── program.so
            （本仓库）              （工具链由 zignocchio 验证）
```

---

## 1. 为什么需要这份文档

最初写 `06-bpf-target.md` 时，我们假设
`zig build-obj -target bpfel-freestanding` 就能直接产出
Solana 可加载的 `.o`。这只是规划期的近似，不是验证过的事实。

zignocchio 是这条 **真实** 工具链与上面那个假设不同的公开证据。
把这件事单独钉在一份文档里 —— 与 ADR 分开 —— 让以后的贡献者
既能看到 "what"（ADR），也能看到 "why we know this"（这份），
而不必去翻 git history。

---

## 2. zignocchio 是什么

- 一个用 Zig 写的 Solana 程序 SDK。
- 最初来自 `vitorpy/zignocchio`；我们引用的是
  `DaviRain-Su/zignocchio` fork（目前比 upstream 多 11 个 commits），
  因为这是我们读的版本。
- 提供：
  - 构建管线（`build.zig`），出 LLVM bitcode + 调 `sbpf-linker`。
  - `sdk/entrypoint.zig` —— Solana ABI v1 输入缓冲反序列化器。
  - `sdk/allocator.zig` —— 程序静态 heap 区上的 bump allocator。
  - `sdk/syscalls.zig` —— syscall 绑定，用 syscall 名字的
    MurmurHash3-32 做 dispatch。
  - `sdk/account_info.zig` —— `AccountInfo` 的零拷贝视图。
  - PDA / CPI / log helper。
  - 测试集成：`litesvm`、`surfpool`、`mollusk`。
  - 一个 TypeScript 客户端。

简言之，它就是"今天怎么用 Zig 写 Solana 程序"的完整答案。

ZxCaml 的工作不是这个：我们是个编译器，输出 `.zig` 源码。
到 P3，我们生成代码会 link 的 runtime 需要 zignocchio 大致同样的
表面 —— 但要自己写、自己拥有、自己排演化节奏。

---

## 3. 我们从读它学到了什么

下面这些事情，2026-04-27 之前的文档要么写错、要么没提：

### 3.1 工具链是两步，不是一步

之前：`zig build-obj -target bpfel-freestanding` → `.o`。
之后：`zig build-lib … -femit-llvm-bc` → `.bc` →
      `sbpf-linker --cpu v2 --export entrypoint` → `.so`
      （`v3` 为可选，详见 ADR-013 Revised 2026-04-27）。

Solana loader **不**接受标准 `lld` 链出来的 ELF。
`sbpf-linker` 是"通用 BPF bitcode → Solana 形态 ELF"的桥。

→ 落到：`06-bpf-target.md` §2、§6；ADR-012。

### 3.2 产物后缀是 `.so`，不是 `.o`

很小但很普遍的修订。验收命令、CLI 文档、CI 门槛都从
`program.o` 改成 `program.so`。

→ 落到：`06-bpf-target.md` §1、§7；ADR-003 修订说明。

### 3.3 SBPF 版本要 pin

`sbpf-linker` 接受 `--cpu v0|v1|v2|v3`。默认值对现代 Solana 不够。
zignocchio 自己的 `build.zig` pin 了 `--cpu v2`
（"v2: No 32-bit jumps (Solana sBPF compatible)"），
也就是当前 mainnet validator 默认接受的版本。
v3 是更新的版本，作为可选保留给明确需要它特性的用户
（比如 static syscalls）。

ZxCaml 镜像 zignocchio 的选择：默认 `--cpu v2`，
通过 `--sbpf-version=v3` 显式启用 `--cpu v3`。

→ 落到：ADR-013（Revised 2026-04-27）。

### 3.4 Zig 0.16 有已知的 BPF 代码放置 bug

模块作用域 const 数组（尤其全零的）可能被放在极低地址（0x0、0x20），
Solana verifier 视为 access violation。
mitigation 是：取地址前先把这种常量复制到本地栈。

这件事会进 ZxCaml 的 codegen 规则：任何模块作用域绑定的
`let _ = [|0; 0; …|]`（或同形态常量数组）都得发一段 stack-copy shim。

→ 落到：`06-bpf-target.md` §4（注）、§8（症状行）。

### 3.5 syscall dispatch 用 MurmurHash3-32

Solana 不按符号暴露 syscall；loader 是按 syscall 名的 32 位 hash 查
（MurmurHash3，seed `0x00000000`，IIRC）。
zignocchio 有 `tools/gen_syscalls.zig` 预先算好这些 hash。

P1 用不到（我们没 syscall）但 P3 路线图重要。先记下来免得回头再发现一次。

→ 未来落到：`runtime/zig/syscalls.zig`（P3）。

### 3.6 bump allocator 的设计是趋同的

zignocchio 的 `sdk/allocator.zig` 是基于静态 buffer 的 bump allocator。
ADR-007 的设计（一条 arena 穿过所有函数）落点完全一样。
这是我们的内存模型获得了一次温和的外部验证。

→ ADR-005、ADR-007 已经写过。无需改文档，
但值得记一下：在 Solana-Zig 生态里，我们不是唯一选这个答案的项目。

### 3.7 macOS 开发没问题

zignocchio 在 macOS 上开发。
我们 preflight 假设清单上的一个开放问题被消掉了。

---

## 4. 我们 **没有** 复制的东西

为了让 ADR-014 站得住脚，下面把"明明可以省事但我们没复制"的清单列出来：

| zignocchio 模块 | 复制能省什么 | 为什么不复制 |
|---|---|---|
| `sdk/entrypoint.zig` | 一份已知正确的 Solana ABI v1 反序列化器 | 我们要用自己的命名、错误故事、arena 所有权语义重写。ABI 是公开的；趋同没问题，身份相同不行。 |
| `sdk/allocator.zig` | 一份能用的 bump allocator | 同上。ADR-007 拥有我们的 allocator 设计。 |
| `sdk/syscalls.zig` + `tools/gen_syscalls.zig` | MurmurHash3-32 的 syscall dispatch | P3 工作。生成器我们可以用 OCaml 或 Zig 自己重写。 |
| `sdk/account_info.zig` | AccountInfo 的零拷贝视图 | P3 工作。看起来很像也无所谓。 |
| 测试集成（litesvm/surfpool/mollusk） | 三个能用的测试 harness | 不在 P1 范围。P3 选一个 canonical 的。 |
| TypeScript 客户端 | 一个能用的 JS 表面 | 至少 P1–P3 都不在范围。 |

---

## 5. 我们欠 zignocchio 什么

我们欠的是 attribution，不是代码。

ZxCaml 文档或 commit message 引用一个起源于 zignocchio 的非显然技巧时
（比如 const-array workaround、SBPF `--cpu` flag 与 v2/v3 的选择），
我们注明出处。
这份文档和相关 ADR 已经做到这一点。

我们不欠它 upstream contribution，因为我们没有改它的代码。
如果 ZxCaml 之后在 `sbpf-linker` 里发现 bug，我们上报上游 ——
那是正常的开源行为，不是因为读了 zignocchio 才特别欠的债。

---

## 6. 这个姿态在什么情况下会改变

Way A 在 **当下** 是对的。它可能在以下情况下不再对：

- zignocchio 发布稳定、有版本号、有文档的 `runtime` crate，
  ZxCaml 可以依赖它而无需对它的 Zig 源码做耦合。
  那时 "Way B"（依赖它）在维护成本上可能比 Way A 优。
- ZxCaml 在 P3 累积的 runtime 代码多到明显是 zignocchio 的复制品。
  那时 "Way C / D"（vendor / fork）的对话值得重新打开。
- 出现 license 或 governance 顾虑，使得"仅作为灵感阅读"
  不足以为我们独立写出来的、看起来像它的 runtime 提供合理理由。
  我们不预期这会发生 —— Solana ABI 是公开的，趋同设计不可避免 ——
  但显式列出来，免得未来贡献者以为没人考虑过。

在这些条件之一被触发之前，Way A 就是答案。
