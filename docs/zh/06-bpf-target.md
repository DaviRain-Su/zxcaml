# 06 — BPF 目标平台

> **Languages / 语言**: [English](../06-bpf-target.md) · **简体中文**

## 1. 目标

Phase 1 必须以下面这条命令链在开发者机器上端到端跑通收尾：

```sh
omlz build examples/solana_hello.ml --target=bpf -o solana_hello.o
solana-test-validator &                          # 另一个 shell
solana program deploy ./solana_hello.o
```

…然后向这个程序发起的事务必须返回 `0`。

## 2. 工具链链路

```text
.ml
 │  omlz 前端 + ArenaStrategy + ZigBackend
 ▼
out/program.zig + out/runtime.zig + out/build.zig
 │  zig build-obj -target bpfel-freestanding -O ReleaseSmall
 ▼
program.o   (Solana 可加载的 BPF ELF)
```

我们刻意 **不** 直接调 LLVM。`zig` 0.16 自带的 LLVM 已经认识 BPF target；
通过 `zig build-obj` 间接驱动它就够了。

## 3. Target triple

```
bpfel-freestanding
```

- `bpfel` —— 小端 eBPF（Solana 用的方言）。
- `freestanding` —— 没有宿主操作系统接口。

P1 **不** 使用 Solana 自己的 LLVM fork。
如果 `zig` 自带的 LLVM 不够用，P3 可能加入备选工具链路径；
P1 不能依赖它。

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

BPF 用：

```sh
zig build-obj \
  -target bpfel-freestanding \
  -O ReleaseSmall \
  -fno-stack-check \
  -fno-PIC \
  -fno-PIE \
  --strip \
  out/program.zig
```

Native 仅供开发便利（**不是** P1 交付物）：

```sh
zig build-exe -O Debug out/program.zig
```

## 7. "P1 完成"前的正确性检查

P1 产出的 BPF `.o` 必须满足：

1. `llvm-objdump -d solana_hello.o` 显示一个 `entrypoint` 符号，
   带有合法 eBPF 指令。
2. 能被 `solana-test-validator` 加载：
   ```sh
   solana program deploy ./solana_hello.o
   ```
   成功。
3. 一次 no-op 调用返回 `0`。
4. 目标文件可重现：相同输入 → 相同字节（除了时间戳元数据）。

1–3 是 CI 门槛。4 在 P1 是尽力而为，到 P3 强制要求。

## 8. 可能出错的点（以及怎么应对）

| 现象 | 可能原因 | 应对 |
|---|---|---|
| `zig` 拒绝 target triple | Zig 版本漂移 | 在 CI 里 pin `zig 0.16.x`；升级流程写进 ADR |
| BPF verifier 拒绝程序 | 栈帧太深、循环无界、非法 helper | 前端 / ANF 阶段加逃逸分析（P3） |
| Solana loader 失败 | ELF section 布局不对 | 检查 `runtime/zig/bpf_entry.zig` 的链接器 flag |
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
