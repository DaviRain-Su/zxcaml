# Spike β — BPF toolchain reproduction

This directory contains the **scripts and notes** used to verify on this developer
machine that the Zig + sbpf-linker toolchain assumed by ADR-012/013 actually
produces a Solana-loadable `.so`.

The upstream reference project we reproduced is **`DaviRain-Su/zignocchio`**
(commit `7300b6c`). We do NOT vendor it (per ADR-014); it is git-cloned locally
into `spike/bpf-toolchain/zignocchio/` and that path is `.gitignore`d.

For the verdict, see [`docs/preflight-results-spike-beta.md`](../../docs/preflight-results-spike-beta.md)
(or [中文](../../docs/zh/preflight-results-spike-beta.md)).

## Reproduce

```sh
./reproduce.sh
```

The script:
1. Clones `zignocchio` if missing.
2. Builds `examples/hello/lib.zig` to LLVM bitcode via `zig build-lib -target bpfel-freestanding -femit-llvm-bc`.
3. Links to a Solana ELF with `sbpf-linker --cpu v2` (note: zignocchio
   uses **v2**, not v3 — see the verdict for implications).
4. Starts a `solana-test-validator`, deploys, and confirms `solana program show` succeeds.

## Key findings recorded here, full details in the verdict doc

- `sbpf-linker 0.1.8` (ADR-012 pin) installs cleanly from crates.io.
- On macOS with **Homebrew Rust**, `sbpf-linker` cannot find `libLLVM` at runtime:
  `aya-rustc-llvm-proxy` searches `LD_LIBRARY_PATH` / `DYLD_FALLBACK_LIBRARY_PATH`
  / `PATH→lib`, none of which contain a `libLLVM*.dylib` by default.
  Workaround: `DYLD_FALLBACK_LIBRARY_PATH=$(brew --prefix llvm@20)/lib`.
  This is required because Homebrew Rust dynamically links to `llvm@21`'s
  `libLLVM.dylib`, but `sbpf-linker 0.1.8` was built against LLVM 20 ABI.
- The zignocchio `build.zig` hard-codes `LD_LIBRARY_PATH=.zig-cache/llvm_fix`
  pointing at a Linux `.so` path. On macOS this points at a non-existent file,
  which makes `aya-rustc-llvm-proxy` fail. `reproduce.sh` works around this by
  invoking `sbpf-linker` directly with the right `DYLD_FALLBACK_LIBRARY_PATH`.
- zignocchio uses `--cpu v2`, not `--cpu v3`. See the verdict for what this
  means for our 06-bpf-target.md and ADR-013 assumptions.
