# 03 — Core IR

> **Languages / 语言**: [English](../03-core-ir.md) · **简体中文**

Core IR 是本编译器的 **唯一稳定契约**。当前 as-built 契约是
`src/core/ir.zig` 中的数据模型、`src/core/layout.zig` 中的 layout 选择，以及
`src/core/types.zig` 中的类型声明。

## 1. 属性

| 属性 | 当前 as-built 值 |
|---|---|
| 形式 | 面向 ANF 的表达式树；lowering/codegen 需要时会保持复杂计算 let-bound |
| 类型 | 每个表达式节点都带已解析的 `Ty` |
| Layout | codegen 需要的每个产值节点都带 `Layout` |
| 纯度 | 无异常、无 mutation 表达式；record 使用函数式 update |
| 名字 | 来自前端的 byte-string 名字；codegen 会为 Zig 做 sanitize |
| 源位置 | 前端诊断带位置；Core IR 节点尚未填充 source span |

Zig 模型 **没有** 把 atom 与 RHS value 拆成单独的 `Atom` / `RhsValue` 变体。
表达式变体直接持有子 `Expr` 指针，ANF/lowering pass 负责维护求值纪律。

## 2. 数据模型（`src/core/ir.zig`）

```text
Module := {
  decls             : Decl list,
  type_decls        : VariantType list,
  tuple_type_decls  : TupleType list,
  record_type_decls : RecordType list,
}

Decl :=
  | Let of Let

Let := { name, value, ty, layout, is_rec }

Expr :=
  | Lambda       of { params, body, ty, layout }
  | Constant     of { Int i64 | String string, ty, layout }
  | App          of { callee, args, ty, layout }
  | Let          of { name, value, body, ty, layout, is_rec }
  | If           of { cond, then_branch, else_branch, ty, layout }
  | Prim         of { op, args, ty, layout }
  | Var          of { name, ty, layout }
  | Ctor         of { name, args, tag, type_name?, ty, layout }
  | Match        of { scrutinee, arms, ty, layout }
  | Tuple        of { items, ty, layout }
  | TupleProj    of { tuple_expr, index, ty, layout }
  | Record       of { fields, ty, layout }
  | RecordField  of { record_expr, field_name, ty, layout }
  | RecordUpdate of { base_expr, fields, ty, layout }

Arm := { pattern : Pattern, guard : Expr option, body : Expr }

Pattern :=
  | Wildcard
  | Var    of { name, ty, layout }
  | Ctor   of { name, args, tag, type_name? }
  | Tuple  of Pattern list
  | Record of { name, pattern } list

Ty :=
  | Int | Bool | Unit | String
  | Var    of string
  | Adt    of { name, params }
  | Tuple  of Ty list
  | Record of { name, params }
  | Arrow  of { params, ret }
```

`VariantType`、`TupleType`、`RecordType` 位于 `src/core/types.zig`，并挂在
`Module` 上，供下游阶段解析构造器 tag、record 字段、具体类型参数和生成的 Zig 名字。

## 3. 构造器、record、tuple 与 pattern

前端会发出内置 stdlib 构造器和用户自定义构造器。`Ctor` 保存源码构造器名，并在可用时
保存解析后的 tag/type 元数据。零参构造器使用 tagged-immediate/static layout；带 payload
的构造器和递归 ADT payload 使用 arena-backed 表示。

Pattern 是递归的。P2 依赖这一点来表达嵌套构造器模式、tuple pattern、record pattern、
通配默认分支和 guarded arm。Guard 保存在 `Arm.guard` 上；guard 为 false 时落到后续候选 arm。

## 4. Layout 分配（`src/core/layout.zig`）

```text
Region := Arena | Static | Stack
Repr   := Flat | Boxed | TaggedImmediate
Layout := { region : Region, repr : Repr }
```

当前默认规则：

| 值类别 | Layout |
|---|---|
| 整数常量、布尔、unit 值 | `Static / Flat` 或目标等价 immediate |
| 顶层 lambda | `Arena / Flat` |
| 一等 closure record | `Arena / Boxed` |
| 字符串 | `Static / Boxed` |
| 零参构造器 | `Static / TaggedImmediate` |
| 带 payload 构造器 / list / 递归 ADT payload | `Arena / Boxed` |
| tuple 和 record | lower 成 product value；codegen 可把不逃逸 pack 保持为栈形态 |

`Stack` 是扩展点，也可用于明显不逃逸的 lowered value；用户永远不显式选择 region。

## 5. ANF 与 lowering 规则

ANF pass 把 `ttree` mirror 转成 Core IR，并保留 `let`、`match`、tuple/record 构造、
record update 的源码求值顺序。当前规则包括：

- 顶层声明变成 `Decl.Let` 和 module type declaration 表；
- 嵌套 `let` / `let rec` 变成设置了 `is_rec` 的 `Expr.Let`；
- 函数变成 `Expr.Lambda`，应用变成 `Expr.App`；
- 算术/比较运算符变成 `Expr.Prim`；
- 构造器、tuple pack、record pack、字段访问和 update 变成对应 Core 变体；
- guarded/nested match 保留递归 `Pattern` 树和可选 guard 表达式。

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
- 影响 Core IR 形状的 wire-format version bump，必须在 as-built 管线落地时同步反映到这里。

## 8. Core IR 尚未携带什么

- 源码注释或格式 trivia；
- 每个节点上的前端 source span；
- 除 `Layout` 外的优化 hint；
- Zig 标识符 sanitize 后的后端专用名字。
