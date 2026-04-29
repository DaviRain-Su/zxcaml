# ZxCaml

> **Languages / 语言**: [English](../../README.md) · **简体中文**

> 一个带有 **Zig / BPF 后端** 的 **OCaml 方言**。
> 我们 **不** 发明新语言。源文件用标准的 `.ml` 后缀。
> 我们替换的是 *后端*，不是 *前端*。

---

## TL;DR

```text
.ml 源码
   │
   ▼
[ ocamlc -bin-annot ]    ◀── 上游 OCaml，作为库使用，绝不 fork
   │  .cmt (Typedtree)
   ▼
[ zxc-frontend (小段 OCaml 胶水) ]
   │  .cir.sexp  (有版本的 wire 格式)
   ▼
[ omlz (Zig)  : ANF → Core IR → ArenaStrategy → Lowered IR → Zig 代码生成 ]
   │  .zig
   ▼
[ zig build-lib -target bpfel-freestanding -femit-llvm-bc ]
   │  .bc (LLVM bitcode)
   ▼
[ sbpf-linker --cpu v2 --export entrypoint ]    ◀── v3 可选（ADR-013）
   │
   ▼
Solana BPF .so
```

- 前端：**上游 OCaml `compiler-libs`**（不 fork、不重写）。见 ADR-009 / ADR-010。
- 前端以下所有部分的宿主语言：**Zig 0.16**。
- 源语言：**OCaml**（子集，逐步扩大）。
- 主要目标平台：**Solana BPF**（`bpfel-freestanding`）。
- 内存模型（P3）：**arena，完全推断，对用户隐藏**；BPF entry 程序使用
  32 KiB arena。
- Core IR 形态：**ANF**（A-Normal Form），带类型，带 layout 标注。
- CLI 二进制名：**`omlz`**（OCaml on Zig）。
- 构建驱动：单一 **`build.zig`** 同时编排 OCaml 前端桥接和 Zig 管线（ADR-011）。

---

## 这个项目为什么存在

OCaml 有优雅的前端（HM 类型系统、ADT、模式匹配、模块），还有久经考验的类型系统。
它**缺**的是面向**资源受限、确定性执行**环境（比如 Solana BPF）的后端故事 ——
那种环境里 OCaml runtime（GC、boxed float、异常）根本跑不起来。

ZxCaml 保留 OCaml 语言、复用它的心智模型，但把程序导入一条新的管线，
通过 Zig 产出扁平、无 GC、能上 BPF 的代码。

我们**刻意不**去 fork 任何 OCaml 编译器发行版（上游 OCaml 或 OxCaml）。
而是把上游 `compiler-libs` 当成库来用，做 parser 和类型检查；
从 `Typedtree` 之后，所有东西都是我们自己的。
推理过程在
[`docs/alternatives-considered.md`](../alternatives-considered.md)（英文）/
[`alternatives-considered.md`](./alternatives-considered.md)（中文），
锁定在 ADR-009 / ADR-010。

---

## Native 执行是顺带免费的

因为每个 ZxCaml 程序按构造都是合法 OCaml（ADR-001），
而且 `omlz` 本来就要求开发者机器上有一套可用的 OCaml 工具链（ADR-010），
所以 **同一份 `.ml` 文件** 能用两条路径编译并运行：

```
一份 .ml 文件
  ├── ocaml / dune  →  native x86_64 / arm64 二进制   （本地测试、fuzzing、REPL）
  └── omlz          →  Solana BPF .so                 （部署）
```

这意味着 **ZxCaml 不需要一个专门的 x86 后端** 也能给你原生执行能力。
装 `ocaml`（你为了 `omlz` 已经装了）或者装 OxCaml，
然后用 `dune exec` 跑同一份文件。
两条路径产生相同结果；这是由确定性不变量（ADR-008）保证的。

更长的讨论 —— OxCaml 和本项目是什么关系、为什么还是不 fork ——
见 [`oxcaml-relationship.md`](./oxcaml-relationship.md)。

---

## Quickstart

完整安装细节和故障排查见 [安装](./INSTALLING.md)。
从仓库根目录构建 `omlz` 和规范 Solana BPF 示例：

```sh
./init.sh && zig build && zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```

这组命令使用的就是 CI 同一个 `init.sh` setup 脚本。

## 项目状态

**P3 Solana runtime integration 已实现。** P1 walking skeleton 和 P2 子集扩展
仍是基线。P3 增加了带类型的 Solana account 视图、syscall 绑定、CPI helper、
SPL-Token transfer 支持、保守的 `no_alloc` 分析、结构化错误码，以及 JSON IDL
发出。

`omlz` 已端到端工作：通过上游 `compiler-libs` 解析/类型检查 OCaml → 发出
sexp `0.9` → lower 到 Core IR → 解释执行、构建 native Zig、构建 Solana BPF
`.so` 产物，或发出 JSON IDL。

### 当前功能

- **CLI 命令：** `omlz check <file>`、`omlz check --no-alloc <file>`、`omlz run <file>`、`omlz build --target=native <file> -o <out>`、`omlz build --target=bpf <file> -o <out>`、`omlz idl <file>`
- **Wire 格式：** 版本 0.9（P1 为 `0.4`；P2 在 `0.5` 加用户 ADT、在 `0.6` 加嵌套/guarded pattern、在 `0.7` 加 tuple/record；P3 在 `0.8` 加 account/syscall 引用、在 `0.9` 加 CPI 类型/引用）
- **OCaml 子集：** let 绑定、嵌套 let、let rec、curried 函数、函数应用、算术/比较运算、if/then/else、用户自定义 ADT、嵌套构造器模式、带 `when` 的 match arm、tuple、record、字段访问、函数式 record update、列表（`[]` / `::`），以及覆盖这些形式的模式匹配
- **Stdlib：** 内置 `List`（`length`、`map`、`filter`、`fold_left`、`rev`、`append`、`hd`、`tl`）、`Option`（`is_none`、`is_some`、`value`、`get`）和 `Result`（`is_ok`、`is_error`、`ok`、`error`）模块
- **内存模型：** 仅 arena，完全推断，对用户隐藏；BPF entry arena 为 32 KiB
- **后端：** 树遍历解释器、Zig native 代码生成、通过 `sbpf-linker --cpu v2` 的 BPF 代码生成
- **Solana accounts：** 内置 `account` record 值暴露从 BPF 输入 buffer 解析出来的 key、lamports、data、owner 和 signer/writable/executable 标志零拷贝视图；runtime parser 还会跟踪 rent epoch
- **Solana syscalls：** logging、`sol_log_64`、pubkey logging、SHA-256/Keccak、Clock/Rent sysvar、remaining compute units 绑定均使用 MurmurHash3-32 dispatch 地址
- **CPI 和 PDA helpers：** 内置 `instruction` / `account_meta` records、`invoke`、`invoke_signed`、PDA helpers 和 return-data syscalls 镜像 Solana C ABI
- **SPL-Token：** helper 支持和 acceptance 示例会用 source/destination/authority metas 编码 legacy Tokenkeg Transfer instruction
- **no_alloc：** `omlz check --no-alloc` 运行保守的 Core IR 分配证明，失败时报告导致分配的 node
- **IDL：** `omlz idl <file>` 发出 ZxCaml JSON，包含 schema version、instruction accounts/args、用户类型和结构化错误常量
- **BPF 闭包：** 加固的一等闭包 — 捕获 ADT 值的闭包、多环境捕获和嵌套闭包均被 lower 成不依赖 BPF 不支持的 code-pointer relocation 的形态，并由 Solana closure acceptance 测试覆盖
- **Solana 验收：** canonical hello harness、closure harness、account/syscall harness、simple CPI harness 和 SPL-Token transfer harness 均可在 `solana-test-validator` 上部署 + 调用
- **确定性：** P1 + P2 + P3 examples corpus 上解释器 ≡ Zig native
- **CI：** GitHub Actions 工作流覆盖 `macos-latest` + `ubuntu-latest`，运行 `./init.sh`、`zig build`、`zig build test`、P3 `no_alloc` 和 IDL smoke check，以及 examples `omlz check` 语料循环
- **诊断信息：** 人性化的 `path:line:col: severity: message` 渲染
- **示例：** `examples/` 下 34 个程序，覆盖 ADT、嵌套/guarded pattern、tuple、record、stdlib、closure、BPF smoke、account/syscall、CPI 和 SPL-Token 程序
- **Golden/UI 测试：** Core IR/sexp snapshot 和 UI 测试通过 `zig build test` 运行
- **安装：** `./init.sh && zig build`（见 [INSTALLING.md](./INSTALLING.md)）

---

## 文档（按顺序读）

| # | 文档 | 锁定了什么 |
|---|---|---|
| —  | [安装](./INSTALLING.md) | 全新 setup、前置依赖、quickstart 和故障排查 |
| 00 | [概览](./00-overview.md) | 愿景、范围、三盆冷水（避免的陷阱） |
| 01 | [架构](./01-architecture.md) | 管线、分层 IR、扩展点 |
| 02 | [语法](./02-grammar.md) | 截至 P2 接受的 OCaml 子集 |
| 03 | [Core IR](./03-core-ir.md) | ANF IR 数据模型，核心契约 |
| 04 | [内存模型](./04-memory-model.md) | 当前仅 arena，未来扩展用 region 描述符 |
| 05 | [后端](./05-backends.md) | Zig 代码生成、树遍历解释器、后端 trait |
| 06 | [BPF 目标](./06-bpf-target.md) | 到 Solana `.so` 的工具链链路（zig + sbpf-linker） |
| 07 | [仓库布局](./07-repo-layout.md) | 目录契约，谁拥有什么 |
| 08 | [路线图](./08-roadmap.md) | P1–P7 各阶段，以及 P1/P2 release notes |
| 09 | [决策（ADR）](./09-decisions.md) | 锁定的决策，附带理由 |
| 10 | [前端桥接](./10-frontend-bridge.md) | OCaml `compiler-libs` → sexp → Zig |
| 11 | [Solana P3 指南](./11-solana-p3.md) | Account layout、syscall、CPI、SPL-Token、no_alloc、IDL 和 CI 覆盖 |
| —  | [备选方案对比](./alternatives-considered.md) | 为什么不自写、为什么不 fork OxCaml |
| —  | [OxCaml 关系](./oxcaml-relationship.md) | OxCaml 是什么，"用 OxCaml" 的四种解读，该选哪种 |
| —  | [zignocchio 关系](./zignocchio-relationship.md) | 我们读的 Zig→Solana SDK，学到了什么、没复制什么（ADR-014） |

> 所有中文文档都是英文版的对照翻译，结构完全一致；
> 真理来源是英文版。如果两边出现冲突，以英文版为准。

---

## 一句话总结

> **借用 OCaml 的前端，扔掉它的 runtime，通过 Zig 落到 BPF。**
>
> 借用 ≠ fork。我们把 `compiler-libs` 当库调用，**绝不**改它。
