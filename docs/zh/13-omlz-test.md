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

## 性质测试

`let%test_prop` 在同一条 `omlz test` 循环里加入生成式测试。
它适合代数律、往返检查、parser 风格不变量，以及用一个
`let%test_unit` 手写 case 覆盖不够的纯 helper。
性质测试仍然是普通 OCaml 源码。
上游 OCaml frontend 继续负责解析和类型检查。
ZxCaml runner 只额外负责生成样本、重复执行、缩小失败样本，以及在
reporter 中给出可复现信息。
如果行为依赖 Solana account 或 BPF loader，请继续使用 Mollusk。
如果行为足够纯，可以通过 interpreter 快速跑很多次，就适合使用
`let%test_prop`。

支持的表面语法是：

```ocaml
let%test_prop "name" generator = fun x -> property_expr
```

绑定必须位于模块顶层。
名称必须是非空字符串字面量。
名称和 `=` 之间的表达式是 generator。
右侧通常是一个参数的 `fun`，返回 `bool`。
返回 `true` 表示这个生成样本通过。
返回 `false` 会按断言失败处理。
测试体也可以显式调用 `assert`，失败时仍走普通的
`ZXCAML_PANIC:assert_failure` 路径。
预扫描会拒绝未知 `let%...` 扩展、缺少名称、缺少 generator，以及嵌套的
property 绑定。
这些错误使用与 `omlz check` 相同的诊断渲染器。
扫描前会跟踪 OCaml 注释深度，因此注释里的 property 文本会被忽略。

最小示例可以自己定义一个 seed transformer：

```ocaml
let int seed = (seed, seed + 1)

let%test_prop "add commutative" int = fun x ->
  x + 7 = 7 + x
```

generator 接收当前 seed，并返回 `(sample, next_seed)`。
`omlz test` 会把返回的 seed 继续传给下一次采样。
因此传入 `--seed` 后，整条样本流都是确定性的。
JSON 输出会打印这次使用的 seed；失败报告也会带上它。
如果没有显式 seed，默认值来自当前 monotonic time。
CI 和 bug 报告中应使用显式 seed。

当 generator 产生 tuple 时，property body 可以使用二元组模式：

```ocaml
let int seed = (seed, seed + 1)
let pair = Generators.tuple2 int int

let%test_prop "pair addition symmetry" pair = fun (x, y) ->
  x + y = y + x
```

预扫描内部会把二元组模式改写成 `fst` / `snd` 绑定。
当前 tuple 模式只支持两个标识符。
更大的结构建议先绑定为单个值，再在 body 内部解构。
保持 header 简单，可以让 source location 和 shrunk example 更容易理解。

内置 generator API 位于 `stdlib/generators.ml`，模块名是 `Generators`。
核心类型是：

```ocaml
type seed = int64
type 'a generator = seed -> 'a * seed
```

已经提供的组合子包括：

| API | 采样内容 |
|---|---|
| `Generators.int_range ~low ~high` | 闭区间整数 |
| `Generators.bool` | 布尔值 |
| `Generators.string_of_len ~len` | 固定长度的可打印 ASCII 字符串 |
| `Generators.list_of gen max_len` | 长度为 `0..max_len` 的列表 |
| `Generators.option_of gen` | `None` 或 `Some sample` |
| `Generators.tuple2 left right` | 按 left 再 right 采样的二元组 |
| `Generators.map f gen` | 对样本做转换 |
| `Generators.filter pred gen` | 满足谓词的样本，带重试预算 |

PRNG 是确定性的 64-bit 线性同余生成器。
同一个 seed、同一个 generator 表达式、同一个 case 顺序会产生同一条样本流。
`filter` 有有限重试预算。
如果谓词不可能满足，它会明确失败，而不是挂住测试进程。
组合子都是普通 OCaml 值，因此可以命名、组合，并在多个
`let%test_prop` 之间复用。

Shrinking 会尝试把第一次失败的样本换成更小但仍失败的样本。
stdlib 为 generator 家族提供了配套 shrinker：
`shrink_int`、`shrink_bool`、`shrink_string`、`shrink_list`、
`shrink_option`、`shrink_tuple2`、`shrink_map` 和 `shrink_filter`。
公共 helper `Generators.shrink_to_minimal` 会沿着候选值前进，直到找不到
更小的失败值。
runner 在 property 样本类型为 `int` 时，也会应用内建的整数 shrink 路径。
它会先尝试 `0`，再用类似二分的候选值向零靠近。
shrink 循环最多执行 `100` 步。
如果预算内找不到最小值，stdlib helper 会抛出
`Generators.shrink: budget exhausted`，而不是无限循环。

运行 property 使用同一个子命令：

```sh
zig-out/bin/omlz test --num-cases 100 --seed 42 examples/tests/prop_int_add.ml
```

`--num-cases N` 控制每个 property 的采样次数。
默认值是 `100`。
`N` 必须为正数；无效值是调用错误，退出码为 `2`。
`--seed N` 固定 property runner 使用的初始 seed。
CLI parser 接受十进制有符号整数。
后续 seed 来自 generator 返回值，而不是 runner 自己重新生成。
`--filter SUBSTR` 仍按人类可读的 property 名称过滤。
显式文件仍会替代默认的 `examples/tests/*.ml` 扫描。

cargo-style 输出会用 `prop_` 前缀标出 property，并显示 case 数：

```text
running 1 tests
test examples/tests/prop_int_add.ml::prop_add commutative ... ok (10 cases)
test result: ok. 1 passed; 0 failed; finished in 0ms
```

失败时会报告源码位置、已经执行的 case 数，以及 shrink 后的反例：

```text
test /tmp/prop_int_add_fail.ml::prop_broken overflow assertion ... FAILED (10 cases)
  /tmp/prop_int_add_fail.ml:13:21: ZXCAML_PANIC:assert_failure; FAILED after 1 tests; shrunk to: 0 (in 1 shrink steps)
test result: FAILED. 0 passed; 1 failed; finished in 0ms
```

同一次运行加上 `--format=json` 会输出 JSON Lines。
property 的 test object 会包含 `kind:"prop"`、`num_cases` 和 `seed`。
失败的 property object 还包含 `message`、`line`、`col`、
`shrunk_steps` 和 `counterexample`。
最后的 summary object 保留既有的 `type`、`status`、`total`、
`passed`、`failed` 和 `elapsed_ms` 字段。
工具应解析 JSON Lines，不应抓取 cargo 文本。

默认 corpus 现在包含三个通过的 property demo：
`examples/tests/prop_list_rev.ml`、`examples/tests/prop_string_concat.ml` 和
`examples/tests/prop_int_add.ml`。
另外还有 `examples/tests/prop_int_add.fail.ml.template` 用于演示和回归说明。
模板不会被默认的 `*.ml` 发现规则扫描到。
需要展示失败和 shrunk counterexample 时，可把模板复制成临时 `.ml` 文件。

这个功能有意比 QuickCheck 或 Hypothesis 更小。
和 QuickCheck 一样，它把 property 看作生成样本上的谓词，并在失败时打印
可重放的 seed。
和 QuickCheck、Hypothesis 一样，它会在报告前尝试缩小失败样本。
不同于 QuickCheck，ZxCaml 不从类型自动推导 generator。
你需要在 `let%test_prop` header 中显式传入 generator 表达式。
不同于 Hypothesis，ZxCaml 不维护 example database、自适应搜索策略，或
coverage-guided exploration。
目标是一个确定性、无额外依赖、能贴合现有 OCaml frontend 和 interpreter
pipeline 的 runner。

建议实践：

- generator 保持足够小，让 `100` 个 case 能快速完成。
- 只有在复现已知失败时，才把显式 seed 写进命令或说明。
- BPF build 之前，优先用生成值覆盖纯 helper 逻辑。
- 简单关系用 pair property；复杂结构在 body 内部解构。
- 编辑器、CI annotation 和自动 triage 使用 JSON 输出。
- 保留 `.fail.ml.template` 后缀，避免失败模板进入默认扫描。
- Solana account-state 不变量应交给 Mollusk，而不是硬塞进 property test。
