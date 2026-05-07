# 16 — omlz fmt 格式化器

> **Languages / 语言**: [English](../16-omlz-fmt.md) · **简体中文**
>
> **范围：** Milestone M-FMT 与 M-FMT-2 共同交付的 canonical `omlz fmt`
> 源码格式化器、CLI 契约、面向编辑器的 LSP formatting 方法，以及
> bytewise idempotency 保证。
>
> **相关文档：** [`docs/lsp.md`](../lsp.md)、
> [`docs/diagnostics.md`](../diagnostics.md)、
> [`tests/omlz_fmt_subcommand_test.zig`](../../tests/omlz_fmt_subcommand_test.zig)、
> [`tests/omlz_fmt_golden_test.zig`](../../tests/omlz_fmt_golden_test.zig)、
> [`runtime/lsp/test_harness.py`](../../runtime/lsp/test_harness.py)。

## 1. 定位

`omlz fmt` 用来格式化普通的 ZxCaml `.ml` 源码。
它是 developer-experience surface，不是新的语言特性。
它不改变 parsing、type checking、Core IR、lowering、codegen 或 runtime 行为。
formatter core 位于 `src/frontend/fmt.zig`。
CLI wrapper 位于 `src/omlz/fmt.zig`。
LSP 集成位于 `src/lsp/lsp_main.zig`。
formatter core 由 commit `40a9e22` 引入。
CLI subcommand 由 commit `72a0b1a` 引入。
golden idempotency corpus 由 commit `50e5346` 引入。
LSP formatting 方法由 commit `09b1a7d` 引入。
同样的 input bytes 会得到同样的 formatted output bytes。
输出目标是稳定、朴素、容易 review。
formatter 更看重 canonical whitespace，而不是保留每一种局部 style。
formatter 会保留作者写下的 comment 文本。
formatter 是 fixed point：已经格式化的输出再次格式化不应变化。
这个 fixed-point 规则是 editors 和 CI 共同依赖的契约。

## 2. 设计目标

保持 `.ml` 作为唯一源码语言。
让 CLI 和 LSP 共用同一个 formatter core。
避免 editor-specific 的格式化行为。
所有缩进都使用两个空格。
输出缩进使用 spaces，不使用 tabs。
去掉行尾 horizontal whitespace。
始终写入 final newline。
让顶层 declarations 的视觉结构保持可预测。
不重排 declarations。
不重命名 identifiers。
不规范化 comment 内部文本。
不插入源文件中不存在的语义代码。
让 file、directory、stdin、editor formatting 使用同一套规则。
让 formatter failure 安全退出：CLI 报错，LSP 返回 no edits。
保持实现足够小，可以在 `omlz-lsp` 内 in process 运行。
项目选择 conservative style，而不是大型配置面。

## 3. Formatter 模型

核心 formatter 是 line-oriented、token-stream based 的实现。
它会 token 化 identifiers、numbers、strings、chars、comments、operators、punctuation。
它保留 string literal bytes。
它保留 char literal bytes。
它保留 comment body bytes。
它会 trim 每行右侧的 spaces、tabs、carriage returns。
它在处理文档时保留 blank lines。
文档末尾会移除 trailing whitespace。
然后追加且只追加一个 newline。
core formatter 本身不运行 OCaml frontend。
CLI 会在 formatting 前运行同一类轻量 lexical malformed-input check。
LSP 路径在返回 edits 前使用轻量 structural malformed-input check。
这种拆分让 formatting 保持快速，并把 semantic diagnostics 留给 `check`、`build`、`run` 和 `test`。
当前 formatter 不是完整的 OCaml AST pretty-printer。
所谓 AST-faithful，是指它不会有意改变程序含义。
更精确地说，它是 conservative token-stream canonicalization。

## 4. Canonical layout 规则

每层缩进是两个空格。
缩进不会输出 tabs。
顶层 `let` 从 column zero 开始。
顶层 `let rec` 从 column zero 开始。
顶层 `let%test_unit` 和 `let%test_prop` 从 column zero 开始。
顶层 `type` 从 column zero 开始。
顶层 `external` 从 column zero 开始。
顶层 declaration 如果以 `=` 结束，后续缩进增加两个空格。
包含 `match` 的行可能让后续缩进增加两个空格。
`match ... with` 行会让后续缩进增加两个空格。
以 `|` 开头的 match arm 保持当前 match-arm indentation。
以 `in` 开头的行会在可能时减少两个空格缩进。
以 `else` 开头的行会在可能时减少两个空格缩进。
以 `then` 结束的行会让后续缩进增加两个空格。
以 `else` 结束的行会让后续缩进增加两个空格。
以 `=` 结束的行会让后续缩进增加两个空格。
短的 `let ... in ...` chain 在能放进一行时保持一行。
如果 `let ... in ...` chain 会超过 100 columns，会在 `in` 前换行。
function application 在包含缩进后不超过 100 columns 时保持一行。
长 application 会按 word boundary 换行。
continuation lines 使用当前缩进再加两个空格。

## 5. Token spacing 规则

operators 两侧会有空格。
formatter 输出 `x + y`，而不是 `x+y`。
formatter 输出 `a = b`，而不是 `a=b`。
formatter 输出 `x -> y`，而不是 `x->y`。
commas 和 semicolons 前面没有空格。
后面还有 token 时，commas 和 semicolons 后面有一个空格。
closing delimiters `)`、`]`、`}` 前面没有空格。
opening delimiters `(`、`[`、`{` 在 non-punctuation token 后面可能有一个前导空格。
field-selection dots 两侧没有空格。
相邻 identifiers 之间有一个空格。
numbers 与 identifiers 相邻且 tokenization 需要时会有一个空格。
comments 会强制和周围 token 用空格分隔。
inline comments 会在 formatted code 后用一个空格重新接上。
comment text 本身保持 verbatim。
string escapes 保持 verbatim。
character escapes 保持 verbatim。
formatter 不会 reflow docstrings。
formatter 不会按列对齐 tables 或 records。
formatter 不会做 semantic parenthesis minimization。
parentheses 会作为 source tokens 保留。

## 6. Comments 与 attributes

block comments 被当作 opaque text 保留。
扫描时会识别 nested comment delimiters。
处在 multi-line comment 内部的行，在 right-trim 后原样输出。
以 `(*` 开头的行，在 right-trim 后原样输出。
只有当 inline `(* ... *)` 出现在 strings 和 chars 外部时，才会从 code 中切分出来。
inline comment 之前的 code 会进行 token formatting。
inline comment bytes 随后重新接上。
formatter 不会 wrap long comments。
formatter 不会规范化 comments 内部 whitespace。
formatter 不会翻译 comments。
形如 `let%...` 的 attributes 被保留为 top-level starts。
`let%test_unit` 格式化后不会丢失 percent attribute。
`let%test_prop` 格式化后不会丢失 percent attribute。
golden corpus 包含 `let_test_unit` 覆盖。
inline tests 包含 `let%test_prop` preservation case。
当 comment layout 很重要时，应 format 一次并人工 review diff。
当 comments 内包含代码示例时，不要期待 formatter 进入 comment 内部继续格式化。

## 7. CLI quickstart

先构建工具。

```sh
./init.sh
zig build
```

格式化一个文件到 stdout，不修改文件。

```sh
./zig-out/bin/omlz fmt examples/solana_hello.ml
```

检查一个文件是否已经格式化。

```sh
./zig-out/bin/omlz fmt --check examples/solana_hello.ml
```

原地 rewrite files。

```sh
./zig-out/bin/omlz fmt --write examples/solana_hello.ml
```

从 stdin 读取源码并把 formatted source 写到 stdout。

```sh
printf 'let x=1\n' | ./zig-out/bin/omlz fmt --stdin
```

给 tooling 使用 JSON summaries。

```sh
./zig-out/bin/omlz fmt --check --format=json examples/solana_hello.ml
```

## 8. CLI options

`--check` 会比较 formatted output 与 input bytes。
`--check` 在所有 input 已格式化时 exit `0`。
`--check` 在任意 input 会变化时 exit `1`。
text mode 下，`--check` 会把 changed paths 写到 stderr。
`--write` 会把 changed file inputs 原地重写。
所有写入成功时，`--write` exit `0`。
`--stdin` 从 standard input 读取单个 source document。
text mode 下，`--stdin` 把 formatted text 写到 stdout。
`--stdin` 不能和 positional paths 组合。
`--stdin` 不能和 `--check` 组合。
`--stdin` 不能和 `--write` 组合。
`--format=text` 是默认 text-oriented output mode。
`--format=json` 每个 processed input 输出一个 JSON object。
JSON object 包含 `path`、`changed`、`original_bytes`、`formatted_bytes`。
`--no-color` 在 malformed-input diagnostics 输出时关闭 ANSI color。
positional file input 会格式化该文件。
positional directory input 会递归收集 `*.ml` 文件。
directory results 在 processing 前按 lexicographic order 排序。
unsupported options exit `2`。
CLI 遇到 lexical malformed OCaml input 时 exit `2`，因为 `analyze` guard 失败。
missing files exit `2`。

## 9. Exit codes 与 automation

Exit code `0` 表示命令成功完成。
默认 file mode 中，`0` 表示 formatted text 已打印。
`--write` 中，`0` 表示写入完成或无需写入。
`--stdin` 中，`0` 表示 stdin 已成功格式化。
`--check` 中，`0` 表示没有 input 会变化。
Exit code `1` 专门表示 `--check` 发现可重新格式化的 input。
Exit code `1` 不用于 parse errors。
Exit code `2` 表示 usage、file 或 malformed-input failure。
CI 应运行 `omlz fmt --check`，并把 `1` 当作 style failure。
CI 应把 `2` 当作 tool 或 source validity failure。
pre-commit hooks 在 developer-owned working tree 中应优先使用 `--write`。
bots 需要 machine-readable summaries 时应优先使用 `--check --format=json`。
有 JSON summaries 可用时，shell scripts 不应解析 human diagnostics。
检查 directories 时，传入 directory path，让 `omlz fmt` 自己递归 `.ml` files。
检查 generated files 时，先生成，再 format，并只比较一次 bytes。

## 10. Idempotency 保证

formatter 承诺 bytewise idempotency。
需要满足的等式是 `format(format(source)) == format(source)`。
这个保证针对 bytes，而不仅是视觉相似。
formatter 始终写入一个 final newline，所以 fixed point 也包含这个 newline。
formatter 会在到达 fixed point 前去掉 trailing whitespace。
`src/frontend/fmt.zig` 中有 inline double-apply tests。
`tests/golden/fmt/` 下有十一组 golden snapshot pairs。
golden test 会格式化每个 `*.input.ml` 并与 `*.expected.ml` 比较。
同一个 golden test 还会格式化每个 `*.expected.ml` 并要求 bytes 不变。
十一组 cases 覆盖 simple lets。
十一组 cases 覆盖 let-in chains。
十一组 cases 覆盖 match expressions。
十一组 cases 覆盖 mutual recursion。
十一组 cases 覆盖 `let%test_unit`。
十一组 cases 覆盖 comments。
十一组 cases 覆盖 deeply nested expressions。
十一组 cases 覆盖 multi-argument functions。
十一组 cases 覆盖 record patterns。
十一组 cases 覆盖 binding-position record destructuring。
十一组 cases 覆盖 string escapes。
editors 依赖这个保证避免 repeated format churn。
CI 依赖这个保证保持 `--check` 稳定。

## 11. LSP integration

`omlz-lsp` 支持 `textDocument/formatting`。
`omlz-lsp` 支持 `textDocument/rangeFormatting`。
server 在 `initialize` 时声明 document formatting provider capability。
server 在 `initialize` 时声明 document range formatting provider capability。
formatting 使用通过 `didOpen` 打开或通过 `didChange` 更新的 in-memory document。
formatting 不会 fork `omlz fmt`。
formatting in process 调用共享的 `src/frontend/fmt.zig` core。
whole-document formatting 在 document unchanged 时返回 empty edit list。
whole-document formatting 在 document changed 时返回一个替换全文的 `TextEdit`。
range formatting 会解析请求中的 LSP range。
range formatting 只格式化 selected byte span。
invalid ranges 会让 range formatting 返回 empty edit list。
malformed selected text 会让 range formatting 返回 empty edit list。
如果原 selection 没有 line break，range formatting 会移除 formatter 追加的 final newline。
malformed full-document formatting 返回 empty edit list，而不是 JSON-RPC error。
runtime harness 检查 whole-document formatting。
runtime harness 检查 range formatting。
runtime harness 检查 malformed formatting。
runtime harness 检查五次 measured rounds 的 median formatting latency。
FMT latency budget 是 500 LOC 文件 p50 不超过 30 ms。

## 12. Editor usage

使用 [`docs/lsp.md`](../lsp.md) 中记录的同一个 `omlz-lsp` binary。
editors 应发送标准 LSP formatting requests。
为了清晰，editors 应传 `tabSize = 2` 和 `insertSpaces = true`。
formatter 当前忽略 editor-specific style options，并使用 canonical rules。
这是有意设计，目的是让所有 editors 产生同样的 bytes。
保存文件时使用 whole-document formatting。
编辑中的小范围清理使用 range formatting。
不要期待 range formatting 重新缩进未选中的 surrounding context。
不要期待 LSP formatting 显示 compiler diagnostics。
diagnostics 仍通过 document sync 后的 `publishDiagnostics` 到达。
如果 document syntactically malformed，diagnostics 可能报告问题，而 formatting 返回 no edits。
如果 editor 收到 empty edit list，应保持 buffer 不变。
如果 selection 不包含 trailing newline，range formatting 会保留这种形态。
repository-wide cleanup 应使用 CLI，而不是手动打开每个文件。

## 13. Philosophy: rustfmt、prettier 与 ZxCaml

`rustfmt` 是面向单一语言生态、贴近 compiler 的 formatter。
`prettier` 是覆盖多种 web formats 的 syntax-tree printer。
`omlz fmt` 借鉴二者共同的 fixed-point expectation。
像 `rustfmt` 一样，它希望无聊到团队不再争论 whitespace。
像 `rustfmt` 一样，它随 toolchain 提供，而不是独立 style package。
像 `prettier` 一样，它偏向少量一致的 layout choices。
不同于 `prettier`，它不试图支持很多无关语言。
不同于 `prettier`，它不暴露大量 style configuration surface。
不同于 `rustfmt`，它目前还不是覆盖每个 construct 的 deep AST rewrite。
ZxCaml 的优先级是 tokenizable OCaml source 的 deterministic formatting。
formatter 对 comments 和 partial ranges 保持 conservative。
100-column rule 是 wrapping trigger，不保证每个输出行都短于 100 columns。
two-space indent 是 canonical，不可配置。
formatter 让 OCaml source 对 OCaml developers 保持熟悉。
formatter 避免引入 Solana-specific layout conventions。
formatter 最适合理解为 project style contract。
project style contract 由 `omlz fmt --check` enforce。
editor style contract 由 `textDocument/formatting` 提供。

## 14. Common pitfalls

不要组合 `--check` 和 `--write`。
CLI 会用 exit code `2` 拒绝这个组合。
不要组合 `--stdin` 和 positional files。
CLI 会用 exit code `2` 拒绝这个组合。
不要期待 `--stdin --check` 可用。
check workflows 请使用临时文件或 direct file mode。
不要期待 formatter 校验完整 OCaml syntax 或 ZxCaml subset。
CLI 在 formatting 前只检查 lexical malformed-input cases。
LSP 路径对 structurally malformed text 返回 no formatting edits。
不要期待 comments 被 reflow。
长 comments 会保持长 comments。
不要期待 record fields 或 table-like comments 自动对齐。
formatter 规范化 spacing、indentation、wrapping，不做 semantic alignment。
不要期待 editor options 改变 indentation width。
永远使用两个空格。
不要期待 range formatting 修复 surrounding lines。
只有 selected span 会被替换。
不要期待 directory formatting 包含非 `.ml` 文件。
只会收集以 `.ml` 结尾的文件。
不要把 `--check` 的 exit code `1` 当成 compiler error。
它表示 formatting 会改变文件。

## 15. Review checklist

fresh checkout 中先运行 `zig build`，再调用 installed CLI。
提交 source changes 前，对 touched files 运行 `omlz fmt --check`。
bot 需要 byte counts 或 changed flags 时使用 `--format=json`。
从 formatter CLI 收集 deterministic parse diagnostics 时使用 `--no-color`。
comment-heavy diffs 需要人工 review。
修改 generators 后要 review generated `.ml` files。
大规模 refactor 前优先使用 whole-document formatting。
小的 editor selection cleanup 使用 range formatting。
确认第二次 formatter run 不产生 diff。
如果第二次运行仍改变 bytes，应按 idempotency contract 提 bug。
如果 LSP formatting 对有效但未格式化源码返回 no edits，请用 `omlz fmt` 对比同一份源码。
如果 CLI formatting 成功但 LSP formatting 不成功，请检查 structural malformed-input checks 和 LSP ranges。
如果 `--check` exit `2`，先修复 malformed literals、未结束 comments 或 missing paths，再调查 style。
如果 `--check` exit `1`，运行 `--write`，或检查 default mode 的 stdout。
formatter changes 应保持 focused commits，方便 review style churn。
除非 feature 明确要求，不要把 formatter-only rewrites 和 semantic compiler work 混在一起。

## 仅格式化模式（与子集检查器解耦）

M-FMT-2 把 `omlz fmt` 调整为真正的 format-only surface。
现在，只要输入能够被 formatter lexer token 化，formatter 就会尝试格式化。
输入不再必须是一个可由 ZxCaml subset 编译的程序。
这个边界是有意设计的：formatting 是 whitespace 操作，不是 buildability proof。
在 M-FMT-2 之前，`omlz fmt` 会在 pretty-printing 前调用 frontend subset validator。
这意味着某个文件即使能被 token-stream formatter 安全格式化，也可能先被 `fmt` 拒绝。
最典型的问题是 binding-position record destructuring。
普通 OCaml 源码 `let manhattan {x;y}=x+y` 对 formatter 来说 lexical structure 很清楚。
但 full subset checker 仍会拒绝这个 binding pattern，因为当前 compiler pipeline 还没有 lowering 该 construct。
于是用户只是请求 whitespace formatting，却收到了 semantic compiler-subset failure。
这次解耦移除了这个不匹配。
`src/omlz/fmt.zig` 不再为 `fmt` happy path 运行完整的 `validateFile`。
`src/frontend/fmt.zig` 现在暴露 `analyze(source) !void`，作为 `formatAlloc` 前面的 guard。
`analyze` 有意保持 lex-only。
它复用 formatter scanner 中处理 strings、char literals、comments 的路径。
它保留 automation 已经依赖的 malformed-input exit-2 contract。
它不做 type-check。
它也不判断某个 construct 是否被 ZxCaml backend 支持。
完整 subset validator 仍然由 semantic commands 运行，例如 `omlz check`、`omlz build`、`omlz run` 和 `omlz test`。
这些命令仍然是证明文件能穿过 compiler pipeline 的正确入口。
`omlz fmt` 现在只负责为更广的 OCaml syntax 规范化 whitespace。

示例 1：binding-position record patterns 现在可以格式化。

```ocaml
let manhattan {x;y}=x+y
```

会格式化为 M-FMT-2 golden 锁定的 canonical form：

```ocaml
let manhattan {x; y} = x + y
```

示例 2：module-shaped source 可以先格式化，再决定它是否是 ZxCaml build target。

```ocaml
module M=struct let x=1 let y=x+1 end
```

formatter 会把 token spacing 规范化，方便 review；module declarations 是否可 build 仍是 build/run subset question。

```ocaml
module M = struct let x = 1 let y = x + 1 end
```

示例 3：labelled arguments、class declarations、GADT declarations 不会再仅仅因为超出当前 backend subset 而被 `fmt` 拒绝。

```ocaml
let dist ~x ~y=x+y
type _ witness = Int : int witness
class counter = object val mutable n=0 method bump=n<-n+1 end
```

formatter 会把这些内容当成 tokenizable OCaml，并规范化 identifiers、operators、punctuation 周围的 spacing。
这些 declarations 能否编译到 Solana BPF，仍由 compiler commands 回答，而不是由 `fmt` 回答。
这样一来，`fmt` 可以用于 mixed OCaml workspaces、正在编写中的 examples，以及包含 non-ZxCaml helper code 的 editor buffers。

Malformed input 仍然 exit `2`。
canonical malformed case 是未结束的 string literal：

```ocaml
let s = "unterminated
```

这种情况下，`analyze` 会在接受任何 formatted output 之前报告 lexical error。
同样的规则也适用于未结束 char literals 和未结束 block comments。
关键边界是 lexical tokenization：malformed tokens 会失败，unsupported-but-tokenizable OCaml 会格式化。

迁移说明：如果 tools/scripts 过去把 `omlz fmt` 当作“这个文件是否属于 ZxCaml subset”的代理，应切换到 semantic gate。
可以使用 `omlz check`、由 wrapper 提供时的 `omlz build --check`，或者与你实际 artifact 对应的 `omlz build|run|test` 命令。
`omlz fmt --check` 应只用于 style enforcement。
M-FMT-2 之后，`fmt --check` 成功只表示“bytes 已符合 formatter style”；它不再表示“program 已被 ZxCaml subset checker 接受”。

## Phase 19 — corpus expansion (M-FMT-3)

M-FMT-3 在 P17 / F-FMT2-1 解除 `omlz fmt` 与完整 subset checker 的绑定之后，扩展了 formatter corpus。
那次变更让 formatting 回到 lexical token-stream 操作。
只要 OCaml 输入能够 token 化，即使暂时不是 backend 可编译的 ZxCaml subset，`fmt` 也不应先拒绝它。
因此，本阶段需要把更多普通 OCaml 形态纳入 golden 证据。
这次扩展的目标是锁定现有行为，而不是修改 formatter 行为。
formatter source 在本阶段保持冻结。
新增 golden 用来证明既有 spacing、indentation 与 newline 规则能覆盖更宽的 OCaml syntax。
每个 expected file 都只用 `./zig-out/bin/omlz fmt INPUT > EXPECTED` 捕获一次。
随后 `tests/omlz_fmt_golden_test.zig` 会把 expected file 当作 fixed point 检查。
五个对应 commit 已写入 `CHANGELOG.md` 的 `### Added — fmt corpus expansion (M-FMT-3)` 小节。
第一个 golden 是 `gadt_decl`。
它的 input 锁定紧凑写法的 GADT declaration：

```ocaml
type _ witness=
|Int:int witness
|Bool:bool witness
```

它的 expected output 证明 constructor bars 与 result-type colons 的 spacing 是稳定的：

```ocaml
type _ witness =
  | Int : int witness
  | Bool : bool witness
```

第二个 golden 是 `module_decl`。
它的 input 覆盖普通 module declaration 和紧凑 bindings：

```ocaml
module M=struct
let x=1
let y=x+1
end
```

它的 expected output 保留 module 外壳，同时规范化 token spacing：

```ocaml
module M = struct
let x = 1
let y = x + 1
end
```

第三个 golden 是 `poly_variant`。
它的 input 覆盖 polymorphic variant constructors：

```ocaml
type color=
|`Red
|`Green
|`Blue of int
```

它的 expected output 保留 backtick constructors，并规范化每一行 variant：

```ocaml
type color =
  | `Red
  | `Green
  | `Blue of int
```

第四个 golden 是 `functor_decl`。
它的 input 覆盖带 compact signature 参数的 functor：

```ocaml
module F(X:sig val x:int end)=struct
let y=X.x+1
end
```

它的 expected output 证明 formatter 会规范化参数、signature、field access 与 body expression：

```ocaml
module F (X : sig val x : int end) = struct
let y = X.x + 1
end
```

第五个 golden 是 `class_decl`。
它的 input 覆盖 class declaration 和 object body：

```ocaml
class counter=object
val mutable n=0
method bump=n+1
end
```

它的 expected output 会规范化 class、field 与 method 的 spacing：

```ocaml
class counter = object
val mutable n = 0
method bump = n + 1
end
```

`class_decl` 同时把 snapshot floor 提升到 `snapshots.len >= 16`。
这个 floor 用来防止 expanded corpus 被意外删减。
trailing-newline contract 仍适用于每一个 `*.expected.ml` 文件。
formatter 会去掉 trailing whitespace，然后且只然后追加一个 `\n`。
文件末尾不能没有 newline。
文件末尾也不能出现两个 newline。
这很重要，因为 idempotency 是 bytewise 契约，而不只是视觉上相同。
M-FMT-3 的 off-limits 规则同样关键。
`src/frontend/fmt.zig` 由 `FMT3-LEX-GUARD-UNCHANGED-001` 锁定。
`src/omlz/fmt.zig` 也属于同一个 guard 的范围。
M-FMT-3 只负责文档和 corpus 证据，不修改 formatter implementation。
已知的 lex-level warts 继续放在 `TD-FMT-LEX-WARTS` 下延后处理。
这个 cluster 包含 labelled args、optional args、poly type vars，以及 dense `let%lwt` input。
这些修复应进入未来的 M-FMT-FIXES milestone。
更新本 corpus 时不要顺手修掉它们。
本阶段的正确做法是如实记录当前 formatter output，并让未来 work 有意识地改变它。

## 第 20 阶段 — lex wart fixes (M-FMT-FIXES)

M-FMT-FIXES 关闭了第 19 阶段末尾记录的 `TD-FMT-LEX-WARTS` cluster。
这一次和 M-FMT-3 不同，不只是新增 corpus，而是有意修正 formatter lexer 与 spacing 规则。
相关实现 commit 是 `d4a9974`、`b3976e3`、`b77d92a` 和 `41bce59`。
每个 wart 都对应 `tests/golden/fmt/` 下的一组 golden input / expected 文件。
每个 expected file 都通过 `./zig-out/bin/omlz fmt` 捕获，然后由 bytewise idempotency test 固定下来。
`tests/omlz_fmt_golden_test.zig` 的 snapshot registry 现在包含二十个 formatter cases。
安全下限同步提高为 `snapshots.len >= 20`，旧的 `>= 16` floor 不再可能掩盖第 20 阶段 fixture 被误删。

第一个 wart 是 `poly_type_var`。
本阶段之前，`type 'a box = Box of 'a` 会被误判为未结束的 character literal。
命令在产生 formatted output 之前就以 `UnterminatedChar` 失败。

```ocaml
(* M-FMT-FIXES 之前：exit 2, UnterminatedChar *)
type 'a box = Box of 'a
```

`d4a9974` 之后，apostrophe 开头的 type variable 会和 character literal 分开 token 化。
固定后的 expected output 保持普通 OCaml 写法，并且只有一个 trailing newline。

```ocaml
type 'a box = Box of 'a
```

第二个 wart 是 `labelled_args`。
本阶段之前，相邻 labelled parameters 之间需要的空格可能被吞掉。
错误输出是 `let f~x~y = x + y`，函数名和 labels 在视觉上粘在一起。

```ocaml
(* M-FMT-FIXES 之前的输出 *)
let f~x~y = x + y
```

`b3976e3` 之后，`~ident` 会作为一个 label token 保留，同时普通 word-to-word spacing 仍会分隔 arguments。
新的 golden output 稳定且容易 review。

```ocaml
let f ~x ~y = x + y
```

第三个 wart 是 `optional_args`。
本阶段之前，带 default expression 的 optional binder 会在 `?` 后被拆开，又在下一个 argument 前丢失空格。
错误输出是 `let f ? (x = 1)y = x + y`。

```ocaml
(* M-FMT-FIXES 之前的输出 *)
let f ? (x = 1)y = x + y
```

`b77d92a` 之后，窄化的 `?(...)` binder scanner 会保留 optional-argument token shape。
后面的普通 argument 与它之间保留且只保留一个空格。

```ocaml
let f ?(x = 1) y = x + y
```

第四个 wart 是 `ppx_lwt`。
本阶段之前，dense PPX let input 会保留 `let%lwt` token，但把 `) in` keyword boundary 压成 `)in`。
错误输出是 `let%lwt x = fetch (y)in return (x)`。

```ocaml
(* M-FMT-FIXES 之前的输出 *)
let%lwt x = fetch (y)in return (x)
```

`41bce59` 之后，formatter 使用 scout report 建议的 PPX-local keyword-boundary 规则。
这能修复 dense `let%lwt` 行，同时不需要重新 bless 旧的非 PPX goldens。

```ocaml
let%lwt x = fetch (y) in return (x)
```

因此，第 20 阶段把这些问题从“known deferred”变成“已由 regression suite 覆盖”。
后续 formatter work 应继续保留这四个 input 在 golden list 中，并把对应 expected files 当作 fixed points 对待。
