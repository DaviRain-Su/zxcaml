# 20 — Functional Multichain Architecture ADR

**Status:** Accepted  
**Date:** 2026-05-15  
**Scope:** MTF-0 target contract, MTF-1 generic WASM architecture, MTF-2 NEAR no-storage adapter architecture, and MTF-3 portable contract core API architecture

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

### 11. MTF-1 generic WASM architecture is a future pure-logic smoke target

MTF-1 extends this ADR with the architecture for a future
`omlz build --target=wasm` path. This section is still **architecture-only**:
it does **not** add the CLI flag, artifact generation, runtime code, tests, or
support claim in this slice.

The MTF-1 target contract is deliberately narrow:

- support status starts at **`experimental`** only;
- the artifact target is **`wasm32-freestanding`**;
- the scope is **deterministic pure portable logic only**;
- storage, caller identity, host imports, cross-contract calls, chain metadata,
  and adapter-specific APIs stay out of scope.

In other words, MTF-1 is a freestanding smoke target for portable computation,
not a contract-runtime adapter.

Conceptually, the future path is:

```text
Core IR / Lowered IR
  -> backend facade
  -> generated Zig source (if still the right lowering boundary)
  -> zig wasm32-freestanding build path
  -> standalone .wasm artifact
```

The exact build-driver syntax may evolve, but the intended user-facing contract
is a future `omlz build --target=wasm ...` command that emits a `.wasm`
artifact for freestanding smoke validation. MTF-0 + MTF-1 do **not** claim
that this command or artifact exists yet.

### 12. MTF-1 import and runner contract

The MTF-1 MVP acceptance gate is **import-free instantiation** under Node's
built-in WebAssembly runtime.

That contract is explicit because current tool readiness is also explicit:

- **available:** `zig`, Node, and the JavaScript `WebAssembly` API;
- **not available in the verified environment:** `wasmtime`, `wasmer`.

Therefore the first canonical acceptance runner for generic WASM is Node, not a
third-party WASM runtime.

Future MTF-1 acceptance must prove one of the following equivalent facts:

1. the emitted module instantiates successfully with an empty import object,
   such as `WebAssembly.instantiate(bytes, {})`; or
2. the emitted module has zero unexpected imports by inspection, with any
   remaining imported surface explicitly justified by a later scoped ADR.

The MVP expectation is stronger than "the toolchain produced a `.wasm` file":
the module should be **freestanding and import-free for its pure-function
smoke surface**.

### 13. MTF-1 export ABI and scalar scope

The MTF-1 smoke ABI is intentionally tiny and explicit:

- exported functions are named smoke-test entrypoints corresponding to selected
  top-level pure OCaml functions;
- each export takes **zero or more scalar parameters** and returns **at most one
  scalar result**;
- supported MVP scalar shapes are:
  - `i64` for portable `int` if ZxCaml keeps `int` aligned to signed 64-bit
    semantics;
  - `i32` for `bool`, encoded as `0` or `1`;
- tuples, records, variants, lists, refs, arrays, strings, bytes, and any
  pointer- or allocation-bearing surface are outside the MTF-1 MVP ABI.

String/bytes support is therefore **deferred on purpose**. MTF-1 does not yet
standardize:

- linear-memory layout for user-visible buffers;
- allocator/import contracts for memory management;
- string encoding rules;
- bytes ownership or slice lifetime rules.

Those require a later memory/ABI slice and must not be smuggled into the pure
WASM smoke target by implication.

### 14. MTF-1 JavaScript `i64` behavior is part of the contract

If portable `int` remains `i64`, Node-based acceptance must use JavaScript
`BigInt` values for `i64` parameters and results. That is a WebAssembly runner
contract, not an implementation detail.

Consequences:

- smoke fixtures must call `i64` exports with `1n`, `42n`, etc., not `Number`;
- result comparison must likewise expect `BigInt`;
- any future docs/examples for this target must state the `BigInt` requirement
  directly so the runner semantics are not mistaken for JS `Number` semantics.

### 15. Generic WASM success does not imply any WASM-chain adapter

MTF-1 proves only that ZxCaml can eventually target a **generic freestanding
pure-function WASM artifact**. It does **not** prove readiness for:

- NEAR exported-method contracts;
- CosmWasm `instantiate` / `execute` / `query`;
- Substrate contract selectors and SCALE metadata;
- Stylus, Internet Computer, or any other WASM-like runtime.

Each of those targets needs its **own** target contract, host adapter, ABI,
toolchain checks, and real acceptance runner. Generic WASM is a prerequisite
building block, not inherited support for every WASM-chain family.

### 16. MTF-2 NEAR adapter architecture is a method-export contract, not a pure-export smoke target

MTF-2 extends the ADR with a **NEAR-compatible `.wasm` adapter MVP**. This is
still architecture-only in the current slice: it does **not** implement
`omlz build --target=near`, NEAR runtime code, sandbox tests, storage helpers,
or support claims.

The MTF-2 output contract is intentionally distinct from MTF-1:

- **MTF-1** exports freestanding pure functions whose parameters/results are
  expressed directly in the WASM export signature;
- **MTF-2** exports **NEAR method-style entrypoints** whose observable contract
  is the exported method name plus NEAR host interaction, not direct scalar
  parameters/results in the WASM signature.

The architectural consequence is that a future NEAR target is not "generic
WASM plus a deployment wrapper". It is a separate adapter family with its own
entrypoint, serialization, host-import, and acceptance rules.

For the no-storage MVP, each exported method is treated as:

- a named contract entrypoint emitted as a NEAR-visible WASM export;
- a guest function that receives its call payload via `env.input`, not through
  direct WASM parameters;
- a guest function that returns observable output through
  `env.value_return`, not through the WASM result slot.

### 17. MTF-2 NEAR host surface and runtime semantics are deliberately minimal

The NEAR no-storage MVP host surface is restricted to exactly the following
imports:

| Import | MVP role | Contract |
|---|---|---|
| `env.input` | inbound payload handoff | Runtime writes the raw method input into a guest-chosen register. |
| `env.register_len` | inbound payload sizing | Guest queries how many bytes were written into that register. |
| `env.read_register` | inbound payload materialization | Guest copies the register bytes into linear memory it owns. |
| `env.value_return` | success output | Guest returns the final response bytes to the runtime. |
| `env.log_utf8` | observable logging | Guest emits human-readable UTF-8 logs. |
| `env.panic_utf8` | trap / failure surface | Guest aborts execution with a UTF-8 panic message. |

Everything else is out of scope for MTF-2, including:

- persistent storage host functions;
- promise and cross-contract-call host functions;
- async callback choreography;
- metadata/schema generation;
- richer SDK surfaces beyond input, output, log, and panic.

The runtime contract for the no-storage adapter is:

1. reserve a stable input register ID for the adapter MVP;
2. call `env.input(register_id)` at method entry;
3. call `env.register_len(register_id)` to learn the payload size;
4. call `env.read_register(register_id, ptr)` to copy the payload bytes into
   guest linear memory;
5. run portable contract logic over that payload;
6. on success, call `env.value_return(len, ptr)` with the response bytes;
7. for human-visible diagnostics, call `env.log_utf8(len, ptr)` with UTF-8 log
   text;
8. for malformed input or contract-defined fatal failure, call
   `env.panic_utf8(len, ptr)` with a UTF-8 panic message.

This means the observable NEAR semantics are explicit:

- **input** is register-mediated and byte-addressed;
- **return** is explicit via `value_return`;
- **logs** are explicit via `log_utf8`;
- **failure** is explicit via `panic_utf8`.

MTF-2 deliberately does **not** standardize success/failure through direct WASM
return values, hidden traps, storage side effects, or promise scheduling.

### 18. MTF-2 serialization stance and readiness gate stay narrow

The no-storage NEAR MVP adopts a **raw-bytes input/output profile**:

- method payloads arrive as uninterpreted bytes via `env.input`;
- the adapter may decode those bytes into target-selected OCaml values in guest
  memory;
- method success returns uninterpreted bytes via `env.value_return`;
- logs and panic text are the only UTF-8-specific surfaces in the MVP.

This is a deliberate constraint, not an omission. It keeps MTF-2 aligned with
the minimal host surface above and avoids prematurely locking the project into a
JSON-first or Borsh-first policy before the portable capability layer and
cross-target serialization rules exist. Any later JSON or Borsh profile must be
added as a separate, explicit adapter contract with its own acceptance gates.

Tool readiness is likewise explicit:

- **verified available for architecture planning:** Zig, Node, and the generic
  WASM path assumptions from MTF-1;
- **verified absent locally:** `near`, `near-sandbox`, and
  `near-workspaces`.

Therefore sandbox-backed NEAR validation is a **future prerequisite**, not a
current accomplishment. No implementation mission may claim MTF-2 runtime
acceptance until NEAR Sandbox (and the companion local tooling needed to drive
it) is installed and used to prove the method-export contract end to end.

### 19. MTF-3 portable capabilities are abstract operations with target-owned mappings

MTF-3 adds a portable contract core API architecture. The key rule is that
portable capabilities are defined as **abstract operations** first, and each
target family must then either:

1. map that capability into an explicit target-owned adapter contract; or
2. reject it with a target-aware unsupported-capability diagnostic.

The portable capability surface for this milestone is intentionally small:

- caller identity;
- storage read;
- storage write;
- log;
- return;
- trap/revert.

Those names describe **what the portable program is asking for**, not a promise
that every target can provide the same runtime meaning.

### 20. MTF-3 capability matrix and rejection policy

The future capability contract is:

| Portable capability | Native acceptance harness | Solana SBF | Generic WASM (MTF-1) | NEAR no-storage MVP (MTF-2) | EVM Yul MVP (MTF-4) |
|---|---|---|---|---|---|
| `Portable.Caller.current` | Optional harness-injected synthetic caller for tests only | Adapter-defined signer/account-meta view; must not be presented as identical to `msg.sender` | **Unsupported**: freestanding pure WASM has no caller host | **Unsupported in MTF-2**: no caller host imports in the no-storage MVP | **Deferred**: later EVM adapter may map to `msg.sender`, but MTF-4 does not claim it |
| `Portable.Storage.read` | Optional harness-owned in-memory fixture only when a native adapter declares it | Adapter-owned account-data read, never implicit global storage | **Unsupported**: MTF-1 is import-free and hostless | **Unsupported in MTF-2**: storage host functions are explicitly out of scope | **Deferred**: EVM storage is out of MTF-4 scope pending later ADRs |
| `Portable.Storage.write` | Optional harness-owned in-memory fixture only when a native adapter declares it | Adapter-owned account mutation/write path | **Unsupported**: MTF-1 is import-free and hostless | **Unsupported in MTF-2**: storage host functions are explicitly out of scope | **Deferred**: EVM storage is out of MTF-4 scope pending later ADRs |
| `Portable.Log.emit` | Harness log sink or stdout capture | Solana log/syscall surface | **Unsupported**: import-free WASM MVP has no host log channel | `env.log_utf8` | **Deferred**: EVM logs/events are outside MTF-4 MVP |
| `Portable.Return.finish` | Harness-captured return value | Adapter-defined success surface only; may require return-data bytes or other explicit adapter contract rather than a pretend universal VM return slot | Direct exported-function result within the scalar MTF-1 ABI | `env.value_return` | ABI-encoded return data once the EVM adapter exists |
| `Portable.Trap.abort` | Harness failure / process error | Panic or explicit non-success adapter path | WASM trap | `env.panic_utf8` | `revert` once the EVM adapter exists |

Rules that follow from this matrix:

- a portable capability exists only when the requested target's registry entry
  declares a mapping for it;
- a target may reject a capability even if another target supports it;
- adapter-owned semantics stay visible in documentation and diagnostics;
- a rejected capability is a compile-time or preflight error, never a silent
  fallback.

### 21. Unsupported-capability diagnostics, invariants, and namespace rules

Unsupported-capability diagnostics are first-class architecture requirements.
Every future target must emit actionable diagnostics that name:

- the requested target;
- the capability or API surface used;
- whether the failure is architectural, milestone-scoped, or toolchain-gated;
- the nearest supported alternative, if one exists.

Representative required diagnostics:

- `Portable.Storage.read` under `--target=wasm`: reject with guidance that
  MTF-1 generic WASM is import-free pure logic only and has no storage host.
- `Portable.Caller.current` under `--target=near`: reject in the MTF-2
  no-storage MVP because the minimal NEAR host surface does not expose caller
  identity yet.
- `Portable.Log.emit` under `--target=wasm`: reject because import-free WASM
  has no host log channel; direct pure return values remain the supported smoke
  path.

Cross-chain invariants must trace into milestone gates rather than live as
unowned aspirations:

| Invariant | MTF-3 architecture rule | Milestone gates it constrains |
|---|---|---|
| Determinism | Portable capability APIs may not depend on hidden host behavior; target mappings must preserve explicit observable semantics | MTF-1 import-free pure exports, MTF-2 method input/output contract, MTF-4 ABI dispatch/revert checks |
| Memory / resource bounds | Capability mappings must declare memory ownership, allocation limits, and metering-visible resource behavior | MTF-1 scalar-only export ABI, MTF-2 register/linear-memory boundary, later EVM gas-aware lowering |
| ABI / account boundaries | Portable core cannot erase target entrypoint and state-boundary differences | MTF-1 scalar exports, MTF-2 `env.input` / `value_return`, Solana account adapters, MTF-4 selector dispatch |
| Serialization / layout | Cross-target data exchange must be explicitly profiled, never inferred from a portable name | MTF-2 raw-bytes stance, later JSON/Borsh or Solidity ABI profiles, numeric ADR blocker for EVM |
| Diagnostics | Unsupported target/capability pairs must fail with target-aware messages | MTF-3 capability diagnostics, all later target build/test gates |
| Real toolchain conformance | Capability claims are valid only if the target's canonical tools and runners are present | MTF-1 Node WebAssembly, MTF-2 NEAR Sandbox/near-workspaces, MTF-4 `solc` + `anvil` + `cast` |

Public API naming is likewise constrained. Future user-facing surfaces must
follow these namespace rules:

- `Portable.*` is reserved for operations whose contract can be written without
  chain-specific nouns.
- chain-specific semantics must stay under explicit namespaces such as
  `Solana.*`, `Near.*`, `Evm.*`, or `NativeTest.*`.
- no chain-specific API may be re-exported through a generic alias that hides
  semantic differences.
- documentation must show when a portable capability maps to a target-specific
  surface instead of pretending the surface is identical everywhere.

Examples:

- acceptable: `Portable.Log.emit`, `Solana.Account.primary_signer`,
  `Near.Runtime.predecessor`, `Evm.Context.msg_sender`;
- rejected: `Portable.sender` when it really means `msg.sender`,
  `Portable.account` when it really means a Solana account meta bundle, or
  `Portable.storage` when the target has no stable storage contract.

### 22. Target-aware toolchain preflight diagnostics are mandatory

Every future target build and acceptance runner must execute preflight checks
derived from the target registry/runtime manifest before lowering or launch.
Those checks must verify both build tools and canonical acceptance runners.

At minimum, the registry entry for each target must carry:

- required binaries or runtimes;
- which step needs each tool (build, adapter assembly, acceptance run, diff);
- the diagnostic to show when the tool is absent;
- whether the failure blocks build, acceptance, or target graduation.

The MTF-3 minimum policy is:

- **MTF-1 generic WASM:** require `zig` for artifact production and Node's
  built-in WebAssembly runtime for the canonical import-free acceptance runner.
- **MTF-2 NEAR:** require the future NEAR adapter toolchain plus
  `near-sandbox`/`near-workspaces` before any mission claims runtime
  acceptance; absence must produce an actionable prerequisite diagnostic.
- **MTF-4 EVM:** require `solc`, `anvil`, and `cast` for strict-assembly
  validation and local deploy/call smoke tests.

Preflight failures must be specific. For example:

- missing Node for `--target=wasm` acceptance should explain that the canonical
  MTF-1 runner is unavailable, even if artifact generation might still be
  possible;
- missing `near-sandbox` for `--target=near` should explain that MTF-2 runtime
  validation is blocked by missing NEAR Sandbox rather than by source-program
  semantics;
- missing `solc` or `anvil` for `--target=evm` should explain which part of
  the validation flow cannot run.

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

- Later milestones may extend this document, but they must preserve the MTF-0,
  MTF-1, MTF-2, and MTF-3 statements above unless superseded by a later ADR.
- Multichain work is now blocked on explicit target contracts rather than
  roadmap optimism.
- The current native/Solana baseline remains authoritative and unchanged.
- Portable capability APIs are now required to expose unsupported-target
  failures explicitly instead of pretending every adapter has equivalent host
  semantics.
- EVM planning remains blocked on the numeric-model ADR.
- Future WASM-family work must prove each adapter independently; generic WASM
  success will not imply NEAR, CosmWasm, Substrate, Stylus, or Internet
  Computer readiness.

## Relationship to `docs/19-functional-multichain-roadmap.md`

`docs/19-functional-multichain-roadmap.md` remains the exploratory product and
milestone thesis. This ADR is the MTF-0 + MTF-1 + MTF-2 + MTF-3 contract that
constrains how later milestones may be implemented.

In short:

- the roadmap says **why** multichain work may matter;
- this ADR says **what must be true before target support claims are allowed**.
