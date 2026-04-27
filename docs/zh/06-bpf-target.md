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
