# 14 — Hash syscalls and secp256k1 recovery

> **Languages / 语言**: **English** · [简体中文](./zh/14-hash-syscalls.md)
>
> **Scope:** Solana hash syscalls exposed through the ZxCaml runtime and
> stdlib: SHA-256, Keccak-256, BLAKE3, and secp256k1 public-key recovery.
>
> **See also:** [`docs/runtime-api.md`](./runtime-api.md),
> [`docs/11-solana-p3.md`](./11-solana-p3.md),
> [`examples/keccak_demo.ml`](../examples/keccak_demo.ml),
> [`examples/blake3_demo.ml`](../examples/blake3_demo.ml), and
> [`examples/secp_recover_demo.ml`](../examples/secp_recover_demo.ml).

## 1. Position

Hashing is a runtime boundary, not a new language feature.
ZxCaml source remains ordinary `.ml`.
The frontend type-checks calls such as `Crypto.keccak256 payload`.
The Zig backend recognizes the bundled externals.
Generated BPF code calls Solana's syscalls through `runtime/zig/syscalls.zig`.
Hosted native builds use deterministic `std.crypto` fallbacks for hash digests.
Hosted secp256k1 recovery is success-shaped only; real recovery belongs to SVM.
The public OCaml surface intentionally returns `bytes` values.
A digest is always exactly 32 bytes.
A recovered secp256k1 public key is exactly 64 bytes on success.
Recovery failure is represented as a zero-length byte slice.
This keeps hash use simple in examples while still matching the SBF ABI.
The implementation commits for this milestone are `cd2bc31`, `721aeae`,
`e48ea82`, `973850b`, and `40fa8bd`.

## 2. ABI summary

All digest syscalls use Solana's byte-slice descriptor ABI.
`runtime/zig/syscalls.zig` names that descriptor `SolBytes`.
The descriptor is an extern struct with two fields.
`addr` is a pointer to the first byte of one segment.
`len` is the segment length as `u64`.
The syscall receives a pointer to the first descriptor.
The syscall also receives the number of descriptors.
The syscall writes the 32-byte digest into caller-owned output memory.
The syscall returns a `u64` status code.
The current public `Crypto.*` wrappers pass one descriptor for one OCaml `bytes`.
The runtime shape still leaves room for future multi-segment wrappers.
secp256k1 recovery has a separate four-argument ABI.
It receives the 32-byte hash pointer.
It receives the recovery id as `u64`.
It receives the 64-byte compact signature pointer.
It receives a mutable 64-byte output pointer for the uncompressed public key.
It returns zero on success and non-zero on failure.
The ZxCaml wrapper validates obvious length and recovery-id mistakes first.

| Operation | Runtime wrapper | SBF syscall address | Output |
|---|---|---:|---|
| SHA-256 | `sol_sha256` / `sol_sha256_alloc` | `0x11f49d86` | 32-byte digest |
| Keccak-256 | `sol_keccak256` / `sol_keccak256_alloc` | `0xd7793abb` | 32-byte digest |
| BLAKE3 | `sol_blake3` / `sol_blake3_alloc` | `0x174c5122` | 32-byte digest |
| secp256k1 recovery | `sol_secp256k1_recover_alloc` | `0x17e40350` | 64-byte pubkey or empty bytes |

## 3. Stdlib binding signatures

The bundled stdlib lives in [`stdlib/core.ml`](../stdlib/core.ml).
The hash API is in `module Crypto`.
The current signatures are deliberately small:

```ocaml
module Crypto : sig
  val sha256 : bytes -> bytes
  val keccak256 : bytes -> bytes
  val blake3 : bytes -> bytes
  val secp256k1_recover : bytes -> int -> bytes -> bytes
end
```

`Crypto.sha256 payload` returns a 32-byte SHA-256 digest.
`Crypto.keccak256 payload` returns a 32-byte Keccak-256 digest.
`Crypto.blake3 payload` returns a 32-byte BLAKE3 digest.
`Crypto.secp256k1_recover hash recovery_id signature` returns recovered bytes.
The `hash` argument must contain exactly 32 bytes.
The `signature` argument must contain exactly 64 compact ECDSA bytes.
The `recovery_id` argument must be in the inclusive range `0..3`.
A successful recovery returns 64 bytes.
A failed recovery returns `Bytes.length result = 0`.
The low-level `Syscall.sol_sha256` helper remains available for older samples.
Prefer `Crypto.*` in new user code because it names the algorithm directly.

## 4. SHA-256

SHA-256 was already part of the runtime surface before this milestone.
It remains the conservative default when a Solana or Anchor convention says
"hash" without specifying Ethereum compatibility.
Use it for Anchor instruction discriminators.
Use it for program-derived-address helper material.
Use it when matching existing ZxCaml examples that already call
`sol_sha256_alloc`.
Use it when a protocol document explicitly says SHA-256.
Do not substitute Keccak-256 just because both produce 32 bytes.
Do not substitute BLAKE3 just because it is fast off-chain.
The digest type is still a byte string, so domain separation is your job.
Prefix application-specific messages before hashing them.
Keep the prefix stable and documented.

```ocaml
let digest : bytes = Crypto.sha256 payload
```

The runtime wrapper is:

```zig
pub inline fn sol_sha256(payload: []const u8) Hash
pub inline fn sol_sha256_alloc(arena: *Arena, payload: []const u8) []const u8
```

On BPF the wrapper calls `sol_sha256` through the pinned dispatch address.
On hosted targets it calls `std.crypto.hash.sha2.Sha256.hash`.
Both paths produce 32 bytes for the same input.

## 5. Keccak-256

Keccak-256 was added for Ethereum-style digest compatibility.
Use it when a signature fixture, bridge protocol, or off-chain indexer expects
Ethereum's Keccak-256 digest rather than NIST SHA3-256.
The function name intentionally says `keccak256`, not `sha3_256`.
This avoids the common Keccak/SHA3 padding confusion.
The BPF wrapper mirrors SHA-256 exactly.
The hosted fallback uses Zig's Keccak implementation.
The public example is [`examples/keccak_demo.ml`](../examples/keccak_demo.ml).
That program hashes instruction data and writes the digest to account data.
The Mollusk fixture checks the byte-for-byte digest in SVM.

```ocaml
let entrypoint output_account instruction_data =
  let digest = Crypto.keccak256 instruction_data in
  set_account_data output_account digest;
  0
```

Runtime ABI shape:

```zig
const SolHashFn = *align(1) const fn ([*]const u8, u64, [*]u8) u64;
pub inline fn sol_keccak256(payload: []const u8) Hash
pub inline fn sol_keccak256_alloc(arena: *Arena, payload: []const u8) []const u8
```

The descriptor count is currently one for `Crypto.keccak256`.
The output length is always 32 bytes.
The wrapper ignores the raw status code because the runtime owns valid pointers.
If Solana changes the syscall contract, update `runtime/zig/syscalls.zig` first.

## 6. BLAKE3

BLAKE3 was added for protocols that choose modern BLAKE3 digests.
Solana's syscall returns a fixed 32-byte digest.
ZxCaml follows that fixed digest size.
It does not expose BLAKE3's extendable-output mode.
Use BLAKE3 only when the on-chain or off-chain protocol names BLAKE3.
Do not use it for Anchor discriminators.
Do not use it for Ethereum-compatible message hashes.
It is a good fit for content-addressed internal data when both sides agree.
The public example is [`examples/blake3_demo.ml`](../examples/blake3_demo.ml).
That program has the same structure as the Keccak demo.
The paired Mollusk test compares the SVM digest against a known BLAKE3 value.

```ocaml
let entrypoint output_account instruction_data =
  let digest = Crypto.blake3 instruction_data in
  set_account_data output_account digest;
  0
```

Runtime ABI shape:

```zig
pub inline fn sol_blake3(payload: []const u8) Hash
pub inline fn sol_blake3_alloc(arena: *Arena, payload: []const u8) []const u8
```

The wrapper allocates 32 bytes from the BPF entry arena when returning to OCaml.
The arena allocation is explicit in generated Zig.
The OCaml user sees only a `bytes` value.
The output account must have at least 32 writable bytes when examples copy it.

## 7. secp256k1 recovery

`sol_secp256k1_recover` verifies and recovers an Ethereum-style public key.
It does not hash the message for you.
Callers pass the already-computed 32-byte hash.
Callers pass a compact 64-byte ECDSA signature in `r || s` order.
Callers pass the recovery id separately.
The valid recovery-id range is exactly `0`, `1`, `2`, or `3`.
Values outside that range fail before invoking the BPF syscall.
Wrong hash or signature lengths also fail before invoking the syscall.
The successful return is a 64-byte uncompressed secp256k1 public key.
It is the x-coordinate followed by the y-coordinate.
It is not a compressed 33-byte SEC1 key.
It is not a 65-byte key with a `0x04` prefix.
The public example is [`examples/secp_recover_demo.ml`](../examples/secp_recover_demo.ml).
The Mollusk test uses a libsecp256k1 fixture from Bitcoin Core recovery tests.

```ocaml
match String.length (Crypto.secp256k1_recover hash recovery_id signature) with
| 64 -> (* success: write or compare the recovered key *) 0
| _ -> (* failure: invalid id, invalid lengths, or syscall rejection *) 1
```

Runtime ABI shape:

```zig
const SolSecp256k1RecoverFn = *align(1) const fn (
    [*]const u8,
    u64,
    [*]const u8,
    [*]u8,
) u64;

pub inline fn sol_secp256k1_recover(
    hash: []const u8,
    recovery_id: i64,
    signature: []const u8,
) ?Secp256k1Pubkey

pub inline fn sol_secp256k1_recover_alloc(
    arena: *Arena,
    hash: []const u8,
    recovery_id: i64,
    signature: []const u8,
) []const u8
```

The `_alloc` wrapper maps `null` to an empty slice.
Generated OCaml-facing code therefore has a single `bytes` return type.
Document failure handling at every call site that accepts user signatures.

## 8. Choosing the right operation

Use SHA-256 for Solana-native conventions unless a protocol says otherwise.
Use SHA-256 for Anchor discriminator compatibility.
Use SHA-256 for existing PDA helper material in this repository.
Use Keccak-256 for Ethereum message-hash compatibility.
Use Keccak-256 when reproducing an `ecrecover` flow.
Use BLAKE3 for protocols that explicitly commit to BLAKE3.
Use BLAKE3 for internal content hashes only when every verifier agrees.
Use secp256k1 recovery only after you already have a 32-byte digest.
Do not feed arbitrary user text directly to recovery.
Do not treat the recovered 64-byte public key as a Solana `Pubkey`.
If you need an Ethereum address, hash the recovered key with Keccak-256 and
apply the protocol's address derivation rules outside this primitive.
If two protocols share a digest algorithm, still use domain-separated prefixes.
If a hash guards authority, bind it to program id, account keys, and purpose.

## 9. Security notes

Hash functions do not make ambiguous encodings safe.
Always encode typed fields with fixed lengths or explicit length prefixes.
Avoid concatenating variable-length fields without separators.
Include a domain string when the same fields appear in different contexts.
Include the program id when a digest authorizes a program-specific action.
Include account keys when a digest authorizes account-specific state changes.
Do not compare a digest prefix unless the protocol explicitly specifies one.
Use constant-size account writes for digest outputs.
Reject or ignore outputs with unexpected lengths.
For secp256k1, enforce `recovery_id` in `0..3` before calling recovery.
The runtime wrapper already does this, but explicit checks improve diagnostics.
ECDSA signatures are malleable unless the protocol enforces a low-`s` rule.
The recovery syscall recovers a key; it does not by itself enforce low-`s`.
If your protocol depends on non-malleability, validate canonical signatures at
the protocol layer or reuse a fixture source that states the canonical rule.
The demo fixture is for interoperability, not for production authorization.
Never accept a recovered key without also checking the expected signer identity.
Never log private signature material.

## 10. Example: digest writer

The Keccak and BLAKE3 demos both use the same pattern.
They accept a writable output account and instruction data.
They compute one digest from all instruction data.
They copy the digest into the output account.
They return zero after the write.
The helper below is a type witness in source.
Generated BPF code performs the actual account-data copy.

```ocaml
let set_account_data (account : account) bytes =
  let _ = account.data in
  let _ = bytes in
  ()

let entrypoint output_account instruction_data =
  let digest = Crypto.keccak256 instruction_data in
  let _ = set_account_data output_account digest in
  0
```

For BLAKE3, replace `Crypto.keccak256` with `Crypto.blake3`.
See [`examples/keccak_demo.ml`](../examples/keccak_demo.ml).
See [`examples/blake3_demo.ml`](../examples/blake3_demo.ml).

## 11. Example: recovery writer

The recovery demo uses a fixed instruction-data layout.
Bytes `0..32` are the message hash.
Byte `32` is the recovery id.
Bytes `33..97` are the compact signature.
The program slices the hash and signature.
It checks the recovery id with an OCaml-level branch.
It calls the recovery external.
It writes the result to the first account.
An empty recovery result means the output write has no key bytes to copy.
The Mollusk test supplies the known-good tuple.

```ocaml
let hash = String.sub instruction_data 0 32
let signature = String.sub instruction_data 33 64
let recovered = recover hash checked_recovery_id signature
```

See [`examples/secp_recover_demo.ml`](../examples/secp_recover_demo.ml).
The test fixture documents its source in
[`tests/secp_recover_demo_test.rs`](../tests/secp_recover_demo_test.rs).

## 12. Verification checklist

When adding a new hash-using program, check the input shape first.
Check the exact algorithm name second.
Check the expected output length third.
Check whether the result is a digest, an address, or a public key.
Run `omlz check` before building BPF.
Run the matching Mollusk test when account writes are involved.
For digest writers, assert 32 bytes were written.
For recovery writers, assert 64 bytes on success.
For recovery failures, assert zero bytes or an explicit program error.
Keep fixture provenance comments next to static signature data.
Prefer known-answer vectors over runtime-generated signatures.
Record the commit hash when a public docs or changelog claim depends on it.

## 13. Troubleshooting

A 32-byte mismatch usually means the wrong algorithm was selected.
Check Keccak-256 versus SHA3-256 first.
Then check whether the input bytes include a prefix, discriminator, or length.
A zero-length secp256k1 result means the wrapper rejected the input or the
SVM syscall returned non-zero.
Check `hash` length is 32.
Check `signature` length is 64.
Check `recovery_id` is between 0 and 3.
Check the signature is compact `r || s`, not DER.
Check that the expected key omits the SEC1 `0x04` prefix.
A hosted native recovery test cannot prove real secp256k1 recovery.
Use Mollusk or another SVM-backed path for that.
A BPF account-write failure usually means account data is too small or not
writable in the test fixture.

## 14. File map

`runtime/zig/syscalls.zig` owns syscall addresses, wrappers, and hosted fallbacks.
`stdlib/core.ml` owns the `Crypto` binding signatures.
`src/backend/zig_codegen/runtime_imports.zig` maps bundled externals to wrappers.
`examples/keccak_demo.ml` is the Keccak digest writer.
`examples/blake3_demo.ml` is the BLAKE3 digest writer.
`examples/secp_recover_demo.ml` is the secp256k1 recovery writer.
`tests/keccak_demo_test.rs` validates Keccak in Mollusk.
`tests/blake3_demo_test.rs` validates BLAKE3 in Mollusk.
`tests/secp_recover_demo_test.rs` validates recovery and fixture provenance.
`CHANGELOG.md` records the five milestone commits under `[Unreleased]`.
`mission-internal/canonical-facts.md` records current post-M-HASH values.

## Direct-write optimization

`Crypto.secp256k1_recover` still has the same public OCaml type.
The ordinary, allocation-shaped form is still the baseline semantics.
In that form the frontend sees `bytes -> int -> bytes -> bytes`.
The bundled external lowers to `sol_secp256k1_recover_alloc`.
Generated Zig passes the BPF entry arena to that helper.
The helper validates the 32-byte hash, the `0..3` recovery id, and the
64-byte compact signature.
On success it materializes a 64-byte recovered public key in arena-owned
memory and returns it as OCaml `bytes`.
On failure it returns an empty byte slice.
This allocation form remains correct when user code compares the result,
branches on its length, stores it for later, passes it through another helper,
or otherwise needs a real `bytes` value.

M-CODEGEN-OPT adds a narrower backend-only direct-write path.
The ANF post-pass recognizes a recovered pubkey whose only consumer is an
account-data write.
The source still calls `Crypto.secp256k1_recover`; no user-facing API changes.
The pass rewrites the internal expression to
`Crypto.secp256k1_recover_into_account`.
The Zig backend maps that intrinsic to
`syscalls.sol_secp256k1_recover_into_account_data`.
That runtime helper receives `account.data` as a mutable slice and passes
`account.data.ptr` directly as the Solana syscall output pointer.
No 64-byte arena buffer is created.
No second copy from recovered bytes into account data is needed.
The hosted fallback writes the deterministic success-shaped bytes directly into
the same account-data slice so native/codegen tests still exercise the shape.

The pass fires only for a single-use pattern.
The producer must be a `Crypto.secp256k1_recover` call, or an external that
resolves to `sol_secp256k1_recover_alloc`.
The bound recovered value must appear exactly once in the continuation.
That one appearance must be the value passed to `set_account_data account r`,
or the value of an `AccountFieldSet` whose field name is exactly `data`.
The account expression is preserved as the first argument to the new intrinsic.
The hash, recovery id, and signature expressions are preserved in order.
Program order remains explicit because the replacement is still an effectful
call in the same ANF position as the account write.

The pass deliberately does not fire when the recovered value is unused.
It does not fire when the recovered value is read more than once.
It does not fire when the value is captured by a closure.
It does not fire when the consumer writes a non-`data` account field.
It does not fire for SHA-256, Keccak-256, or BLAKE3 digest writers.
It does not fire when user code needs to inspect `Bytes.length recovered` before
writing, because that requires the allocation-shaped `bytes` value.
It does not remove the alloc helper; both codegen paths remain available.
The old `crypto_secp_recover` golden continues to cover the non-direct case.
The new `crypto_secp_recover_direct` golden freezes the direct case.

This matters because the generic recovered-bytes shape was too expensive for
one common BPF account writer.
The previous Mollusk fixture had to patch generated Zig after `omlz build` and
relink with a larger BPF stack allowance after sbpf-linker reported that the
BPF stack limit was exceeded.
With direct-write codegen, `examples/secp_recover_demo.ml` builds through the
normal BPF path without that relink workaround.
The SVM fixture can now validate the same generated program that users build.
The optimization also keeps the public source code simple: the programmer still
writes the natural recover-then-write shape.

Worked source pattern:

```ocaml
let recover_into_account (acc : account) h k s =
  let r = Crypto.secp256k1_recover h k s in
  let _ = set_account_data acc r in
  0
```

Emitted Zig shape after the ANF rewrite:

```zig
_ = syscalls.sol_secp256k1_recover_into_account_data(
    omlz_secp_account_1.data,
    h,
    k,
    s,
);
```

The direct helper returns the syscall status as an integer-shaped effect.
Generated program code can keep returning `0` or the helper result depending on
the surrounding lowered expression.
The account-data length check happens inside the runtime helper.
If the output account is too small, the helper returns non-zero instead of
writing partial pubkey bytes.
Keep using the allocation form when the recovered key is not immediately and
exclusively copied into `account.data`.

