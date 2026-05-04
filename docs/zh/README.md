# ZxCaml

> **Languages / 语言**: [English](../../README.md) · **简体中文**

> 一个带有 **Zig / BPF 后端** 的 **OCaml 方言**。
> 我们 **不** 发明新语言。源文件使用标准 `.ml` 后缀。
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
[ zxc-frontend（小段 OCaml 胶水）]
   │  .cir.sexp  （带版本的 wire 格式）
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
- 源语言：**OCaml**（子集，持续扩展中）。
- 主要目标平台：**Solana BPF**（`bpfel-freestanding`）。
- 内存模型（P3）：**arena，完全推断，对用户隐藏**；BPF entry 程序使用
  32 KiB arena。
- Core IR 形态：**ANF**（A-Normal Form），带类型，带 layout 标注。
- CLI 二进制名：**`omlz`**（OCaml on Zig）。
- 构建驱动：单一 **`build.zig`** 同时编排 OCaml 前端桥接和 Zig 管线（ADR-011）。

---

## 这个项目为什么存在

OCaml 有优雅的前端（HM 类型、ADT、模式匹配、模块）和久经考验的类型系统。
它缺的是面向 **资源受限、确定性执行** 环境（例如 Solana BPF）的后端故事；
在这类环境里，OCaml runtime（GC、boxed float、异常）无法落地。

ZxCaml 保留 OCaml 语言和它的心智模型，但把程序送进一条新的编译管线，
经由 Zig 产出扁平、无 GC、适合 BPF 的代码。

我们刻意 **不** fork 任何 OCaml 编译器发行版（上游 OCaml 或 OxCaml）。
相反，我们把上游 `compiler-libs` 当作库来做 parsing 和 type-checking；
从 `Typedtree` 往后，全部由 ZxCaml 自己负责。这个选择的推理过程写在
[`alternatives-considered.md`](./alternatives-considered.md)，并由 ADR-009 / ADR-010 锁定。

---

## Native 执行是顺带免费的

因为每个 ZxCaml 程序按构造都是合法 OCaml（ADR-001），而且 `omlz` 本来就要求
开发者机器上有可用的 OCaml 工具链（ADR-010），所以 **同一份 `.ml` 文件**
天然可以走两条编译/运行路径：

```
一份 .ml 文件
  ├── ocaml / dune  →  native x86_64 / arm64 二进制   （本地测试、fuzzing、REPL）
  └── omlz          →  Solana BPF .so                 （部署）
```

也就是说，**ZxCaml 不需要专门写一个 x86 后端**，也能给你 native 执行能力。
安装 `ocaml`（为了使用 `omlz`，你本来就需要它），或者安装 OxCaml，
然后用 `dune exec` 跑同一份文件即可。两条路径计算出相同结果；
这个性质由确定性不变量（ADR-008）保证。

关于 OxCaml 与本项目的关系，以及为什么我们仍然不 fork 它，
详见 [`oxcaml-relationship.md`](./oxcaml-relationship.md)。

---

## Quickstart

完整安装细节和故障排查见 [安装](./INSTALLING.md)。
从仓库根目录构建 `omlz` 和规范 Solana BPF 示例：

```sh
./init.sh && zig build && zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```

这组命令使用的就是 CI 里的同一个 `init.sh` setup 脚本。

## 项目状态

**P8 Compiler Optimizations 已封版。** P1-P8 现在覆盖 walking skeleton、子集扩展、
Solana runtime 集成、Mollusk 测试基础设施、external declarations、Anchor IDL、
函数式持久化 stdlib、region inference、OCaml 子集继续扩展（desugar、patterns、
strings、扩展 stdlib），以及源码级编译器优化：constant folding、dead code
elimination、自递归 tail call optimization 和 function inlining。

近期的 hackathon 工作把这些编译器能力包装成可录制的演示：Surfpool localnet
deploy/invoke 流程、公平性取向的 Anchor 对照、双语 Slidev deck，以及上线在
[`https://zxcaml.pages.dev/`](https://zxcaml.pages.dev/) 的 Cloudflare Pages
站点。Storyboard、脚本、对照材料和录制清单见
[`docs/hackathon/README.md` 索引](../hackathon/README.md)。

`omlz` 已端到端工作：通过上游 `compiler-libs` 解析/type-check OCaml → 发出
sexp `1.1` → 带 constant folding、DCE、inlining、escape analysis 地 lower 到
Core IR → 解释执行、构建 native Zig、构建 Solana BPF `.so` 产物，或发出
Anchor-compatible IDL。

### 当前功能

- **CLI 命令：** `omlz check <file>`、`omlz check --no-alloc <file>`、`omlz run <file>`、`omlz build --target=native <file> -o <out>`、`omlz build --target=bpf <file> -o <out>`、`omlz idl <file>`
- **Wire 格式：** 版本 1.1（P1 为 `0.4`；P2 在 `0.5` 加用户 ADT、在 `0.6` 加嵌套/guarded pattern、在 `0.7` 加 tuple/record；P3 在 `0.8` 加 account/syscall 引用、在 `0.9` 加 CPI 类型/引用；P4/P5 让 instruction data 和 external declarations 走过 `1.0`；P8 为 mutual-recursion groups 升到 `1.1`）
- **OCaml 子集：** let 绑定、嵌套 let、let rec、curried 函数、函数应用、算术/比较运算、if/then/else、用户自定义 ADT、嵌套构造器模式、带 guard 的 match arm、字面量常量模式、or-pattern、alias pattern、tuple、record、字段访问、函数式 record update、列表（`[]` / `::`）、sequence 表达式（`;`）、function cases（`function |`）、string 操作（`^`、length、get、sub）、char 操作（code、chr），以及覆盖这些形式的模式匹配
- **Stdlib：** bundled `List`（`length`、`map`、`filter`、`fold_left`、`rev`、`append`、`hd`、`tl`、`nth`、`exists`、`for_all`、`find`、`sort`、`combine`、`split`）、`Option`（`is_none`、`is_some`、`value`、`get`、`fold`）、`Result`（`is_ok`、`is_error`、`ok`、`error`、`map`、`bind`）、`Fun`（`id`、`const`、`flip`）、`Map`（`empty`、`singleton`、`add`、`find`、`remove`、`mem`、`size`、`to_list`）、`Set`（`empty`、`singleton`、`add`、`mem`、`remove`、`size`、`to_list`、`union`、`inter`）、`String`（`length`、`get`、`sub`）、`Char`（`code`、`chr`）、`Crypto`（`sha256`、`keccak256`）和 `Pubkey`（`zero`、`token_program`、`of_hex`）模块
- **内存模型：** arena-only，并通过 region inference 自动把不逃逸的局部值放到栈上；BPF entry arena 为 32 KiB
- **后端：** tree-walk interpreter、Zig native codegen，以及通过 `sbpf-linker --cpu v2` 的 BPF codegen
- **Solana accounts：** 内置 `account` record 值把 BPF input buffer 解析出的 key、lamports、data、owner，以及 signer/writable/executable flags 暴露为零拷贝视图；runtime parser 还会跟踪 rent epoch
- **Solana syscalls：** logging、`sol_log_64`、pubkey logging、SHA-256/Keccak、Clock/Rent sysvars 和 remaining compute units 都通过 `external` declarations 直接绑定到 Zig runtime symbols
- **External declarations：** `external name : type = "zig_symbol"` 语法允许以类型安全方式直接 FFI 到 Zig runtime 函数
- **CPI 和 PDA helpers：** 内置 `instruction` / `account_meta` records、`invoke`、`invoke_signed`、PDA helpers 和 return-data syscalls，形状贴近 Solana C ABI
- **SPL-Token：** helper 支持和 acceptance 示例会用 source/destination/authority metas 编码 legacy Tokenkeg Transfer instructions
- **no_alloc：** `omlz check --no-alloc` 运行保守的 Core IR allocation proof，失败时报告导致分配的 node
- **IDL：** `omlz idl <file>` 发出 Anchor 0.30+ compatible JSON，包含 SHA-256 discriminators、instruction accounts/args、account types、events、errors 和 constants
- **BPF 闭包：** 加固的一等闭包——捕获 ADT 值的闭包、多环境捕获和嵌套闭包都会 lower 成不依赖 BPF 不支持的 code-pointer relocations 的形态，并由 Solana closure acceptance tests 覆盖
- **Solana 验收：** canonical hello harness、closure harness、account/syscall harness、simple CPI harness 和 SPL-Token transfer harness 都可在 `solana-test-validator` 上部署 + 调用
- **Region inference：** 自动 escape analysis 会把不逃逸的局部值标成 stack allocation，降低 arena 压力并改善 BPF compute 效率
- **Constant folding：** 在 Core IR 中编译期求值 arithmetic、comparison、string concatenation、boolean conditions 和已知 constructor matches
- **Dead code elimination：** 移除未使用的 let bindings（保留有副作用或可能 trap 的操作）以及不可达的 if branches
- **Tail call optimization：** ANF lowering 会识别自递归尾调用，并在生成的 Zig 中发出 `while (true)` loops，让深递归（n > 10000）不再溢出栈
- **Function inlining：** 小型单表达式函数（≤3 个 Core IR nodes）会带 alpha-renaming 地 inline 到 call site，触发更多 constant folding；String、ADT、Tuple 和 Record 等类型都受支持
- **确定性：** sealed P1-P8 examples corpus 上，interpreter ≡ Zig native
- **CI：** GitHub Actions 工作流以 `macos-latest` + `ubuntu-latest` matrix 运行 `./init.sh`、`zig build`、`zig build test`、`cargo test`（Mollusk SVM）、P3 `no_alloc` 与 IDL smoke checks、Mollusk tests，以及 examples `omlz check` corpus loop
- **Mollusk SVM tests：** `tests/` 下有 21 个使用 Mollusk SVM v0.12.1 的 integration tests（hello、demo、simple_cpi、counter、vault、external_demo、crypto_demo、hackathon_greet，以及 real-world zignocchio ports）
- **诊断信息：** 人性化的 `path:line:col: severity: message` 渲染
- **示例：** `examples/` 下 54 个程序，覆盖 ADT、嵌套/guarded pattern、tuple、record、stdlib、closure、BPF smoke、account/syscall、CPI、SPL-Token、counter、vault、external demo、crypto demo、multi-instruction、region allocation、string demo、tail recursion（TCO）、hackathon greeting 和 zignocchio-port programs
- **Golden/UI 测试：** Core IR/sexp snapshot 和 UI tests 通过 `zig build test` 运行
- **安装：** `./init.sh && zig build`（见 [INSTALLING.md](./INSTALLING.md)）

---

## 文档

建议按顺序阅读：

| # | 文档 | 锁定了什么 |
|---|---|---|
| —  | [安装](./INSTALLING.md) | 全新 setup、前置依赖、quickstart 和故障排查 |
| 00 | [概览](./00-overview.md) | 愿景、范围、三盆冷水（避免的陷阱） |
| 01 | [架构](./01-architecture.md) | 管线、分层 IR、扩展点 |
| 02 | [语法](./02-grammar.md) | ZxCaml 接受的 OCaml 子集 |
| 03 | [Core IR](./03-core-ir.md) | ANF IR 数据模型，核心契约 |
| 04 | [内存模型](./04-memory-model.md) | 当前的 arena-only 模型，以及未来 region 描述符 |
| 05 | [后端](./05-backends.md) | Zig codegen、tree-walk interpreter、backend trait |
| 06 | [BPF 目标](./06-bpf-target.md) | 到 Solana `.so` 的工具链链路（zig + sbpf-linker） |
| 07 | [仓库布局](./07-repo-layout.md) | 目录契约，谁拥有什么 |
| 08 | [路线图](./08-roadmap.md) | P1-P8 已封版；P9 Developer Experience 预览 |
| 09 | [决策（ADR）](./09-decisions.md) | 锁定的决策，附带理由 |
| 10 | [前端桥接](./10-frontend-bridge.md) | OCaml `compiler-libs` → sexp → Zig |
| 11 | [Solana P3 指南](./11-solana-p3.md) | Account layout、syscalls、CPI、SPL-Token、no_alloc、IDL 和 CI coverage |
| —  | [Hackathon assets](../hackathon/README.md) | Surfpool demo、Anchor comparison、Slidev decks、录制清单和 submission copy |
| —  | [Live site](https://zxcaml.pages.dev/) | 当前公开项目 landing page |
| —  | [备选方案对比](./alternatives-considered.md) | 为什么不自写、为什么不 fork OxCaml |
| —  | [OxCaml 关系](./oxcaml-relationship.md) | OxCaml 是什么，“用 OxCaml”的四种解读，该选哪种 |
| —  | [zignocchio 关系](./zignocchio-relationship.md) | 我们参考的 Zig→Solana SDK，学到了什么、没有搬进来什么（ADR-014） |

---

## 一句话总结

> **借用 OCaml 的前端。扔掉它的 runtime。经由 Zig 落到 BPF。**
>
> 借用 ≠ fork。我们把 `compiler-libs` 当库调用，绝不 patch 它。
