# 20 — Functional Multichain Architecture ADR

**Status:** Accepted  
**Date:** 2026-05-15  
**Scope:** MTF-0 target contract, MTF-1 generic WASM architecture, MTF-2 NEAR no-storage adapter architecture, MTF-3 portable contract core API architecture, MTF-4 EVM/Yul MVP architecture, MTF-5 verified extraction profile architecture, and MTF-6 additional adapter reservation architecture

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

### 23. MTF-4 EVM/Yul is a sibling backend with a strict-assembly gate

MTF-4 extends this ADR with an **EVM/Yul MVP architecture**, still as
architecture only. It does **not** add `omlz build --target=evm`, a Yul
emitter, bytecode artifacts, Foundry tests, or any EVM support claim in this
slice.

The backend relationship is explicit:

```text
Core IR / Lowered IR
  -> backend facade
  -> EVM lowering
  -> Yul
  -> solc strict-assembly validation
  -> EVM bytecode artifact
```

This path is a **sibling backend** to the generated-Zig native/Solana/WASM
family, not a variant of it. The EVM adapter therefore owns its own ABI,
dispatch, revert, and artifact-assembly rules rather than pretending those can
be inherited from the Zig-source path.

The existing numeric-model blocker remains binding here. No MTF-4 mission may
claim broad EVM lowering until a dedicated ADR resolves:

- integer width and signedness policy;
- overflow and modular arithmetic semantics;
- conversion rules between portable values and EVM ABI words; and
- whether target-specific surfaces such as `u256` or `bytes32` are introduced.

Result: MTF-4 may define a narrow smoke-test ABI and lowering shape, but it may
not overclaim general EVM numeric portability before that ADR lands.

### 24. MTF-4 tool readiness and smoke validation use real local EVM tooling

The verified local EVM toolchain state for this architecture slice is:

| Tool | Verified state | Role in future MTF-4 validation |
|---|---|---|
| `solc` | available (`0.8.34`) | Validate Yul through `--strict-assembly` and emit bytecode. |
| `anvil` | available (`1.5.1-stable`) | Provide the canonical local dev chain for deploy/call smoke tests. |
| `cast` | available (`1.5.1-stable`) | Deploy bytecode, encode calldata, perform calls, and inspect return/revert bytes. |
| `forge` | available (`1.5.1-stable`) | Ready for future fixture/workflow expansion, but not the canonical MVP acceptance gate. |
| `revm` CLI | absent locally | Non-blocking for MTF-4 because the MVP validation path uses `solc` + `anvil` + `cast`. |

Future MTF-4 acceptance must use real local chain tooling, not a mock-only
surrogate. The minimum smoke path is:

1. emit a Yul artifact from the EVM backend;
2. validate and compile it with `solc --strict-assembly --bin <generated.yul>`;
3. run a local `anvil` instance as the execution VM;
4. deploy the compiled bytecode with `cast`;
5. call the deployed contract with ABI-encoded calldata via `cast`;
6. compare the observed ABI-encoded return bytes and revert bytes against the
   expected portable-program behavior.

`forge` may later wrap or automate parts of this flow, but the architecture
contract is the underlying `solc` + `anvil` + `cast` evidence chain above.

### 25. MTF-4 ABI dispatch/decode/encode/revert scope is deliberately narrow

The EVM/Yul MVP surface is intentionally limited to pure function dispatch and
ABI behavior that can be stated precisely:

| Surface | MTF-4 MVP contract |
|---|---|
| Selector dispatch | Read the first four calldata bytes as the function selector and branch to a fixed dispatch table. |
| Supported calldata decode | Decode only statically-sized ABI words for the documented MVP scalar surface; dynamic arrays, `string`, `bytes`, nested tuples, and rich structs are excluded. |
| Supported return encoding | Encode only the documented statically-sized MVP return surface as Solidity-ABI word output; no rich metadata envelope is implied. |
| Arithmetic / conditionals | Support pure arithmetic, comparisons, and deterministic conditional branching within the narrowed numeric contract. |
| Unknown selector behavior | Deterministically reject unknown selectors with a plain `revert`, using empty revert data rather than rich error metadata. |

This section deliberately defines the MVP as an ABI and control-flow slice, not
as "general Solidity compatibility". In particular, MTF-4 excludes:

- storage layout and `sload` / `sstore`;
- events, logs, and event-topic metadata;
- `address`, `msg.sender`, `msg.value`, and other call-context surfaces;
- external calls, `staticcall`, `delegatecall`, contract creation, and other
  inter-contract messaging;
- Solidity ABI JSON generation and rich selector metadata products;
- custom errors, string revert reasons, and other rich revert/error metadata.

Those exclusions are architectural guardrails. Later milestones may add any of
them only by defining explicit semantics, validation gates, and target-owned
adapter surfaces rather than treating them as automatic consequences of Yul
code generation.

### 26. MTF-5 verified extraction is a constrained hosting profile, not automatic compiler verification

MTF-5 extends the ADR with a **verified extraction profile architecture**. This
is still architecture-only. It does **not** claim that ZxCaml, its backends, or
its adapters are formally verified today, and it does **not** claim that every
accepted OCaml program carries proof-backed guarantees.

The MTF-5 goal is narrower: ZxCaml may eventually **host verified or extracted
portable contract logic** when the upstream proof/extraction toolchain produces
ordinary `.ml` that fits an explicit profile named
`zxcaml-verified-subset`.

That profile is bounded as follows:

| Area | In scope for `zxcaml-verified-subset` | Out of scope for MTF-5 |
|---|---|---|
| Source shape | Extracted or hand-reviewed `.ml` accepted by upstream OCaml `compiler-libs` and then accepted by the ZxCaml subset gate | Extraction output that requires patching the OCaml frontend, custom compiler forks, or unsupported syntax/runtime features |
| Logic surface | Deterministic portable business logic: pure functions, algebraic data, pattern matching, bounded recursion/control flow, and arithmetic that stays within the active portable numeric contract | Host-driven workflows whose proof story depends on target storage layout, caller identity, cross-contract calls, promises, events, or chain-specific side effects |
| Dependency surface | Self-contained extracted code plus only the ZxCaml-supported subset/bundled helpers needed by that logic | Arbitrary opam libraries, GC-dependent code, exceptions-as-control-flow, threads, objects, effect handlers, or hidden runtime services |
| IR boundary | Claims may cover logic that survives the OCaml frontend boundary and lowers through the existing Core IR / Lowered IR contracts | Claims that skip over lowering details or treat unverified backend/runtime rewrites as proof-preserving by default |
| Runtime assumptions | Portable logic runs under the same determinism, arena/resource limits, and target capability gates as ordinary ZxCaml portable code | Any claim that extraction removes the need to reason about memory/resource bounds, adapter ABI contracts, or target VM behavior |
| Target reach | Hosted verified logic may later be deployed behind explicit target adapters that already satisfy their own ADR gates | Automatic inheritance of proof claims by every target family, adapter, or generated artifact |

The architectural rule is therefore: **verified extraction applies to the
hosted portable logic slice only, unless a later milestone proves more.**

### 27. MTF-5 proof claims require runnable evidence and narrow artifact-scoped language

Future MTF-5 acceptance must distinguish proof-backed claims by artifact and by
boundary. The required language is:

- allowed: **"ZxCaml can host formally verified contract logic within the
  `zxcaml-verified-subset` profile."**
- disallowed: **"ZxCaml automatically verifies every contract."**
- disallowed: **"The entire compiler/backend/adapter stack is formally
  verified."**

Any accepted verification claim must name:

1. the upstream proof system and proof artifact;
2. the extraction tool and extracted OCaml artifact;
3. the exact subset/profile boundary being relied on;
4. the target/backend/adapter path that was exercised; and
5. the runnable checks that compared expected behavior against the extracted
   program.

Prose proof intent is not enough. Future MTF-5 acceptance must include
**executable equivalence/regression evidence** for representative extracted
programs. The minimum architecture contract is:

1. choose a representative proof-backed program and its upstream reference
   property or executable model;
2. retain the extracted OCaml artifact that enters ZxCaml;
3. run the extracted program through the canonical ZxCaml execution surfaces
   relevant to the target claim (at minimum interpreter/native, and any claimed
   target adapter path);
4. compare the observed outputs/failures against the upstream reference,
   extracted baseline, or approved golden corpus;
5. keep those checks runnable as regression tests for later compiler changes.

This means MTF-5 is gated on **runnable equivalence checks**, not on
"we extracted code once and the proof system said it was fine."

### 28. MTF-5 verification artifacts must be reproducible and the trust chain must stay visible

Any future accepted MTF-5 proof claim must ship with reproducible verification
artifacts. At minimum, the evidence bundle must either store or reference:

- proof sources and theorem/checker inputs;
- checker outputs or certificates;
- extraction logs and extracted OCaml files;
- the exact ZxCaml command lines used for subset checking/build/execution;
- target-runner commands for any claimed adapter/backend path; and
- stable version identifiers or hashes for the proof toolchain, extraction
  toolchain, ZxCaml revision, and target runner.

Each artifact set must be paired with reproduction commands so another worker
can regenerate or re-check the same claim without guesswork.

The proof/trust chain for MTF-5 is:

| Link | Required status language |
|---|---|
| Upstream proof system theorem/proof artifact | **Proven/checker-validated** by the upstream tool, not by ZxCaml |
| Extraction semantics from proof system to OCaml | **Assumed or checker-backed only to the degree the upstream extractor guarantees** |
| `zxcaml-verified-subset` acceptance | **Checked** by upstream OCaml parsing/typechecking plus ZxCaml subset/profile admission |
| Core IR / lowering preservation | **Tested and architecture-constrained**, not formally verified in this ADR |
| Backend code generation correctness | **Tested/assumed** per backend acceptance gates, not proven here |
| Runtime / host adapter correctness | **Tested/assumed** per adapter acceptance gates, not proven here |
| Target VM / external toolchain behavior | **Assumed except where exercised by canonical runtime/toolchain tests** |

This table is binding documentation hygiene: every future verification claim
must say which links are **proven**, **checked**, **tested**, **assumed**, or
still **out of scope** instead of collapsing the entire chain into a single
"verified" label.

### 29. MTF-6 additional adapters are reserved for later named use cases, not pre-committed roadmap debt

MTF-6 reserves additional adapter families as **future candidates only**. It
does not schedule implementation work, support claims, or acceptance promises
for CosmWasm, Substrate contracts, Stylus, Internet Computer, or similar
targets unless a later milestone names:

1. a concrete user or product use case;
2. an owner for the adapter work; and
3. the canonical toolchain or simulator that can prove the adapter really
   works.

Until those conditions exist, these targets remain `reserved` in the target
registry. They are not implied by generic WASM reachability, by Zig being able
to emit `.wasm`, or by another adapter family already working.

The reservation matrix future workers must fill for each candidate adapter is:

| Reserved adapter dimension | Questions that must be answered before implementation can graduate |
|---|---|
| Entrypoints | What are the externally visible contract entrypoints (`instantiate` / `execute` / `query`, selector dispatch, canister methods, etc.) and how do they map from portable contract entrypoints? |
| ABI / encoding | What wire format is canonical for inputs and outputs: JSON, Borsh, SCALE, Candid, Solidity ABI, or something else? |
| Storage / account model | Does the target expose key-value storage, account/state objects, stable memory, or another persistence model, and what semantics are target-owned rather than portable? |
| Caller / value context | How are caller identity, attached value/funds, signer semantics, and permission checks surfaced? |
| Calls / messages | Are cross-contract calls synchronous, asynchronous, message-based, callback-based, or metered differently from local execution? |
| Deterministic effects | What logging, event, response-message, randomness, time, or host-side effects are allowed, and which must stay outside the portable core? |
| Gas / fee / weight model | How are execution cost, metering, deposits, rent, or weight accounted for, and what resource-boundary assumptions must the adapter preserve? |
| Artifact / deployment format | Is the deliverable a `.wasm`, bytecode blob, package bundle, metadata pair, canister image, or another deployable artifact? |
| Errors | What is the target's canonical failure surface: trap, revert, panic string, response enum, exit code, or structured error payload? |
| Metadata / schema | What metadata, ABI schema, interface description, or manifest format is required by downstream tooling? |
| Canonical testing harness | What real toolchain or canonical simulator proves behavior end to end: `cw-multi-test`/`wasmd`, `cargo-contract`/`substrate-contracts-node`, Stylus Nitro tooling, `dfx`/PocketIC, or another target-owned runner? |

The architecture policy for these reserved adapters is strict:

- **Real toolchain gates are mandatory.** Future acceptance must use the real
  target toolchain or a canonical simulator where one exists. Mock-only tests
  are allowed only for explicitly labeled readiness gaps and cannot on their
  own graduate a target beyond `reserved`.
- **Existing invariants remain binding.** Any future adapter must preserve the
  current frontend boundary (upstream OCaml `compiler-libs`), Core IR semantic
  center, determinism contract, and documented memory/resource boundaries
  unless a later ADR explicitly introduces and validates a target-specific
  exception.
- **Support never inherits across WASM-like families.** Generic WASM, NEAR,
  CosmWasm, Substrate, Stylus, Internet Computer, and any similar runtime each
  need an independent target contract, adapter ABI, capability mapping, and
  acceptance gate. Success for one does not imply readiness for another.

### 30. The seven MTF milestones form one connected sequence, and current support stays separate from future targets

This ADR defines exactly **seven** multichain milestones:
**MTF-0**, **MTF-1**, **MTF-2**, **MTF-3**, **MTF-4**, **MTF-5**, and
**MTF-6**.

They are connected by explicit deliverables and gates:

| Milestone | Depends on | Delivers to the next milestone |
|---|---|---|
| **MTF-0** target contract ADR | current native/Solana baseline plus existing ADRs | vocabulary, registry/manifest shape, graduation gates, anti-overclaim language, and the numeric blocker used by every later target |
| **MTF-1** generic WASM | MTF-0 target vocabulary, backend/adapter seam, and graduation gates | a hostless `wasm32-freestanding` pure-logic smoke target that later adapter families may build on without inheriting support |
| **MTF-2** NEAR no-storage adapter | MTF-1 generic WASM artifact assumptions plus MTF-0 adapter contract rules | a method-export host-adapter contract with explicit input/return/log/panic boundaries and a named sandbox-readiness prerequisite |
| **MTF-3** portable capability API | MTF-0 vocabulary plus MTF-1/MTF-2 target contracts | the portable capability matrix, namespace policy, and unsupported-capability diagnostics used by every future adapter/backend |
| **MTF-4** EVM/Yul MVP | MTF-0 numeric blocker and MTF-3 capability/diagnostic rules | a sibling Yul backend contract, strict-assembly validation path, and ABI/revert scope that stays separate from Zig-output targets |
| **MTF-5** verified extraction profile | MTF-0 anti-overclaim rules and MTF-3 portable-core boundaries | a constrained `zxcaml-verified-subset`, runnable evidence expectations, and trust-boundary language for proof-backed portable logic |
| **MTF-6** additional adapter reservation | MTF-1 generic WASM separation, MTF-3 capability rules, and the earlier graduation policy | a reservation matrix for later adapters that forbids inherited support and requires named owners plus real toolchain gates |

Support status remains explicitly split between the **current verified
baseline** and **future planned targets**:

| Target family | Status in this ADR | Notes |
|---|---|---|
| **`native`** | implemented baseline | Current supported build target today. |
| **Solana `bpf`** | implemented baseline | Current supported build target today through `solana-zig`. |
| **Generic WASM** | future / experimental architecture only | Planned by MTF-1; no current target implementation or support claim. |
| **NEAR** | future / experimental architecture only | Planned by MTF-2; adapter contract only, no current runtime validation. |
| **EVM/Yul** | future / experimental architecture only | Planned by MTF-4; sibling backend contract only, blocked on numeric ADR. |
| **Verified extraction profile** | future / accepted-hosting concept only | Planned by MTF-5; constrains claims about proof-backed portable logic only. |
| **CosmWasm / Substrate / Stylus / Internet Computer / similar** | reserved only | MTF-6 reserves them as candidates; none inherit support from generic WASM. |

### 31. Verified tool readiness, upper syntax boundaries, and acceptance surface are explicit

The verified local toolchain/readiness snapshot for this architecture-only ADR
slice is:

| Tool / runtime | Verified state | Impact on this ADR |
|---|---|---|
| `zig 0.16.0` | available | Current compiler/build baseline and planned generic WASM builder. |
| Node `v25.9.0` WebAssembly runtime | available | Canonical MTF-1 import-free `.wasm` runner. |
| `solana-zig 0.16.0` | available | Confirms the current Solana `bpf` baseline toolchain. |
| `solana-cli 3.1.12` | available | Confirms the current Solana acceptance environment exists. |
| `solc 0.8.34` | available | Future MTF-4 strict-assembly validator. |
| `anvil 1.5.1-stable` | available | Future MTF-4 local EVM execution runner. |
| `cast 1.5.1-stable` | available | Future MTF-4 deploy/call and ABI-observation tool. |
| `forge 1.5.1-stable` | available | Optional future EVM workflow wrapper; not the canonical MVP gate. |
| `wasmtime` | unavailable locally | Not required because MTF-1 uses Node WebAssembly. |
| `wasmer` | unavailable locally | Not required because MTF-1 uses Node WebAssembly. |
| `near` / `near-sandbox` / `near-workspaces` | unavailable locally | MTF-2 remains architecture-only until NEAR Sandbox tooling is installed. |
| `revm` CLI | unavailable locally | Non-blocking because MTF-4 uses `solc` + `anvil` + `cast`. |

Upper syntaxes and future source layers are also bounded explicitly:

- **ReasonML / ReScript-like syntax layers** may only participate by lowering
  deterministically into ordinary `.ml` accepted by upstream OCaml and then by
  the ZxCaml subset gate; this ADR does **not** commit to a new frontend
  language or alternate runtime semantics.
- **PPX or custom DSL expansions** are acceptable only when the expansion
  result is plain OCaml that remains subset-safe, deterministic, and readable
  through the existing `compiler-libs` frontend.
- **Verified-source extraction** from F*, Coq, WhyML, or similar systems is a
  future input path only when the extracted OCaml fits the
  `zxcaml-verified-subset`; extraction does not bypass the OCaml subset,
  lowering, adapter, or runtime boundaries above.

Final acceptance for this ADR slice is intentionally review-only:

- document review of this ADR against the roadmap and existing ADRs;
- shell-based tool/version checks and repository validators;
- git diff/status review confirming the artifact stays architecture-only.

No browser, Electron, TUI, app server, database, or interactive external
service is required for final acceptance of this slice.

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
  MTF-1, MTF-2, MTF-3, MTF-4, MTF-5, and MTF-6 statements above unless
  superseded by a later ADR.
- Multichain work is now blocked on explicit target contracts rather than
  roadmap optimism.
- The current native/Solana baseline remains authoritative and unchanged.
- Portable capability APIs are now required to expose unsupported-target
  failures explicitly instead of pretending every adapter has equivalent host
  semantics.
- EVM planning remains blocked on the numeric-model ADR.
- Verification-marketing language is now constrained to artifact-scoped hosted
  logic claims plus reproducible runnable evidence.
- Future WASM-family work must prove each adapter independently; generic WASM
  success will not imply NEAR, CosmWasm, Substrate, Stylus, or Internet
  Computer readiness.

## Relationship to `docs/19-functional-multichain-roadmap.md`

`docs/19-functional-multichain-roadmap.md` remains the exploratory product and
milestone thesis. This ADR is the MTF-0 + MTF-1 + MTF-2 + MTF-3 + MTF-4 +
MTF-5 + MTF-6 contract that constrains how later milestones may be
implemented.

In short:

- the roadmap says **why** multichain work may matter;
- this ADR says **what must be true before target support claims are allowed**.
