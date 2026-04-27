# Preflight results — Spike β (BPF toolchain)

> Sibling document to `preflight-results.md` (Spike α).
> Languages / 语言: **English** · [简体中文](./zh/preflight-results-spike-beta.md)

## Environment
- **macOS version**: 26.4.1 (build 25E253), Apple Silicon (`aarch64-apple-darwin`)
- **zig version**: 0.16.0
- **rustc version**: 1.94.1 (e408947bf 2026-03-25) (Homebrew)
- **cargo version**: 1.94.1 (Homebrew)
- **solana-cli version**: 3.1.12 (Agave; src 6c1ba346; feat 4140108451)
- **sbpf-linker version**: 0.1.8 (crates.io, ADR-012 pin)  ✅
- **zignocchio commit reproduced**: `7300b6c39034d5593a7d98e72c34b60b1c951a05`

## What we did

We installed `sbpf-linker 0.1.8` from crates.io exactly per ADR-012, cloned
`DaviRain-Su/zignocchio` (used as inspiration only — not vendored, per ADR-014),
and built the `hello` example end-to-end on this machine: `zig build-lib
-target bpfel-freestanding -femit-llvm-bc=entrypoint.bc` → `sbpf-linker --cpu v2
--export entrypoint -o hello.so entrypoint.bc`. We then booted
`solana-test-validator --reset --quiet`, deployed `hello.so`, and submitted a
no-op invocation transaction whose log output and exit status we captured.

## Build artefact
- **Path**: `spike/bpf-toolchain/zignocchio/zig-out/lib/hello.so`
- **Size**: 1160 bytes
- **`file` output**: `ELF 64-bit LSB shared object, eBPF, version 1 (SYSV), dynamically linked, stripped`
- **ELF header highlights**:
  - Class `ELF64`, little-endian, `Machine: EM_BPF`, `Type: DYN`
  - 8 sections including `.text`, `.rodata`, `.dynamic`, `.dynsym`, `.dynstr`, `.rel.dyn`
- **`llvm-objdump -d` head** (last few instructions of `.text`):

  ```
  00000000000000e8 <.text>:
        29: 79 11 ...  r1 = *(u64 *)(r1 + 0x0)
        30: 15 01 ...  if r1 == 0x0 goto +0x0
        31: 18 01 ...  r1 = 0x128 ll
        33: b7 02 ...  r2 = 0x16
        34: 85 10 ff ff ff ff   call -0x1     # syscall (sol_log_)
        35: b7 00 ...  r0 = 0x0
        36: 95 00 ...  exit
  ```

## Deployment result
- `solana program deploy`: **SUCCESS**
  - Program ID: `C6qKh4Uff14LX9urgSf1UUaXZBBjupNwmF1VMRfRDSSX`
  - Deploy tx signature: `2KvrcQWxrkzPFq5qDLAV796tkVFSHpft5CK4PSK17itBva85MmpHcUo37wSX1WKi2v8msuv7R6Bcpohm3P3m1RPm`
- `solana program show`:
  - Owner: `BPFLoaderUpgradeab1e11111111111111111111111`
  - Data Length: 1160 bytes
  - Last Deployed In Slot: 72
- **Test invocation result**: empty-data transaction confirmed `finalized`,
  `err: null`, `status: Ok`, `computeUnitsConsumed: 107`.
  Logs:
  ```
  Program C6qKh4Uff14LX9urgSf1UUaXZBBjupNwmF1VMRfRDSSX invoke [1]
  Program log: Hello from Zignocchio!
  Program ... consumed 107 of 200000 compute units
  Program ... success
  ```

## Acceptance

| # | Criterion | Result |
|---|---|---|
| 1 | sbpf-linker installs from pinned version (0.1.8, crates.io) | ✅ PASS |
| 2 | zignocchio hello builds end-to-end | ✅ PASS (with macOS LLVM-dylib workaround, see below) |
| 3 | Output is a valid SBPF ELF `.so` | ✅ PASS (`EM_BPF`, `DYN`, sections present) |
| 4 | solana-test-validator accepts deploy | ✅ PASS (no `Access violation` / `Invalid section`) |
| 5 | No-op invocation returns 0 | ✅ PASS (`r0 = 0; exit`, `status: Ok`, `err: null`) |

## Risks / surprises observed

1. **`sbpf-linker` cannot find `libLLVM` at runtime on macOS without help.**
   `aya-rustc-llvm-proxy 0.10.0` (used by `sbpf-linker`) `dlopen`s the first
   `libLLVM*` it finds in `LD_LIBRARY_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`, or
   any `lib/` adjacent to a `PATH` entry. On a stock macOS + Homebrew
   environment **none of these paths contain a `libLLVM.dylib`** by default,
   so the linker panics with `unable to find LLVM shared lib`.
   - **Workaround used in `reproduce.sh`**: export
     `DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix llvm@20)/lib"` before
     invoking `sbpf-linker`.
   - We chose `llvm@20` because `sbpf-linker 0.1.8` was built against the
     LLVM 20 ABI; using `llvm@21` (the version Homebrew Rust links against)
     also "works" in the sense of resolving symbols at runtime, but is not
     ABI-guaranteed.

2. **`zignocchio`'s `build.zig` actively breaks the macOS build.**
   It hard-codes `LD_LIBRARY_PATH=.zig-cache/llvm_fix` containing a Linux-only
   symlink to `/usr/lib/x86_64-linux-gnu/libLLVM.so.20.1`. On macOS that path
   does not exist; setting `LD_LIBRARY_PATH` to it makes
   `aya-rustc-llvm-proxy` `dlopen` the broken symlink first, which fails, and
   then the proxy continues searching but can still panic before finding a
   real dylib. Our `reproduce.sh` invokes `sbpf-linker` directly to bypass
   the build script's Linux assumption.

3. **zignocchio uses `--cpu v2`, not `--cpu v3`.**
   `06-bpf-target.md` and our ADRs assume **SBPFv3** as the build target.
   Zignocchio's own `build.zig` and AGENTS.md state `sBPF v2` ("v2: No 32-bit
   jumps (Solana sBPF compatible)"). This deserves a doc revision: either
   align ZxCaml on v2 by default and treat v3 as opt-in (matching the wider
   Solana ecosystem today), or document the v2/v3 distinction explicitly.
   Mainnet validators currently default to v2; v3 features (e.g. static
   syscalls) require activation flags. The `hello` artefact we produced is
   `--cpu v2` and was accepted by `solana-test-validator` 3.1.12 without
   issue.

4. **Zig 0.16 low-address const-array workaround (referenced in
   `06-bpf-target.md` §4): NOT encountered.** The `hello` example does
   include an inlined `[_]u8{...}` string literal (rather than a top-level
   `const` array, which the doc mentions can land in low BPF addresses).
   This pattern is exactly the workaround already documented; we did not
   need to discover or invent any new mitigation. The `.rodata` section in
   our artefact lives at file offset `0x128` and contains
   `Hello from Zignocchio!`, which decodes correctly via the syscall.

5. **`solana program show` warning**: The first runs of `solana airdrop`
   reported a balance of `500000010 SOL` (i.e. 500_000_000 SOL pre-existing
   on the test ledger plus the 10 we requested). This is a `solana-cli 3.x`
   default behaviour for `--reset` ledgers and is not a problem; flagged
   for future-us only.

6. **Homebrew Rust quirk**: `librustc_driver-*.dylib` from Homebrew Rust links
   against `llvm@21`'s `libLLVM.dylib`, but `sbpf-linker 0.1.8` itself
   embeds the LLVM 20 C-API entry points. They do not collide because
   `sbpf-linker` is statically linked except for `libSystem`/`libiconv` and
   uses the dynamic proxy only. Worth recording in case a future ADR
   considers requiring rustup-installed Rust instead of Homebrew Rust.

## Verdict

**PROCEED — toolchain works as ADR-012/013 assume**, with two small
caveats that should be reflected in our docs (do NOT enact in this spike).

In one paragraph: `cargo install sbpf-linker --version 0.1.8 --locked` works,
the resulting linker successfully consumes Zig-generated LLVM bitcode, and
the `.so` it produces is loaded and executed by a current `solana-test-validator`
without verifier complaints. The `hello` program logs and returns 0 at
107 compute units. The two caveats are (a) the macOS environment needs a
`DYLD_FALLBACK_LIBRARY_PATH=$(brew --prefix llvm@20)/lib` shim to satisfy
`aya-rustc-llvm-proxy`'s dlopen, and (b) zignocchio itself targets `--cpu v2`,
not the `--cpu v3` our docs reference.

## Implications for ZxCaml docs (recommendations only — not enacted)

1. **`docs/06-bpf-target.md` §6 ("build flags")**: should document the
   macOS LLVM-dylib environment issue and the
   `DYLD_FALLBACK_LIBRARY_PATH=$(brew --prefix llvm@20)/lib` shim. Linux
   users with rustup-installed Rust likely don't hit this, but our
   developer baseline (Homebrew Rust on macOS) does.
2. **`docs/06-bpf-target.md` and ADR-013**: clarify the `--cpu v2` vs
   `--cpu v3` decision. Today's reference (zignocchio) uses v2; if ZxCaml
   really wants v3, we need an explicit reason and a feature-flag plan,
   not just "use v3 because it's newer". A defensible default is **v2 by
   default, v3 opt-in**, matching the upstream ecosystem.
3. **ADR-012**: keep the pin at `sbpf-linker = 0.1.8` — it works as
   advertised. Optionally add a note that the underlying LLVM ABI is
   LLVM 20, so on macOS the matching Homebrew formula is `llvm@20`.
4. **CONTRIBUTING / preflight script**: add an explicit dependency check
   for `brew --prefix llvm@20` on macOS, surfaced before any build attempt.
5. **No change needed** to ADR-014 (no-vendor-zignocchio): we successfully
   used it as inspiration without copying its source, and `.gitignore`
   keeps the local clone out of our tree.
