# Anchor Reference Program

This isolated Anchor workspace exists only as a fairness reference for the
Colosseum demo's line-count and artifact-size comparison against
`examples/hackathon_greet.ml`. It is not part of ZxCaml's shipped compiler,
runtime, examples, tests, or root workspace builds.

## What It Mirrors

- `init` validates the bump-255 PDA derived from `[b"greet", maker]`, requires a
  program-owned writable greeting account with at least 40 bytes, and zeroes the
  first 40 bytes.
- `greet` validates the same PDA, stores the maker pubkey on the first greeting,
  then increments the little-endian `u64` counter at bytes `32..40`.
- The account data layout intentionally remains `maker: [u8; 32]` followed by
  `counter: u64`, matching the ZxCaml demo fixture instead of Anchor's usual
  8-byte account discriminator layout.

## Isolation

Build this reference only from this directory:

```sh
cd scripts/demo/anchor_reference
cargo check
anchor build
```

The top-level repository build does not reference this workspace. Generated
Anchor artifacts such as `target/`, `.anchor/`, and `Cargo.lock` should be
treated as local comparison outputs unless a later comparison task explicitly
captures them.
