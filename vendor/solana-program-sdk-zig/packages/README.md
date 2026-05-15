# Packages

Sub-packages of [`solana-sdk-mono`](../README.md). Each directory is
an independent Zig package with its own `build.zig.zon`, depending on
the root SDK via a path import.

## Layout

| Package | Target | Status | Purpose |
|---|---|---|---|
| [`spl-token`](./spl-token) | dual (on-chain CPI + off-chain ix builder) | ✅ v0.3 | SPL Token (transfer / authority / multisig / syncNative / …) |
| [`spl-token-2022`](./spl-token-2022) | host + on-chain-safe interface | ✅ v0.1 interface-core | Token-2022 TLV + fixed/variable extension parsing including confidential raw views, generic prepared CPI helpers, base mint/account/authority + reallocate + withdrawExcessLamports + Transfer Fee / ConfidentialTransfer proof-location lifecycle and registry configure / ConfidentialTransferFee proof-location withdraw/config/harvest toggles / MintCloseAuthority / DefaultAccountState / MemoTransfer / NonTransferable / CpiGuard / InterestBearingMint / PermanentDelegate / Pausable / pointer / TransferHook / ScaledUiAmount instruction builders, and Rust parity fixtures |
| [`spl-ata`](./spl-ata) | dual | ✅ v0.1 | Associated Token Account derivation, precomputed-address instruction builders, create CPI, and Rust parity fixtures |
| [`spl-memo`](./spl-memo) | dual | ✅ v0.1 | SPL Memo instruction builders, checked scratch variant, CPI helpers, and Rust parity fixtures |
| [`spl-token-metadata`](./spl-token-metadata) | on-chain/interface | 🚧 v0.1 interface | SPL Token Metadata interface: discriminators, raw instruction builders/parsers, bounded TokenMetadata state, and pinned Rust parity fixtures |
| [`spl-token-group`](./spl-token-group) | on-chain/interface | 🚧 v0.1 interface | SPL Token Group interface: discriminators, raw instruction builders/parsers, fixed-layout group/member state, and pinned Rust parity fixtures |
| [`spl-transfer-hook`](./spl-transfer-hook) | on-chain/interface | 🚧 v0.1 interface-core | SPL Transfer Hook discriminators, validation PDA helper, raw `ExtraAccountMeta` helpers, and tested instruction builders/parsers |
| [`spl-elgamal-registry`](./spl-elgamal-registry) | on-chain/interface | 🚧 v0.1 interface | SPL ElGamal Registry PDA, fixed account layout, create/update registry builders, and pinned Rust parity fixtures |
| [`spl-name-service`](./spl-name-service) | on-chain/interface | 🚧 v0.1 interface | SPL Name Service header parsing, name hash/PDA helpers, create/update/transfer/delete/realloc builders, and pinned Rust parity fixtures |
| [`spl-stake-pool`](./spl-stake-pool) | on-chain/interface | 🚧 v0.1 interface-core | SPL Stake Pool PDA helpers, validator-list parsing, common deposit/withdraw/update builders, and pinned Rust parity fixtures |
| [`spl-governance`](./spl-governance) | on-chain/interface | 🚧 v0.1 interface-core | SPL Governance PDA helpers, account-type/header parsing, realm/config/admin, token deposit/delegate, proposal/signatory/vote, and proposal transaction builders, with pinned Rust parity fixtures |
| [`solana-address-lookup-table`](./solana-address-lookup-table) | off-chain/shared | 🚧 v0.1 ALT helpers | Address Lookup Table account parsing, index resolution, v0 lookup records, management instruction builders, and Rust parity fixtures |
| [`solana-codec`](./solana-codec) | shared | 🚧 v0.1 codec primitives | Allocation-free shortvec, Borsh primitive/string/bytes, bincode string/options, and bincode `COption` helpers |
| [`solana-config`](./solana-config) | dual instruction builder | 🚧 v0.1 config store helpers | Config Program raw ConfigKeys encoding, store instruction builders, and ConfigState views |
| [`solana-compute-budget`](./solana-compute-budget) | dual instruction builder | 🚧 v0.1 instruction builders | Compute Budget instruction builders for heap frame, CU limit, CU price, and loaded account data size |
| [`solana-feature-gate`](./solana-feature-gate) | shared helpers | 🚧 v0.1 feature helpers | Feature account encode/decode and activation instruction sequence |
| [`solana-zk-elgamal-proof`](./solana-zk-elgamal-proof) | dual instruction builder | 🚧 v0.1 raw proof builders | ZK ElGamal proof-program close-context, inline proof, and proof-account verify instruction builders |
| [`solana-loader-v3`](./solana-loader-v3) | dual instruction builder | 🚧 v0.1 loader helpers | Upgradeable BPF Loader v3 state layout, chunked program writes, and deploy/upgrade/authority/extend instruction builders |
| [`solana-loader-v4`](./solana-loader-v4) | dual instruction builder | 🚧 v0.1 loader helpers | Loader v4 state layout and write/copy/deploy/retract/authority/finalize instruction builders |
| [`solana-system`](./solana-system) | dual instruction builder | 🚧 v0.1 instruction builders | System Program createAccount, transfer, assign, and allocate instruction builders |
| [`solana-stake`](./solana-stake) | dual instruction builder | 🚧 v0.1 instruction builders | Stake Program initialize, authorize including seeded variants, lockup mutation, delegate, split, withdraw, deactivate, merge, minimum delegation, and move builders |
| [`solana-vote`](./solana-vote) | dual instruction builder | 🚧 v0.1 instruction builders | Vote Program initialize, authorize including seeded variants, update validator identity, update commission, withdraw, and raw runtime vote/update/tower builders |
| [`solana-tx`](./solana-tx) | off-chain | 🚧 v0.1 transaction foundation | Legacy transaction message compilation plus legacy/v0 message and transaction serialization |
| [`solana-transaction-builder`](./solana-transaction-builder) | off-chain | 🚧 v0.1 transaction assembly | Compile/sign/serialize legacy/v0 transactions, ALT selection, durable nonce pairs, compute-budget System/SPL Token/Token-2022 transfer, transfer-fee, confidential-transfer and confidential-transfer-with-fee proof preludes, and context cleanup, plus ATA+token transfer helpers |
| [`solana-keypair`](./solana-keypair) | off-chain | 🚧 v0.1 signing foundation | Ed25519 keypair recovery from seeds, public-key export, and detached message signing |
| [`solana-client`](./solana-client) | off-chain | 🚧 v0.1 RPC client core | Caller-buffer JSON-RPC/account-info builders/parsers, ALT fetch helper, std HTTP transport adapter, caller-owned stream WebSocket adapter, endpoint/retry/commitment/deadline policy, and typed RPC error normalization |
| [`solana-wallet`](./solana-wallet) | off-chain | 🚧 v0.1 wallet core | Solana CLI keypair JSON, bundled BIP39 English wordlist, seed derivation/checksum validation, Solana derivation paths, wallet adapter boundary, and AEAD encrypted-keystore helpers |

See [`../ROADMAP.md`](../ROADMAP.md#monorepo-分层) for the full
package-naming convention and dependency layout rationale.

## Conventions

Most sub-packages follow the same shape:

```
packages/<name>/
├── README.md
├── build.zig                    # builds the package + its examples
├── build.zig.zon                # depends on solana_program_sdk via path
├── src/
│   ├── root.zig                 # public re-exports
│   ├── id.zig                   # Program ID + well-known constants
│   ├── state.zig                # account-state extern structs / base views
│   ├── instruction.zig          # ix builders — when the package exposes them
│   ├── cpi.zig                  # on-chain invoke() wrappers when needed
│   ├── tlv.zig                  # TLV parsing packages such as spl_token_2022
│   └── extension.zig            # fixed extension views when applicable
└── examples/                    # demo programs using the package
```

Integration tests live under [`../program-test/tests/`](../program-test/tests/)
and load the built `.so` artifacts from `program-test/zig-out/lib`.

For client-style packages, the split between `instruction.zig` (dual-target) and `cpi.zig`
(on-chain only) mirrors the Rust ecosystem's pattern of having a
single SPL crate usable both on-chain (CPI) and off-chain (transaction
building) — `instruction.zig` constructs `sol.cpi.Instruction` /
`sol.cpi.AccountMeta` byte buffers that work in either context, while
`cpi.zig` adds a thin wrapper around `sol_invoke_signed_c` for the
common on-chain case. `spl-token-2022` is interface-core in v0.1:
it exports `id.zig`, `state.zig`, `tlv.zig`, `extension.zig`, and base
`instruction.zig` builders, but no CPI surface.
Interface-only packages such as `spl-token-metadata`,
`spl-token-group`, `spl-transfer-hook`, `spl-elgamal-registry`, `spl-name-service`, `spl-stake-pool`, and `spl-governance` keep their public roots
package-scoped and limited to raw instruction/state boundaries rather
than full transaction orchestration. `solana-address-lookup-table`
parses and resolves ALT account data for v0 transactions and builds
ALT management instructions.
`solana-codec` is the shared allocation-free byte-codec layer for
shortvec, Borsh, bincode string/options, and bincode `COption` layouts. `solana-compute-budget`,
`solana-config`, `solana-feature-gate`, `solana-loader-v3`,
`solana-loader-v4`, `solana-system`, `solana-stake`, and `solana-vote` expose shared
transaction instruction builders.
Off-chain `solana_*` packages such as `solana-tx`,
`solana-transaction-builder`, `solana-keypair`, `solana-client`, and `solana-wallet` consume those raw
instruction surfaces and provide host-only orchestration layers without
importing RPC transport or wallet state into the on-chain core.
`solana-client` includes concrete HTTP and WebSocket transport adapters while
keeping socket/TLS lifetime caller-owned.
`solana-wallet` includes the canonical BIP39 English wordlist while still
allowing caller-owned wordlist resolvers for entropy/checksum validation and
encrypted-keystore envelope parsing/writing.

## Adding a new package

1. `mkdir packages/<name>` and copy the scaffold from an existing
   package (start with `spl-memo` for CPI/builder packages, or
   `spl-token-2022` for TLV/interface packages).
2. Update `build.zig.zon` with the package's own name and version.
3. Add a row to the table above and to the top-level README.
4. Wire the package into `.github/workflows/main.yml` so CI runs its
   tests + SBF build.
