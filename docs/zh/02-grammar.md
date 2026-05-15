# 02 — 语法（当前 OCaml 子集）

> **Languages / 语言**: [English](../02-grammar.md) · **简体中文**

## 1. 定位

ZxCaml 接受 **OCaml 的严格子集**。每个被接受的程序都会先由上游 OCaml
解析并完成类型检查；随后 ZxCaml 遍历 `Typedtree`，拒绝当前子集之外的节点。

截至当前 post-P9 baseline，用户程序子集包含顶层 `let`、mutually recursive `let rec ... and ...`
组、`external` 声明和 `type` 声明；整数、字符串、char、布尔值、unit、函数、`let`、
`if`、`match`、sequence expression、函数应用、`while` / 计数 `for` loop、整数 / 比较 / 字符串原语、`assert`、
用户自定义 ADT、嵌套 / guarded / or / alias / literal patterns、tuple、record、
字段访问、函数式 record update、受控可变 `int` array、`int` / `bool` ref cell，以及内置 `Option`、`Result`、`List`、`Map`、
`Set`、`String`、`Char`、`Crypto`、`Pubkey` stdlib 表面。

权威实现是 `src/frontend/zxc_subset.ml`；当前前端发出的 wire contract 是 sexp
**版本 `1.5`**。`src/frontend/zxc_sexp_format.md` 是更底层的 wire-contract 参考；
本文描述用户可见的子集。

文件扩展名是 `.ml`。当前编译器不支持 `.mli` 或多文件模块。

## 2. 词法规则

词法由 OCaml 自己处理。当前子集消费：

- 十进制 `int` 字面量，进入前端以下后表示为有符号 64 位整数；
- 字符串字面量；
- 布尔字面量 `true` 和 `false`；
- OCaml 接受的标识符和构造器名；
- 内置 stdlib 构造器（`None`、`Some`、`Ok`、`Error`、`[]`、`::`），以及由已接受
  `type` 声明引入的用户 ADT 构造器。

## 3. 当前编译器接受的表层形式

```ocaml
(* 用户自定义 ADT *)
type color = Red | Green | Blue
type 'a tree = Leaf of 'a | Node of 'a tree * 'a tree

(* record 和 tuple *)
type person = { name : string; age : int }

let entrypoint _input =
  let pair = (1, true) in
  let alice = { name = "alice"; age = 30 } in
  let older = { alice with age = alice.age + 1 } in
  match pair with
  | (n, keep) when keep -> n + older.age
  | _ -> 0
```

接受的表达式类别：

| 表层形式 | 说明 |
|---|---|
| `let x = e` / `let rec f x = e` / recursive `and` groups | 顶层和嵌套均可；mutually recursive groups 会保留在 sexp `1.5` 中；该分组形态最早由历史版本 `1.1` 引入 |
| `fun x -> e` / 函数语法糖 let | curried 多参数函数表示为嵌套 lambda / 多参数 arrow |
| 变量引用 | OCaml 在序列化前完成解析；`List.map` 等 stdlib 路径保持 qualified |
| 整数、字符串、char、布尔、unit 常量 | 其他常量拒绝 |
| 函数应用 | 无 label 应用，以及已接受的 stdlib / external 调用；partial/labeled/optional application 仍在范围外 |
| `if c then a else b` | `else` 必须存在 |
| `match e with ...` | 支持任意 scrutinee 表达式、嵌套构造器/tuple/record pattern 和 `when` guard |
| 构造器 | 内置 stdlib 构造器 + 用户 ADT 构造器 |
| tuple | 构造、模式解构，以及 `fst`/`snd` 投影 helper |
| record | 类型声明、构造、字段访问（`r.x`）、模式解构、函数式更新（`{ r with x = v }`） |
| 原语运算 | `+`、`-`、`*`、`/`、`mod`、bitwise ops、`=`、`<>`、`<`、`<=`、`>`、`>=`、字符串拼接 `^`，以及已支持的 string/char helper |
| `while` / 计数 `for` loop | 支持 imperative-style accumulator，lower 后不依赖 OCaml runtime |
| `int` array（ADR-015 R9.1/R9.2） | `[| 1; 2; 3 |]` literal、`Array.get` / `a.(i)`、`Array.length`、`Array.set` / `a.(i) <- v`，以及 `N` 为非负 `int` literal 时的 `Array.make N init`；element type 必须是 `int` |
| ref cell（ADR-015 R10） | element type 为 `int` 或 `bool` 时支持 `ref e`、`!r` 和 `r := v`；single-cell only，不承诺跨函数/闭包 aliasing。string、record、list、polymorphic 等 element type 会用 `E0013` 拒绝 |

接受的模式：

| 模式 | 说明 |
|---|---|
| `_` | 通配 |
| `x` | 变量绑定 |
| 构造器模式 | 零参和带 payload 的构造器，包含嵌套 payload pattern |
| tuple pattern | 固定 arity 的 tuple 解构 |
| record pattern | 命名字段，按 OCaml 接受的任意源码顺序 |
| guarded arm | `pattern when expr -> body`；guard 为 false 时落到后续 arm |
| literal/or/alias patterns | 整数 / 字符串 / char 常量、`p1 | p2`，以及前端接受的 `p as name` |

## 4. 接受的类型和 external 声明

接受：

```ocaml
type color = Red | Green | Blue
type 'a option_like = Nothing | Just of 'a
type 'a tree = Leaf of 'a | Node of 'a tree * 'a tree
type point = { x : int; y : int }
type 'a box = { value : 'a }
type pair = int * bool
```

限制：

- 不支持 GADT、多态变体、private type、type constraint 或 module signature；
- variant 声明中不支持 record constructor payload；
- 不支持普通 mutable record-field writes（`r.x <- v`，Solana `AccountFieldSet` 路径之外），即使 OCaml `Typedtree` 中能看到 record 字段可变性；
- recursive ADT 和 erased type aliases 在前端接受的范围内受支持；完整的一般递归类型推断仍刻意保持很窄。

顶层 `external name : type = "zig_symbol"` 声明受支持，用于把 Zig runtime 符号绑定成带类型的值。

## 5. 保留但拒绝的形式

OCaml parser 可能接受这些语法，但子集 walker 会用带位置的诊断拒绝：

```text
module  sig  struct  functor  open  include
exception  try  raise
普通 mutable record-field writes（`r.x <- v`，`AccountFieldSet` 之外）
instance-variable writes  override expressions
不在 R9 int-array 子集内的 array 形式（dynamic-size `Array.make`、polymorphic arrays、`Array.init`、`Array.unsafe_get`）
不支持 element type 的 `ref`（string、record、list、polymorphic）
class  object  method  inherit  initializer
lazy
whitelisted stdlib surface 之外的 labelled arguments  optional arguments  local opens
```

## 6. 程序可见的标准库

内置 stdlib（`stdlib/core.ml`）定义 `Option`、`Result`、`List`、`Map`、`Set`、`String`、
`Char`、`Crypto`、`Pubkey` 和面向 Solana 的 helper 模块。核心函数式表面包含常用函数：

- `List.length`、`List.map`、`List.filter`、`List.fold_left`、`List.rev`、
  `List.append`、`List.hd`、`List.tl`；
- `Option.map`、`Option.bind`、`Option.value`、`Option.get`、
  `Option.is_none`、`Option.is_some`；
- `Result.map`、`Result.bind`、`Result.is_ok`、`Result.is_error`、
  `Result.ok`、`Result.error`；
- `Map` / `Set` 构造和查找 helper；
- `String.length`、`String.get`、`String.sub`；
- `Char.code`、`Char.chr`；
- `Crypto.sha256`、`Crypto.keccak256`，以及 `Pubkey` 常量 / helper。

这些函数都是普通 OCaml 子集代码，由上游 OCaml 类型检查，并由同一条管线编译。

## 7. 对被拒绝 OCaml 构造的诊断

有两层诊断：

1. **语法/类型错误** 由上游 `ocamlc` 报告，`zxc-frontend` 捕获后转换成与子集错误相同的扁平 JSON 形状。
2. **子集违规** 由 `zxc-frontend` 遍历 `Typedtree` 时发现，会包含不支持的节点类型，以及已知时的 hint。

经 `omlz` 渲染后，子集违规看起来像：

```text
foo.ml:1:0: error: Texp_try is not supported in the current ZxCaml subset; exceptions are out of scope
```

## 8. 兼容性检查

因为 `omlz` 的输入来自上游 OCaml `compiler-libs`，被接受的程序天然是合法 OCaml。
CI 会对 examples corpus 运行 `omlz check`；诊断 fixture `examples/m0_unsupported.ml`
会被该 corpus 循环刻意跳过，因为它预期失败。
