# 06 — BPF target

> **Languages / 语言**: **English** · [简体中文](./zh/06-bpf-target.md)

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

## 10. Why not "every target Zig can produce"?

Because the Zig backend emits `.zig` source and then drives the Zig
toolchain, it is tempting to claim that **any target Zig can compile
to is therefore a target ZxCaml supports**. That claim is wrong, and
the wrongness is worth pinning down so it does not creep back in.

There are three independent layers in the chain:

```
1. Zig toolchain        — what Zig can lower to (≈ what LLVM supports)
2. ZxCaml codegen       — what our backend emits valid Zig for
3. ZxCaml runtime       — what we can actually run there
```

Layer 1 is enormous: `aarch64`, `arm`, `x86`, `x86_64`, `riscv*`,
`mips*`, `loongarch*`, `bpfel`/`bpfeb`, `wasm32`/`wasm64`, `nvptx*`,
`amdgcn`, `spirv*`, `avr`, `msp430`, and many more. Listing this is
not the same as supporting it.

Layer 2 is mostly target-agnostic in P1. Our codegen produces
straight-line Zig with no SIMD, no inline asm, no platform intrinsics.
Any reasonable target accepts it.

**Layer 3 is where the optimism dies.** Each target needs at least:

- An **entrypoint shim**. Solana BPF wants
  `u64 entrypoint(const u8 *)`; Linux wants `int main(int, char**)`
  via the libc `_start` shim; WASM wants exported functions; bare
  metal wants a reset vector; eBPF (kernel) wants `SEC(...)` plus a
  context-typed function. Each is hand-written.
- A **panic strategy**. BPF aborts; native may print and exit;
  bare metal may halt or reboot.
- A **memory plan**. BPF gets a static buffer arena; native could
  in principle support `malloc`-backed regions; freestanding ARM has
  to be told where RAM begins. P1 only knows the static-buffer plan.
- An **agreed calling convention to user code**. Implicit
  `arena: *Arena` first parameter is the BPF / freestanding rule;
  hosted targets may want to skip it.

Beyond shims, **the language itself was shaped by BPF's constraints**:

| ZxCaml choice | Why it exists | What it costs elsewhere |
|---|---|---|
| No GC | BPF verifier disallows allocation | x86 could afford GC, we don't have one |
| Single arena | BPF cannot `malloc` | x86 / WASM lose expressiveness |
| No syscalls | BPF only allows whitelisted helpers | x86 cannot open files, cannot print |
| No threads | BPF is single-threaded | Modern targets waste their cores |
| No exceptions | BPF disallows unwind | Unusual for general-purpose targets |
| Bounded stack | BPF verifier stack limit | Limits recursion depth everywhere |

So even if `zig build-obj -target x86_64-linux out/program.zig`
succeeds, the result is a stripped-down OCaml-flavoured language with
no I/O, no GC, no threads, no exceptions, no real stdlib. There is no
audience for that program. **A working toolchain is necessary but not
sufficient**; we would also need to relax the BPF-imposed constraints
on a per-target basis, which is real design work.

### What we **do** allow incidentally

- `omlz build --target=native` is documented for **developer
  convenience only**: it lets you run the compiled program locally to
  spot integration bugs faster than going through
  `solana-test-validator`. It is not a supported deliverable; we do
  not promise stability, performance, or feature parity.

### When a new target becomes a real goal

A target only enters the supported set when **all** of the following
hold:

1. There is a concrete, named use case — not "wouldn't it be nice".
2. Someone owns the entrypoint shim, panic strategy, and memory plan
   for that target.
3. Either the BPF-shaped language constraints already fit the use
   case, or a documented relaxation plan exists (and is approved as
   an ADR).
4. The target gains a CI lane and at least one acceptance example.

Until those conditions hold, "Zig supports it" is interesting
trivia, not a commitment.

See `08-roadmap.md` for the optional, gated **PX — Multi-target
expansion** phase that codifies this rule.
