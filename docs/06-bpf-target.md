# 06 — BPF target

## 1. Goal

Phase 1 must end with this command sequence succeeding end-to-end on
a developer's machine:

```sh
omlz build examples/solana_hello.ml --target=bpf -o solana_hello.o
solana-test-validator &                          # in another shell
solana program deploy ./solana_hello.o
```

…and a subsequent transaction calling the program must return `0`.

## 2. Toolchain chain

```text
.ml
 │  omlz frontend + ArenaStrategy + ZigBackend
 ▼
out/program.zig + out/runtime.zig + out/build.zig
 │  zig build-obj -target bpfel-freestanding -O ReleaseSmall
 ▼
program.o   (Solana-loadable BPF ELF)
```

We deliberately do **not** invoke LLVM directly. `zig` 0.16 ships an
LLVM that knows the BPF target; we drive it via `zig build-obj`.

## 3. Target triple

```
bpfel-freestanding
```

- `bpfel` — little-endian eBPF (Solana's flavour).
- `freestanding` — no host OS surface.

We do **not** use the Solana-specific LLVM fork in P1. If the stock
`zig`-bundled LLVM proves insufficient, P3 may add an alternative
toolchain path; P1 must not depend on this.

## 4. Entrypoint contract

A Solana BPF program exposes one symbol:

```c
uint64_t entrypoint(const uint8_t *input);
```

In ZxCaml, the user writes:

```ocaml
let entrypoint _input = 0
```

The driver wraps this in `runtime/zig/bpf_entry.zig` (P1
hand-written, generated thereafter):

```zig
// runtime/zig/bpf_entry.zig (sketch)
export fn entrypoint(input: [*]const u8) callconv(.c) u64 {
    var buf: [ARENA_BYTES]u8 align(8) = undefined;
    var arena = Arena.fromStaticBuffer(&buf);
    return omlz_user_entrypoint(&arena, input);
}
```

The compiler's job is to emit `omlz_user_entrypoint` with the
correct signature. The runtime shim is what Solana actually loads.

## 5. Runtime artefacts (`runtime/zig/`)

| File | Role |
|---|---|
| `arena.zig` | Bump allocator over a static buffer. Used by every program. |
| `panic.zig` | BPF-safe panic: writes a small marker and aborts. No stdlib panic handler. |
| `bpf_entry.zig` | The `entrypoint` shim above. |
| `prelude.zig` | Helpers: integer wrap, ADT discriminator helpers, list cons. |

P1 explicitly does **not** include:

- syscall wrappers (`sol_log_`, `sol_invoke_signed`, …) — P3
- account parsing — P3
- CPI helpers — P3
- error-code conventions beyond returning a `u64` — P3

## 6. Build flags

For BPF:

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

For native (developer convenience only, **not** a P1 deliverable):

```sh
zig build-exe -O Debug out/program.zig
```

## 7. Sanity checks before "P1 done"

A BPF `.o` produced by P1 must satisfy:

1. `llvm-objdump -d solana_hello.o` shows a single `entrypoint`
   symbol with valid eBPF instructions.
2. Loadable by `solana-test-validator`:
   ```sh
   solana program deploy ./solana_hello.o
   ```
   succeeds.
3. A no-op invocation returns `0`.
4. The object file is reproducible: identical input → identical
   bytes (modulo timestamp metadata).

Items 1–3 are CI gates. Item 4 is best-effort in P1, mandatory in P3.

## 8. What can go wrong (and how we respond)

| Symptom | Likely cause | Response |
|---|---|---|
| `zig` rejects the target triple | Zig version drift | Pin `zig 0.16.x` in CI; document upgrade in ADR |
| BPF verifier rejects the program | Stack frames too deep, unbounded loops, illegal helper | Frontend / ANF lowering escape analysis (P3) |
| Solana loader fails | ELF section layout off | Check `runtime/zig/bpf_entry.zig` linker flags |
| Returns wrong value | Backend mismatches interpreter | Determinism suite (`05-backends.md` §6) catches this |

## 9. Out of scope (P1)

- IDL generation (Anchor-style)
- BPF-side logging
- Program-derived addresses
- Cross-program invocation
- Compute-unit budgeting analysis
- Upgrade authority / multisig flows

These are explicitly P3+ work.
