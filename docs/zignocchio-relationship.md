# ZxCaml ↔ zignocchio relationship

> **Languages / 语言**: **English** · [简体中文](./zh/zignocchio-relationship.md)
>
> **Status:** Accepted · **Date:** 2026-04-27
> **See also:** ADR-014 (formal "no import" decision),
> ADR-012 (`sbpf-linker`), ADR-013 (SBPF version pin: v2 default, v3 opt-in),
> `06-bpf-target.md` §2 (toolchain chain).

---

## TL;DR

`zignocchio` (`github.com/DaviRain-Su/zignocchio`, a fork of
`vitorpy/zignocchio`) is a working **Zig → Solana SBF** SDK. It
proves the toolchain we plan to use can produce loadable Solana
programs, and it taught us several non-obvious things our docs
were wrong or silent about.

ZxCaml will **not** import its code. We treat it the same way
ADR-009 treats OxCaml: read freely, write our own.

```
                          ┌────────────────────────────────────┐
                          │  zignocchio                        │
                          │  hand-written Zig SDK for Solana   │
                          │  developers                        │
                          └─────────────┬──────────────────────┘
                                        │ inspiration only
                                        │ (no code, no submodule)
                                        ▼
   .ml ──── omlz ────► .zig ──── zig+sbpf-linker ──── program.so
            (this repo)            (toolchain validated by zignocchio)
```

---

## 1. Why this document exists

When we first wrote `06-bpf-target.md`, we assumed `zig build-obj
-target bpfel-freestanding` would directly produce a Solana
loadable `.o`. That assumption was a planning approximation, not
a verified fact.

zignocchio is the public-domain proof that the **actual** chain is
shaped differently. Pinning that fact in a document — separately
from the ADRs — means future contributors can read both the
"what" (ADRs) and the "why we know this" (this file) without
having to dig through git history.

---

## 2. What zignocchio is

- A Solana program SDK written in Zig.
- Originally `vitorpy/zignocchio`; we reference the
  `DaviRain-Su/zignocchio` fork (currently 11 commits ahead of
  upstream) because it is the version we read.
- Provides:
  - Build pipeline (`build.zig`) that emits LLVM bitcode and
    drives `sbpf-linker`.
  - `sdk/entrypoint.zig` — Solana ABI v1 input buffer
    deserialiser.
  - `sdk/allocator.zig` — bump allocator over the program's
    static heap region.
  - `sdk/syscalls.zig` — syscall bindings, dispatched via
    MurmurHash3-32 of the syscall name.
  - `sdk/account_info.zig` — zero-copy `AccountInfo` view.
  - PDA, CPI, log helpers.
  - Test integrations: `litesvm`, `surfpool`, `mollusk`.
  - A TypeScript client.

It is, in short, a complete answer to "how do I write a Solana
program in Zig today".

ZxCaml's job is different: we are a compiler whose output is
`.zig` source. The runtime our generated code links against will,
by P3, need most of the same surface area zignocchio exposes —
but written by us, owned by us, evolving on our schedule.

---

## 3. What we learned from reading it

These items were either wrong or absent in the pre-2026-04-27
docs:

### 3.1 The toolchain has two steps, not one

Pre: `zig build-obj -target bpfel-freestanding` → `.o`.
Post: `zig build-lib … -femit-llvm-bc` → `.bc` →
      `sbpf-linker --cpu v2 --export entrypoint` → `.so`
      (`v3` opt-in per ADR-013 Revised 2026-04-27).

The Solana loader does **not** accept stock `lld`-linked ELFs.
`sbpf-linker` is what bridges generic-BPF bitcode to the
Solana-shaped ELF Solana actually loads.

→ Captured in: `06-bpf-target.md` §2, §6; ADR-012.

### 3.2 The artefact extension is `.so`, not `.o`

A small but pervasive correction. Acceptance commands, CLI
documentation, and CI gates all changed from `program.o` to
`program.so`.

→ Captured in: `06-bpf-target.md` §1, §7; ADR-003 revision note.

### 3.3 The SBPF version must be pinned

`sbpf-linker` accepts `--cpu v0|v1|v2|v3`. The default is **not**
sufficient for modern Solana. zignocchio's own `build.zig`
pins `--cpu v2` ("v2: No 32-bit jumps (Solana sBPF compatible)"),
which is what current mainnet validators accept by default. v3
is newer and reserved as an opt-in for users who explicitly need
its features (e.g. static syscalls).

ZxCaml mirrors zignocchio: `--cpu v2` is the default, `--cpu v3`
is opt-in via `--sbpf-version=v3`.

→ Captured in: ADR-013 (Revised 2026-04-27).

### 3.4 Zig 0.16 has a known BPF code-placement bug

Module-scope const arrays (especially all-zero ones) can be
placed at very low addresses (0x0, 0x20), which Solana's verifier
treats as access violations. The mitigation is to copy such
constants to the local stack before taking their address.

This will affect ZxCaml's codegen rules: any `let _ = [|0; 0;
…|]` (or equivalent constant array bound at module scope) must
emit a stack-copy shim.

→ Captured in: `06-bpf-target.md` §4 (note), §8 (symptom row).

### 3.5 syscall dispatch uses MurmurHash3-32

Solana doesn't expose syscalls by symbol; the loader looks them
up by a 32-bit hash of the syscall name (MurmurHash3 with seed
`0x00000000`, IIRC). zignocchio has a `tools/gen_syscalls.zig`
that pre-computes these.

This is irrelevant for P1 (no syscalls) but important for our P3
roadmap. Documented here so we don't rediscover it.

→ Future capture: `runtime/zig/syscalls.zig` (P3).

### 3.6 Bump-allocator design is convergent

zignocchio's `sdk/allocator.zig` is a bump allocator over a
static-buffer region. ADR-007's design (single arena threaded
through every function) lands on the same shape. This is mild
external validation of our memory model.

→ Already captured in ADR-005, ADR-007. No doc change needed,
but worth noting that we are not the only Solana-Zig project to
land on this answer.

### 3.7 macOS development is fine

zignocchio is developed on macOS. Removed an open question in
our preflight assumptions.

---

## 4. What we did **not** copy

To keep ADR-014 honest, here is the list of things we deliberately
did not import even though they would have saved us work:

| zignocchio module | What we'd save by copying | Why we don't |
|---|---|---|
| `sdk/entrypoint.zig` | A known-correct Solana ABI v1 deserialiser | We will write our own with our naming, error story, and arena ownership. The ABI is documented; convergence is fine, identity is not. |
| `sdk/allocator.zig` | A working bump allocator | Same. ADR-007 owns our allocator design. |
| `sdk/syscalls.zig` + `tools/gen_syscalls.zig` | MurmurHash3-32 syscall dispatch | P3 work. We may re-implement the generator in OCaml or Zig as we prefer. |
| `sdk/account_info.zig` | Zero-copy AccountInfo view | P3 work. Likely to look very similar; that is fine. |
| Test integrations (litesvm/surfpool/mollusk) | Three working test harnesses | Out of P1 scope. P3 picks one canonical harness. |
| TypeScript client | A working JS surface | Out of scope for at least P1–P3. |

---

## 5. What we owe back

We owe attribution, not code.

When ZxCaml's documentation or commit messages reference a
non-obvious technique that originated in zignocchio (e.g. the
const-array workaround, the SBPF `--cpu` flag and v2/v3 choice),
we cite it.
This document and the relevant ADRs already do so.

We do not owe upstream contributions, because we are not
modifying their code. If ZxCaml later finds, say, a bug in
`sbpf-linker`, we report it upstream — that is normal open-source
behaviour, not a special obligation arising from having read
zignocchio.

---

## 6. When this posture might change

Way A is correct for **now**. It might stop being correct if:

- zignocchio publishes a stable, versioned, documented `runtime`
  crate that ZxCaml could depend on without taking on Zig
  source-level coupling. Then "Way B" (depend on it) might beat
  Way A on maintenance cost.
- ZxCaml accumulates so much P3 runtime code that it becomes
  obviously a duplicate of zignocchio. Then a vendor/fork
  conversation (Way C / D) becomes worth re-having.
- A licensing or governance concern arises that makes
  inspirational reading insufficient grounds for our
  independently-written runtime to look similar to theirs. We do
  not anticipate this — the Solana ABI is documented, convergent
  designs are inevitable — but we name it explicitly so future
  contributors know it has been considered.

Until one of those triggers, Way A is the answer.
