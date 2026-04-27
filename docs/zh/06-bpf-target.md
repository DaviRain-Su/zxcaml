# 06 — BPF 目标平台

> **Languages / 语言**: [English](../06-bpf-target.md) · **简体中文**

## 1. 目标

Phase 1 必须以下面这条命令链在开发者机器上端到端跑通收尾：

```sh
omlz build examples/solana_hello.ml --target=bpf -o solana_hello.so
solana-test-validator &                          # 另一个 shell
solana program deploy ./solana_hello.so
```

…然后向这个程序发起的事务必须返回 `0`。

> **产物是 `.so`，不是 `.o`。** Solana 的 BPF loader 接受的是 ELF 共享对象。
> 整篇文档里我们都把产物叫 `program.so`。

## 2. 工具链链路（已被 zignocchio 验证）

```text
.ml
 │  omlz 前端 + ArenaStrategy + ZigBackend
 ▼
out/program.zig + out/runtime.zig + out/build.zig
 │  zig build-lib -target bpfel-freestanding -femit-llvm-bc=…
 ▼
out/program.bc   (LLVM bitcode)
 │  sbpf-linker --cpu v2 --export entrypoint    （v3 为可选；ADR-013）
 ▼
program.so   (Solana 可加载的 SBPF ELF)
```

工具链 **不是** "原生 `zig build-obj`" 这一步就完。
能产出 Solana loader 接受的 ELF 的真实链路是：

1. `zig build-lib … -femit-llvm-bc` → 出 LLVM bitcode（这一步真正的产物
   是 `.bc`；`zig` 自己接着产的 `.o` **不是** Solana 兼容 ELF）。
2. **`sbpf-linker --cpu v2 --export entrypoint`** → 出 `program.so`。
   这是 Solana 专用的 linker，它懂 SBPF（默认 v2，v3 可选）的 ELF
   section 布局和入口符号 export 语义；标准 `lld` 不懂。

所以 `sbpf-linker` 是 `omlz` 的 build-time 依赖。
pinning 策略见 ADR-012；SBPF 版本固定见 ADR-013。

> **来源说明。** 这套工具链的形态是通过阅读
> `DaviRain-Su/zignocchio`（一个 Zig→Solana SBF SDK，
> 端到端管线已经能跑通）总结出来的。
> 我们 **不复制它的代码**；我们按 ADR-014 独立重新得到同样的形态。
> 见 `zignocchio-relationship.md`。

## 3. Target triple

```
bpfel-freestanding
```

- `bpfel` —— 小端 eBPF，也就是 Solana 的方言。
- `freestanding` —— 没有宿主操作系统接口。

P1 **不** 使用 Solana 自己的 LLVM fork。
`zig` 0.16 自带的 LLVM 产出的 BPF bitcode `sbpf-linker` 接受；
linker 才是把"通用 BPF bitcode"转成"Solana 形 ELF"的桥。

## 4. Entrypoint 契约

一个 Solana BPF 程序对外暴露一个符号：

```c
uint64_t entrypoint(const uint8_t *input);
```

ZxCaml 用户写：

```ocaml
let entrypoint _input = 0
```

driver 用 `runtime/zig/bpf_entry.zig` 包一层（P1 手写，之后是生成）：

```zig
// runtime/zig/bpf_entry.zig (草图)
export fn entrypoint(input: [*]const u8) callconv(.c) u64 {
    var buf: [ARENA_BYTES]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);
    return omlz_user_entrypoint(&arena, input);
}
```

编译器的工作是发出签名正确的 `omlz_user_entrypoint`。
runtime shim 才是 Solana 实际加载的东西。

> **Zig 0.16 已知 BPF 怪癖（一定会咬到我们）。**
> 模块作用域的 const 数组 —— 尤其是全零的 —— 可能被 LLVM 放在
> 极低地址（如 0x0、0x20），Solana verifier 视为 access violation。
> zignocchio 的解法是：在取地址之前先把这种常量复制到本地栈上。
> 任何 `let _ = [|0; 0; ...|]` 形态、模块作用域的常量数组，
> codegen 必须套用这个 workaround。
> 当作 P1 的 codegen 规则记下；如果 Zig 0.17 修了再回过头评估。

## 5. Runtime 产物（`runtime/zig/`）

| 文件 | 角色 |
|---|---|
| `arena.zig` | 基于静态 buffer 的 bump allocator。每个程序都用。 |
| `panic.zig` | BPF 安全的 panic：写一个小标记然后 abort。不带 stdlib 的 panic handler。 |
| `bpf_entry.zig` | 上面那个 `entrypoint` shim。 |
| `prelude.zig` | 助手：整数绕回、ADT 判别符助手、列表 cons。 |

P1 **明确不** 包含：

- syscall wrapper（`sol_log_`、`sol_invoke_signed`、…）—— P3
- account 解析 —— P3
- CPI helper —— P3
- 超出"返回 `u64`"之外的错误码约定 —— P3

## 6. Build flag

### macOS 前置条件（sbpf-linker LLVM 20 dlopen）

`sbpf-linker 0.1.8`（ADR-012 pin 的版本）通过 `aya-rustc-llvm-proxy`
在运行时 `dlopen` `libLLVM*`。在 stock macOS + Homebrew 环境里，
该库不在动态链接器搜索路径上，所以 linker 会 panic：

```
sbpf-linker: unable to find LLVM shared lib
```

修复方式（Spike β 已验证）：

```sh
brew install llvm@20
export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix llvm@20)/lib"
```

我们要 **`llvm@20`**，因为 `sbpf-linker 0.1.8` 是按 LLVM 20 ABI 编出来的；
`llvm@21` 在运行时也"能解析符号"，但 ABI 不保证。
Linux 上大多数发行版自带 `libLLVM-20.so`；若没有，
把 `LD_LIBRARY_PATH=/path/to/llvm-20/lib` 指过去。

完整理由及"`sbpf-linker` 哪天去掉这个依赖时的升级路径"
见 ADR-012（Revised 2026-04-27）。

### BPF 用 —— 两步管线（先出 bitcode，再链接）

```sh
# Step 1：Zig → LLVM bitcode
zig build-lib \
  -target bpfel-freestanding \
  -O ReleaseSmall \
  -fno-stack-check \
  -fno-PIC \
  -fno-PIE \
  --strip \
  -femit-llvm-bc=out/program.bc \
  -fno-emit-bin \
  out/program.zig

# Step 2：SBPF 链接
sbpf-linker \
  --cpu v2 \
  --export entrypoint \
  -o program.so \
  out/program.bc
```

`--cpu v2` 把 SBPF 版本钉死（默认；与 Solana mainnet 一致）。
`--cpu v3` 通过 CLI flag `--sbpf-version=v3` 作为可选路径，
保留给明确需要 v3 特性的用户。理由见 ADR-013（Revised 2026-04-27）。

Native 仅供开发便利（**不是** P1 交付物）：

```sh
zig build-exe -O Debug out/program.zig
```

## 7. "P1 完成"前的正确性检查

P1 产出的 BPF `.so` 必须满足：

1. `llvm-objdump -d solana_hello.so` 显示一个 export 出去的
   `entrypoint` 符号，带合法 eBPF（默认 SBPFv2，v3 可选）指令。
2. 能被 `solana-test-validator` 加载：
   ```sh
   solana program deploy ./solana_hello.so
   ```
   成功。
3. 一次 no-op 调用返回 `0`。
4. 目标文件可重现：相同输入 → 相同字节（除了时间戳元数据）。
5. （新加）通过 `sbpf-linker` 链接后的 section 布局检查 ——
   没有 `.rodata` 符号解析到 < 0x100 的地址（Zig 0.16 的低地址怪癖；
   见 §4 的注）。

1–3、5 是 CI 门槛。4 在 P1 是尽力而为，到 P3 强制要求。

## 8. 可能出错的点（以及怎么应对）

| 现象 | 可能原因 | 应对 |
|---|---|---|
| `zig` 拒绝 target triple | Zig 版本漂移 | 在 CI 里 pin `zig 0.16.x`；升级流程写进 ADR |
| `sbpf-linker` 没装 | 新增的 build-time 依赖 | 按 ADR-012 pin 的版本 `cargo install`；CI 装 |
| `sbpf-linker` 拒绝 bitcode | LLVM IR 形态它不认 | 把 `ZigBackend` 生成的代码降复杂度；扩 `--cpu` 必须走 ADR |
| loader 报 "Access violation" 在低地址 | Zig 0.16 const-array 放置怪癖（§4 注） | codegen 规则：对 const 数组先复制到栈再取地址 |
| `sbpf-linker: unable to find LLVM shared lib` | macOS 上 `DYLD_FALLBACK_LIBRARY_PATH` 找不到 `libLLVM*` | `brew install llvm@20`；`export DYLD_FALLBACK_LIBRARY_PATH=$(brew --prefix llvm@20)/lib`（详见 §6、ADR-012 Revised 2026-04-27） |
| BPF verifier 拒绝程序 | 栈帧太深、循环无界、非法 helper | 前端 / ANF 阶段加逃逸分析（P3） |
| Solana loader 因别的原因失败 | ELF section 布局不对 | 拿 zignocchio 的参考 `program.so` 做 diff；上报 sbpf-linker |
| 返回值不对 | 后端和解释器不一致 | 由确定性套件捕获（`05-backends.md` §6） |

## 9. 范围之外（P1）

- IDL 生成（Anchor 风格）
- BPF 端日志
- Program-derived address（PDA）
- Cross-program invocation（CPI）
- Compute-unit 预算分析
- Upgrade authority / multisig 流程

这些都明确属于 P3+。

## 10. 为什么不"凡是 Zig 能产出的目标都支持"？

因为 Zig 后端发的是 `.zig` 源码，再调 Zig 工具链，
所以很容易得出"Zig 能编到的目标 = ZxCaml 支持的目标"这个结论。
**这个结论是错的。**
错在哪里值得写清楚，免得以后再有人这么想。

整条链路上有三个独立的层：

```
1. Zig 工具链        — Zig 自己能 lower 到的目标（≈ LLVM 支持的目标）
2. ZxCaml 代码生成    — 我们后端能产出合法 Zig 源码的目标
3. ZxCaml runtime    — 我们能在那里实际跑起来的目标
```

第 1 层 **极广**：`aarch64`、`arm`、`x86`、`x86_64`、`riscv*`、`mips*`、
`loongarch*`、`bpfel`/`bpfeb`、`wasm32`/`wasm64`、`nvptx*`、`amdgcn`、
`spirv*`、`avr`、`msp430` …… 和更多。把它们列出来不等于支持它们。

第 2 层在 P1 几乎与目标无关。我们生成的 Zig 是直白的代码，
没有 SIMD、没有 inline asm、没有平台 intrinsic。任何合理目标都能接受。

**第 3 层才是乐观主义死掉的地方。** 每个目标至少需要：

- **入口 shim。**
  Solana BPF 要 `u64 entrypoint(const u8 *)`；
  Linux 要走 libc `_start` → `int main(int, char**)`；
  WASM 要 export 函数；
  裸金属要 reset vector；
  Linux 内核 eBPF 要 `SEC(...)` 加 context-typed 函数。
  每一种都得单独手写。
- **panic 策略。**
  BPF 是 abort；native 可能 print + exit；裸金属可能 halt 或 reboot。
- **内存方案。**
  BPF 给一段静态 buffer 当 arena；native 理论可以用 `malloc`-backed region；
  freestanding ARM 必须告诉它 RAM 起点。P1 只懂"静态 buffer arena"这一种。
- **与用户代码之间的调用约定。**
  隐式 `arena: *Arena` 首参是 BPF / freestanding 的规则；
  hosted 目标可能想跳过它。

**不止 shim —— 语言本身就是按 BPF 约束塑形的：**

| ZxCaml 选择 | 为什么这么选 | 在其它目标上的代价 |
|---|---|---|
| 没有 GC | BPF verifier 不允许 | x86 上其实可以加 GC，但我们没 |
| 单 arena | BPF 不能 `malloc` | x86 / WASM 上限制了表达力 |
| 没有 syscall | BPF 只能用白名单 helper | x86 上不能开文件、不能 print |
| 没有线程 | BPF 单线程 | 现代平台浪费了多核 |
| 没有异常 | BPF 不允许 unwind | 通用语言里不常见 |
| 有界栈 | BPF verifier 限制 | 在所有目标上都限制了递归深度 |

所以即使 `zig build-obj -target x86_64-linux out/program.zig` 成功，
产物也是一个被剪掉了 I/O、GC、线程、异常、stdlib 的 OCaml 方言 ——
没人会想用它写 x86 程序。
**工具链能编通是必要条件，不是充分条件。**
要"在那个目标上是个有用的语言"，
还得逐目标松开 BPF 强加的约束 —— 那是真实的设计工作。

### 我们 **顺带** 允许什么

- `omlz build --target=native` 文档化为 **仅供开发便利**：
  它让你能本地跑编译产物以更快发现集成 bug，比走 `solana-test-validator` 快。
  这**不**是被支持的交付物；我们不承诺稳定性、性能、功能对等。

### 一个新目标在什么情况下会成为真实目标

只有当 **以下全部** 成立时，新目标才进入"被支持"集合：

1. 存在一个具体、有名字的用例 —— 不是"如果有就好了"。
2. 有人为这个目标的 entry shim、panic 策略、内存方案负责。
3. 或者 BPF 形态的语言约束已经匹配这个用例，
   或者有文档化的"按目标松绑约束"方案（且作为 ADR 通过）。
4. 这个目标拿到一条 CI lane 和至少一个验收 example。

直到这些条件成立之前，"Zig 能编到它"只是有趣的小知识，不是承诺。

可选、有门槛的 **PX —— 多目标扩展** 阶段，
把这条规则写进了路线图，见 `08-roadmap.md`。
