---
theme: default
title: ZxCaml Colosseum Demo
---

# ZxCaml — OCaml → Solana BPF

Colosseum 10 分钟演示中文 Deck

从普通 `.ml` 源码到真实 BPF artifact、IDL、Mollusk 测试与 Surfpool 本地链部署。

<!-- 旁白：今天我们会从一份普通 `.ml` 源码开始，走到真实的 BPF artifact、IDL、Mollusk 测试，以及 Surfpool 本地链部署。 -->

---

## 0:00–0:35 Hook：OCaml on Solana

Solana 程序需要同时满足三件事：

- 类型安全
- 执行确定
- 产物足够小，能落到 BPF

ZxCaml 的路线：保留 OCaml 的类型系统、ADT 和函数式表达力，替换后端，面向 Solana 编译。

<!-- 旁白：如果你写过 Solana 程序，你一定熟悉这三个要求：类型要安全，执行要确定，最后产物还必须足够小，能落到 BPF 上。ZxCaml 的目标很直接：让开发者继续用 OCaml 的类型系统、代数数据类型和函数式表达能力，同时把后端替换成面向 Solana 的编译链。 -->

---

## 0:35–1:20 架构概览：借前端，换后端

```mermaid
graph LR
  OCaml["OCaml .ml"] --> CoreIR["Core IR"]
  CoreIR --> ANF["ANF"]
  ANF --> Zig["Zig codegen"]
  Zig --> BPF["Solana BPF .so"]
```

- 上游 OCaml frontend：解析、类型检查、Typedtree
- ZxCaml bridge：Typedtree → Core IR
- ANF/Core IR：确定性 lowering、arena 策略、代码生成

<!-- 旁白：先看整体架构。ZxCaml 不发明新语言，也不 fork OCaml 编译器。我们借用上游 OCaml frontend 做解析、类型检查和 Typedtree，然后用一个很小的 bridge 把它变成我们自己的 Core IR。Core IR 采用 ANF 形态，方便做确定性的 lowering、arena 内存策略和 Zig codegen。最后 Zig 工具链和 `sbpf-linker` 负责生成 Solana BPF。简单说，就是借前端，换后端，把熟悉的 OCaml 程序送到链上。 -->

---

## 1:20–2:20 主角：`hackathon_greet.ml`

```ocaml {1|2|3|all}
external hackathon_greet_process : account -> account -> bytes -> int
  = "hackathon_greet_process"
let instruction_init (greeting_account : account) (maker : account) = ...
let instruction_greet (greeting_account : account) (maker : account) = ...
```

- PDA-backed greeting counter
- 两条指令：`init` 初始化，`greet` 递增计数
- 仍然是一份普通 `.ml` 源码

<!-- 旁白：现在进入今天的主角：`hackathon_greet.ml`。这是一个从零写的 greeting counter，用 PDA 保存状态，并提供两条指令：`init` 初始化计数器，`greet` 每次调用把计数加一，同时在第一次问候时记录发起者。重点是，它看起来仍然是一份普通的 OCaml 源码：模式匹配、记录、函数组合都在这里；只是它的目标不是本地 runtime，而是 Solana 程序。 -->

---

## 2:20–3:20 指令分发与类型化状态

```ocaml {1|2-5|6-9|all}
let discriminator = read_u8 instruction_data 0 in
if discriminator = 0 then
  hackathon_greet_process greeting_account maker instruction_data
else if discriminator = 1 then
  hackathon_greet_process greeting_account maker instruction_data
else 1
```

- discriminator：`init = 0`，`greet = 1`
- 账户数据 layout 显式、可审计
- 上层保持 OCaml 的表达方式，降低手写 offset 风险

<!-- 旁白：Solana ABI 通常从字节开始：第一位 discriminator 决定执行哪条指令，账户数据也需要明确的 layout。这里我们把 `init = 0`、`greet = 1` 写成非常小的分发逻辑，再用类型化的 state 编解码把字节数组还原成可读的数据结构。好处是观众能同时看到两层东西：底层仍然尊重 Solana 的 ABI，上层则保持 OCaml 的表达方式，减少手写 offset、魔法数字和状态不一致的风险。 -->

---

## 3:20–4:10 PDA 与账户流

PDA-backed 状态写入路径：

1. 检查 greeting PDA 与账户权限
2. `init` 写入起始状态
3. `greet` 读取旧状态并计算新 counter
4. 确定性写回账户数据

链上细节没有消失；它们被压缩在 helper 和小函数里。

<!-- 旁白：接下来是账户流。这个示例会检查 greeting PDA，确认传入账户符合预期；初始化时写入起始状态，后续 `greet` 调用则读取旧状态、计算新 counter，并确定性地写回账户数据。PDA、bump、账户权限这些链上细节不会消失，但它们被压缩在清晰的 helper 和小函数里。录制时这里要让观众感受到：我们没有绕开 Solana 模型，而是把它放进更可维护的类型化程序里。 -->

---

## 4:10–5:10 构建 BPF 并导出 IDL

```sh
./scripts/demo/01_build.sh
./zig-out/bin/omlz idl examples/hackathon_greet.ml > out/hackathon_greet.json
```

- 同一份 `.ml` 生成真实 Solana `.so`
- 同一份源码导出 Anchor-compatible IDL
- 程序逻辑与接口描述共享 source of truth

<!-- 旁白：写完源码之后，我们不做 mock，直接生成真实 artifact。`01_build.sh` 会调用 `omlz build --target=bpf`，把同一份 `.ml` 编成 Solana 可以部署的 `.so`。紧接着我们从同一份源码导出 Anchor-compatible IDL。也就是说，程序逻辑和接口描述来自同一个 source of truth；demo 里展示的不是手工补的一份 JSON，而是编译链理解源码之后自动生成的接口。 -->

---

## 5:10–6:10 用 Mollusk 证明行为

```sh
cargo test -p zxcaml-tests --test hackathon_greet_test
```

测试覆盖真实执行路径：

- 加载刚生成的 BPF 程序
- 执行一次 `init`
- 执行两次 `greet`
- 断言 PDA 状态精确变化

<!-- 旁白：在部署之前，我们先用 Mollusk 做快速、可重复的行为证明。这个测试会在 SVM 环境里加载刚生成的 BPF 程序，执行一次 `init`，再执行两次 `greet`，最后检查 PDA 里的状态是否精确变成预期值。这里的重点不是“测试跑过了”这么简单，而是同一个链上 artifact 已经被真实执行路径验证过：账户输入、instruction data、状态写回，全都被覆盖。 -->

---

## 6:10–7:20 启动 Surfpool 并部署

```sh
./scripts/demo/02_surfpool_up.sh
./scripts/demo/03_deploy.sh
```

从 in-process 测试切到本地 Solana 网络：

- 等待 Surfpool RPC ready
- 使用 fresh program keypair 部署 BPF `.so`
- 展示 program ID，证明标准部署流程可用

<!-- 旁白：现在从 in-process 测试切到本地 Solana 网络。Surfpool 给我们一个适合录制的本地链环境，启动后脚本会等待 RPC 就绪，再用新生成的 program keypair 部署刚才的 BPF `.so`。这一步非常关键：我们展示的是标准部署流程，不是只在编译器内部跑通。屏幕上出现 program ID 的那一刻，说明 ZxCaml 产物已经像普通 Solana 程序一样进入本地链。 -->

---

## 7:20–8:30 本地链调用与状态检查

```sh
./scripts/demo/04_invoke.sh
```

录制重点：

- 提交 `init` 和 `greet` 交易
- 使用正确 PDA seeds 与账户列表
- 读回 greeting account 状态
- 展示 counter 变化

<!-- 旁白：部署完成后，我们发送真实交易来调用程序。脚本会提交 `init` 和 `greet` 指令，使用正确的 PDA seeds 和账户列表，然后读回 greeting account 的状态。这里要特别强调：我们不是只证明“能部署”，而是证明部署后的程序能响应指令、更新链上状态，并把 counter 的变化展示出来。对开发者来说，这就是从源码到本地链闭环的最短路径。 -->

---

## 8:30–9:20 Anchor 对比

| 指标 | ZxCaml `hackathon_greet.ml` | Anchor reference `lib.rs` |
|---|---:|---:|
| 源码行数 | 39 | 105 |
| BPF artifact 大小 | 6.5 KB | 183.5 KB |
| 本地构建时间 | 1 秒 | 42 秒 |

结论不是替代 Anchor，而是给 Solana builder 一条 OCaml + 函数式建模路线。

<!-- 旁白：最后我们做一个诚实的 Anchor 对比。Anchor 是 Solana 生态里非常成熟的默认选择，所以这里不是为了贬低它，而是为了说明 ZxCaml 提供了另一条路线：用 OCaml 的类型和函数式建模来表达同样的账户与指令语义。比较脚本会重新统计源码行数、BPF artifact 大小，以及能测到的编译时间；文档则补充开发体验上的取舍，比如 discriminator、PDA ergonomics 和接口生成。 -->

---

## P9 Developer Experience：rustc-style caret diagnostics

P9 把错误从一行日志升级成可定位的源码片段：

```text
error[OCAML-FRONTEND]: This expression has type "string"
 --> examples/demo.ml:1:13
  |
1 | let _: int = "json"
  |             ^^^^^^
```

- 默认 human 输出：rustc-style 标题、位置、源码行和 caret span
- `--error-format=human|json|oneline`：终端、LSP、CI 各走合适格式
- `--color=auto|always|never` 与 `NO_COLOR` 保持日志可复现

<!-- 旁白：P9 的第一层开发体验是诊断。过去错误更像一行日志，现在默认是 rustc-style 的块状输出：有错误代码、文件位置、源码行和 caret 高亮。对本地调试，用 human；对工具和编辑器，用 `--error-format=json`；对 CI grep，用 `oneline`。这让错误从“看见消息”变成“直接定位到源码跨度”。 -->

---

## P9 Developer Experience：`omlz-lsp` Zig stdio LSP

```text
editor didOpen/didChange
        │
        ▼
omlz-lsp (Zig, stdio JSON-RPC)
        │ forks
        ▼
omlz check --error-format=json
        │
        ▼
textDocument/publishDiagnostics
```

- LSP 3.17 基础协议：`initialize`、`didOpen`、`didChange`、`shutdown`
- 全量文档同步，fork-per-request，避免常驻 OCaml frontend 状态
- harness 观测 median `~138ms`，足够支撑编辑器 debounce

<!-- 旁白：第二层是编辑器闭环。`omlz-lsp` 是一个 Zig 写的 stdio language server，走标准 LSP JSON-RPC framing。它有意保持小而可靠：收到 didOpen 或 didChange，就把文档写成临时 `.ml`，调用 `omlz check --error-format=json`，再把结果推成 diagnostics。当前 harness 的中位延迟大约是一百三十八毫秒，足够做实时反馈。 -->

---

## P9 Developer Experience：source maps + `omlz unmap`

BPF 运行时位置可以反查回 OCaml 源码：

```sh
./zig-out/bin/omlz build --target=bpf examples/hackathon_greet.ml -o out/hackathon_greet.so
./zig-out/bin/omlz unmap --so out/hackathon_greet.so --pc 0x80
```

- deterministic JSON sidecar：`out/<name>.map`
- BPF `.so` 内嵌 `.zxcaml.srcmap` metadata section
- `omlz unmap`：PC → `examples/*.ml:line:col`

<!-- 旁白：第三层是链上调试闭环。P9 的 source map 把 BPF 指令偏移反查回 OCaml 文件、行和列。构建时会生成确定性的 `.map` sidecar，同时把压缩后的信息放进 `.zxcaml.srcmap` ELF metadata section。遇到 Mollusk 或链上 PC 时，`omlz unmap` 能把底层地址重新翻译成开发者写过的 `.ml` 源码位置。 -->

---

## 9:20–10:00 收尾与行动号召

今天的闭环：

`.ml` 源码 → ZxCaml pipeline → BPF → IDL → Mollusk → Surfpool localnet

```sh
./scripts/demo/run_full_demo.sh
```

欢迎检查源码、脚本和测试，然后告诉我们：你想把哪个 OCaml 程序带到 Solana？

<!-- 旁白：今天我们从一个普通 OCaml `.ml` 文件出发，经过 ZxCaml pipeline，生成 BPF、导出 IDL、通过 Mollusk 验证，再部署到 Surfpool 本地链并完成真实调用。这就是 ZxCaml 想带给 Solana builder 的体验：保留强类型和函数式抽象，同时产出确定、紧凑、可部署的链上程序。欢迎直接打开仓库，运行 `./scripts/demo/run_full_demo.sh`，检查源码、脚本和测试，然后告诉我们你想把哪个 OCaml 程序带到 Solana。 -->

---

# 谢谢

ZxCaml：Borrow the frontend. Replace the backend. Land on BPF.

<!-- 旁白：谢谢观看。 -->
