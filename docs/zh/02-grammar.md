# 02 — 语法（P1 阶段的 OCaml 子集）

> **Languages / 语言**: [English](../02-grammar.md) · **简体中文**

## 1. 定位

ZxCaml 接受 **OCaml 的严格子集**。
ZxCaml 写出来的程序一定是合法 OCaml 程序；反之不成立。

**我们不定义自己的语法。** 根据 ADR-010，语法就是上游 OCaml 编译器接受的语法；
ZxCaml 限制的是 **类型检查后的 Typedtree**，不是表层语法。
权威的子集列表在
[`10-frontend-bridge.md` §4](./10-frontend-bridge.md)，用 `Typedtree` 构造子表达。

本文档仍然存在，是为了从 **人读** 的角度描述这个子集大致是什么样，
并枚举出"保留但拒绝"的关键字以便给出友好的错误信息。
**它不是真理来源；真理来源是 `10-frontend-bridge.md` §4。**

文件后缀是 `.ml`。P1 **没有** `.mli`；签名以行内类型标注的形式出现。

## 2. 词法规则

完全等同于 OCaml 的词法规范，限制如下：

- 仅 ASCII 源码（UTF-8 字符串字面量允许，但不能用作标识符字符）。
- 注释：`(* ... *)`，可嵌套。
- 数字字面量：十进制 `int`（`0`、`42`、`-1`），P1 不支持 `Int64.t`、不支持浮点。
- 布尔字面量：`true`、`false`。
- 字符串字面量：标准双引号，仅支持 `\n \r \t \\ \"` 转义。
  **P1 仅用于诊断 / stdlib 内部；不向用户暴露 runtime 字符串运算。**
- 字符字面量：P1 不支持。
- 标识符：小写字母开头（值），大写字母开头（构造子和模块名 ——
  模块名保留但模块语法是 P3 的事）。

## 3. P1 接受的保留关键字

```
let  rec  and  in  fun  function
match  with  if  then  else
type  of
true  false
```

保留但 **拒绝** 的（parser 必须给出清晰的"暂不支持"诊断，而不是普通语法错误）：

```
module  sig  struct  functor  open  include
exception  try  raise
mutable  ref  while  for  do  done
class  object  method  inherit  initializer
lazy  assert
external
when
```

## 4. 语法（EBNF，描述性 —— 非权威）

下面这份 EBNF 是这个子集的 **描述性** 草图；它便于上下文理解，
但**不是**编译器实际强制的内容。强制发生在 `Typedtree` 这一层
（见 `10-frontend-bridge.md` §4）。OCaml 编译器自身实现了真正的 parser。

```ebnf
program        ::= { top_item } EOF

top_item       ::= type_decl
                 | let_binding

(* ───── 类型声明 ───── *)

type_decl      ::= "type" [ type_params ] LIDENT "=" type_rhs

type_params    ::= "'" LIDENT
                 | "(" "'" LIDENT { "," "'" LIDENT } ")"

type_rhs       ::= variant_rhs
                 | record_rhs
                 | type_expr                      (* 类型别名 *)

variant_rhs    ::= [ "|" ] variant_case { "|" variant_case }
variant_case   ::= UIDENT [ "of" type_expr_tuple ]

record_rhs     ::= "{" field_decl { ";" field_decl } [ ";" ] "}"
field_decl     ::= LIDENT ":" type_expr

(* ───── 类型表达式 ───── *)

type_expr      ::= type_expr_tuple
type_expr_tuple::= type_expr_arrow { "*" type_expr_arrow }
type_expr_arrow::= type_expr_app { "->" type_expr_app }   (* 右结合 *)
type_expr_app  ::= type_atom { type_atom }                (* 后缀应用：'a list *)
type_atom      ::= "'" LIDENT
                 | LIDENT
                 | "(" type_expr ")"

(* ───── 值声明 ───── *)

let_binding    ::= "let" [ "rec" ] binding_chain
binding_chain  ::= binding { "and" binding }
binding        ::= pattern { param } [ ":" type_expr ] "=" expr
                                                          (* 函数糖：
                                                             let f x y = e
                                                             ≡ let f = fun x -> fun y -> e *)
param          ::= simple_pattern

(* ───── 表达式 ───── *)

expr           ::= "let" [ "rec" ] binding_chain "in" expr
                 | "fun" param { param } "->" expr
                 | "function" match_arms
                 | "if" expr "then" expr [ "else" expr ]
                 | "match" expr "with" match_arms
                 | infix_expr

match_arms     ::= [ "|" ] match_arm { "|" match_arm }
match_arm      ::= pattern [ "when" expr ]   (* P1：碰到 "when" 给出诊断并拒绝 *)
                   "->" expr

infix_expr     ::= app_expr { binop app_expr }

binop          ::= "+" | "-" | "*" | "/" | "mod"
                 | "=" | "<>" | "<" | "<=" | ">" | ">="
                 | "&&" | "||"
                 | "::"                                   (* 列表 cons *)

app_expr       ::= simple_expr { simple_expr }            (* 左结合并置 *)

simple_expr    ::= LIDENT
                 | UIDENT [ simple_expr ]
                 | INT_LIT
                 | "true" | "false"
                 | STRING_LIT
                 | "(" ")"
                 | "(" expr { "," expr } ")"
                 | "[" [ expr { ";" expr } [ ";" ] ] "]"
                 | "{" record_field_init { ";" record_field_init } [ ";" ] "}"
                 | simple_expr "." LIDENT

record_field_init ::= LIDENT "=" expr

(* ───── 模式 ───── *)

pattern        ::= or_pattern
or_pattern     ::= cons_pattern { "|" cons_pattern }
cons_pattern   ::= app_pattern { "::" app_pattern }       (* 右结合 *)
app_pattern    ::= UIDENT [ simple_pattern ]
                 | simple_pattern

simple_pattern ::= "_"
                 | LIDENT
                 | UIDENT
                 | INT_LIT
                 | "true" | "false"
                 | "(" ")"
                 | "(" pattern { "," pattern } ")"
                 | "[" [ pattern { ";" pattern } [ ";" ] ] "]"
                 | "{" field_pattern { ";" field_pattern } [ ";" ] "}"

field_pattern  ::= LIDENT [ "=" pattern ]
```

## 5. 运算符优先级（P1）

从低到高：

| 级别 | 运算符 | 结合性 |
|---|---|---|
| 1 | `||` | 右 |
| 2 | `&&` | 右 |
| 3 | `=`, `<>`, `<`, `<=`, `>`, `>=` | 左 |
| 4 | `::` | 右 |
| 5 | `+`, `-` | 左 |
| 6 | `*`, `/`, `mod` | 左 |
| 7 | 函数应用 | 左 |
| 8 | `.field` | 后缀 |

实现：用 Pratt parser，按上表配置。

## 6. P1 用户程序可见的标准库类型

定义在 `stdlib/core.ml` 中（用这个子集本身写，详见 `07-repo-layout.md`）：

```ocaml
type 'a option = None | Some of 'a
type ('a, 'e) result = Ok of 'a | Error of 'e
type 'a list = []  | (::) of 'a * 'a list
```

`list` 用 OCaml 内置的语法糖 `[1; 2; 3]` 和 `x :: xs`，
parser 在构造 AST 时把它们脱糖成构造子应用。

## 7. 对被拒绝 OCaml 构造的诊断

分两层：

1. **纯语法错误** 由上游 OCaml 编译器报告（通过 `zxc-frontend`）。
   `omlz` 用自己的诊断风格重新渲染，但不重新编写：
   ```
   error: Syntax error
     --> foo.ml:5:14
   ```
2. **子集违规** 由 `zxc-frontend` 在遍历 `Typedtree` 时发现。形如：
   ```
   error[P1-UNSUPPORTED]: `try ... with` is not supported in P1
     --> foo.ml:12:3
     note: ZxCaml accepts a subset of OCaml; this construct is
           planned for a later phase, see docs/08-roadmap.md
   ```

两类都由 `zxc-frontend` 以 JSON（`--json-diag`）形式产出，
由 `omlz` 统一渲染。

## 8. 兼容性检查

在 ADR-010 下，子集漂移在结构上不可能：上游 OCaml 编译器就是 parser /
类型检查器，因此 `omlz` 接受的程序按定义就是合法 OCaml。
**不需要**额外的正确性参考工具。

CI 仍然会做的：

```sh
# 每个 example 和 stdlib 文件都必须能在锁定的 OCaml 版本上类型检查通过
# （这已经被 omlz 自身的构建间接保证了）。
for f in stdlib/*.ml examples/*.ml; do
    omlz check "$f"
done
```

只要 `omlz check` 成功，输入按定义就是合法 OCaml。
