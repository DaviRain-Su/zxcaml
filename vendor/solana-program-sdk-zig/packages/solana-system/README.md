# solana-system

Shared System Program instruction builders for Zig.

The root SDK already exposes `sol.system.*` CPI helpers for on-chain
programs. This package exposes the same common wire formats as raw
`sol.cpi.Instruction` builders from pubkeys, which is the shape needed
by off-chain transaction assembly packages.

## Scope

- `createAccount`
- `transfer`
- `assign`
- `allocate`
- `createAccountWithSeed`
- `assignWithSeed`
- `allocateWithSeed`
- `transferWithSeed`
- durable nonce maintenance:
  - `initializeNonceAccount`
  - `advanceNonceAccount`
  - `withdrawNonceAccount`
  - `authorizeNonceAccount`
  - `upgradeNonceAccount`

Convenience builders that expand into multiple instructions, such as
create-and-initialize nonce account flows, remain a transaction assembly
concern for now.
