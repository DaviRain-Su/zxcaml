# 06 — BPF target

> **Languages / 语言**: **English** · [简体中文](./zh/06-bpf-target.md)

## 1. Goal

The original Phase 1 BPF acceptance goal was this command sequence succeeding
end-to-end on a developer's machine:

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
 │  └─  solana-zig build-lib -target sbf-solana  (direct path)
 ▼
program.so   (Solana-loadable SBPF ELF)
```

The toolchain is **not** "stock `zig build-obj`". The actual chain
that produces a Solana-loadable artefact is:

1. `solana-zig build-lib -target sbf-solana -fPIC -fstrip -dynamic`
   emits Solana-loadable `program.so` directly.

See ADR-013 for the SBPF version behavior used by the direct path.

> **Lineage.** This toolchain shape was discovered by reading
> `DaviRain-Su/zignocchio` (a Zig→Solana SBF SDK that has the
> end-to-end pipeline working). We **do not import its code**; we
> independently re-derive the same shape per ADR-014. See
> `zignocchio-relationship.md`.

## 3. Target triple

The current direct path uses Solana Zig's target:

```text
sbf-solana
```

Historical experiments used Zig's generic `bpfel-freestanding` target plus a
separate linker step; current `omlz build --target=bpf` goes through
`solana-zig` and emits the final Solana-loadable ELF directly.

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

The original P1 runtime deliberately did **not** include syscalls, account
parsing, CPI helpers, or richer error conventions. Those Solana-facing surfaces
were added by sealed P3/P5 work and are documented in `11-solana-p3.md`; the
BPF target contract here remains the toolchain, entrypoint, and ELF-shape
contract.

## 6. Build flags

### `SOLANA_ZIG` direct path

`SOLANA_ZIG` is used as the direct `solana-zig build-lib` command path when
unset/empty (default), set to `1`, or set to a custom path. No alternate compatibility
path is supported. `SOLANA_ZIG=0` is treated as an invalid custom value.

The direct path does not invoke any external linker like `sbpf-linker`; it
writes the final Solana `.so` directly.

For native convenience only (not a P1 deliverable), use `zig build-exe`.

```sh
zig build-exe -O Debug out/program.zig
```

### Historical ELF post-pass (removed)

Earlier toolchain combinations required `tests/bpf_test_support.rs` to
post-process integration-test artifacts (set `BPF_CALL_IMM` source-register
bits and rewrite `e_flags` to SBPF v1). With the current `omlz` +
`solana-zig 0.16.0 / solana-v1.53.0` toolchain, codegen already emits both
correctly, so the post-pass and its environment-variable toggles were
removed; see `mission-internal/elf-patch-investigation.md` for the full
investigation.

## 7. BPF sanity checks

A BPF `.so` produced by the current pipeline must satisfy:

1. `llvm-objdump -d solana_hello.so` shows a single exported
   `entrypoint` symbol with valid eBPF (SBPFv2 by default; v3
   opt-in) instructions.
2. Loadable by `solana-test-validator`:
   ```sh
   solana program deploy ./solana_hello.so
   ```
   succeeds.
3. A no-op invocation returns `0`.
4. **G13 reproducibility result (2026-04-28): PASS.** Running
   `zig-out/bin/omlz build --target=bpf examples/solana_hello.ml -o /tmp/a.so && zig-out/bin/omlz build --target=bpf examples/solana_hello.ml -o /tmp/b.so && diff /tmp/a.so /tmp/b.so; echo "diff_exit=$?"`
   produced `diff_exit=0`. The two `.so` files were byte-identical.
5. Section layout pass includes stable symbol placement of runtime sections.
   The `.so` output should not place data symbols below low-addresses known to
   trigger verifier access violations.

Items 1–4 are the canonical hello acceptance checks. Closure-focused
BPF acceptance is covered separately by `tests/solana/closures/` when the
Solana harness is enabled.


## 7.5. Static profiling reports

`omlz check --report=<kinds>` runs a static analysis over the
post-optimization, post-region-inference Core IR and prints a deterministic
report to stdout. The report is **opt-in**: without `--report`, `omlz check`
behavior is unchanged.

```sh
omlz check --report=cu examples/factorial.ml
omlz check --report=stack examples/factorial.ml
omlz check --report=all examples/factorial.ml
omlz check --report=cu,stack examples/hello.ml
```

The report never executes the BPF VM. It is intended as a fast early
warning for risky shapes (large stack frames, unbounded loops, large CU
budgets) before deploying.

### Kinds

- `cu` — Compute units. Estimates total cost as
  `prim_count * 1 + branch_count * 1 + non_syscall_calls * 5 +
  Σ syscall_cost + Σ loop_body_cost · (iterations − 1)`. Syscall costs
  come from a small static table: `sol_log_=100`, `sol_log_64=100`,
  `sol_sha256=85+10·bytes`, `sol_keccak256=85+10·bytes`,
  `sol_blake3=85+10·bytes`, `sol_secp256k1_recover=25000`,
  `sol_invoke_signed_c=1000`, default `100`. Byte arguments are
  inferred from string literals when available; otherwise per-byte
  cost is treated as zero. Loops desugared by ADR-015 option D appear
  as `__zxc_loop_*` self-recursive helpers; when both `lo` and `hi`
  bind to integer literals the analyzer multiplies the loop's body
  cost by `|hi − lo| + 1` iterations (the back-edge tail call is
  excluded from the non-syscall call counter to avoid double-counting).
  When the resolved iteration count exceeds `256` the loop is treated
  as **unbounded** and the multiplier is skipped; when bounds are
  not literal (or the body is a `while` loop) the loop is treated as
  **unknown dynamic** and the multiplier is likewise skipped.
  Risky loops are listed in a `risks:` subsection of the `cu` report,
  e.g.

  ```text
  risks:
    - has unbounded loop (bound > 256): __zxc_loop_2 in entrypoint
    - has unknown dynamic loop: __zxc_loop_5 (while) in entrypoint
  ```

  The `risks:` subsection is omitted entirely when every loop in the
  program has a known, bounded literal range, so tiny programs without
  loops keep their pre-existing report shape.
- `stack` — Max function stack depth. Counts parameter sizes and the
  size of named lets the region pass marked `Stack`. Closure captures
  stored in arena are not counted. The deepest function is listed, plus
  the sorted per-function table. Any function over 1024 bytes is flagged
  `WARN: large stack frame`.

### Output shape

Output is markdown-ish and deterministic across runs of the same input:
syscall names and function names are sorted alphabetically. Sections
emit in this fixed order: `cu` first, then `stack`. The report is
written to stdout. Diagnostics still go to stderr. The exit code is the
unchanged `omlz check` exit code; the report is diagnostic-independent.

### Error code

`omlz check --report=<bogus>` exits non-zero with `error[E0200]: unknown
--report kind; expected csv of cu,stack or all`. The CU/stack analysis
itself never blocks the check; if it fails internally, a one-line
`report failed: <reason>` is written to stderr and the original
`omlz check` exit code still bubbles up.

### Caveats

- Compute-unit estimates are conservative bounds, not Solana's runtime
  cost. The canonical cost table lives at
  https://docs.solana.com/developing/programming-model/runtime.
- Syscall byte-length is exact only for static string literals; dynamic
  buffer lengths are approximated as zero per-byte cost.
- Loops desugared from `for`/`while` (ADR-015 option D) are multiplied
  by their literal iteration count when both `lo` and `hi` bind to
  integer literals and the resolved iteration count is `≤ 256`. Loops
  that exceed `256` iterations are reported as `unbounded` and not
  multiplied; loops whose bounds are non-literal (or `while` loops,
  whose condition is opaque to the static pass) are reported as
  `unknown (dynamic)` and likewise not multiplied. `for downto`
  variants whose desugared step is something other than the canonical
  `i - 1` are treated as dynamic.
- Stack-frame sizes use a coarse type-to-bytes table (`int=8`, `bool=1`,
  `unit=0`, pointer/closure/record=`8`/`16`); this is not the layout
  produced by the Zig backend.

## 8. What can go wrong (and how we respond)

This table is the early mission bug/landmine log distilled into BPF and
release-engineering guidance for later workers.

| Symptom | Likely cause / observed source | Response |
|---|---|---|
| `zig` rejects the target triple | Zig version drift | Pin `zig 0.16.x` in CI; document any upgrade in ADR-002 and rerun BPF acceptance |
| Solana verifier rejects low-address layout | Direct `solana-zig` path output has section-layout or symbol-order quirks | Keep existing low-address workaround for module-scope consts; compare against known-good output |
| `llvm-objdump` is not on `PATH` on macOS | Homebrew may place LLVM tools outside `PATH` | Use `/opt/homebrew/bin/llvm-objdump` (or add it to `PATH`) for manual inspection |
| Loader rejects with low-address `Access violation` | Zig 0.16 module-scope const-array placement quirk (§4) | Codegen rule: copy module-scope const arrays to stack before taking their address |
| BPF build rejects Zig `@trap` / abort builtin | Freestanding BPF cannot use the hosted panic path | Keep `runtime/zig/panic.zig` on the BPF-safe no-return path; add Solana-friendly logging only in P3 |
| First-class closure BPF build fails or runtime faults | Closure lowering regressed into an unsupported code-pointer relocation or invalid capture address | Keep P2 closure hardening: known callees lower to direct helper calls where possible, first-class closures use arena-backed capture storage and typed dispatch metadata, and `tests/solana/closures/invoke.sh` must remain green when `SOLANA_BPF=1` |
| BPF verifier rejects the program | Stack frames too deep, unbounded loops, illegal helper, or unsupported relocation | Minimize generated code, compare against the Solana harness output, and add no-alloc/stack analysis in P3 |
| Solana loader fails for ELF-layout reasons | Section layout or exported symbol wrong | Diff against the known-good P1 `solana_hello.so` flow; report suspected linker issues upstream and pin the last known-good tool |
| Program deploys but returns the wrong value | Backend semantics diverged from interpreter | Determinism suite (`05-backends.md` §6) must catch native divergence; add a Solana harness case for BPF-only divergence |
| Validation says `examples/solana_hello.ml` is missing | Historical M0 used `examples/m0_zero.ml`; M3 added the canonical Solana example | Use `examples/solana_hello.ml` for G06/G13 from P1 onward |
| CI corpus loop fails on `examples/m0_unsupported.ml` | That file is an intentional diagnostic fixture | Skip it in corpus loops or move future negative examples under `tests/ui/` |
| `zig build test -Dtest-filter=...` is advertised but unsupported | The build option has not been implemented | Use plain `zig build test` until scoped test filtering lands |
| `zig build test` prints `zxc-frontend not found ...` | Negative subprocess-path test intentionally exercises the diagnostic | Treat as expected if the test command exits 0 |
| `ocamlc -c ... -o /dev/null` fails on macOS | OCaml tries to create `/dev/null.cmi.tmp` | Use `ocamlfind ocamlc -i stdlib/core.ml > /dev/null` or write artifacts to `/tmp` |

## 9. Out of scope for the original P1 target contract

The original BPF target contract excluded IDL generation, BPF-side logging,
program-derived addresses, cross-program invocation, compute-unit budgeting,
and upgrade-authority / multisig flows. Sealed P3/P5 work has since added
logging, PDA/CPI helpers, no-allocation checks, and Anchor-compatible IDL;
upgrade-authority and multisig flows remain outside the compiler target
contract.

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
  to be told where RAM begins. The sealed BPF path still uses the static-buffer arena plan.
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
  `solana-test-validator`. It is not the primary deployment target;
  Solana BPF remains the validated target.

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
