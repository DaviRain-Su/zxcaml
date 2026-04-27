# 备选方案对比 —— 前端策略

> **Languages / 语言**: [English](../alternatives-considered.md) · **简体中文**

这是 ZxCaml 前端三个备选方案、为什么选 B、以及被拒方案各自意味着什么的快照。
它存在的意义是：未来贡献者在重新讨论这个决策之前，先读完为什么是这样决定的。

决策本身记录在 **ADR-009**（不 fork）和 **ADR-010**（用上游 `compiler-libs`）。
本文档是它们引用的 *上下文*。

---

## 方案 A —— 用 Zig 全部手写

```text
.ml  →  Zig lexer  →  Zig parser  →  Zig HM/ADT  →  Zig Typed AST
        →  ANF  →  Core IR  →  Lowered IR  →  Zig codegen
        →  zig build-lib + sbpf-linker  →  program.so
```

### 优点
- 构建期零 OCaml 工具链依赖。
- 整个编译器单一语言。
- 对诊断和 IR 形态有完全控制。

### 缺点
- 多写约 3–5 千行 Zig：lexer、parser、HM（带 let-poly）、ADT 推断、
  穷尽性检查、错误报告。
- 持续存在 *子集漂移* 风险 —— 我们 parser 接受但真实 OCaml 拒绝（或反过来）。
  抓这种漂移需要持续对照 `ocaml` 的 oracle 测试，
  也就是说工具链依赖会从后门绕回来。
- 手写的 HM 错误信息出名地难做好。OCaml 在这上面打磨了几十年；
  我们追不上。

### 为什么暂时不选
代价是真实而持续的；收益是我们其实不需要的"独立性"。
我们的验收标准是 BPF 输出，不是 *编译器* 本身的工具链零依赖发行。
跑已部署 BPF 程序的终端用户从不接触 OCaml；
只有构建 ZxCaml 程序的开发者才接触，他们本就有工具链。

如果 `compiler-libs` 稳定性变成长期问题，这条路作为退路保留。

---

## 方案 B —— 上游 OCaml `compiler-libs` 当前端 ★ 已选

```text
.ml  →  ocamlc -bin-annot  →  .cmt
        →  zxc-frontend (OCaml，~几百行)
        →  .cir.sexp
        →  Zig 前端桥
        →  ANF  →  Core IR  →  Lowered IR  →  Zig codegen
        →  zig build-lib + sbpf-linker  →  program.so
```

### 优点
- **不写 parser，不写 HM。** 两者都来自 OCaml 自己。
- **子集漂移结构上不可能。** `zxc-frontend` 字面意义上遍历真 `Typedtree`；
  我们接受一个节点就等于 OCaml 接受同一程序。
- **编辑器支持开箱即用。** `merlin`、`ocamlformat`、VSCode OCaml 扩展等
  在用户 `.ml` 上原封不动地工作。
- OCaml 占地极小：几百行，只依赖 `compiler-libs.common`
  （OCaml 发行版自带）。
- 编译器是 **双语但每一面都很小**；各做擅长的事。

### 缺点
- 构建期依赖一个能用的 OCaml 工具链（`ocamlc`、`ocamlfind`）。
- `compiler-libs` `Typedtree` 形态跨主版本不正式稳定；每个 phase pin 一个版本。
- 每次编译要拉起一个小型 OCaml 子进程。代价可忽略（典型 < 100 ms）。

### 缓解
- ADR-011 让构建保持单驱动（`build.zig`），双语对外不可见。
- `.cir.sexp` wire 格式带版本（见 `10-frontend-bridge.md` §3.2）。
  major bump 同 PR 内更新两侧。
- "每个 phase 一个 OCaml 版本"的策略写在 ADR-010 里，
  并被 `08-roadmap.md` 引用。

### 为什么选它
这是唯一既给我们 OCaml 前端、又不继承 OCaml runtime 的方案。
它和我们已经锁定的所有决策一致（ADR-001、-004、-005、-006、-009），
而且只新增最小的需要维护面。

---

## 方案 C —— Fork OxCaml（或上游 OCaml）

```text
oxcaml/oxcaml fork
  添加：backend/bpf_codegen.ml
  添加：runtime/bpf/*  (与现有 C runtime 并列)
  打补丁：BPF 目标上去掉 caml_call_gc
  打补丁：BPF 目标上 stub 异常
  打补丁：BPF 目标上 stub 线程
  rebase：每周对着 oxcaml/main（37k commits、非常活跃）
```

### 优点（理论上）
- 继承 Flambda 2 的优化。
- 继承 Cfg 后端基础设施。
- 继承 OxCaml 的 `mode` / `local` / `unique` 分析。

### 缺点（实际上）
- **优化在 BPF 上不迁移。** Flambda 2 围绕 OCaml ABI 和 OCaml GC 做 unbox；
  BPF 上两者都没有。Cfg 为 x86 / arm64 lower；BPF 需要单独 lower。
  `local` mode 区分 GC heap 和栈分配；BPF 上没有 GC heap。
  所有这些优化都不 *面向* BPF；它们面向 BPF 缺的东西。
- **OxCaml 是 ~37k commits、~970 branch、~87% OCaml + ~9% C，
  并且持续 rebase 上游 OCaml。** 维护这种规模的 fork 是全职团队工作量。
  我们不是团队。不 rebase 的 fork 变死代码；持续 rebase 的 fork 吃光大部分工程预算。
- **在 OxCaml 内部加 BPF 目标对上游是敌对的。** 它必须和 Cfg 后端共存、
  绕过 `caml_call_gc`、stub 异常和线程、随包带一个并行迷你 runtime。
  这一切都不被上游欢迎，所以 fork 发散度只增不减。
- **OCaml C runtime 恰恰是我们想丢掉的东西。**
  fork 一个把那个 runtime 随包带的编译器，会让我们永久处于
  "随身携带我们想删除的所有东西"的境地。

### 为什么拒绝
fork 一个 37k commits 的活跃 OCaml 编译器、就为加一个"主打无 OCaml runtime"
的后端 —— 这个项目形状对本团队是错的。fork 的每一个收益要么不适用 BPF，
要么有更便宜的获得方式。

OxCaml 的设计思想仍然有价值，但作为 **参考材料**，不是导入的代码。
我们可以读他们的论文、研究他们的 IR、借用他们的术语；我们 **不** 把他们的源码搬进来。

---

## 决策汇总

| 标准 | A：自写 | B：compiler-libs ★ | C：fork OxCaml |
|---|---|---|---|
| 我们要写的代码量 | 多 | 少 | 灾难（rebase） |
| OCaml 保真度 | 尽力而为 | 精确 | 精确 |
| 构建期依赖 | 无 | OCaml + Zig | Jane Street 构建链 |
| 长期维护 | parser 漂移 | minor `compiler-libs` API 变动 | 永久 rebase 战 |
| 拿到的优化 | 无明显增益 | 无明显增益 | 多 —— 但**全部**假设 OCaml runtime |
| 与现有 ADR 自洽 | 部分 | 完全 | 违反 ADR-001/006/009 |

**选 B。** 决策记录在 ADR-010；新管线住在 `10-frontend-bridge.md`。

---

## 何时重新评估

下面任一条件成立时应当重新评估：

1. `compiler-libs` 在连续两个 minor 都引入破坏性变化。→ 考虑方案 A。
2. OCaml 前端胶水超过 ~1500 行 OCaml。→ 考虑拆成 `dune` 项目（修订 ADR-011）。
3. 出现某个 BPF 优化必须控制 OCaml 的 `Lambda` 或 `Cmm` IR，
   而 `Typedtree` 表达不了。→ 考虑把切入点从 `Typedtree` 移到 `Lambda`
   （仍是方案 B 形状，只是更深）。

fork OxCaml **不在** 重审清单里。如果某位未来维护者认为它应该在，
他必须先回答清楚（书面）：

- 你打算怎么跟上 37k commits？
- 具体是 Flambda 2 的哪一个优化能迁移到 BPF？
- 那个优化为什么"继承+维护"比"基于我们 Core IR 从头写"更便宜？

如果这些问题有令人信服的答案，再 supersede ADR-009 和本文档。
