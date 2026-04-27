# 预飞结果 — Spike β（BPF 工具链）

> Spike α 的姊妹文档：`preflight-results.md`。
> 语言 / Languages：[English](../preflight-results-spike-beta.md) · **简体中文**

## 环境
- **macOS 版本**：26.4.1（构建 25E253），Apple Silicon（`aarch64-apple-darwin`）
- **zig 版本**：0.16.0
- **rustc 版本**：1.94.1（e408947bf 2026-03-25）（Homebrew）
- **cargo 版本**：1.94.1（Homebrew）
- **solana-cli 版本**：3.1.12（Agave；src 6c1ba346；feat 4140108451）
- **sbpf-linker 版本**：0.1.8（来自 crates.io，对应 ADR-012 的版本固定） ✅
- **复现的 zignocchio 提交**：`7300b6c39034d5593a7d98e72c34b60b1c951a05`

## 我们做了什么

我们严格按照 ADR-012 从 crates.io 安装了 `sbpf-linker 0.1.8`，克隆了
`DaviRain-Su/zignocchio`（依据 ADR-014，仅作为参考，未 vendor 进仓库），并在
本机端到端构建了 `hello` 示例：`zig build-lib -target bpfel-freestanding
-femit-llvm-bc=entrypoint.bc` → `sbpf-linker --cpu v2 --export entrypoint -o
hello.so entrypoint.bc`。随后启动 `solana-test-validator --reset --quiet`，
部署 `hello.so`，并提交了一笔空数据的 no-op 调用，记录其日志和退出状态。

## 构建产物
- **路径**：`spike/bpf-toolchain/zignocchio/zig-out/lib/hello.so`
- **大小**：1160 字节
- **`file` 输出**：`ELF 64-bit LSB shared object, eBPF, version 1 (SYSV), dynamically linked, stripped`
- **ELF 头要点**：
  - Class `ELF64`，小端，`Machine: EM_BPF`，`Type: DYN`
  - 8 个 section，包含 `.text`、`.rodata`、`.dynamic`、`.dynsym`、`.dynstr`、`.rel.dyn`
- **`llvm-objdump -d` 头部**（`.text` 末尾几条指令）：

  ```
  00000000000000e8 <.text>:
        29: 79 11 ...  r1 = *(u64 *)(r1 + 0x0)
        30: 15 01 ...  if r1 == 0x0 goto +0x0
        31: 18 01 ...  r1 = 0x128 ll
        33: b7 02 ...  r2 = 0x16
        34: 85 10 ff ff ff ff   call -0x1     # syscall（sol_log_）
        35: b7 00 ...  r0 = 0x0
        36: 95 00 ...  exit
  ```

## 部署结果
- `solana program deploy`：**成功**
  - 程序 ID：`C6qKh4Uff14LX9urgSf1UUaXZBBjupNwmF1VMRfRDSSX`
  - 部署交易签名：`2KvrcQWxrkzPFq5qDLAV796tkVFSHpft5CK4PSK17itBva85MmpHcUo37wSX1WKi2v8msuv7R6Bcpohm3P3m1RPm`
- `solana program show`：
  - Owner：`BPFLoaderUpgradeab1e11111111111111111111111`
  - 数据长度：1160 字节
  - 部署所在槽：72
- **测试调用结果**：空数据交易确认为 `finalized`，`err: null`，
  `status: Ok`，`computeUnitsConsumed: 107`。日志：
  ```
  Program C6qKh4Uff14LX9urgSf1UUaXZBBjupNwmF1VMRfRDSSX invoke [1]
  Program log: Hello from Zignocchio!
  Program ... consumed 107 of 200000 compute units
  Program ... success
  ```

## 验收

| # | 标准 | 结果 |
|---|---|---|
| 1 | 按固定版本安装 sbpf-linker（0.1.8，crates.io） | ✅ 通过 |
| 2 | zignocchio hello 端到端构建成功 | ✅ 通过（macOS 需走 LLVM-dylib 兼容方案，详见下文） |
| 3 | 输出为合法的 SBPF ELF `.so` | ✅ 通过（`EM_BPF`、`DYN`、section 完整） |
| 4 | solana-test-validator 接受部署 | ✅ 通过（无 `Access violation` / `Invalid section`） |
| 5 | no-op 调用返回 0 | ✅ 通过（`r0 = 0; exit`，`status: Ok`，`err: null`） |

## 风险 / 意外发现

1. **macOS 上 `sbpf-linker` 在运行时找不到 `libLLVM`**。
   `sbpf-linker` 依赖的 `aya-rustc-llvm-proxy 0.10.0` 会在
   `LD_LIBRARY_PATH`、`DYLD_FALLBACK_LIBRARY_PATH`，或 `PATH` 项相邻的
   `lib/` 中按顺序 `dlopen` 第一个匹配的 `libLLVM*`。在原生
   macOS + Homebrew 环境里，**这些路径默认都没有 `libLLVM.dylib`**，
   导致链接器以 `unable to find LLVM shared lib` panic。
   - **`reproduce.sh` 中采用的兼容方案**：在调用 `sbpf-linker` 之前
     `export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix llvm@20)/lib"`。
   - 选择 `llvm@20` 是因为 `sbpf-linker 0.1.8` 是基于 LLVM 20 ABI 编译的；
     使用 Homebrew Rust 链接的 `llvm@21` 在符号解析层面也"能用"，但不
     保证 ABI 兼容。

2. **zignocchio 的 `build.zig` 在 macOS 上会主动破坏构建**。
   它硬编码了 `LD_LIBRARY_PATH=.zig-cache/llvm_fix`，里面是一个指向
   Linux 路径 `/usr/lib/x86_64-linux-gnu/libLLVM.so.20.1` 的符号链接。
   macOS 上该文件不存在；把这个路径塞进 `LD_LIBRARY_PATH` 会让
   `aya-rustc-llvm-proxy` 先尝试 `dlopen` 这个坏链接而失败，并可能在
   找到真正 dylib 之前就 panic。我们的 `reproduce.sh` 直接调用
   `sbpf-linker`，绕过 build script 中的 Linux 假设。

3. **zignocchio 使用 `--cpu v2`，不是 `--cpu v3`**。
   `06-bpf-target.md` 和我们的 ADR 假设构建目标是 **SBPFv3**。zignocchio 自己
   的 `build.zig` 与 AGENTS.md 都明确写成 `sBPF v2`（"v2: 无 32-bit 跳转
   （Solana sBPF 兼容）"）。这里值得做一次文档修订：要么把 ZxCaml 默认
   对齐到 v2、把 v3 当成 opt-in（与目前 Solana 生态保持一致），要么明确
   记录 v2/v3 的区别。当前主网验证器默认 v2；v3 的特性（如静态 syscall）
   需要 feature 激活。我们这次产出的 `hello` artefact 是 `--cpu v2`，被
   `solana-test-validator 3.1.12` 顺利接受。

4. **Zig 0.16 低地址常量数组绕路（`06-bpf-target.md` §4 提到）：未触发**。
   `hello` 示例使用了内联的 `[_]u8{...}` 字符串字面量，而不是顶层的
   `const` 数组（文档中说后者可能落到 BPF 的低地址）。这本身就是文档
   已经记录的绕路办法；我们不需要发明新的缓解措施。我们的 artefact
   中 `.rodata` 位于文件偏移 `0x128`，存有 `Hello from Zignocchio!`
   字符串，syscall 能正确解码。

5. **`solana-test-validator --reset` 的初始余额**：第一次 `solana airdrop`
   报告余额为 `500000010 SOL`（即 ledger 预置的 500_000_000 SOL 加上我们
   请求的 10）。这是 `solana-cli 3.x` 在 `--reset` ledger 上的默认行为，
   并非问题；仅作记录。

6. **Homebrew Rust 的小坑**：Homebrew Rust 的 `librustc_driver-*.dylib`
   动态依赖 `llvm@21` 的 `libLLVM.dylib`，但 `sbpf-linker 0.1.8` 自己
   内嵌了 LLVM 20 的 C-API 入口。两者并不冲突，因为 `sbpf-linker` 除
   `libSystem`/`libiconv` 之外是静态链接的，只通过动态代理使用 LLVM。
   这点值得记录，未来若有 ADR 考虑要求使用 rustup 安装的 Rust 而非
   Homebrew Rust 时可以参考。

## 结论

**PROCEED — 工具链按 ADR-012/013 的假设正常工作**，但有两处小注意点
应在文档中体现（本 spike 不直接修改文档）。

一句话总结：`cargo install sbpf-linker --version 0.1.8 --locked` 成功；
该链接器能正确消费 Zig 生成的 LLVM bitcode；产出的 `.so` 被当前的
`solana-test-validator` 正确加载和执行，verifier 没有任何抱怨。
`hello` 程序消耗 107 compute units，打印日志并返回 0。两处注意点是：
（a）macOS 环境需要 `DYLD_FALLBACK_LIBRARY_PATH=$(brew --prefix llvm@20)/lib`
来满足 `aya-rustc-llvm-proxy` 的 dlopen；（b）zignocchio 自身使用
`--cpu v2`，而非我们文档引用的 `--cpu v3`。

## 对 ZxCaml 文档的建议（仅建议，未直接落地）

1. **`docs/06-bpf-target.md` §6（"build flags"）**：应记录 macOS 的
   LLVM-dylib 环境问题与
   `DYLD_FALLBACK_LIBRARY_PATH=$(brew --prefix llvm@20)/lib` 这一兼容
   方案。Linux + rustup 的开发者大概率不会遇到，但我们的开发基线
   （macOS + Homebrew Rust）会遇到。
2. **`docs/06-bpf-target.md` 与 ADR-013**：明确 `--cpu v2` vs `--cpu v3`
   的取舍。今天的参考实现（zignocchio）使用 v2；如果 ZxCaml 真的要
   走 v3，需要明确理由与 feature flag 计划，而不是单纯"用 v3 是因为
   它更新"。一个可以辩护的默认是 **默认 v2，v3 opt-in**，与上游生态
   保持一致。
3. **ADR-012**：保留 `sbpf-linker = 0.1.8` 的版本固定 — 它如所宣告
   工作。可选地附注：底层 LLVM ABI 是 LLVM 20，所以 macOS 上对应
   的 Homebrew formula 是 `llvm@20`。
4. **CONTRIBUTING / 预飞脚本**：在 macOS 上构建之前，明确检查
   `brew --prefix llvm@20` 是否存在，并显式提示。
5. **ADR-014（不 vendor zignocchio）无需更改**：我们成功地把它当作
   参考使用而没有拷贝其源码，且 `.gitignore` 把本地 clone 排除在
   仓库之外。
