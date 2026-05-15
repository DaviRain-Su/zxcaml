# 20 — Functional Multichain Architecture ADR

**Status:** Accepted  
**Date:** 2026-05-15  
**Scope:** MTF-0 target contract only

## Context

[`docs/19-functional-multichain-roadmap.md`](./19-functional-multichain-roadmap.md)
captures an exploratory thesis: ZxCaml can eventually host portable contract
logic across multiple runtimes. That roadmap is intentionally aspirational. It
does not yet define the exact target contract, codebase seams, acceptance
requirements, or anti-overclaim language required before implementation work can
start safely.

MTF-0 exists to close that gap.

This slice is **architecture-only**. It adds **no** compiler target, runtime
adapter, CLI flag, generated artifact, validator lane, CI behavior, or support
claim for WASM, NEAR, EVM, formal verification, or any other new runtime. The
deliverable of MTF-0 is this ADR and only this ADR.

## Decision

### 1. Product framing

ZxCaml remains:

- an **OCaml-subset compiler** whose canonical source input is `.ml`;
- an implementation that reuses upstream OCaml `compiler-libs` as the frontend;
- a compiler/runtime stack written in **Zig** below that frontend boundary; and
- a project whose **only implemented build targets today are `native` and
  `bpf`**.

Multichain work is framed as:

```text
portable contract core
  +
explicit target contract
  +
runtime / host adapter
  +
real target acceptance gate
```

The unification point is portable contract logic, not a pretend universal
runtime.

### 2. Target contract vocabulary

The following terms are normative for all later multichain work:

| Term | Meaning |
|---|---|
| **Portable contract core** | Deterministic chain-neutral logic: math, records/variants, state transitions, validation, and tests that do not assume a host ABI. |
| **Target family** | A runtime class such as native, Solana SBF, generic WASM, NEAR, EVM, CosmWasm, or Substrate contracts. |
| **Backend** | The compiler component that lowers shared IR into a target-specific artifact representation. |
| **Backend output language** | The emitted representation, such as generated Zig source, `.wasm`, Yul, or EVM bytecode. |
| **Runtime adapter** | Bundled runtime code or shims owned by ZxCaml for a target's entrypoint, memory, panic/error, and serialization boundary. |
| **Host adapter** | The contract with target-provided host features such as syscalls, imports, storage, caller identity, logs, or cross-program calls. |
| **Artifact** | The build output consumed by a target toolchain or runtime, such as a native executable, Solana `.so`, `.wasm`, Yul file, or bytecode blob. |
| **Support status** | `reserved`, `experimental`, `accepted`, or `supported`; each status requires explicit evidence and must never be inferred from toolchain reachability alone. |
| **Acceptance gate** | The real or canonical toolchain/VM evidence required before a target can advance support status. |

### 3. Zig implementation language is not the same thing as a target

Zig plays two distinct roles and they must stay separate:

1. **Implementation language** for the compiler and runtime.
2. **One possible backend output language** for the current native/Solana path,
   and for future targets only where that output shape is appropriate.

This separation is binding. In particular:

- generic WASM may reuse generated Zig source if that remains the right lowering
  boundary for that target family;
- **EVM is not a generated-Zig target**; it is a **sibling backend** that
  lowers shared IR into Yul/bytecode-oriented artifacts with EVM-specific ABI
  and numeric semantics.

### 4. Current baseline is explicit and limited

The current implemented target surface is:

- `omlz build --target=native`
- `omlz build --target=bpf`

This is reflected in the current CLI and driver shape:

- `src/main.zig` accepts only `native` and `bpf`;
- `src/driver/build.zig` owns the native Zig build path;
- `src/driver/bpf.zig` owns the Solana BPF path through `solana-zig`.

Today target selection is **late and string-based**, not a first-class target
registry. That is acceptable for the current two-target baseline, but it is not
the architecture we should extend for multichain work.

### 5. Portable core and target-specific APIs must remain separate

The portable contract core may contain:

- deterministic arithmetic and fixed-point helpers;
- validation predicates and state-transition logic;
- typed records, tuples, variants, pattern matching, and pure control flow;
- pure helper functions and tests that do not assume a chain host.

The following remain **target-specific adapter surface**, not portable core:

- Solana account values and account mutation helpers;
- sysvar readers and other host-bound data sources;
- CPI/PDA/cross-contract call helpers;
- target-specific caller identity surfaces;
- IDL, metadata, deployment, and artifact packaging conventions.

If a source program uses a capability or API that the requested target does not
support, the compiler must eventually emit an **unsupported-capability
diagnostic**. It must not silently lower to incorrect behavior or pretend the
API is portable.

### 6. Future target registry and runtime manifest contract

Future target work must be driven by a first-class registry entry whose shape is
conceptually:

```text
TargetContract {
  name: string
  family: string
  support_status: reserved | experimental | accepted | supported
  backend_facade: string
  backend_output_language: string
  artifact_type: string
  runtime_adapter: string
  host_adapter: string
  entrypoint_contract: string
  calling_convention: string
  memory_plan: string
  panic_error_strategy: string
  capability_set: []Capability
  unsupported_capability_diagnostics: string
  required_tools: []ToolRequirement
  preflight_checks: []Check
  acceptance_runner: string
  acceptance_evidence: string
}
```

The important architectural rule is not the exact eventual syntax. The rule is
that every target must declare:

- what lowers shared IR;
- what artifact is produced;
- what runtime/host adapter owns the boundary;
- what capabilities are supported or rejected;
- what tools are required; and
- what runner proves the target actually works.

### 7. Backend facade and adapter ABI seams are explicit

The target-neutral compiler/backend seam is:

```text
Core IR / Lowered IR
  -> backend facade
  -> target artifact representation
```

What flows through that seam:

- typed portable program structure;
- control flow, data flow, and pure computations;
- explicit calls into target-declared capability surfaces.

What remains adapter-owned and must not be hidden in the generic lowering:

- entrypoint shape;
- memory ownership and arena/heap/import rules;
- panic, trap, and revert behavior;
- serialization and ABI encoding;
- host calls/imports/syscalls/storage access;
- final artifact assembly and deployment packaging.

Representative current boundaries:

| Boundary | Current representative paths | Why this matters |
|---|---|---|
| Backend facade | `src/backend/api.zig`, `src/backend/zig_codegen.zig`, `src/driver/build.zig`, `src/driver/bpf.zig` | The backend boundary exists today, but only native/Solana are wired through it. |
| Runtime/host adapter ABI | `src/backend/zig_codegen/runtime_imports.zig`, `runtime/zig/native_entry.zig`, `runtime/zig/bpf_entry.zig`, `runtime/zig/syscalls.zig`, `runtime/zig/cpi.zig` | Target-specific entry, host calls, and assembly are already real code and must stop leaking into future generic targets. |

### 8. Solana coupling inventory

Solana is the current product baseline, but it is not yet cleanly isolated.
Future target work must treat the following as seams to extract or gate:

| Coupling seam | Representative current paths | Why it blocks naive target expansion |
|---|---|---|
| Frontend/bundled names already expose chain-shaped APIs | `src/frontend/zxc_subset.ml`, `stdlib/core.ml` | `Account`, `Sysvar`, `Pubkey`, `invoke`, and `invoke_signed` exist today as named language surface, so portability is not just a backend toggle. |
| Core IR still carries Solana-shaped effects and types | `src/core/ir.zig`, `src/driver/idl.zig` | Account mutation, instruction/account metadata, and IDL discovery all assume Solana-flavored concepts. |
| Codegen imports map directly to Solana runtime helpers | `src/backend/zig_codegen/runtime_imports.zig` | External lowering currently hardwires syscalls, CPI, sysvars, PDA flows, and SPL-Token helpers. |
| Runtime materialization is heavily Solana-specific | `runtime/zig/account.zig`, `runtime/zig/syscalls.zig`, `runtime/zig/cpi.zig`, `runtime/zig/sysvar.zig`, `runtime/zig/spl_token.zig`, `runtime/zig/programs/*.zig` | The runtime surface already owns account parsing, cross-program calls, sysvars, SPL helpers, and Solana-oriented examples. |
| Entry shims and artifact assembly are target-specific today | `runtime/zig/bpf_entry.zig`, `runtime/zig/native_entry.zig`, `src/driver/bpf.zig`, `src/driver/build.zig` | Native and Solana have distinct entry/materialization rules; new targets need equally explicit adapters, not reuse-by-hope. |
| Acceptance harnesses are Solana-oriented | `tests/Cargo.toml`, `tests/bpf_test_support.rs`, `tests/solana/hello/invoke.sh`, `tests/solana/surfpool_harness.sh` | Current acceptance proves the Solana/native baseline, not generic multichain readiness. |

MTF-0 does **not** claim these seams are already abstracted. It records that
they exist and must be isolated deliberately.

### 9. Numeric model is an ADR-level blocker

The portable numeric model remains unresolved and blocks broad EVM work.

The open decision is whether ZxCaml multichain portability should:

1. preserve the current portable `int` story around signed `i64` semantics; or
2. introduce explicit target-specific numeric surfaces such as EVM-oriented
   `u256`, `bytes32`, modular arithmetic, and conversion rules.

This is not a small implementation detail. It affects:

- ABI design;
- overflow behavior;
- signedness rules;
- calldata/storage encoding strategy;
- portable math claims across targets; and
- how much of EVM is genuinely portable versus explicitly target-specific.

**Result:** no future EVM milestone may claim broad lowering support until a
separate numeric ADR resolves this boundary.

### 10. Target graduation gates

No target graduates to `supported` status until it has all of the following:

1. a named use case and owner;
2. an explicit entrypoint contract;
3. a panic/error strategy;
4. a memory plan;
5. a calling convention;
6. a runtime/host adapter document;
7. at least one real or canonical VM acceptance example;
8. CI coverage for build and execution;
9. actionable diagnostics for invalid target/API combinations; and
10. user-facing documentation that separates portable behavior from
    target-specific behavior.

Failing any gate means the target stays `reserved`, `experimental`, or
`accepted`; it does not become `supported`.

## Non-goals and anti-overclaim guardrails

The following claims are explicitly disallowed:

| Disallowed claim | Required replacement framing |
|---|---|
| “Every Zig target is automatically a ZxCaml target.” | Zig reachability only proves a possible toolchain path; support requires a target contract and acceptance gates. |
| “One artifact deploys byte-identically to every chain.” | Portable logic may be shared, but artifacts, entrypoints, ABIs, and host semantics remain target-specific. |
| “Chain semantics can be hidden behind universal names.” | Portable capabilities must stay distinct from chain-specific APIs and documentation. |
| “OCaml runtime/opam ecosystem features come along automatically.” | ZxCaml remains an OCaml-subset compiler without the OCaml runtime, GC, exceptions, or arbitrary opam package compatibility in deployed artifacts. |
| “ZxCaml automatically verifies every contract.” | ZxCaml may later host verified or extracted logic within an explicit subset and trust boundary; it does not make all contracts formally verified. |

## Consequences

- Later milestones may extend this document, but they must preserve the MTF-0
  statements above unless superseded by a later ADR.
- Multichain work is now blocked on explicit target contracts rather than
  roadmap optimism.
- The current native/Solana baseline remains authoritative and unchanged.
- EVM planning remains blocked on the numeric-model ADR.
- Future WASM-family work must prove each adapter independently; generic WASM
  success will not imply NEAR, CosmWasm, Substrate, Stylus, or Internet
  Computer readiness.

## Relationship to `docs/19-functional-multichain-roadmap.md`

`docs/19-functional-multichain-roadmap.md` remains the exploratory product and
milestone thesis. This ADR is the MTF-0 contract that constrains how later
milestones may be implemented.

In short:

- the roadmap says **why** multichain work may matter;
- this ADR says **what must be true before target support claims are allowed**.
