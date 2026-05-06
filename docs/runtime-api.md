# Runtime API

This document summarizes the post-RT Zig runtime surface that generated ZxCaml code may import.
It is intentionally source-oriented: every section names the canonical file to inspect before changing behavior.
The API is small, deterministic, and tuned for Solana BPF entrypoints plus hosted tests.
Examples are Zig snippets because the public surface described here is the runtime layer, not user OCaml syntax.

Reading guide:

- Treat public Zig declarations as the compatibility surface for generated code.
- Treat private helpers as implementation details even when this document mentions their behavior.
- Check the cited source file before changing an exported type, constant, or function.
- Keep generated-code ABI concerns separate from user-facing OCaml documentation.

## Arena

Source file: `runtime/zig/arena.zig`.

- `Arena` is the public bump-allocator type used by generated functions and runtime helpers.
- `Arena.buffer` is a caller-owned `[]u8`; the arena never allocates or frees that backing memory.
- `Arena.offset` is the current bump cursor measured in bytes from the start of `buffer`.
- `Arena.fromStaticBuffer(buf)` constructs an arena view over static or stack-provided bytes.
- `Arena.alloc(T, count)` returns a typed slice and reports `error.OutOfMemory` or arithmetic overflow.
- `Arena.allocIntoOrTrap(T, count, out)` writes the allocated slice into `out` and traps on exhaustion.
- `Arena.allocOneOrTrap(T)` returns a pointer to one value and rounds the slot size to an 8-byte boundary.
- `Arena.reset()` rewinds the cursor so later work can reuse the same storage.
- The allocator aligns `alloc` results to `@alignOf(T)` using Zig's `std.mem.alignForward`.
- Generated BPF entry code supplies the arena implicitly; user OCaml code does not pass or see it.
- Hosted tests can build tiny arenas from stack buffers to validate runtime functions without Solana.
- The arena is deliberately single-owner: references into it are valid only while the backing buffer remains live.

Usage example:

```zig
var scratch: [1024]u8 align(8) = undefined;
var arena = Arena.fromStaticBuffer(&scratch);
const words = try arena.alloc(u64, 4);
```

Operational notes:

- Prefer `alloc` in tests where error reporting is useful.
- Prefer the `OrTrap` helpers in generated BPF paths that must keep the ABI surface simple.
- Do not store an `Arena` beyond the lifetime of its backing buffer.
- Do not call `reset` while slices allocated from the current pass are still needed.
- Keep additions allocation-policy-neutral; region inference belongs in compiler lowering, not this file.

## Syscalls

Source file: `runtime/zig/syscalls.zig`.

- `Pubkey` is `[32]u8`, shared with CPI and account-facing runtime code.
- `Hash` is `[32]u8`, used by SHA-256 and Keccak-256 wrappers.
- `SolBytes` is the C ABI byte-slice descriptor expected by Solana hash syscalls.
- `Clock` mirrors the Solana Clock sysvar layout returned by `sol_get_clock_sysvar`.
- `Rent` mirrors the Rent sysvar layout returned by `sol_get_rent_sysvar`.
- `sol_log_address`, `sol_log_64_address`, and `sol_log_pubkey_address` pin BPF dispatch addresses.
- `sol_sha256_address` and `sol_keccak256_address` pin the hash syscall dispatch addresses.
- `sol_get_clock_sysvar_address` and `sol_get_rent_sysvar_address` pin sysvar lookup addresses.
- `sol_log_compute_units_address` and `sol_remaining_compute_units_address` identify compute-budget probes.
- `sol_log_(message)` logs a byte slice on BPF and is a no-op on hosted targets.
- `sol_log_64_(a, b, c, d, e)` logs five 64-bit values using Solana's numeric log shape.
- `sol_log_pubkey(pubkey)` logs a public key by pointer.
- `sol_sha256(payload)` and `sol_keccak256(payload)` return fixed `[32]u8` digests.
- `sol_sha256_alloc(arena, payload)` and `sol_keccak256_alloc(arena, payload)` copy digests into arena slices.
- `sol_get_clock_sysvar()`, `sol_get_rent_sysvar()`, `sol_log_compute_units_()`, and `sol_remaining_compute_units()` expose runtime inspection helpers.

Usage example:

```zig
syscalls.sol_log_("zxcaml: entered");
const digest = syscalls.sol_sha256(instruction_data);
```

Operational notes:

- The file includes hosted hash fallbacks so native tests can assert deterministic digest values.
- Logging helpers intentionally do not allocate.
- `sol_remaining_compute_units()` currently logs compute units on BPF and returns `0` as the portable value.
- Syscall address constants are tested against the current MurmurHash3-32 assignments.
- Add new syscall wrappers here only when the compiler or runtime needs them directly.

## CPI

Source file: `runtime/zig/cpi.zig`.

- `Pubkey` aliases `syscalls.Pubkey` so account, syscall, and CPI code share one key representation.
- `max_seed_len` is `32`, matching Solana's per-seed PDA limit.
- `max_seeds` is `16`, matching Solana's maximum seed vector length.
- `pda_marker` is the `ProgramDerivedAddress` domain separator used by hosted PDA derivation.
- `SolAccountMeta` is the C ABI account-meta record: pubkey pointer plus writable and signer flags.
- `SolInstruction` is the C ABI instruction descriptor: program id, metas, and instruction bytes.
- `SolInstruction.fromSlices(program_id, accounts, data)` safely builds an instruction descriptor from Zig slices.
- `SolAccountInfo` mirrors the C ABI account-info descriptor passed to CPI calls.
- `SolSignerSeed.fromSlice(seed)` turns one byte slice into the ABI seed descriptor.
- `SolSignerSeeds.toC()` exposes a higher-level seed group as `SolSignerSeedsC`.
- `accountInfoFromView(view)` converts an `account.AccountView` into a CPI-ready `SolAccountInfo`.
- `sol_invoke_signed_c(instruction, infos, signer_seeds)` calls the Solana CPI syscall or hosted fallback.
- `invoke(instruction, infos)` is the no-signer-seed convenience wrapper.
- `sol_create_program_address` and `sol_try_find_program_address` bind PDA derivation with hosted fallbacks.
- `sol_set_return_data`, `sol_get_return_data`, and `sol_get_return_data_alloc` expose Solana return data.

Usage example:

```zig
const ix = cpi.SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
const status = cpi.invoke(&ix, infos[0..]);
```

Operational notes:

- CPI program-specific entrypoints were moved out of this file during RT; this file should stay primitive-only.
- Hosted `invoke` returns success so tests can validate instruction construction without a loader.
- Hosted PDA derivation rejects invalid seeds and on-curve derived addresses.
- Return data has a hosted scratch capacity of 1024 bytes.
- Use `accountInfoFromView` when a caller already parsed accounts through `runtime/zig/account.zig`.

## Account

Source file: `runtime/zig/account.zig`.

- `AccountView` is a zero-copy view over one serialized Solana account entry.
- `AccountView.is_signer`, `is_writable`, and `executable` expose the loader flags as booleans.
- `AccountView.key` and `AccountView.owner` point at 32-byte public keys inside the input buffer.
- `AccountView.lamports` points at mutable lamports in the input buffer.
- `AccountView.data` is a mutable view over account data bytes.
- `AccountView.rent_epoch` points at the rent epoch value in the input buffer.
- `AccountView.lamportsValue()` reads the current lamports value through the pointer.
- `AccountView.rentEpochValue()` reads rent epoch through the pointer.
- `ParseError` reports `TruncatedInput`, `InvalidPadding`, `AccountCountOverflow`, and `OutOfMemory`.
- `parseAccounts(arena, input)` parses a bounded mutable byte slice for tests and harnesses.
- `parseAccountsFromPtr(arena, input)` parses the raw Solana entrypoint pointer into arena storage.
- `parseAccountsFromPtrInto(arena, input, out)` avoids returning a large slice by value on BPF.
- `parseAccountsFromPtrIntoStorage(input, storage, out)` uses caller-provided view storage.
- `parseInstructionData` and `parseInstructionDataFromPtr` locate the instruction payload after accounts.
- `logAccountsFromPtr(input)` logs account keys and lamports for account/syscall smoke programs.

Usage example:

```zig
const views = try account.parseAccountsFromPtr(&arena, input);
const data = try account.parseInstructionDataFromPtr(input);
```

Operational notes:

- Bounded parsers validate truncation and padding; pointer parsers trust Solana's loader layout.
- Account data and lamports are views, so writes mutate the serialized input buffer directly.
- The parser accounts for Solana's permitted data growth area and 8-byte alignment.
- `parseAccountsFromPtrIntoStorage` is useful when the caller must avoid arena allocation for views.
- `logAccountsFromPtr` uses a local 1 KiB scratch arena and returns silently if parsing fails.

## SPL Token

Source file: `runtime/zig/spl_token.zig`.

- `Pubkey` aliases `cpi.Pubkey` for SPL Token account and program ids.
- `pubkey_len` is `32`, the fixed public-key byte length.
- `transfer_discriminator` is `3`, the legacy Tokenkeg Transfer instruction tag.
- `transfer_instruction_data_len` is `9`, one discriminator byte plus a little-endian `u64` amount.
- `token_account_len` is `165`, the packed SPL Token account state length parsed by this runtime.
- `program_id_base58` is the canonical `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA` string.
- `program_id` decodes that base58 string at comptime through `runtime/zig/bs58.zig`.
- `Error` covers `OutputTooShort`, `TruncatedInput`, and `InvalidOptionTag`.
- `TokenAccountView` exposes mint, owner, amount, delegate, state, native flag, delegated amount, and close authority.
- `writeProgramId(out)` writes the canonical Tokenkeg id to a caller-owned `Pubkey`.
- `writeProgramIdFromBytes(out, bytes)` accepts either raw 32-byte ids or the canonical base58 text.
- `encodeTransfer(amount)` returns fixed-size Transfer instruction data.
- `encodeTransferInto(out, amount)` writes Transfer data into a caller-owned buffer.
- `transferAccountMetas(source, destination, authority)` builds the three standard Transfer metas.
- `zxcaml_transfer_one(arena, input)` parses initial accounts and invokes a one-token Transfer.

Usage example:

```zig
const data = spl_token.encodeTransfer(1_000);
const metas = spl_token.transferAccountMetas(&source, &destination, &authority);
```

Operational notes:

- The helper layer is intentionally narrow: it covers the legacy SPL Token Transfer path used by examples.
- `program_id` is now decoded instead of hand-coded as a byte array.
- Transfer metas mark source and destination writable and authority signer.
- `parseTokenAccount(data)` returns zero-copy pointers into the packed token account buffer.
- Optional pubkey and `u64` fields reject unknown option tags rather than guessing.

## Bs58

Source file: `runtime/zig/bs58.zig`.

- `alphabet` is the Bitcoin/Solana Base58 alphabet without ambiguous characters.
- `pubkey32_encoded_len` is `44`, the maximum encoded length for a 32-byte Solana public key.
- `Error.InvalidCharacter` is returned when decode sees a byte outside the alphabet.
- `encode(allocator, bytes)` encodes arbitrary bytes and allocates an exact-size result.
- `decode(allocator, text)` decodes Base58 text and allocates an exact-size byte result.
- `encodePubkey32(bytes)` encodes one 32-byte public key into a fixed `[44]u8` buffer.
- Leading zero bytes encode as leading `1` characters.
- Leading `1` characters decode back to leading zero bytes.
- General encode/decode use caller-provided allocators so tests and comptime callers can choose storage.
- `encodePubkey32` pads unused trailing bytes with NUL so callers can slice to the actual text length.
- The fixture tests cover zero pubkey, all-`0xff` pubkey, Tokenkeg, and Associated Token Account ids.
- The invalid-character test rejects `0`, `O`, `I`, and `l`, which are not in the Solana alphabet.

Usage example:

```zig
const decoded = try bs58.decode(allocator, spl_token.program_id_base58);
const encoded = bs58.encodePubkey32(&pubkey);
```

Operational notes:

- Use `decode` when accepting arbitrary Base58 text from a canonical constant or a test fixture.
- Use `encodePubkey32` when a no-allocation fixed pubkey representation is sufficient.
- Callers own and must free allocations returned by general `encode` and `decode`.
- The module has no external package dependency.
- Comptime decoding should use a fixed-buffer allocator and validate the decoded length.

## Programs

Source files: `runtime/zig/programs/common.zig`, `runtime/zig/programs/transfer_sol.zig`, `runtime/zig/programs/vault.zig`, `runtime/zig/programs/vault_v2.zig`, `runtime/zig/programs/hackathon_greet.zig`, `runtime/zig/programs/token_vault.zig`, and `runtime/zig/programs/escrow_full.zig`.

- `common.isZeroPubkeyBytes(bytes)` recognizes a 32-byte all-zero public key.
- `common.isSystemProgramKey(key)` recognizes the all-zero System Program id used by fixtures.
- `common.isTokenProgramKey(key)` recognizes the canonical Tokenkeg byte id.
- `common.writeU64Le(out, value)` writes an unsigned 64-bit integer in little-endian order.
- `common.readU64LeSlice(bytes)` reads a little-endian `u64` from an 8-byte slice.
- `common.programIdFromInput(input)` locates the invoked program id at the end of Solana input.
- `common.writeSystemTransferData(out, amount)` writes System Program Transfer instruction data.
- `common.pubkeyEq(lhs, rhs)` compares public keys by bytes.
- `common.readU64Raw(input, cursor)` reads little-endian `u64` values while advancing a raw cursor.
- `common.parseAccountInfoUnchecked(input, cursor, out)` fills a CPI account-info descriptor from raw input.
- `zxcaml_transfer_sol_process(arena, input, instruction_data)` handles the transfer-sol amount payload.
- `zxcaml_vault_process(arena, input, views, instruction_data)` handles the original vault deposit/withdraw dispatch.
- `zxcaml_vault_v2_process(arena, input, views, instruction_data)` handles the zignocchio-compatible vault flow.
- `zxcaml_hackathon_greet_process(arena, input, views, instruction_data)` handles init/greet for the demo PDA counter.
- `zxcaml_token_vault_process(arena, input, views, instruction_data)` handles token-vault initialize/deposit/withdraw.

Usage example:

```zig
const views = try account.parseAccountsFromPtr(&arena, input);
return programs.hackathon_greet.zxcaml_hackathon_greet_process(&arena, input, views, ix_data);
```

Operational notes:

- Program entry helpers return `0` for success and `1` for rejected inputs or failed checks.
- The RT split keeps example-specific logic out of `runtime/zig/cpi.zig`.
- `runtime/zig/programs/escrow_full.zig` also exports `zxcaml_escrow_full_process` for make/accept/refund.
- Several fixtures use canonical bump `255`; helpers verify the exact PDA expected by their tests.
- Keep new example entrypoints in this directory so the CPI primitive layer remains reusable.
- Prefer shared helpers in `common.zig` before duplicating raw account or integer parsing in a program file.

## Test Coverage

Runtime program coverage now uses two layers. The first layer is inline Zig
white-box testing in `runtime/zig/programs/*.zig`; those tests inspect private
helpers, branch guards, PDA seeds, and byte-layout rules directly. The second
layer is the Mollusk integration suite under `tests/`, which runs compiled BPF
programs through Solana-shaped account fixtures and keeps the public happy paths
anchored to loader behavior.

Current inline white-box counts are extracted from the shipped Zig sources with
`rg -nP '^test "' runtime/zig/programs/<name>.zig | wc -l`:

| Program file | Inline tests | White-box focus |
|---|---:|---|
| `ata.zig` | 4 | ATA program ids, metas, and malformed account shapes |
| `ata_transfer.zig` | 5 | Init/transfer state mutations plus bad instruction shapes |
| `common.zig` | 7 | Little-endian helpers, pubkey predicates, and raw input parsing |
| `dao_voting.zig` | 7 | Proposal lifecycle, vote guards, close path, and PDA checks |
| `escrow_full.zig` | 7 | Accept/refund state changes plus make-path early rejects |
| `hackathon_greet.zig` | 14 | Init/greet happy paths, PDA derivation, and negative fixtures |
| `order_book.zig` | 9 | Post/fill flows, arithmetic guards, mint checks, and side validation |
| `spl_burn.zig` | 4 | Burn mutation and malformed SPL account/data cases |
| `spl_close_account.zig` | 4 | Close-account mutation, authority checks, and lamport overflow |
| `spl_revoke.zig` | 4 | Revoke mutation, owner checks, and malformed input |
| `token_vault.zig` | 7 | Initialize/deposit/withdraw state transitions and guard rails |
| `transfer_sol.zig` | 7 | Amount decoding and early rejects before System Program CPI |
| `vault.zig` | 10 | Deposit/withdraw dispatch guards before CPI |
| `vault_v2.zig` | 10 | Vault-v2 PDA/account guards before CPI |

CPI-touching success paths are intentionally not asserted at this white-box
layer. `transfer_sol.zig`, `vault.zig`, `vault_v2.zig`, and the
`escrow_full.zig` make arm return through Solana `invoke` or
`sol_invoke_signed_c`; hosted Zig unit tests cover only negative branches that
return before CPI. Their happy paths remain covered by Mollusk tests, where the
loader, account ownership, signer flags, lamports, and CPI effects are modeled
as integration behavior rather than mocked runtime internals.

Inline tests follow a per-file private-mock convention. Each program keeps its
small fixture builders next to the code being tested, so the branch expectations
stay local and reviewable. There is deliberately no shared
`test_support.zig`; reusable production parsing or integer helpers belong in
`common.zig`, while test-only account buffers and mock PDA inputs stay private
to the program file that needs them.
