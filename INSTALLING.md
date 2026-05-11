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
| solana-cli | stable | Runs the BPF acceptance harness and local validator checks | Installed only when `SOLANA_BPF=1` is set before running `init.sh` |

### P3 dependency state

P3 adds Solana runtime integration but introduces **no new compiler build
prerequisites** beyond the P1/P2 toolchain listed above. The same `./init.sh`,
`zig build`, and `zig build test` commands are used locally and in CI.

For BPF acceptance runs, `SOLANA_BPF=1 ./init.sh` must make
`solana-test-validator` available. The SPL-Token transfer harness additionally
expects the `spl-token` CLI and the legacy SPL Token program
`TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA` on the local validator. No extra
tool is needed for `omlz check --no-alloc` or `omlz idl`.

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
3. `solana`, `solana-keygen`, and `solana-test-validator` when `SOLANA_BPF=1`.

If you intend to run the SPL-Token acceptance harness, also ensure
`spl-token --version` succeeds in the same shell.

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

### Solana CLI installation

If you need local validator workflows (`SOLANA_BPF=1`), ensure these commands
are available after running `init.sh`:

```sh
solana --version
solana-keygen --version
solana-test-validator --version
```

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

`solana` and related CLI tools are required only when running with `SOLANA_BPF=1`.


After setup, these commands should succeed:

```sh
zig version
ocaml -vnum
zig build
zig build test
zig-out/bin/omlz check --no-alloc examples/arith_wrap.ml
zig-out/bin/omlz idl tests/idl/entrypoint.ml
zig-out/bin/omlz build examples/solana_hello.ml --target=bpf -o sh.so
```
