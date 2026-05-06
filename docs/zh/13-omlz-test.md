# 13 — `let%test_unit` 与 `omlz test`

> **Languages / 语言**: [English](../13-omlz-test.md) · **简体中文**
>
> **范围：** 在 `.ml` 文件中编写 OCaml-native 单元测试，使用 `omlz test`
> 运行，并通过 LSP CodeLens 在编辑器中运行单个测试。
>
> **相关文档：** [`docs/lsp.md`](../lsp.md)、
> [`docs/diagnostics.md`](../diagnostics.md)、
> [`examples/tests/`](../../examples/tests/)。

## 1. 定位

`let%test_unit` 给 ZxCaml 增加了一条快速的 OCaml-native 测试循环。
它适合纯 helper、语法 lowering 示例和编辑器内反馈。
它不是 property testing 框架。
测试仍然是普通 OCaml 源码。
上游 OCaml frontend 仍负责解析和类型检查。
ZxCaml 仍会经过 Core IR、ANF、优化 pass 和 interpreter。
测试层只增加发现、选择、报告和退出码。
默认 corpus 位于 [`examples/tests/`](../../examples/tests/)。

## 2. 语法

唯一支持的写法是：

```ocaml
let%test_unit "name" = expr
```

绑定必须在模块顶层。
名称必须是字符串字面量。
右侧表达式必须返回 `unit`。
多数测试体会以一个或多个 `assert` 结束。
示例：

```ocaml
let triple x = x * 3
let%test_unit "triple works" =
  assert (triple 4 = 12)
```

多行测试体就是普通 OCaml 表达式。

```ocaml
let%test_unit "list reverse" =
  let xs = [ 1; 2; 3 ] in
  assert (List.rev xs = [ 3; 2; 1 ])
```

未知的 `let%...` 扩展会被拒绝。
缺少字符串名称会被拒绝。
嵌套的 `let%test_unit` 也会被拒绝。
这些错误使用与 `omlz check` 一致的 rustc-style 诊断。

## 3. 语义

frontend 会在正式编译前预扫描测试绑定。
每个测试会被改写为隐藏的 unit thunk。
概念上，这段源码：

```ocaml
let%test_unit "adds" = assert (1 + 1 = 2)
```

会被编译成类似形态：

```ocaml
let __otest_unit_0__ _ : unit = assert (1 + 1 = 2)
let __otest_registry__ : (string * (unit -> unit)) list =
  [ ("adds", __otest_unit_0__) ]
```

隐藏 thunk 的类型是 `unit -> unit`。
registry 是 `(string * thunk)` 列表。
`omlz test` 在 Core IR lowering 之后发现 `__otest_registry__`。
每个被选中的 case 都会临时合成一个 `entrypoint`。
这个 entrypoint 只调用一个 thunk。
thunk 正常返回，测试通过。
`assert` 触发 interpreter panic，测试失败。
所以第一版是 assert-driven 的。
当前不引入额外 assertion library。

## 4. 发现规则

不传文件时，runner 扫描：

```sh
examples/tests/*.ml
```

只有 `.ml` 文件会被纳入。
默认文件列表按字典序排序。
显式 `FILE...` 会替换默认扫描。

```sh
zig-out/bin/omlz test examples/tests/list_ops.ml
```

也可以传多个文件。

```sh
zig-out/bin/omlz test examples/tests/list_ops.ml examples/tests/pda_helpers.ml
```

显式文件不存在时是 setup 错误。
没有 registry 的文件贡献零个测试。
runner 不递归扫描任意目录。
测试不在 `examples/tests/` 时，请显式传路径。

## 5. 过滤

`--filter SUBSTR` 只保留名称包含 `SUBSTR` 的测试。
匹配是字节级、大小写敏感的 substring。
过滤发生在 registry 被发现之后。

```sh
zig-out/bin/omlz test --filter list_ops
```

LSP 的单测试运行也走同一路径。
点击 CodeLens 会 fork：

```sh
zig-out/bin/omlz test --filter "selected name" --format=json FILE
```

建议使用清晰且尽量唯一的测试名。
如果多个名称匹配同一 substring，它们都会运行。

## 6. 报告格式

默认 reporter 是 cargo-style 文本。
开头是：

```text
running N tests
```

通过测试显示：

```text
test path/to/file.ml::test name ... ok
```

失败测试显示：

```text
test path/to/file.ml::test name ... FAILED
  path/to/file.ml:line:col: assertion failed
```

summary 行是：

```text
test result: ok. P passed; F failed; finished in 0ms
```

工具集成应使用 JSON Lines：

```sh
zig-out/bin/omlz test --format=json
```

每个 test object 包含 `type`、`file`、`name`、`status` 和 `elapsed_ms`。
失败 object 还包含 `message`、`line` 和 `col`。
summary object 包含 `type`、`status`、`total`、`passed`、`failed` 和 `elapsed_ms`。
LSP 消费的就是这条 JSON 流。

## 7. 退出码

`0` 表示所有被选中的测试都通过。
`1` 表示 runner 正常完成，但至少一个测试失败。
`2` 表示调用或准备阶段失败。
不支持的 flag 返回 `2`。
显式文件缺失返回 `2`。
frontend 准备失败返回 `2`。
默认扫描为空时仍然成功：零测试、零失败。
CI 可把 `1` 视为测试失败。
把 `2` 视为命令或环境问题。

## 8. 颜色与 `NO_COLOR`

cargo 文本只在 stdout 是 TTY 时使用颜色。
传 `--no-color` 可以关闭颜色。
设置 `NO_COLOR=1` 也会关闭颜色。
这个环境变量也影响 runner 调用 frontend 时的诊断颜色。
JSON Lines 输出不包含颜色。
脚本和编辑器建议使用 `--format=json --no-color`。

## 9. LSP CodeLens

`omlz-lsp` 声明 `textDocument/codeLens` 能力。
每个可见的 `let%test_unit "name"` 都会在字符串名称上得到一个 lens。
未运行时，标题是：

```text
▶ Run test "name"
```

命令名是 `omlz.runTest`。
参数是文档 URI 和测试名。
执行期间，server 通过 `$/omlz.testOutput` 推送输出行。
它也会通过 `window/logMessage` 镜像这些行。
通过后，标题变成 `✓ name`。
失败后，server 发送 `window/showMessage`，标题变成 `✗ name (line N)`。
收集 lens 时只扫描内存文本，不运行 frontend。
真正执行时才 fork `omlz test --filter --format=json`。
CodeLens latency harness 在 warm-up 后测量五次请求。
当前 p50 预算是 ≤ 100 ms。

## 10. 常见坑

测试必须在顶层。
名称必须是字符串字面量。
依赖 `--filter` 时，名称要具体。
测试体应保持确定性。
纯逻辑和快速反馈用 `omlz test`。
Solana account 与 BPF 行为用 Mollusk。
程序解析输出时用 `--format=json`。
纯文本日志用 `--no-color` 或 `NO_COLOR=1`。
`examples/tests/` 之外的文件要显式传入。
一个历史坑已经修复：注释里的 `let%test_unit` 是安全的。
下面只是注释：

```ocaml
(* let%test_unit "not a real test" = assert false *)
```

frontend 会跟踪 OCaml comment depth。
因此预扫描会跳过注释内容。
这是 F-OT-FIX-COMMENT 的修复范围。

## 11. 示例 corpus

默认 corpus 当前有三个 `.ml` 文件。
`examples/tests/list_ops.ml` 覆盖 length、reverse 和 map helper。
`examples/tests/arith_overflow.ml` 覆盖整数 wraparound 示例。
`examples/tests/pda_helpers.ml` 覆盖纯 PDA/pubkey helper 逻辑。
三个文件合计有八个通过的 `let%test_unit` case。
`.fail.ml.template` 只用于 demo 录制。
它不会进入默认扫描。

## 12. 分层

`let%test_unit` 补充现有测试栈。
需要快速本地信心时，先用它。
Zig 编译器和 runtime 单元测试仍用 `zig build test`。
Solana 执行语义仍用 Mollusk。
只想运行光标下的测试时，用 CodeLens。
