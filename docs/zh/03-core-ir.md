# 03 — Core IR

> **Languages / 语言**: [English](../03-core-ir.md) · **简体中文**

Core IR 是本编译器的 **唯一稳定契约**。P1 as-built 契约就是
`src/core/ir.zig` 中的数据模型，以及 `src/core/layout.zig` 中的 layout 选择。
本文描述的是这个具体模型，而不是更大的 P2+ 形状。

## 1. 属性

| 属性 | P1 as-built 值 |
|---|---|
| 形式 | 面向 ANF 的表达式树；lowering pass 会在当前子集需要的位置保持复杂计算 let-bound |
| 类型 | 每个表达式节点都带已解析的 `Ty` |
| Layout | codegen 需要的每个产值节点都带 `Layout` |
| 纯度 | P1 无 mutation、无 exception、无 effect |
| 名字 | 来自前端的 byte-string 名字；codegen 会为 Zig 做 sanitize |
| 源位置 | 前端诊断带位置；P1 Core IR 节点没有填充 source span |

当前 Zig 模型 **没有** 把 atom 与 RHS value 拆成单独的 `Atom` / `RhsValue` 变体。
表达式变体直接持有子 `Expr` 指针，ANF/lowering pass 负责维护该子集的求值纪律。

## 2. 数据模型（`src/core/ir.zig`）

```text
Module := { decls : Decl list }

Decl :=
  | Let of Let

Let := {
  name   : string,
  value  : Expr,
  ty     : Ty,
  layout : Layout,
  is_rec : bool,
}

Lambda := { params : Param list, body : Expr, ty : Ty, layout : Layout }
Param  := { name : string, ty : Ty }

Expr :=
  | Lambda   of Lambda
  | Constant of Constant
  | App      of { callee : Expr, args : Expr list, ty : Ty, layout : Layout }
  | Let      of { name : string, value : Expr, body : Expr,
                  ty : Ty, layout : Layout, is_rec : bool }
  | If       of { cond : Expr, then_branch : Expr, else_branch : Expr,
                  ty : Ty, layout : Layout }
  | Prim     of { op : PrimOp, args : Expr list, ty : Ty, layout : Layout }
  | Var      of { name : string, ty : Ty, layout : Layout }
  | Ctor     of { name : string, args : Expr list, ty : Ty, layout : Layout }
  | Match    of { scrutinee : Expr, arms : Arm list, ty : Ty, layout : Layout }

Constant :=
  | Int    of i64
  | String of string

PrimOp := Add | Sub | Mul | Div | Mod | Eq | Ne | Lt | Le | Gt | Ge

Arm := { pattern : Pattern, body : Expr }

Pattern :=
  | Wildcard
  | Var  of { name : string, ty : Ty, layout : Layout }
  | Ctor of { name : string, args : Pattern list }

Ty :=
  | Int | Bool | Unit | String
  | Adt   of { name : string, params : Ty list }
  | Arrow of { params : Ty list, ret : Ty }
```

P1 有意没有用户自定义 type declaration、record、tuple、array、source span、
module-level `TypeEnv` 的 Core IR 变体。这些都是 P2+ 扩展；落地时必须在同一个 commit
更新所有 consumer。

## 3. 构造器和模式子集

前端只会发出内置构造器名：

```text
None | Some | Ok | Error | [] | ::
```

`None`、`[]` 这样的无 payload 构造器使用 `Static/TaggedImmediate`。
`Some x`、`Ok x`、`Error e`、`x :: xs` 这样的带 payload 构造器使用 `Arena/Boxed`。

Zig 类型中的 `Pattern` 是递归的，但 P1 前端只会发出通配、变量，以及白名单构造器上的构造器模式；嵌套构造器模式是 P2 功能。

## 4. Layout 分配（`src/core/layout.zig`）

```text
Region := Arena | Static | Stack
Repr   := Flat | Boxed | TaggedImmediate
Layout := { region : Region, repr : Repr }
```

P1 默认规则：

| 值类别 | Layout |
|---|---|
| 整数常量 | `Static / Flat` |
| unit 值和 unit-typed lambda 参数 | `Static / Flat` |
| 顶层 lambda | `Arena / Flat` |
| 一等 closure record | `Arena / Boxed` |
| 字符串 | `Static / Boxed` |
| 无 payload 构造器 | `Static / TaggedImmediate` |
| 带 payload 构造器 / aggregate | `Arena / Boxed` |

`Stack` 作为保留扩展点存在，但 P1 没有真实 escape-analysis pass 会选择它。

## 5. ANF 与 lowering 规则

ANF pass 把 `ttree` mirror 转成 Core IR，并保留 `let` 与 `match` 的源码求值顺序。
当前子集依赖这些规则：

- 顶层声明变成 `Decl.Let`；
- 嵌套 `let` 和 `let rec` 变成设置了 `is_rec` 的 `Expr.Let`；
- 函数变成 `Expr.Lambda`，应用变成 `Expr.App`；
- 算术/比较运算符变成 `Expr.Prim`；
- `if` 条件消费由比较产生的 bool ADT；
- 构造器和 match 保留 option/result/list 的源码顺序；
- match arm 从上到下测试，第一个匹配胜出。

Lowered IR（`src/lower/lir.zig`）随后显式化 arena-threaded 调用约定，并为 codegen
添加 closure-call/direct-call 信息。

## 6. Pretty-printing 与 IR snapshot

Core IR pretty-printer 必须保持确定性，因为 golden tests 会 snapshot 它的输出。使用：

```sh
zig-out/bin/omlz check --emit=core-ir foo.ml
```

打印格式只给人阅读，不作为 parser 输入。

## 7. 稳定性承诺

- 给 `Expr`、`Pattern`、`PrimOp`、`Ty`、`Region`、`Repr` 增加变体属于契约变更。
  必须同时更新 `anf`、`lower`、`interp`、`zig_codegen`、`pretty`、golden tests 和本文。
- 改变已有变体语义是 breaking，需要 ADR 或 ADR addendum。
- 当前没有 records、tuples、source spans、type-env declarations 是 P1 as-built 范围，不是遗漏。

## 8. P1 Core IR **不**携带什么

- 源码注释或格式 trivia；
- 每个节点上的前端 source span；
- 用户 type declaration 或通用 type environment；
- 除 `Layout` 外的优化 hint；
- Zig 标识符 sanitize 后的后端专用名字。
