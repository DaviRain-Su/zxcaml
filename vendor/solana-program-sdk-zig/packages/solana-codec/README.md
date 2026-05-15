# solana-codec

Shared Solana byte-codec primitives for Zig packages.

This package is intentionally small and allocation-free. It provides the
wire formats that appear across Solana programs and client packages, so
SPL packages and off-chain builders can share one tested implementation.

## Scope

- Solana shortvec length encoding and decoding
- Borsh primitive/string/byte-vector and option helpers
- Bincode string helpers with `u64` little-endian length prefixes
- Bincode primitive, length, and `Option<u64>` / `Option<i64>` /
  `Option<Pubkey>` helpers
- Solana serde-varint `u64` writer used by compact vote-state payloads
- Bincode-style `COption<Pubkey>` and `COption<u64>` helpers, including
  zero-copy split tag/payload readers for packed account-state structs

It does not attempt to be a full reflection-based serializer. Callers
compose these primitives into explicit instruction and account layouts.
