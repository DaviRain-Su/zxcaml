# 02 — 语法（P1 的 OCaml 子集）

> **Languages / 语言**: [English](../02-grammar.md) · **简体中文**

## 1. 定位

ZxCaml 接受 **OCaml 的严格子集**。任何被 ZxCaml 接受的程序，都会先由上游
OCaml 解析并完成类型检查；随后 ZxCaml 在 `Typedtree` 层拒绝尚未支持的节点。

P1 的 as-built 用户程序子集刻意很小：**顶层 `let` 声明，以及整数、字符串、
函数、`let`、`if`、`match`、函数应用、整数/比较原语、内置 `option` /
`result` / `list` 构造器上的表达式。** 用户自定义 `type` 声明、record、tuple、
module、exception、mutation、array、object、labelled argument 都会被拒绝。

权威实现是 `src/frontend/zxc_subset.ml`；已接受子集的 wire contract 是
`src/frontend/zxc_sexp_format.md`（当前为 `0.4`）。本文只是便于阅读的表层摘要。

文件扩展名是 `.ml`。P1 不支持 `.mli`。

## 2. 词法规则

词法由 OCaml 自己处理。P1 子集实际消费的只有：

- 十进制 `int` 字面量（`0`、`42`、`-1`），进入后端后表示为有符号 64 位整数；
- 字符串字面量，主要用于诊断和小例子；
- OCaml 接受的标识符；
- 内置 stdlib 的构造器名：`None`、`Some`、`Ok`、`Error`、`[]`、`::`。

P1 没有单独把直接写出的布尔字面量当成前端特例；比较表达式会产生供 `if` 消费的内部 bool ADT。

## 3. P1 接受的表层形式

```ocaml
(* 顶层声明：每个 let group 只能有一个 binding *)
let x = 1
let rec fact n = if n <= 1 then 1 else n * fact (n - 1)

(* 表达式 *)
let entrypoint _input =
  let xs = [1; 2; 3] in
  match xs with
  | [] -> 0
  | x :: _ -> x
```

接受的表达式类别：

| 表层形式 | 说明 |
|---|---|
| `let x = e` / `let rec f x = e` | 顶层和嵌套均可；不支持 `and` group |
| `fun x -> e` / 函数语法糖 let | desugar 后每个 lambda 只带一个参数 |
| 变量引用 | 由 OCaml 在序列化前完成解析 |
| 整数和字符串常量 | 其他常量拒绝 |
| 函数应用 | 只支持无 label、完整应用的参数 |
| `if c then a else b` | `else` 必须存在 |
| `match e with ...` | 不支持 guard；arm 按源码顺序从上到下测试 |
| 构造器 | 仅 `None`、`Some`、`Ok`、`Error`、`[]`、`::` |
| 原语运算 | `+`、`-`、`*`、`/`、`mod`、`=`、`<>`、`<`、`<=`、`>`、`>=` |

接受的模式：

| 模式 | 说明 |
|---|---|
| `_` | 通配 |
| `x` | 变量绑定 |
| `None`、`Some x`、`Ok x`、`Error e`、`[]`、`x :: xs` | P1 中构造器 payload 只支持简单通配/变量模式 |

`Some (Some x)` 这类嵌套构造器模式以及 `when` guard 属于 P2+。

## 4. P1 保留但拒绝的形式

OCaml parser 可能接受这些语法，但子集 walker 会用带位置的诊断拒绝：

```text
type  module  sig  struct  functor  open  include
exception  try  raise
mutable  ref  while  for  do  done
class  object  method  inherit  initializer
lazy  assert  external  when
records  tuples  arrays  labelled arguments  optional arguments
```

## 5. P1 程序可见的标准库类型

内置 stdlib（`stdlib/core.ml`）定义：

```ocaml
type 'a option = None | Some of 'a
type ('a, 'e) result = Ok of 'a | Error of 'e
type 'a list = [] | (::) of 'a * 'a list
```

用户程序可以构造和匹配这些值，但尚不能引入自己的 ADT；那是 P2+ roadmap 工作。

## 6. 对被拒绝 OCaml 构造的诊断

有两层诊断：

1. **语法/类型错误** 由上游 `ocamlc` 报告，`zxc-frontend` 捕获后转换成与子集错误相同的扁平 JSON 形状。
2. **子集违规** 由 `zxc-frontend` 遍历 `Typedtree` 时发现，会包含不支持的节点类型，以及已知时的 hint。

经 `omlz` 渲染后，子集违规看起来像：

```text
foo.ml:1:0: error: Tstr_type is not supported in the current ZxCaml subset; expected top-level `let` declarations ...
```

## 7. 兼容性检查

因为 `omlz` 的输入来自上游 OCaml `compiler-libs`，被接受的程序天然是合法 OCaml。
CI 仍然会对 examples corpus 运行 `omlz check`；诊断 fixture
`examples/m0_unsupported.ml` 会被该 corpus 循环刻意跳过，因为它预期失败。
