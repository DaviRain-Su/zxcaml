# 19 — Functional Multichain Roadmap

> **Status:** exploratory product/architecture direction. This document records a
> planning thesis, not a committed phase. Any implementation slice must still
> land through the activation gates in [`08-roadmap.md`](./08-roadmap.md) and an
> ADR-sized target contract.

## 1. Thesis

ZxCaml can grow from a Solana-focused OCaml-subset compiler into a
**functional smart-contract core** for multiple chains:

```text
verified / portable business logic
  written in a contract-safe OCaml subset
  lowered through ZxCaml Core IR
  deployed through chain-specific runtime adapters
```

The unification point is not the chain runtime. Solana accounts, EVM storage,
NEAR host functions, CosmWasm responses, and Substrate selectors are different
by design. The unification point is the **business logic layer**: pure functions,
state machines, deterministic math, typed records/variants, pattern matching,
and testable validation rules.

A useful product slogan for this direction is:

```text
One contract logic, many chain runtimes.
```

## 2. Layer model

```text
OCaml / upper syntax
  │
  ├─ .ml OCaml subset
  ├─ ReasonML / syntax layers that lower to OCaml
  └─ verified sources that extract to OCaml (F*, Coq, WhyML)
        │
        ▼
upstream OCaml frontend + zxc-frontend
        │
        ▼
Core IR / ANF                         stable semantic contract
        │
        ▼
Lowering / target lowering
        │
        ├─ Zig source   ── solana-zig ── Solana SBF .so
        ├─ Zig source   ── zig wasm32 ── generic WASM / WASM chains
        ├─ Zig source   ── zig        ── native developer executable
        └─ Yul/bytecode ── solc/revm  ── EVM bytecode
```

Two Zig roles must remain separate:

1. **Zig as implementation language** — the compiler, lowerings, drivers, and
   future EVM/Yul emitter are Zig code.
2. **Zig source as backend output** — the existing Solana/native path emits
   `out/program.zig`; WASM targets can likely reuse that path. EVM should not
   route user programs through Zig source, because EVM is a 256-bit stack VM with
   calldata/storage/revert semantics rather than an LLVM CPU target.

## 3. What becomes portable

The portable layer should contain deterministic, chain-neutral logic:

- arithmetic and fixed-point math;
- validation and access-control predicates;
- AMM/order-book/vault/governance state transitions;
- typed state records and event-like domain values before adapter encoding;
- pure serialization helpers that do not assume a chain host;
- unit/property tests and, eventually, formally verified extracted logic.

The chain adapter layer remains target-specific:

| Concern | Solana | EVM | NEAR | CosmWasm | Substrate contracts |
|---|---|---|---|---|---|
| Entry | loader `entrypoint(input)` | ABI selector dispatch | exported methods | `instantiate` / `execute` / `query` | selector dispatch |
| State | account data | contract storage | storage host funcs | storage host funcs | storage host funcs |
| Caller | signer/account metas | `msg.sender` | predecessor/signer | `MessageInfo.sender` | caller host API |
| Calls | CPI | `CALL` / `STATICCALL` | promises | Cosmos messages | contract call host API |
| Errors | status/panic | `revert` | `panic_utf8` | `StdError`/response | return flags/trap |
| Encoding | Solana/Anchor-shaped | Solidity ABI | JSON/Borsh | JSON/schema | SCALE/metadata |

## 4. Target families

### 4.1 Current: Solana SBF

The existing product path remains:

```text
Core IR → Lowered IR → Zig source → solana-zig -target sbf-solana → .so
```

This path already owns Solana-specific account parsing, syscalls, CPI/PDA,
SPL-Token helpers, Anchor-compatible IDL, Mollusk tests, and source maps.

### 4.2 Near-term candidate: generic WASM + adapters

WASM-chain support is the most natural second target family because Zig can
compile generated Zig source to `wasm32`:

```text
Core IR → Zig source → zig -target wasm32-freestanding → .wasm
```

Zig-to-WASM only solves the code generation layer. Each chain still needs an
adapter for entrypoints, host imports, storage, panic, serialization, metadata,
and tests.

Candidate adapter order:

1. **Generic WASM MVP** — no chain host; prove `omlz build --target=wasm`
   can emit deterministic `.wasm` for pure logic.
2. **NEAR adapter** — exported methods, `input`, `value_return`, storage,
   logging, panic, JSON/Borsh profile, near-sandbox tests.
3. **CosmWasm adapter** — `instantiate`/`execute`/`query`, JSON schema,
   `Response` messages/events/data, storage host functions, cw-multi-test or
   wasmd/simapp acceptance.
4. **Substrate contracts adapter** — selector dispatch, SCALE codec, metadata,
   pallet-contracts host API, weight/deposit acceptance.
5. **Other WASM runtimes** — Arbitrum Stylus, Internet Computer, and similar
   targets only after a named use case and host model are written down.

### 4.3 EVM candidate: Yul/bytecode backend

EVM should be a sibling backend, not a Zig-source target:

```text
Core IR → EVM lowering → Yul → solc/revm/anvil → bytecode
```

MVP scope should be deliberately small:

- pure computation and simple function dispatch;
- explicit `i64` compatibility or a documented `uint256`/`bytes32` extension;
- calldata decode and return encode only for supported types;
- revm/anvil/Foundry acceptance for bytecode behavior.

Later slices can add storage layout, events/logs, `address`, external calls,
revert/error metadata, and Solidity ABI JSON.

## 5. Upper syntaxes and verified sources

Because the canonical frontend input is a contract-safe OCaml subset, any upper
language can become a source language if it reliably lowers into that subset.

| Source family | Path | Value | Constraint |
|---|---|---|---|
| OCaml `.ml` | direct | canonical syntax | must stay within ZxCaml subset |
| ReasonML | Reason parser/refmt → OCaml | JS/TS-like syntax over OCaml semantics | generated OCaml must be subset-safe |
| ReScript-like sources | possible only via an OCaml-compatible path | broader syntax familiarity | modern ReScript is JS-oriented and may not map cleanly |
| Coq extraction | Coq proofs → OCaml extraction | verified business logic | extraction profile must avoid unsupported runtime patterns |
| F* extraction | F* proofs → OCaml extraction | verified protocols/state machines | extracted code must avoid heavy libraries/effects |
| WhyML/Why3 | verified specs → OCaml extraction | proof-driven algorithm logic | extraction subset must be pinned |
| PPX/custom DSL | syntax expansion → plain OCaml | contract DSL ergonomics | expansion must be deterministic and subset-safe |

This direction does **not** make ZxCaml itself fully formally verified. It lets
ZxCaml host and deploy **formally verified contract logic** when the upstream
proof/extraction toolchain produces accepted OCaml.

The proof chain has multiple links:

```text
F*/Coq/WhyML proof
  → extraction semantics
  → ZxCaml subset check
  → Core IR lowering correctness
  → backend correctness
  → chain adapter correctness
```

Early product language should therefore say:

```text
ZxCaml can host formally verified contract logic.
```

not:

```text
ZxCaml automatically verifies every contract.
```

## 6. Phased implementation sketch

### MTF-0 — Target contract ADR

- Define the product goal: portable functional business logic with explicit
  chain adapters.
- Separate compiler implementation language from backend output language.
- Specify the accepted portable subset for multichain logic.
- Decide whether portable `int` remains ZxCaml `i64` everywhere or whether EVM
  introduces target-specific `u256`/`bytes32` types.

### MTF-1 — Generic WASM smoke target

- Add `omlz build --target=wasm` behind an experimental flag.
- Reuse Zig source codegen where possible.
- Add `runtime/wasm` entry/panic/memory shims.
- Add one pure-function `.wasm` acceptance test under a deterministic WASM
  runner.

### MTF-2 — NEAR adapter MVP

- Add `--target=near` producing a NEAR-compatible `.wasm`.
- Implement minimal NEAR host imports: input, return, log, panic.
- Add one method-style entrypoint and near-sandbox acceptance.
- Keep storage and promises out until the no-storage MVP is stable.

### MTF-3 — Portable contract core API

- Define target-neutral capabilities: caller, storage read/write, log, return,
  and trap/revert as abstract operations.
- Implement those capabilities for Solana/native/WASM adapters where meaningful.
- Add diagnostics when a target uses unsupported capabilities.

### MTF-4 — EVM Yul MVP

- Add a separate `src/backend/evm_yul_codegen.zig` and `src/driver/evm.zig`.
- Emit Yul for pure functions, conditionals, arithmetic, and simple ABI dispatch.
- Validate with `solc --strict-assembly` plus revm/anvil/Foundry behavior tests.
- Do not route EVM user code through generated Zig source.

### MTF-5 — Verified extraction profile

- Define a `zxcaml-verified-subset` profile for extracted OCaml.
- Try one F* or Coq proof-to-OCaml-to-ZxCaml demo for a small invariant, such as
  non-negative balances or fee bounds.
- Add a checker/golden corpus for generated extraction patterns.

### MTF-6 — Additional chain adapters

- Add CosmWasm or Substrate only after MTF-1/2 prove the generic WASM layer and a
  concrete user story exists.
- Each adapter must include metadata/schema strategy, host imports, storage
  semantics, and acceptance tests.

## 7. Acceptance gates

A target graduates from idea to supported target only when it has:

1. a named use case and owner;
2. an entrypoint, panic strategy, memory plan, and calling convention;
3. a runtime/host adapter document;
4. at least one acceptance example that runs in the real or canonical VM;
5. CI coverage for build and execution;
6. diagnostics for APIs that are invalid on that target;
7. documentation of what is portable and what remains target-specific.

## 8. Anti-goals

- Do not claim that every Zig target is automatically supported.
- Do not claim one byte-identical contract artifact can deploy unchanged to all
  chains.
- Do not hide chain-specific semantics behind leaky names.
- Do not import the OCaml runtime, GC, exceptions, or arbitrary opam packages.
- Do not market formal verification as automatic; only verified/extracted logic
  carries upstream proof claims.
