# 06 — BPF target

> **Languages / 语言**: **English** · [简体中文](./zh/06-bpf-target.md)

## 1. Goal

Phase 1 must end with this command sequence succeeding end-to-end on
a developer's machine:

```sh
omlz build examples/solana_hello.ml --target=bpf -o solana_hello.so
solana-test-validator &                          # in another shell
solana program deploy ./solana_hello.so
```

…and a subsequent transaction calling the program must return `0`.

> **Output is `.so`, not `.o`.** Solana's BPF loader expects an ELF
> shared object. We name the artefact `program.so` throughout.

## 2. Toolchain chain (validated by zignocchio)

```text
.ml
 │  omlz frontend + ArenaStrategy + ZigBackend
 ▼
out/program.zig + out/runtime.zig + out/build.zig
 │  zig build-lib -target bpfel-freestanding -femit-llvm-bc=…
 ▼
out/program.bc   (LLVM bitcode)
 │  sbpf-linker --cpu v3 --export entrypoint
 ▼
program.so   (Solana-loadable SBPF ELF)
```

The toolchain is **not** "stock `zig build-obj`". The actual chain
that produces a Solana-loadable artefact is:

1. `zig build-lib … -femit-llvm-bc` → emit LLVM bitcode (the `.bc`
   file is the deliverable from this step; the `.o` `zig` would
   produce on its own is **not** a Solana-compatible ELF).
2. **`sbpf-linker --cpu v3 --export entrypoint`** → produce
   `program.so`. This is a Solana-specific linker that knows about
   SBPFv3 ELF section layout and entry-symbol export, which stock
   `lld` does not.

`sbpf-linker` is therefore a build-time dependency of `omlz`. See
ADR-012 for the pinning policy and ADR-013 for the SBPF version
pinning.

> **Lineage.** This toolchain shape was discovered by reading
> `DaviRain-Su/zignocchio` (a Zig→Solana SBF SDK that has the
> end-to-end pipeline working). We **do not import its code**; we
> independently re-derive the same shape per ADR-014. See
> `zignocchio-relationship.md`.

## 3. Target triple

```
bpfel-freestanding
```

- `bpfel` — little-endian eBPF, which is Solana's flavour.
- `freestanding` — no host OS surface.

We do **not** use the Solana-specific LLVM fork in P1. The bundled
LLVM that ships with `zig` 0.16 emits BPF bitcode that
`sbpf-linker` accepts; the linker is what bridges generic-BPF
bitcode to a Solana-shaped ELF.

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

> **Known Zig 0.16 BPF quirk (will bite us).** Module-scope const
> arrays — particularly all-zero ones — can be placed at very low
> addresses (e.g. 0x0, 0x20) by the LLVM lowering, which Solana's
> verifier treats as access violations. The mitigation, observed
> in zignocchio, is to copy such constants onto the local stack
> before taking their address. Codegen for any `let _ = [|0; 0;
> ...|]`-shaped value at module scope must apply this workaround.
> Tracked as a P1 codegen rule; revisit if Zig 0.17 fixes the
> placement.

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

For BPF — two-step pipeline (bitcode then link):

```sh
# Step 1: Zig → LLVM bitcode
zig build-lib \
  -target bpfel-freestanding \
  -O ReleaseSmall \
  -fno-stack-check \
  -fno-PIC \
  -fno-PIE \
  --strip \
  -femit-llvm-bc=out/program.bc \
  -fno-emit-bin \
  out/program.zig

# Step 2: SBPF link
sbpf-linker \
  --cpu v3 \
  --export entrypoint \
  -o program.so \
  out/program.bc
```

`--cpu v3` pins the SBPF version. See ADR-013 for the rationale.

For native (developer convenience only, **not** a P1 deliverable):

```sh
zig build-exe -O Debug out/program.zig
```

## 7. Sanity checks before "P1 done"

A BPF `.so` produced by P1 must satisfy:

1. `llvm-objdump -d solana_hello.so` shows a single exported
   `entrypoint` symbol with valid eBPF (SBPFv3) instructions.
2. Loadable by `solana-test-validator`:
   ```sh
   solana program deploy ./solana_hello.so
   ```
   succeeds.
3. A no-op invocation returns `0`.
4. The object file is reproducible: identical input → identical
   bytes (modulo timestamp metadata).
5. (New) Section layout passes the `sbpf-linker` post-link check —
   no `.rodata` symbol resolves to address < 0x100 (the Zig 0.16
   low-address quirk; see §4 note).

Items 1–3, 5 are CI gates. Item 4 is best-effort in P1, mandatory
in P3.

## 8. What can go wrong (and how we respond)

| Symptom | Likely cause | Response |
|---|---|---|
| `zig` rejects the target triple | Zig version drift | Pin `zig 0.16.x` in CI; document upgrade in ADR |
| `sbpf-linker` not found | New build-time dep, not installed | `cargo install` from pinned commit (ADR-012); CI installs it |
| `sbpf-linker` rejects bitcode | LLVM IR shape it doesn't understand | Lower codegen complexity in `ZigBackend`; widen `--cpu` only with ADR |
| Loader rejects with "Access violation" at low address | Zig 0.16 const-array placement quirk (§4 note) | Codegen rule: copy const arrays to stack before address-of |
| BPF verifier rejects the program | Stack frames too deep, unbounded loops, illegal helper | Frontend / ANF lowering escape analysis (P3) |
| Solana loader fails for other reasons | ELF section layout off | Diff against zignocchio's reference `program.so`; report to sbpf-linker |
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
