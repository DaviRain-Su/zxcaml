# 10 — 前端桥接（OCaml `compiler-libs` → Zig）

> **Languages / 语言**: [English](../10-frontend-bridge.md) · **简体中文**

本文档规定 `omlz` 如何在不 fork、不重写 OCaml 的情况下，
拿到 `.ml` 源文件的完整类型检查表示。
是 ADR-010 的具体落地。

## 1. 定位

```text
.ml 源码
   │
   ▼
[ ocamlc -bin-annot ]                        （没有 vendor；用系统 ocaml）
   │
   ▼
.cmt + .cmti                                 （二进制 Typedtree）
   │
   ▼
[ zxc-frontend (OCaml，~几百行) ]            （build.zig 一次性构建）
   │
   ▼
.cir.sexp                                    （Typedtree 子集的 S-expression）
   │
   ▼
[ omlz (Zig) ]                               （读 sexp）
   │
   ▼
Typed AST（Zig 镜像） → ANF → Core IR → …
```

OCaml 这一侧是一个 **小型、只读** 的 `compiler-libs` 消费者。
不扩展 OCaml 编译器，不打补丁，不 fork。

## 2. OCaml 组件：`zxc-frontend`

### 2.1 职责

1. 在用户 `.ml` 上驱动 `Compile.implementation`（或匹配的 `compiler-libs` 等价物），
   产出 `Typedtree.structure`。
2. 遍历 `Typedtree`，**拒绝** 任何子集外的构造（见 §4），并附带精确诊断。
3. 把幸存子集序列化成稳定 S-expression 格式（见 §3）。
4. 用统一形态向 stderr 发诊断；`omlz` 转发给用户。

### 2.2 非职责

- 不生成代码。
- 不做 ANF 或任何 IR lowering。ANF 在 Zig 侧。
- 不加载多文件；P1 一次一个 `.ml`。模块支持是 P3 的事。

### 2.3 源码位置和构建

```text
src/frontend/zxc_frontend.ml         -- 主程序
src/frontend/zxc_subset.ml           -- 子集白名单 + walker
src/frontend/zxc_sexp.ml             -- 序列化器
```

由 `build.zig` 通过
`ocamlfind ocamlopt -package compiler-libs.common -linkpkg ...` 构建（见 ADR-011）。
输出二进制：`build/zxc-frontend`。

### 2.4 `zxc-frontend` 的 CLI

```text
zxc-frontend <input.ml> [--out <path>] [--json-diag]

  退出码：
    0   成功，sexp 写到 stdout（或 --out）
    1   子集违规（诊断到 stderr）
    2   OCaml 类型错误（诊断到 stderr）
    3   I/O 或内部错误
```

`omlz` 始终传 `--json-diag`，统一渲染诊断。

## 3. Wire 格式：`.cir.sexp`

之所以选 S-expression：

- 无歧义、行式、Zig 端解析极简单。
- 容忍空白，方便 diff 和 golden 测试。
- 与 `Typedtree` 子集的代数形态映射干净。

### 3.1 顶层形态

```text
(module
  (source "examples/hello.ml")
  (ocaml-version "5.2.0")
  (zxc-frontend-version "0.1")
  (types
    (adt option (params 'a)
      (variants
        (None)
        (Some 'a)))
    ...
    )
  (decls
    (let head
      (ty (arrow (list 'a) (option 'a)))
      (rec false)
      (body
        (fun (param xs (ty (list 'a)))
          (match (var xs)
            (case (pat (ctor [])) (body (ctor None)))
            (case (pat (ctor :: x _))
                  (body (ctor Some (var x))))))))))
```

### 3.2 稳定性承诺

- wire 格式带版本。header 里写 `zxc-frontend-version`；
  `omlz` 拒绝 major 不匹配。
- 新关键字 **追加** 在节点的子节点尾部；Zig 端宽容解析。
- 删除或重新定义现有关键字属于 major 版本变动。

sexp 的形式语法住在 `src/frontend/zxc_sexp_format.md`，是 wire 契约。

### 3.3 sexp 里有什么、没什么

有：

- 子集内的类型声明（变体、记录、类型别名）。
- 顶层 `let` 绑定（保留递归组）。
- 子集覆盖的表达式：`let`、`fun`、`match`、`if`、应用、构造子、记录、
  投影、元组、字面量。
- 子集覆盖的模式。
- 每个节点：源 span（`(span 12 5 18)` = file_id, line, col）和已解析 `ty`。

没：

- 文档注释、普通注释、格式化 trivia。
- 超出 span 和 `ty` 之外的内部编译器标注。
- 子集外特性产生的节点（这些在序列化前已被拒绝）。

## 4. 接受的子集（P1）

下面是 `zxc-frontend` 在 P1 阶段接受的 `Typedtree` 构造的 **权威** 列表。
不在这个列表上的任何东西都会产出"P1 暂不支持"的诊断。

### 4.1 顶层

- `Tstr_value`（一组 `let`，递归或不递归）
- `Tstr_type Trec_not | Trec_first | Trec_next`（类型声明）

拒绝：`Tstr_module`、`Tstr_modtype`、`Tstr_class`、`Tstr_open`、
`Tstr_include`、`Tstr_exception`、`Tstr_primitive`（`external`）、
`Tstr_attribute`、`Tstr_recmodule`。

### 4.2 表达式

- `Texp_ident`
- `Texp_constant`（仅 `Const_int`、`Const_string`）
- `Texp_let`（递归或不递归）
- `Texp_function` / `Texp_apply`
- `Texp_match`（无 exception case；P1 无 `when` guard）
- `Texp_tuple`
- `Texp_construct`
- `Texp_record`（P1 无 `with` 更新；P2 才支持）
- `Texp_field`
- `Texp_ifthenelse`
- `Texp_sequence` 拒绝 → 用户应当用 `let _ =`

拒绝（带诊断）：`Texp_try`、`Texp_assert`、`Texp_lazy`、`Texp_object`、
`Texp_pack`、`Texp_letmodule`、`Texp_open`、`Texp_extension_constructor`、
`Texp_setfield`、`Texp_array`、`Texp_while`、`Texp_for`、`Texp_send`、
`Texp_new`、`Texp_override`、`Texp_letop`（`let*`）。

### 4.3 模式

- `Tpat_any`（`_`）
- `Tpat_var`
- `Tpat_constant`（int，`bool` 通过 construct）
- `Tpat_tuple`
- `Tpat_construct`
- `Tpat_record`
- `Tpat_or`

拒绝：`Tpat_alias`（P2 候选）、`Tpat_array`、`Tpat_lazy`、
`Tpat_variant`（多态变体）、`Tpat_exception`。

### 4.4 类型

- `Ttyp_var`、`Ttyp_arrow`、`Ttyp_tuple`、`Ttyp_constr`
- ADT 声明，含命名变体（可带 payload）
- 记录声明

拒绝：`Ttyp_object`、`Ttyp_class`、带 effect 的 `Ttyp_alias`、
rank 大于 1 的 `Ttyp_poly`、多态变体、GADT。

## 5. 诊断

`--json-diag` 下的 stderr 格式：

```json
{"severity":"error","code":"P1-UNSUPPORTED",
 "feature":"Texp_try",
 "loc":{"file":"foo.ml","line":12,"col":3,"end_line":12,"end_col":18},
 "message":"`try ... with` is not supported in P1; see roadmap §4"}
```

`omlz` 消费这些诊断，并按自己的风格重新渲染。

## 6. Zig 消费者：`frontend_bridge`

### 6.1 模块位置

```text
src/frontend_bridge/
├── sexp_lexer.zig
├── sexp_parser.zig
└── ttree.zig            -- 接受的 Typedtree 子集的 Zig 镜像
```

### 6.2 职责

1. 把 `zxc-frontend` 当子进程拉起（路径由 `build.zig` 解析并嵌进 `omlz`）。
2. 读它的 stdout（或 `--out` 文件）到内存。
3. 把 sexp parse 成 `ttree.Module`。
4. 把 `ttree.Module` 交给现有的 ANF lowering pass；之后管线不变。

### 6.3 它 **不是** 什么

- 不是类型检查器。无条件信任 sexp 里的 `ty`。
- 不是 name resolver。绑定上的路径已经唯一。
- 不是 OCaml 源码 parser。它只 parse sexp wire 格式。

## 7. 版本与 OCaml 升级

- 每个项目 phase 一个 OCaml minor 版本。
- `zxc-frontend` 与系统 OCaml 一同构建；`build.zig` 检测版本并做兼容性门槛。
- 不兼容的 OCaml minor（比如 5.2 → 5.3）这样应对：
  1. 更新 `src/frontend/zxc_frontend.ml` 适配新 `compiler-libs` API。
  2. 如果 sexp 形态变了，bump `zxc-frontend-version`。
  3. 在 ADR-010 里更新 pin。

## 8. 为什么不用 Lambda IR

`Lambda`（OCaml `Typedtree` 之后的内部 IR）更 lower，更接近 ANF，
理论上能省我们一些工作。我们不用它，因为：

- `Lambda` IR 是 **明确内部** 的，跨 patch 都会变。
- 它编码了对 OCaml C runtime 的假设
  （`caml_call_gc`、分配标签、字段偏移），这些我们不想继承。
- `Typedtree` 已经足够高级，让"子集强制"显而易见；
  `Lambda` 会迫使我们 *逆向* 编译器做了什么。

这与 ADR-010 的理由一致：我们要 OCaml 的 *前端*，不要它的后端或 runtime 模型。

## 9. 这份文档 **不覆盖** 的内容

- 多文件模块（P3）。
- `.mli` 签名（P3+）。
- functor 支持（按 ADR-001，范围之外）。
- 任何要求理解 OCaml C runtime 布局的事。

## 10. 已知陷阱（来自 Spike α，2026-04-27）

下面这些是构建 Spike α reader 时观察到的 `compiler-libs` API 实操陷阱。
未来 P1 frontend-bridge 的实现者一定会撞上；这里只作为导航备忘，
不是教程。每条的实证背景保留在 `docs/preflight-results.md`。

### 10.1 顶层 `let` 是 `Tstr_value`，不是 `Texp_let`

用户写的顶层 `let f x = …` 落在
`structure_item.str_desc = Tstr_value (…)`，**不是** `Texp_let`。
只有嵌套 / 表达式内的 `let` 才以 `Texp_let` 出现。
所以子集 enforcer 必须 **同时** 遍历 `structure_item.str_desc`
和 `expression.exp_desc`。
意味着：iterator 是 structure 级 walker（带
`structure_item` 和 `expr` override 的 `Tast_iterator.iterator`），
不是仅表达式 walker。漏掉这点会做出一个"对顶层绑定的 body 不做检查"的 enforcer。

### 10.2 `-bin-annot` **不是** dune 对 executable 的默认

`dune (library …)` 自动加 `-bin-annot`；`dune (executable …)` **不会**。
按 ADR-011，`omlz` 通过 `build.zig` 直接调 `ocamlc`，不走 `dune`，
所以这个 flag 是我们自己的责任。
任何文档化或实现的 OCaml 编译步骤里（见 ADR-011 的构建流程草图、
`docs/06-bpf-target.md` 工具链），`ocamlc` 命令行 **必须显式带
`-bin-annot`**，否则不出 `.cmt`，`zxc-frontend` 没东西可读。

### 10.3 `Printtyp.type_expr` 写进程级全局状态

通过 `Printtyp.type_expr` pretty-print 一个 OCaml 类型会改一个
**进程级** 环境（printing-environment 的 path table）。
对短命的一次性进程没问题 —— 这正是 `zxc-frontend` 按
ADR-010 / ADR-011 的设计；但常驻进程反复 pretty-print 类型会泄漏 identity，
跨调用产生奇怪输出。如果 bridge 以后演化成 daemon，
调用方必须用 `Printtyp.wrap_printing_env`（或等价物）在每次 pretty-print
前后做环境快照。任何"长生命 OCaml 前端 daemon"优化前先想到这点。

### 10.4 `Cmt_format.cmt_modname` 是 `Misc.modname`，目前是 `string` 的私有别名

OCaml 5.2.x 里 `Cmt_format.cmt_modname` 的类型是 `Misc.modname`，
通过 `(_ :> string)` 强制可访问到 `string` —— 它是 `string` 的私有别名。
今天编译没问题，但若未来 OCaml 把 `Misc.modname` 改成抽象类型，
**可能会断**。建议把这个强制集中到一个 helper 里
（如 `let modname_to_string : Misc.modname -> string = fun s -> (s :> string)`），
未来升级时一行修复，而不是 bridge 各处 find-and-replace。
