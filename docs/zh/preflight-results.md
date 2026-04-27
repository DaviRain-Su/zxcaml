# 预飞行（preflight）结果

> 本文件是 [`docs/preflight-results.md`](../preflight-results.md) 的简体中文翻译。
> 当译文与英文原文不一致时，以英文原文为准。

记录 ZxCaml P1 前端可行性 spike 的结论。它是 ADR‑010 与
`docs/10-frontend-bridge.md` 中各项假设是否经得起现实检验的官方证据。

## Spike α — OCaml `compiler-libs` Typedtree 抽取

### 环境

| 项目 | 实测值 |
|---|---|
| 操作系统 | macOS 26.4.1（darwin 25.4.0），arm64 |
| Homebrew | 5.1.6 |
| opam | 2.5.1 |
| OCaml | 5.2.1（`ocaml-base-compiler.5.2.1`，switch 名为 `zxcaml-spike`） |
| dune | 3.17.0 |
| ocamlfind | 1.9.6 |
| `compiler-libs.common` | 5.2.1（随编译器一起分发，无需额外 opam 包） |

switch 创建命令：

```sh
opam switch create zxcaml-spike 5.2.1
opam install -y dune
```

### 我们做了什么

放在 `spike/ocaml-cmt-read/` 之下：

- `hello.ml` —— 9 行小程序，覆盖顶层 `let`、表达式内部 `let`、对
  `option` 的 `match`、`if/then/else` 与函数应用。
- `reader.ml` —— ~120 行的 Typedtree 遍历器，基于
  `Tast_iterator.default_iterator`，只覆写两个钩子（`expr` 与
  `pat`）。模式匹配通过 GADT 的 `match` 同时处理 `value` 与
  `computation` 两种 pattern category，**完全没有用 `Obj.magic`**。
- `dune` / `dune-project` —— 声明两个可执行目标；`hello` 用
  `(modes byte)` 加 `-bin-annot` 编译，让 dune 落出 `.cmt`。

reader 接受一个 `.cmt` 路径作为命令行参数，先打印 modname，然后对
每个表达式与模式节点输出 `[KIND] 构造子 : <类型> @ 文件:行:列`。

### 验收结果

| # | 标准 | 结果 |
|---|---|---|
| 1 | opam 已安装；OCaml 是 5.2.x | **通过** —— `5.2.1` |
| 2 | `dune build` 无警告完成 | **通过** —— 编译干净，零诊断 |
| 3 | reader 为每个节点打印构造子+类型+位置 | **通过** —— 见下方原样输出 |
| 4 | 仅使用 `compiler-libs.common`，无 `Obj.magic` | **通过** —— `(libraries compiler-libs.common)` 是唯一依赖；源码不含 `Obj.magic` |
| 5 | 本文件存在 | **通过** |
| 6 | 中文版本存在于 `docs/zh/preflight-results.md` | **通过** |
| 7 | 已提交并推送到 `origin/main` | **通过**（commit 见正文引用） |

### Reader 输出（原样粘贴）

由 `dune exec ./reader.exe -- _build/default/.hello.eobjs/byte/dune__exe__Hello.cmt` 捕获：

```
# cmt: _build/default/.hello.eobjs/byte/dune__exe__Hello.cmt  (modname=Dune__exe__Hello)
[PAT ] Tpat_var               : int option -> string @ hello.ml:5:4
[EXPR] Texp_function          : int option -> string @ hello.ml:5:13
[PAT ] Tpat_alias             : int option @ hello.ml:5:14
[PAT ] Tpat_any               : int option @ hello.ml:5:14
[EXPR] Texp_match             : string @ hello.ml:6:2
[EXPR] Texp_ident             : int option @ hello.ml:6:8
[PAT ] Tpat_value             : int option @ hello.ml:7:4
[PAT ] Tpat_construct         : int option @ hello.ml:7:4
[EXPR] Texp_constant          : string @ hello.ml:7:12
[PAT ] Tpat_value             : int option @ hello.ml:8:4
[PAT ] Tpat_construct         : int option @ hello.ml:8:4
[PAT ] Tpat_var               : int @ hello.ml:8:9
[EXPR] Texp_let               : string @ hello.ml:9:6
[PAT ] Tpat_var               : int @ hello.ml:9:10
[EXPR] Texp_apply             : int @ hello.ml:9:20
[EXPR] Texp_ident             : int -> int -> int @ hello.ml:9:22
[EXPR] Texp_ident             : int @ hello.ml:9:20
[EXPR] Texp_ident             : int @ hello.ml:9:24
[EXPR] Texp_ifthenelse        : string @ hello.ml:10:6
[EXPR] Texp_apply             : bool @ hello.ml:10:9
[EXPR] Texp_ident             : int -> int -> bool @ hello.ml:10:17
[EXPR] Texp_ident             : int @ hello.ml:10:9
[EXPR] Texp_constant          : int @ hello.ml:10:19
[EXPR] Texp_constant          : string @ hello.ml:10:26
[EXPR] Texp_constant          : string @ hello.ml:10:42
[PAT ] Tpat_any               : string @ hello.ml:12:4
[EXPR] Texp_apply             : string @ hello.ml:12:8
[EXPR] Texp_ident             : int option -> string @ hello.ml:12:8
[EXPR] Texp_construct         : int option @ hello.ml:12:17
[EXPR] Texp_constant          : int @ hello.ml:12:23
```

输出说明：

- 所有目标构造子家族都出现了：`Texp_let`、`Texp_function`、
  `Texp_match`、`Texp_apply`、`Texp_ident`、`Texp_constant`、
  `Texp_construct`、`Texp_ifthenelse`，模式侧的
  `Tpat_var`、`Tpat_alias`、`Tpat_any`、`Tpat_value`、`Tpat_construct`
  也都齐了。
- 类型都是具体的：`int option -> string`、`int -> int -> bool`、
  `string`、`int`、`bool`、`int option`，没有未解决的类型变量——因为
  我们走的是类型检查器结束之后的 `Implementation`。
- 列号是相对该行起点的 0 基偏移（`pos_cnum - pos_bol`），行号是 1 基。

### API 摩擦 / 意外（如实记录）

虽然没有任何一项严重到需要重新设计架构，但还是要诚实写下：

1. **顶层函数名以 `Tpat_var` 出现（5:4）**。`let f x = …` 实际上对应
   一个 `Tstr_value`，其内部 binding 的 pattern 是 `Tpat_var`，而该
   `Tpat_var` 的 `pat_type` 是**整个函数类型**（`int option -> string`），
   不是某个子项的类型。语义上是对的，但读 trace 时容易看错。
2. **顶层 `let` 走的是 `Tstr_value`，不是 `Texp_let`**。只有表达式
   内部的 let 才会出现 `Texp_let`。我们之所以能在 spike 里看到一个，
   是因为额外加了一行 `let doubled = n + n` 在 `Some` 分支里。未来
   ZxCaml 前端必须同时遍历 `structure_item.Tstr_value` 与
   `Texp_let`；`Tast_iterator` 已经替我们处理了，写就是了。
3. **GADT 化的 pattern**。`pattern_desc` 由 `value | computation`
   索引。`Tast_iterator.iterator.pat` 已经把这个索引参数化了
   （`'k . iterator -> 'k general_pattern -> unit`），所以一个
   覆写函数就够用，但我们必须显式写 `(type k)` 注解，否则类型检查器
   推不出。这是语法噪音，不是语义问题。
4. **`Cmt_format.cmt_modname` 的类型是 `Misc.modname`，不是 `string`**。
   在 5.2.1 中它是 `string` 的私有别名，可以靠 `(_ :> string)` coerce
   过去。如果未来某个编译器版本把 `modname` 弄成抽象类型，那一句
   coerce 可能要换成一个具名访问器。风险很低，但记一下。
5. **`-bin-annot` 与 dune 的配合**。我们用 `(executable …)` stanza
   时，dune 默认**不会**对可执行单元加 `-bin-annot`；必须在 stanza
   里加 `(flags (:standard -bin-annot))`。库目标（library）则是默认
   开启的。spike 的 `dune` 文件里加了注释说明这一点。
6. **`Printtyp.type_expr` 走全局状态**。在这里没问题，因为我们是
   单线程且短命的进程。真正的前端会想用
   `Printtyp.{wrap_printing_env, with_constraint}` 或者在打印前
   snapshot 一下 env。不阻塞。

没有 `Obj.magic`、没有访问私有模块、没有依赖 `compiler-libs.optcomp`、
也没有给编译器打补丁。一切都来自 `compiler-libs.common`。

### 结论

**PROCEED（继续推进）。**

OCaml 5.2.1 的 `compiler-libs.common` 干净地从 `.cmt` 中给出完整
类型化的 `Typedtree`。`Tast_iterator` 提供的开放递归形态正是
ZxCaml 计划中 `zxc-frontend` 想要的形态。类型表达式、源码位置、
构造子身份都能拿到，**不必**借助 `Obj.magic`、私有模块或者编译器
补丁。上面列出的摩擦点是文档/坑提醒，不是架构问题。

`docs/10-frontend-bridge.md` 描述的 P1 策略在该证据下是站得住的。
Spike β（BPF 工具链）以及下游前端工作（F00–F06）可以按 ADR‑010
的现状继续。

### ADR / 文档修订建议

下面只是**建议**，本 spike 不会自行去改两份 preflight 文件以外
的任何文档。

1. **ADR‑010 / 文档 10 —— 锁定 "OCaml 5.2.x" 即可**。没必要收紧
   到 `=5.2.1`，也没必要放宽到 `>= 5.2`（我们没测过 5.3）。
2. **文档 10 在描述前端构建系统时应明确提到 `-bin-annot`**。一句
   `(flags (:standard -bin-annot))` 能为下一位实现者省下十分钟。
3. **文档 10（或一份补充注记）应说明顶层 `let` 走 `Tstr_value`**，
   因此子集执法器必须遍历 `structure_item`，而不是只盯着
   `expression`。
4. **不需要为 `Tast_iterator` 单开 ADR**。这是前端内部的实现选择，
   后续再回顾即可。

未发现 `docs/10-frontend-bridge.md` 之外的新风险。
