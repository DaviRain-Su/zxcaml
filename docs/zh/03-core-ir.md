# 03 — Core IR

> **Languages / 语言**: [English](../03-core-ir.md) · **简体中文**

Core IR 是这个编译器里 **唯一稳定的契约**。
其它一切（Surface AST、Typed AST、Lowered IR、各后端）都是内部细节，可以自由重写。
**改 Core IR 就是在改这个项目本身。**

## 1. 性质

| 性质 | 取值 |
|---|---|
| 形态 | A-Normal Form（ANF） |
| 类型 | 每个节点都带完整解析过的 `Ty` |
| Layout | 每个会引发分配的节点都带 `Layout` |
| 纯度 | P1 没有副作用（不可变、无异常） |
| 名字 | 每个 binder 都 alpha 重命名为唯一 `Symbol` |
| 源位置 | 每个节点都带 `Span`，用于诊断 |

ANF 纪律：

- 任何真正的计算都通过 `let` 命名。
- 应用、原始操作、构造子的每个操作数都是 **atom**（变量或字面量）。
- 控制流构造（`match`、`if`）的 scrutinee 也是 atom。

## 2. 数据模型（与具体语言无关的伪代码）

```text
Symbol  : interned 标识符 + 唯一 id
Span    : { file_id : u32, lo : u32, hi : u32 }

Ty :=
  | TyVar    of TyVarId
  | TyInt
  | TyBool
  | TyUnit
  | TyString
  | TyTuple  of Ty list
  | TyArrow  of Ty list * Ty       -- 多参 arrow，前端柯里化处理
  | TyAdt    of AdtId * Ty list    -- 'a list, ('a,'e) result, ...
  | TyRecord of RecordId * Ty list

Region :=
  | Arena                          -- P1：唯一合法值
  | Static                         -- 编译期常量
  | Stack                          -- 不逃逸的局部（P1 可选）
  -- 未来：Rc | Gc | Region(id)

Repr :=
  | Flat                           -- 内联值
  | Boxed                          -- 指向 region 的指针
  | TaggedImmediate                -- 小整数、bool、unit、零参 ctor

Layout := { region : Region, repr : Repr }

Atom :=
  | AVar of Symbol * Ty
  | ALit of Literal * Ty

Literal :=
  | LInt    of i64
  | LBool   of bool
  | LUnit
  | LString of string_id           -- interned，住在 `Static`

Param := { name : Symbol, ty : Ty }

Pattern :=
  | PWild
  | PVar     of Symbol * Ty
  | PInt     of i64
  | PBool    of bool
  | PUnit
  | PTuple   of Pattern list
  | PCtor    of AdtId * VariantId * Pattern list
  | PRecord  of RecordId * (FieldId * Pattern) list

Arm := { pattern : Pattern, body : Expr, span : Span }

PrimOp :=
  | IAdd | ISub | IMul | IDiv | IMod
  | IEq  | INe  | ILt  | ILe  | IGt | IGe
  | BAnd | BOr  | BNot
  | StrEq                          -- 仅 stdlib 内部，P1 内部用
  -- 未来：位运算、syscall

Expr :=
  | EAtom    of Atom
  | ELet     of { name : Symbol, ty : Ty, value : RhsValue,
                  body : Expr, span : Span }
  | EMatch   of { scrut : Atom, arms : Arm list, ty : Ty, span : Span }
  | EIf      of { cond  : Atom, then_ : Expr, else_ : Expr,
                  ty : Ty, span : Span }

RhsValue :=
  | RAtom   of Atom
  | RApp    of { fun_ : Atom, args : Atom list, ret_ty : Ty }
  | RPrim   of { op : PrimOp, args : Atom list, ret_ty : Ty }
  | RLam    of { params : Param list, body : Expr,
                 ret_ty : Ty, layout : Layout, free_vars : Symbol list }
  | RCtor   of { adt : AdtId, variant : VariantId,
                 args : Atom list, ty : Ty, layout : Layout }
  | RRecord of { record : RecordId, fields : (FieldId * Atom) list,
                 ty : Ty, layout : Layout }
  | RProj   of { record : RecordId, field : FieldId, of_ : Atom, ty : Ty }
  | RTuple  of { elems : Atom list, ty : Ty, layout : Layout }

TopDecl :=
  | TLet  of { name : Symbol, ty : Ty, value : Expr,
               is_rec : bool, span : Span }
  | TType of AdtDecl | RecordDecl

Module := { decls : TopDecl list, type_env : TypeEnv, source : SourceMap }
```

要点：

- `RApp.fun_` 是 atom，所以当 *callee* 本身是个复杂表达式时，
  ANF pass 会先 let-bind 它再用。
- `RLam.free_vars` 是闭包的 capture 列表，由 ANF 计算，
  由 `LoweringStrategy` 消费。
- `RProj` / `RRecord` 带 `RecordId`，让后端能直接算字段偏移而不必重新 typecheck。

## 3. ANF 转换规则

给定 `ttree`（OCaml `Typedtree` 的 Zig 镜像，见 `10-frontend-bridge.md`）
里的表达式 `e`，到 Core IR 的 lowering 遵循标准 ANF 规则：

```
[[ x ]]            = EAtom (AVar x)
[[ k ]]            = EAtom (ALit k)
[[ e1 e2 ]]        = let x1 = [[e1]] in
                     let x2 = [[e2]] in
                     let r  = RApp(x1, [x2]) in
                     EAtom r
[[ if c then a else b ]]
                   = let xc = [[c]] in
                     EIf(xc, [[a]], [[b]])
[[ match e with arms ]]
                   = let xs = [[e]] in
                     EMatch(xs, arms_lowered)
[[ fun p -> body ]]= let f = RLam([p], [[body]], ...) in EAtom f
[[ let x = e1 in e2 ]]
                   = ELet(x, [[e1 as RhsValue]], [[e2]])
[[ Ctor(args) ]]   = let xs = [[args]] in
                     let c  = RCtor(... xs ...) in EAtom c
```

多参构造子和 primop 会被展平 —— 参数变成一连串 `let` 绑定，
然后操作把所有 atom 一次性消费掉。

## 4. Layout 赋值（P1 规则）

ANF lowering pass 给每个 `RLam`、`RCtor`、`RRecord`、`RTuple` 分配 `Layout`。
P1 规则：

1. `LInt`、`LBool`、`LUnit` 和零参构造子拿
   `{ region = Static, repr = TaggedImmediate }`。
2. `LString` 拿 `{ region = Static, repr = Boxed }`。
3. 其它一切拿 `{ region = Arena, repr = Boxed }`。
4. （可选，P1.5）如果逃逸分析能证明某个值不离开词法作用域，
   可以把它改写成 `{ region = Stack, repr = Boxed }`。
   P1 默认禁用。

用户从来看不到这些标注。它们存在的意义，
是让 P4 区域推断能直接替换规则 3，不影响其它任何地方。

## 5. 类型环境

类型信息随 Core IR 模块一起携带，避免后端重做推断：

```text
TypeEnv := {
  adts    : map<AdtId, AdtDecl>            -- 变体、布局 hint
  records : map<RecordId, RecordDecl>      -- 字段、偏移留到后端算
  globals : map<Symbol, Ty>                -- 顶层值的类型
}

AdtDecl := {
  name     : string,
  params   : TyVarId list,
  variants : VariantDecl list,
  source   : Span,
}

VariantDecl := {
  id       : VariantId,
  name     : string,
  payload  : Ty list,                      -- 空 = 零参
}
```

字段偏移和判别符编码由后端计算，不存进 `TypeEnv`。
这是有意为之：不同后端可能选择不同编码
（比如 BPF 后端用扁平结构体偏移，解释器用宿主语言原生 tagged union）。

## 6. Pretty-print 与 IR 快照

Core IR pretty-printer 是必需品，要求：

- 确定性（字段顺序固定，不打印地址）。
- 非正式 round-trip：打印结果给人看，不用 parse 回来。
  测试通过 golden 文件比对。

推荐入口：

```
omlz check --emit=core-ir foo.ml > foo.core.txt
```

快照格式（示意）：

```
module foo
  type 'a option = | None | Some of 'a
  let head : list<'a> -> option<'a> =
    fun (xs : list<'a>) ->
      match xs with
      | [] -> let r = Ctor(option,None) [@layout Static/TaggedImm]
              in r
      | (::)(x, _) -> let r = Ctor(option,Some, x) [@layout Arena/Boxed]
                      in r
```

## 7. 稳定性承诺

- 给 `Expr`、`RhsValue`、`Pattern`、`PrimOp`、`Region`、`Repr` 加 **新变体** 是
  **小** 改动。后端遇到未知变体时必须返回结构化错误，**不能** panic。
- 改变现有变体的语义是 **破坏性** 改动，必须在同一个 commit 里更新所有后端。
- ANF 纪律（"每个操作数都是 atom"）**永不** 放松。
  如果你想把复杂表达式直接放在参数位置，先加一个 `let` 绑定。

## 8. Core IR **不携带** 的内容

- 不带源码注释或 trivia。诊断通过 `Span` 回查 Surface AST。
- ANF 临时变量上不再带超出 atom 自身 `Ty` 之外的类型。
  Core IR 不是类型检查器的草稿纸。
- 不带优化提示。P1 信任 Zig 后端的优化器。
