# Installing ZxCaml

> **Languages / 语言**: **English** · [简体中文](./docs/zh/INSTALLING.md)

## TL;DR

`init.sh` is the canonical setup script for local development and CI. On a fresh
macOS machine, install Homebrew and Rust first, then run:

```sh
SOLANA_BPF=1 ./init.sh
zig build
zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```

The last command should produce `sh.so`, a Solana BPF shared object.

## Prerequisites

| Tool | Required version | How ZxCaml uses it | What `init.sh` does |
|---|---:|---|---|
| Zig | `0.16.0` | Builds `omlz`, the Zig runtime helpers, and generated Zig code | Installs Zig `0.16.0` under `~/zig` if the active `zig` is not exactly `0.16.0` |
| opam + OCaml | OCaml `5.2.x` | Builds the OCaml `zxc-frontend` glue with upstream `compiler-libs` | Installs `opam` via Homebrew on macOS if needed, creates switch `zxcaml-p1` with OCaml `5.2.1`, and installs `ocamlfind` |
| cargo + `sbpf-linker` | `sbpf-linker 0.1.8` | Links Zig-emitted LLVM bitcode into Solana-loadable `.so` files | Requires `cargo`; installs `sbpf-linker --version 0.1.8` with `cargo install --locked --force` |
| solana-cli | stable | Runs the BPF acceptance harness and local validator checks | Installed only when `SOLANA_BPF=1` is set before running `init.sh` |
| macOS `llvm@20` | Homebrew `llvm@20` | Provides `libLLVM` for `sbpf-linker 0.1.8` on macOS | Installs `llvm@20` via Homebrew on macOS and exports `DYLD_FALLBACK_LIBRARY_PATH` while the script runs |

### P2 dependency state

P2 adds compiler/language support only; it introduces **no new external
prerequisites** beyond the P1 toolchain listed above. The same `./init.sh`,
`zig build`, and `zig build test` commands are used locally and in CI.

`init.sh` deliberately does not install Homebrew or Rust. On fresh macOS, install
those first:

```sh
# Homebrew: follow https://brew.sh/
# Rust/cargo:
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Open a new shell after installing Rust so that `cargo` is on `PATH`.

## Fresh macOS install

From the repository root:

```sh
SOLANA_BPF=1 ./init.sh
```

This is the same script CI uses. It verifies or installs:

1. `zig 0.16.0`;
2. `opam`, switch `zxcaml-p1`, OCaml `5.2.1`, `ocamlfind`, and `compiler-libs`;
3. `sbpf-linker 0.1.8`;
4. Homebrew `llvm@20` and the macOS LLVM dynamic-library path;
5. `solana`, `solana-keygen`, and `solana-test-validator` when `SOLANA_BPF=1`.

Then build the compiler:

```sh
zig build
zig-out/bin/omlz --version
```

Build the canonical Solana example:

```sh
zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
file sh.so
```

`file sh.so` should report an ELF eBPF/SBPF shared object.

If you only need to build `omlz` and a BPF `.so`, `./init.sh` without
`SOLANA_BPF=1` is enough. Use `SOLANA_BPF=1 ./init.sh` when you also want the
local Solana validator tools.

## Troubleshooting

### `sbpf-linker: unable to find LLVM shared lib`

On macOS, `sbpf-linker 0.1.8` loads LLVM dynamically. `init.sh` installs
Homebrew `llvm@20` and exports the fallback path while it runs. If you invoke
`sbpf-linker` directly in a different shell, export the same value:

```sh
export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix llvm@20)/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
```

### Missing `libLLVM`

Install or repair Homebrew `llvm@20`:

```sh
brew install llvm@20
brew --prefix llvm@20
```

The prefix must contain a `lib/` directory with `libLLVM*.dylib`.

### opam switch creation fails

`init.sh` expects switch `zxcaml-p1` to contain OCaml `5.2.x`. If the switch is
missing or corrupted, recreate it:

```sh
opam switch remove zxcaml-p1
opam switch create zxcaml-p1 5.2.1 -y
eval "$(opam env --switch=zxcaml-p1 --set-switch)"
opam install -y ocamlfind
```

Then rerun:

```sh
./init.sh
```

### `cargo not found`

Install Rust from `https://rustup.rs/`, open a new shell, and rerun `./init.sh`.

## Verification checklist

After setup, these commands should succeed:

```sh
zig version
ocaml -vnum
sbpf-linker --version
zig build
zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```
