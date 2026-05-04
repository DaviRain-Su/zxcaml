# ZxCaml Colosseum 演示脚本（中文）

本脚本严格对齐 `docs/hackathon/timeline.md` 的 10 分钟时间线。每一段都保留相同时间边界、同一叙事顺序，并面向现场录制的口播节奏编写。

## 0:00 – 0:35 — Hook: OCaml on Solana

- **Surface**: title-card
- **Scene cue**: 黑底标题卡淡入，中央显示项目名和管线箭头；背景可以轻微叠加 Solana 与 OCaml 风格的代码纹理。
- **On-screen command / visual**: `ZxCaml — OCaml → Solana BPF`
- **Narration**: 如果你写过 Solana 程序，你一定熟悉这三个要求：类型要安全，执行要确定，最后产物还必须足够小，能落到 BPF 上。ZxCaml 的目标很直接：让开发者继续用 OCaml 的类型系统、代数数据类型和函数式表达能力，同时把后端替换成面向 Solana 的编译链。今天我们会从一份普通 `.ml` 源码开始，走到真实的 BPF artifact、IDL、Mollusk 测试，以及 Surfpool 本地链部署。

## 0:35 – 1:20 — Compiler pipeline in one picture

- **Surface**: IDE
- **Scene cue**: 打开架构文档并停在 pipeline 图；鼠标从 `.ml source` 逐层扫到 `Solana BPF .so`。
- **On-screen command / visual**: Open `docs/01-architecture.md` at the pipeline diagram
- **Narration**: 先看整体架构。ZxCaml 不发明新语言，也不 fork OCaml 编译器。我们借用上游 OCaml frontend 做解析、类型检查和 Typedtree，然后用一个很小的 bridge 把它变成我们自己的 Core IR。Core IR 采用 ANF 形态，方便做确定性的 lowering、arena 内存策略和 Zig codegen。最后 Zig 工具链和 `sbpf-linker` 负责生成 Solana BPF。简单说，就是借前端，换后端，把熟悉的 OCaml 程序送到链上。

## 1:20 – 2:20 — Start `hackathon_greet.ml`

- **Surface**: IDE
- **Scene cue**: 切到示例源码，先展示文件顶部注释、入口函数和两条 instruction 的整体骨架。
- **On-screen command / visual**: Open `examples/hackathon_greet.ml`
- **Narration**: 现在进入今天的主角：`hackathon_greet.ml`。这是一个从零写的 greeting counter，用 PDA 保存状态，并提供两条指令：`init` 初始化计数器，`greet` 每次调用把计数加一，同时在第一次问候时记录发起者。重点是，它看起来仍然是一份普通的 OCaml 源码：模式匹配、记录、函数组合都在这里；只是它的目标不是本地 runtime，而是 Solana 程序。

## 2:20 – 3:20 — Instruction dispatch and typed state

- **Surface**: IDE
- **Scene cue**: 高亮 discriminator 分支，再切到 state encode/decode 函数；保持侧边栏可见，让观众知道仍在同一个 `.ml` 文件内。
- **On-screen command / visual**: Highlight `init = 0`, `greet = 1`, and state layout code
- **Narration**: Solana ABI 通常从字节开始：第一位 discriminator 决定执行哪条指令，账户数据也需要明确的 layout。这里我们把 `init = 0`、`greet = 1` 写成非常小的分发逻辑，再用类型化的 state 编解码把字节数组还原成可读的数据结构。好处是观众能同时看到两层东西：底层仍然尊重 Solana 的 ABI，上层则保持 OCaml 的表达方式，减少手写 offset、魔法数字和状态不一致的风险。

## 3:20 – 4:10 — PDA and account flow

- **Surface**: IDE
- **Scene cue**: 从 PDA seed/bump helper 跳到 account write path；用光标依次指出检查、初始化、递增和写回。
- **On-screen command / visual**: Highlight PDA seed/bump helpers and account write path
- **Narration**: 接下来是账户流。这个示例会检查 greeting PDA，确认传入账户符合预期；初始化时写入起始状态，后续 `greet` 调用则读取旧状态、计算新 counter，并确定性地写回账户数据。PDA、bump、账户权限这些链上细节不会消失，但它们被压缩在清晰的 helper 和小函数里。录制时这里要让观众感受到：我们没有绕开 Solana 模型，而是把它放进更可维护的类型化程序里。

## 4:10 – 5:10 — Build BPF and emit IDL

- **Surface**: terminal
- **Scene cue**: 切到终端，执行构建脚本；构建成功后立即生成 IDL，并短暂停留在输出文件路径。
- **On-screen command / visual**: `./scripts/demo/01_build.sh && ./zig-out/bin/omlz idl examples/hackathon_greet.ml > out/hackathon_greet.json`
- **Narration**: 写完源码之后，我们不做 mock，直接生成真实 artifact。`01_build.sh` 会调用 `omlz build --target=bpf`，把同一份 `.ml` 编成 Solana 可以部署的 `.so`。紧接着我们从同一份源码导出 Anchor-compatible IDL。也就是说，程序逻辑和接口描述来自同一个 source of truth；demo 里展示的不是手工补的一份 JSON，而是编译链理解源码之后自动生成的接口。

## 5:10 – 6:10 — Prove behavior with Mollusk

- **Surface**: terminal
- **Scene cue**: 保持终端，运行单个 Mollusk integration test；测试通过后高亮 `init`、两次 `greet` 和最终 counter 断言相关输出。
- **On-screen command / visual**: `cargo test -p zxcaml-tests --test hackathon_greet_test`
- **Narration**: 在部署之前，我们先用 Mollusk 做快速、可重复的行为证明。这个测试会在 SVM 环境里加载刚生成的 BPF 程序，执行一次 `init`，再执行两次 `greet`，最后检查 PDA 里的状态是否精确变成预期值。这里的重点不是“测试跑过了”这么简单，而是同一个链上 artifact 已经被真实执行路径验证过：账户输入、instruction data、状态写回，全都被覆盖。

## 6:10 – 7:20 — Start Surfpool and deploy

- **Surface**: terminal
- **Scene cue**: 新终端 pane 或清屏后启动 Surfpool；等待 RPC ready，再执行部署脚本并放大 program ID。
- **On-screen command / visual**: `./scripts/demo/02_surfpool_up.sh && ./scripts/demo/03_deploy.sh`
- **Narration**: 现在从 in-process 测试切到本地 Solana 网络。Surfpool 给我们一个适合录制的本地链环境，启动后脚本会等待 RPC 就绪，再用新生成的 program keypair 部署刚才的 BPF `.so`。这一步非常关键：我们展示的是标准部署流程，不是只在编译器内部跑通。屏幕上出现 program ID 的那一刻，说明 ZxCaml 产物已经像普通 Solana 程序一样进入本地链。

## 7:20 – 8:30 — Invoke on localnet and inspect state

- **Surface**: terminal
- **Scene cue**: 执行 invoke 脚本；在输出中停留交易签名、init/greet 成功日志和账户状态读取结果。
- **On-screen command / visual**: `./scripts/demo/04_invoke.sh`
- **Narration**: 部署完成后，我们发送真实交易来调用程序。脚本会提交 `init` 和 `greet` 指令，使用正确的 PDA seeds 和账户列表，然后读回 greeting account 的状态。这里要特别强调：我们不是只证明“能部署”，而是证明部署后的程序能响应指令、更新链上状态，并把 counter 的变化展示出来。对开发者来说，这就是从源码到本地链闭环的最短路径。

## 8:30 – 9:20 — Anchor comparison

- **Surface**: terminal
- **Scene cue**: 运行比较脚本后打开 comparison 文档；镜头依次扫过行数、artifact size、compile time 和 ergonomics 表格。
- **On-screen command / visual**: `./scripts/demo/compare.sh && open docs/hackathon/anchor-comparison.md`
- **Narration**: 最后我们做一个诚实的 Anchor 对比。Anchor 是 Solana 生态里非常成熟的默认选择，所以这里不是为了贬低它，而是为了说明 ZxCaml 提供了另一条路线：用 OCaml 的类型和函数式建模来表达同样的账户与指令语义。比较脚本会重新统计源码行数、BPF artifact 大小，以及能测到的编译时间；文档则补充开发体验上的取舍，比如 discriminator、PDA ergonomics 和接口生成。

## 9:20 – 10:00 — Close and call to action

- **Surface**: title-card
- **Scene cue**: 回到收尾标题卡；显示 GitHub、docs、demo scripts 路径，并用最后一行命令作为复现入口。
- **On-screen command / visual**: Show repo/docs links and `./scripts/demo/run_full_demo.sh`
- **Narration**: 今天我们从一个普通 OCaml `.ml` 文件出发，经过 ZxCaml pipeline，生成 BPF、导出 IDL、通过 Mollusk 验证，再部署到 Surfpool 本地链并完成真实调用。这就是 ZxCaml 想带给 Solana builder 的体验：保留强类型和函数式抽象，同时产出确定、紧凑、可部署的链上程序。欢迎直接打开仓库，运行 `./scripts/demo/run_full_demo.sh`，检查源码、脚本和测试，然后告诉我们你想把哪个 OCaml 程序带到 Solana。
