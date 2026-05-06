# 16 — omlz fmt 格式化器

> **Languages / 语言**: [English](../16-omlz-fmt.md) · **简体中文**
>
> **范围：** Milestone M-FMT 交付的 canonical `omlz fmt` 源码格式化器、CLI
> 契约、面向编辑器的 LSP formatting 方法，以及 bytewise idempotency 保证。
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
CLI 会在 formatting 前通过 frontend boundary 校验 files 和 stdin。
LSP 路径在返回 edits 前使用轻量 structural malformed-input check。
这种拆分让 CLI 可以显示 compiler diagnostics，同时保持 editor formatting 很快。
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
`--no-color` 在 frontend validation 报 diagnostics 时关闭 ANSI color。
positional file input 会格式化该文件。
positional directory input 会递归收集 `*.ml` 文件。
directory results 在 processing 前按 lexicographic order 排序。
unsupported options exit `2`。
CLI 遇到 malformed OCaml input 时 exit `2`，因为 frontend validation 失败。
missing files exit `2`。

## 9. Exit codes 与 automation

Exit code `0` 表示命令成功完成。
默认 file mode 中，`0` 表示 formatted text 已打印。
`--write` 中，`0` 表示写入完成或无需写入。
`--stdin` 中，`0` 表示 stdin 已成功格式化。
`--check` 中，`0` 表示没有 input 会变化。
Exit code `1` 专门表示 `--check` 发现可重新格式化的 input。
Exit code `1` 不用于 parse errors。
Exit code `2` 表示 usage、file 或 frontend validation failure。
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
`tests/golden/fmt/` 下有十组 golden snapshot pairs。
golden test 会格式化每个 `*.input.ml` 并与 `*.expected.ml` 比较。
同一个 golden test 还会格式化每个 `*.expected.ml` 并要求 bytes 不变。
十组 cases 覆盖 simple lets。
十组 cases 覆盖 let-in chains。
十组 cases 覆盖 match expressions。
十组 cases 覆盖 mutual recursion。
十组 cases 覆盖 `let%test_unit`。
十组 cases 覆盖 comments。
十组 cases 覆盖 deeply nested expressions。
十组 cases 覆盖 multi-argument functions。
十组 cases 覆盖 record patterns。
十组 cases 覆盖 string escapes。
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
ZxCaml 的优先级是 accepted OCaml subset 的 deterministic formatting。
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
不要期待 core formatter 本身校验 OCaml syntax。
CLI 会在 formatting 前校验 syntax。
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
如果 `--check` exit `2`，先修复 parse errors 或 missing paths，再调查 style。
如果 `--check` exit `1`，运行 `--write`，或检查 default mode 的 stdout。
formatter changes 应保持 focused commits，方便 review style churn。
除非 feature 明确要求，不要把 formatter-only rewrites 和 semantic compiler work 混在一起。
