# 06 — BPF 目标平台

> **Languages / 语言**: [English](../06-bpf-target.md) · **简体中文**

## 1. 目标

最初的 Phase 1 BPF 验收目标，是下面这条命令链能在开发者机器上端到端跑通：

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
 │  └─  solana-zig build-lib -target sbf-solana（直连）
 ▼
program.so   (Solana 可加载的 SBPF ELF)
```

工具链 **不是** "原生 `zig build-obj`" 这一步就完。
能产出 Solana loader 接受的 ELF 的真实链路是：

1. `solana-zig build-lib -target sbf-solana -fPIC -fstrip -dynamic` → 直接产出
   可加载的 `program.so`。

`omlz` 直接用 `solana-zig` 的 direct path。

SBPF 版本行为可见 ADR-013。

> **来源说明。** 这套工具链的形态是通过阅读
> `DaviRain-Su/zignocchio`（一个 Zig→Solana SBF SDK，
> 端到端管线已经能跑通）总结出来的。
> 我们 **不复制它的代码**；我们按 ADR-014 独立重新得到同样的形态。
> 见 `zignocchio-relationship.md`。

## 3. Target triple

当前直接路径使用 Solana Zig 的 target：

```text
sbf-solana
```

历史实验曾使用 Zig 的 generic `bpfel-freestanding` target 加单独 linker 步骤；
当前 `omlz build --target=bpf` 走 `solana-zig`，直接发出最终 Solana-loadable ELF。

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

最初的 P1 runtime 刻意 **不** 包含 syscall wrapper、account 解析、CPI helper 或更丰富的错误约定。
这些面向 Solana 的表面后来由已封存的 P3/P5 工作补上，并记录在 `11-solana-p3.md`；
本文的 BPF target 契约仍聚焦在工具链、entrypoint 和 ELF 形态上。

## 6. Build flag

### `SOLANA_ZIG` 直连路径

`SOLANA_ZIG` 未设置/空（默认）或设为 `1`（或某个路径）时，`omlz build --target=bpf` 使用 `solana-zig build-lib` 的一步式直接链路，直接产 `.so`。`SOLANA_ZIG=0` 会被视为非法自定义值，不再作为模式开关。

Native 仅供开发便利（**不是** P1 交付物）：

```sh
zig build-exe -O Debug out/program.zig
```

### 历史 ELF 后处理（已移除）

早期工具链组合曾让 `tests/bpf_test_support.rs` 对集成测试产物做后处理
（补 `BPF_CALL_IMM` 源寄存器位、把 `e_flags` 改成 SBPF v1）。当前
`omlz` + `solana-zig 0.16.0 / solana-v1.53.0` 工具链的 codegen 已经直接
输出正确的字节，所以该后处理及对应的环境变量开关均已删除；详见
`mission-internal/elf-patch-investigation.md`。

## 7. BPF 正确性检查

当前管线产出的 BPF `.so` 必须满足：

1. `llvm-objdump -d solana_hello.so` 显示一个 export 出去的
   `entrypoint` 符号，带合法 eBPF（默认 SBPFv2，v3 可选）指令。
2. 能被 `solana-test-validator` 加载：
   ```sh
   solana program deploy ./solana_hello.so
   ```
   成功。
3. 一次 no-op 调用返回 `0`。
4. **G13 可复现性结果（2026-04-28）：PASS。** 运行
   `zig-out/bin/omlz build --target=bpf examples/solana_hello.ml -o /tmp/a.so && zig-out/bin/omlz build --target=bpf examples/solana_hello.ml -o /tmp/b.so && diff /tmp/a.so /tmp/b.so; echo "diff_exit=$?"`
   得到 `diff_exit=0`。两个 `.so` 字节完全相同。
5. section 布局检查应稳定，不出现低地址 (<0x100) 的可读数据段符号；Zig 0.16 的低地址怪癖见 §4 的注。

1–3、5 是 canonical hello 验收检查。启用 Solana harness 时，closure 相关 BPF 验收由 `tests/solana/closures/` 单独覆盖。


## 8. 可能出错的点（以及怎么应对）

这张表把 P1 mission 中遇到的 bug / landmine 汇总成给 P2+ worker 的 BPF 与发布工程指南。

| 症状 | 可能原因 / 观察来源 | 处理 |
|---|---|---|
| `zig` 拒绝 target triple | Zig 版本漂移 | CI 固定 `zig 0.16.x`；任何升级都要更新 ADR-002 并重跑 BPF acceptance |
| `solana-zig` 输出出现异常节段布局 | 直接链路结果的节段布局或符号顺序存在问题 | 保持 section 排序与零地址保护规则，和已知可用 `solana_hello.so` 做对比 |
| macOS 上 `llvm-objdump` 不在 `PATH` | Homebrew 可能将 LLVM 工具放在 PATH 之外 | 手动检查时使用 `/opt/homebrew/bin/llvm-objdump`（或将其加入 `PATH`） |
| Loader 因低地址 `Access violation` 拒绝 | Zig 0.16 module-scope const-array placement quirk（§4） | Codegen 规则：对 module-scope const array 取地址前先复制到栈上 |
| BPF build 拒绝 Zig `@trap` / abort builtin | freestanding BPF 不能使用 hosted panic path | `runtime/zig/panic.zig` 保持 BPF-safe no-return path；Solana-friendly logging 留到 P3 |
| 一等 closure BPF build 失败或运行时 fault | Closure lowering 回退到不支持的 code-pointer relocation 或无效 capture 地址 | 保持 P2 closure hardening：已知 callee 尽量 lower 成直接 helper 调用，一等 closure 使用 arena-backed capture storage 和类型化 dispatch 元数据；`SOLANA_BPF=1` 时 `tests/solana/closures/invoke.sh` 必须保持绿色 |
| BPF verifier 拒绝程序 | 栈帧过深、无界循环、非法 helper、或不支持的 relocation | 简化生成代码，对照 Solana harness 输出；P3 增加 no-alloc / stack analysis |
| Solana loader 因 ELF layout 失败 | section layout 或 exported symbol 错误 | 与 P1 已知可用的 `solana_hello.so` flow 对比；疑似 linker 问题上报上游，并固定最后可用版本 |
| 程序可部署但返回值错误 | 后端语义与解释器分叉 | Determinism suite（`05-backends.md` §6）必须捕获 native 分叉；BPF-only 分叉需增加 Solana harness case |
| validation 说缺少 `examples/solana_hello.ml` | 历史 M0 使用 `examples/m0_zero.ml`；M3 才加入 canonical Solana example | P1 之后 G06/G13 使用 `examples/solana_hello.ml` |
| CI corpus loop 因 `examples/m0_unsupported.ml` 失败 | 该文件是刻意失败的诊断 fixture | corpus loop 跳过它，或将未来 negative example 放到 `tests/ui/` |
| 文档/命令提到 `zig build test -Dtest-filter=...` 但实际不支持 | build option 尚未实现 | 在 scoped test filtering 落地前使用普通 `zig build test` |
| `zig build test` 打印 `zxc-frontend not found ...` | negative subprocess-path test 刻意测试该诊断 | 只要测试命令 exit 0，就视为预期输出 |
| macOS 上 `ocamlc -c ... -o /dev/null` 失败 | OCaml 会尝试创建 `/dev/null.cmi.tmp` | 使用 `ocamlfind ocamlc -i stdlib/core.ml > /dev/null`，或把 artifact 写到 `/tmp` |

## 9. 最初 P1 target contract 的范围之外

最初的 BPF target contract 排除了 IDL 生成、BPF 端日志、Program-derived address（PDA）、
cross-program invocation（CPI）、compute-unit 预算分析，以及 upgrade-authority / multisig 流程。
已封存的 P3/P5 工作后来加入了 logging、PDA/CPI helpers、no-allocation checks 和
Anchor-compatible IDL；upgrade-authority 和 multisig 流程仍在 compiler target contract 之外。

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
