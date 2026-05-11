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
| solana-cli | stable | 运行 BPF acceptance harness 和本地 validator 检查 | 只有在运行 `init.sh` 前设置了 `SOLANA_BPF=1` 时才安装 |

### P3 依赖状态

P3 增加 Solana runtime integration，但**没有引入新的编译器构建前置依赖**。
本地和 CI 仍使用同一套 `./init.sh`、`zig build`、`zig build test` 命令。

运行 BPF acceptance 时，`SOLANA_BPF=1 ./init.sh` 必须让
`solana-test-validator` 可用。SPL-Token transfer harness 还需要 `spl-token`
CLI，以及本地 validator 上的 legacy SPL Token program
`TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`。运行
`omlz check --no-alloc` 或 `omlz idl` 不需要额外工具。

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
3. 当 `SOLANA_BPF=1` 时的 `solana`、`solana-keygen` 和 `solana-test-validator`。

如果你要运行 SPL-Token acceptance harness，还要确保同一个 shell 中
`spl-token --version` 能成功。

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

### Solana CLI 安装

如果需要本地 validator 工作流（`SOLANA_BPF=1`），请确保运行 `init.sh`
后以下命令可用：

```sh
solana --version
solana-keygen --version
solana-test-validator --version
```

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

`solana` 和相关 CLI 工具仅在启用 `SOLANA_BPF=1` 时才需要。


setup 后，以下命令应成功：

```sh
zig version
ocaml -vnum
zig build
zig build test
zig-out/bin/omlz check --no-alloc examples/arith_wrap.ml
zig-out/bin/omlz idl tests/idl/entrypoint.ml
zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```
