# 安装 ZxCaml

> **Languages / 语言**: [English](../../INSTALLING.md) · **简体中文**

## TL;DR

`init.sh` 是本地开发和 CI 的规范 setup 脚本。在一台全新的 macOS 机器上，
先安装 Homebrew 和 Rust，然后运行：

```sh
SOLANA_BPF=1 ./init.sh
zig build
zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```

最后一个命令应产出 `sh.so`，也就是一个 Solana BPF shared object。

## 前置依赖

| 工具 | 要求版本 | ZxCaml 如何使用它 | `init.sh` 会做什么 |
|---|---:|---|---|
| Zig | `0.16.0` | 构建 `omlz`、Zig runtime helper，以及生成出来的 Zig 代码 | 如果当前激活的 `zig` 不是精确的 `0.16.0`，就在 `~/zig` 下安装 Zig `0.16.0` |
| opam + OCaml | OCaml `5.2.x` | 用上游 `compiler-libs` 构建 OCaml `zxc-frontend` 胶水 | 如有需要，在 macOS 上通过 Homebrew 安装 `opam`，创建带 OCaml `5.2.1` 的 `zxcaml-p1` switch，并安装 `ocamlfind` |
| cargo + `sbpf-linker` | `sbpf-linker 0.1.8` | 把 Zig 产出的 LLVM bitcode 链接成 Solana 可加载的 `.so` 文件 | 要求已有 `cargo`；用 `cargo install --locked --force` 安装 `sbpf-linker --version 0.1.8` |
| solana-cli | stable | 运行 BPF acceptance harness 和本地 validator 检查 | 只有在运行 `init.sh` 前设置了 `SOLANA_BPF=1` 时才安装 |
| macOS `llvm@20` | Homebrew `llvm@20` | 在 macOS 上为 `sbpf-linker 0.1.8` 提供 `libLLVM` | 在 macOS 上通过 Homebrew 安装 `llvm@20`，并在脚本运行期间导出 `DYLD_FALLBACK_LIBRARY_PATH` |

### P2 依赖状态

P2 只增加编译器/语言功能；它 **没有引入新的外部前置依赖**。本地和 CI 仍使用
同一套 `./init.sh`、`zig build`、`zig build test` 命令。

`init.sh` 有意不安装 Homebrew 或 Rust。在全新的 macOS 上，请先安装它们：

```sh
# Homebrew：按 https://brew.sh/ 操作
# Rust/cargo：
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

安装 Rust 后打开一个新的 shell，让 `cargo` 出现在 `PATH` 上。

## 全新 macOS 安装

从仓库根目录运行：

```sh
SOLANA_BPF=1 ./init.sh
```

这就是 CI 使用的同一个脚本。它会验证或安装：

1. `zig 0.16.0`；
2. `opam`、`zxcaml-p1` switch、OCaml `5.2.1`、`ocamlfind` 和 `compiler-libs`；
3. `sbpf-linker 0.1.8`；
4. Homebrew `llvm@20` 和 macOS LLVM 动态库路径；
5. 当 `SOLANA_BPF=1` 时的 `solana`、`solana-keygen` 和 `solana-test-validator`。

然后构建编译器：

```sh
zig build
zig-out/bin/omlz --version
```

构建规范 Solana 示例：

```sh
zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
file sh.so
```

`file sh.so` 应报告一个 ELF eBPF/SBPF shared object。

如果你只需要构建 `omlz` 和一个 BPF `.so`，不带 `SOLANA_BPF=1` 的
`./init.sh` 就足够了。当你还需要本地 Solana validator 工具时，使用
`SOLANA_BPF=1 ./init.sh`。

## 故障排查

### `sbpf-linker: unable to find LLVM shared lib`

在 macOS 上，`sbpf-linker 0.1.8` 会动态加载 LLVM。`init.sh` 会安装
Homebrew `llvm@20`，并在它运行期间导出 fallback 路径。如果你在另一个
shell 中直接调用 `sbpf-linker`，请导出同样的值：

```sh
export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix llvm@20)/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
```

### 缺少 `libLLVM`

安装或修复 Homebrew `llvm@20`：

```sh
brew install llvm@20
brew --prefix llvm@20
```

该 prefix 必须包含带有 `libLLVM*.dylib` 的 `lib/` 目录。

### opam switch 创建失败

`init.sh` 期望 switch `zxcaml-p1` 包含 OCaml `5.2.x`。如果该 switch
缺失或损坏，请重新创建它：

```sh
opam switch remove zxcaml-p1
opam switch create zxcaml-p1 5.2.1 -y
eval "$(opam env --switch=zxcaml-p1 --set-switch)"
opam install -y ocamlfind
```

然后重新运行：

```sh
./init.sh
```

### `cargo not found`

从 `https://rustup.rs/` 安装 Rust，打开一个新的 shell，然后重新运行
`./init.sh`。

## 验证清单

setup 后，以下命令应成功：

```sh
zig version
ocaml -vnum
sbpf-linker --version
zig build
zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```
