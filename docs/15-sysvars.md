# 15 — Solana sysvar readers

> **Languages / 语言**: **English** · [简体中文](./zh/15-sysvars.md)
>
> **Scope:** Solana sysvar account readers exposed through the ZxCaml runtime
> and stdlib: Clock, Rent, Instructions, StakeHistory, and EpochSchedule.
>
> **See also:** [`docs/runtime-api.md`](./runtime-api.md),
> [`docs/11-solana-p3.md`](./11-solana-p3.md),
> [`examples/clock_rent_demo.ml`](../examples/clock_rent_demo.ml), and
> [`examples/instruction_introspect_demo.ml`](../examples/instruction_introspect_demo.ml).

## 1. Position

Sysvars are runtime data accounts, not new OCaml syntax.
ZxCaml source remains ordinary `.ml`.
The frontend type-checks calls such as `Sysvar.clock_from_account account.data`.
The Zig backend recognizes bundled externals under the `sysvar.*` namespace.
Generated BPF code calls `runtime/zig/sysvar.zig` readers over account bytes.
The public API reads account data instead of directly fetching sysvars.
That shape makes the readers easy to test with Mollusk sysvar accounts.
It also keeps serialized layouts explicit in one runtime module.
Malformed or short data returns zero or empty sentinel values.
Programs should still reject sentinels when real sysvar state is required.
Clock and Rent are covered by `examples/clock_rent_demo.ml`.
Instructions is covered by `examples/instruction_introspect_demo.ml`.
StakeHistory and EpochSchedule share the same account-data reader pattern.
The implementation commits are `12cb702`, `944d42c`, `111a7ad`, `7b3e25d`, and `e02837e`.

## 2. ABI summary

All five public readers consume `account_data`.
`account_data` is an alias for `bytes`.
The runtime receives the value as `[]const u8`.
Fields are read field-by-field in little-endian order.
The runtime does not cast arbitrary bytes into packed structs.
Clock occupies 40 serialized bytes.
Rent occupies 17 serialized bytes in the reader.
Instructions starts with a little-endian `u16` instruction count.
Instructions then stores one little-endian `u16` offset per instruction.
Each decoded instruction contains account metas, program id, and data.
StakeHistory starts with a little-endian `u64` entry count.
Each StakeHistory row contains epoch plus three stake amounts.
EpochSchedule stores five packed fields.
Its `warmup` field is encoded as one byte.
Short Clock, Rent, and EpochSchedule payloads return zero-value records.
Malformed Instructions payloads return empty header or instruction records.
Malformed StakeHistory rows stop cursor iteration.

| Sysvar | Runtime entry point | OCaml binding | Output |
|---|---|---|---|
| Clock | `readClock([]const u8)` | `Sysvar.clock_from_account` | `clock_record` |
| Rent | `readRent([]const u8)` | `Sysvar.rent_from_account` | `rent_record` |
| Instructions header | `readInstructionsHeader([]const u8)` | `Sysvar.instructions_header_from_account` | `instructions_header` |
| Instruction at index | `readInstructionAt([]const u8, usize)` | `Sysvar.instruction_at` | `instruction_info` |
| StakeHistory latest rows | `readStakeHistory(cursor)` | `Sysvar.stake_history_latest_from_account` | `stake_history_record array` |
| EpochSchedule | `readEpochSchedule([]const u8)` | `Sysvar.epoch_schedule_from_account` | `epoch_schedule_record` |

## 3. Stdlib binding signatures

The bundled stdlib lives in [`stdlib/core.ml`](../stdlib/core.ml).
The sysvar API is in `module Sysvar`.
The public aliases keep user code readable.
The compiler maps those record values to generated Zig structs.

```ocaml
module Sysvar : sig
  val clock_from_account : account_data -> clock_record
  val rent_from_account : account_data -> rent_record
  val instructions_header_from_account : account_data -> instructions_header
  val instruction_at : account_data -> int -> instruction_info
  val stake_history_latest_from_account : account_data -> int -> stake_history_record array
  val epoch_schedule_from_account : account_data -> epoch_schedule_record
end
```

`clock_record` is the `clock` record type.
`rent_record` is the `rent` record type.
`instruction_info` is the public `instruction` record shape.
`stake_history_record` carries epoch, effective, activating, and deactivating.
`epoch_schedule_record` carries schedule geometry and `warmup`.
Prefer these `Sysvar.*` names over hand-parsing bytes in new code.

## 4. Clock

Clock is the main source of slot and timestamp context.
Use it for lockups.
Use it for expirations.
Use it for vesting windows.
Use it for epoch-gated behavior.
The layout is `slot`, `epoch_start_timestamp`, `epoch`, `leader_schedule_epoch`, `unix_timestamp`.
The integer fields are little-endian 64-bit values.
The timestamp fields are signed in the runtime.
Generated code converts them into OCaml `int` values.
Short account data returns a zero clock.
`slot = 0` is therefore a sentinel unless the fixture intentionally models genesis.
Programs should reject impossible clocks when they need real cluster data.

```ocaml
let clock = Sysvar.clock_from_account clock_account.data in
let slot = clock.slot in
let now = clock.unix_timestamp in
if now < unlock_timestamp then 1 else 0
```

Runtime ABI shape:

```zig
pub const Clock = extern struct {
    slot: u64,
    epoch_start_timestamp: i64,
    epoch: u64,
    leader_schedule_epoch: u64,
    unix_timestamp: i64,
};
pub fn readClock(account_data: []const u8) Clock
```

The Clock demo reads from `clock_account.data`.
It writes the slot and unix timestamp to the output payload.
See [`examples/clock_rent_demo.ml`](../examples/clock_rent_demo.ml).
The paired Mollusk test is [`tests/clock_rent_demo_test.rs`](../tests/clock_rent_demo_test.rs).

## 5. Rent

Rent describes cluster rent parameters.
Use it for minimum-balance checks.
Use it for rent-exemption calculations.
The layout is `lamports_per_byte_year`, `exemption_threshold`, and `burn_percent`.
`lamports_per_byte_year` is an unsigned 64-bit integer.
`exemption_threshold` is read as `f64` in Zig.
The current OCaml record exposes the threshold as an integer witness.
`burn_percent` is a single byte.
Short account data returns a zero rent record.
A zero rent record is a sentinel, not a production policy.

```ocaml
let rent = Sysvar.rent_from_account rent_account.data in
let per_year = rent.lamports_per_byte_year in
if per_year <= 0 then 1 else 0
```

Runtime ABI shape:

```zig
pub const Rent = struct {
    lamports_per_byte_year: u64,
    exemption_threshold: f64,
    burn_percent: u8,
};
pub fn readRent(account_data: []const u8) Rent
```

The Clock + Rent demo writes `lamports_per_byte_year`.
That keeps the fixture focused on byte decoding.
See [`examples/clock_rent_demo.ml`](../examples/clock_rent_demo.ml).
Use the same sysvar bytes to derive expected rent values in tests.

## 6. Instructions

The Instructions sysvar exposes the current transaction instruction list.
Use it for instruction introspection.
Use it when a sibling instruction must be checked.
Common cases include prior verification instructions.
Common cases also include checking the next program id.
The reader has two public steps.
`instructions_header_from_account` reads the count and offset table.
`instruction_at data idx` decodes one instruction by absolute transaction index.
Malformed input returns an empty instruction record.
Out-of-bounds indexes return an empty instruction record.
The decoded program id is a 32-byte `bytes` value.
The decoded account metas expose pubkey, writable, and signer flags.
The decoded data field is the sibling instruction data slice.

```ocaml
let header = Sysvar.instructions_header_from_account instructions_account.data in
if header.instruction_count <= next_index then 1 else
let next = Sysvar.instruction_at instructions_account.data next_index in
if String.length next.program_id = 32 then 0 else 2
```

Runtime ABI shape:

```zig
pub fn readInstructionsHeader(account_data: []const u8) InstructionsHeader
pub fn readInstructionAt(account_data: []const u8, idx: usize) InstructionInfo
```

The runtime caps decoded account metas at `max_instruction_accounts = 256`.
This prevents malformed payloads from growing unbounded state.
Programs should still check exact program ids and required account metas.
The public demo walks raw bytes to make the serialized layout visible.
See [`examples/instruction_introspect_demo.ml`](../examples/instruction_introspect_demo.ml).
The paired Mollusk test is [`tests/instruction_introspect_demo_test.rs`](../tests/instruction_introspect_demo_test.rs).

## 7. StakeHistory

StakeHistory contains historical stake activation data by epoch.
Each row has an epoch.
Each row has an `effective` amount.
Each row has an `activating` amount.
Each row has a `deactivating` amount.
The account format begins with a declared row count.
Rows follow as fixed 32-byte records.
The public stdlib call returns the latest `N` rows as an array.
The underlying Zig implementation uses a newest-first cursor.
The cursor starts at the newest available row and walks backwards.
Malformed rows stop iteration instead of trapping.
Asking for more rows than exist returns only available rows.

```ocaml
let latest =
  Sysvar.stake_history_latest_from_account stake_history_account.data 2
in
let first_epoch = if Array.length latest = 0 then 0 else latest.(0).epoch in
first_epoch
```

Runtime ABI shape:

```zig
pub fn stakeHistoryCursor(account_data: []const u8, latest_count: usize) StakeHistoryCursor
pub fn readStakeHistory(account_data: []const u8, cursor: *StakeHistoryCursor) ?StakeHistoryRecord
```

Use StakeHistory when stake warmup or cooldown affects authorization.
Keep the requested count small.
If the program only needs the newest epoch, request `1`.
If no rows are returned, branch explicitly.
There is no dedicated public demo yet.
The binding shares the sysvar-reader backend with Clock, Rent, and Instructions.

## 8. EpochSchedule

EpochSchedule describes how slots map to epochs.
Use it when a program needs epoch boundaries.
The layout has five fields.
`slots_per_epoch` sets the steady-state epoch size.
`leader_schedule_slot_offset` controls leader schedule timing.
`warmup` is encoded as one byte.
`first_normal_epoch` marks the transition out of warmup.
`first_normal_slot` marks the corresponding slot.
Short account data returns a zero schedule.
A zero schedule is only a malformed-data sentinel.
Reject zero `slots_per_epoch` before doing schedule math.

```ocaml
let schedule =
  Sysvar.epoch_schedule_from_account epoch_schedule_account.data
in
if schedule.slots_per_epoch = 0 then 1
else if schedule.warmup then 2
else 0
```

Runtime ABI shape:

```zig
pub const EpochSchedule = struct {
    slots_per_epoch: u64,
    leader_schedule_slot_offset: u64,
    warmup: bool,
    first_normal_epoch: u64,
    first_normal_slot: u64,
};
pub fn readEpochSchedule(account_data: []const u8) EpochSchedule
```

Use EpochSchedule together with Clock for epoch-relative rules.
Clock gives the current slot and epoch.
EpochSchedule explains the schedule geometry.
Do not hard-code mainnet schedule constants in portable examples.

## 9. Example: Clock + Rent payload writer

The Clock + Rent demo accepts three accounts.
The first account is writable output.
The second account is the Clock sysvar account.
The third account is the Rent sysvar account.
It logs a short message for traceability.
It reads `clock_account.data` with `Sysvar.clock_from_account`.
It reads `rent_account.data` with `Sysvar.rent_from_account`.
It writes `slot`, `unix_timestamp`, and `lamports_per_byte_year`.
This is a compact pattern for programs needing time and rent policy together.

```ocaml
let clock = Sysvar.clock_from_account clock_account.data in
let rent = Sysvar.rent_from_account rent_account.data in
let payload =
  write_u64_le clock.slot
  ^ write_u64_le clock.unix_timestamp
  ^ write_u64_le rent.lamports_per_byte_year
in
set_account_data output_account payload
```

See [`examples/clock_rent_demo.ml`](../examples/clock_rent_demo.ml).
The test fixture supplies mock Clock and Rent accounts.

## 10. Example: Instructions introspection

The Instructions demo accepts a writable output account.
It also accepts an Instructions sysvar account.
It treats the current instruction index as zero for the fixture.
It checks that a next instruction exists.
It reads the next instruction offset from the sysvar account.
It computes the next program-id offset after account metas.
It compares that 32-byte program id with instruction data.
It writes a small proof payload when the match succeeds.
The same control-flow idea applies to verification preconditions.
The demo uses raw byte reads to make serialized layout visible.
New application code can use `Sysvar.instruction_at` for the decoded shape.

```ocaml
let next =
  Sysvar.instruction_at instructions_account.data (current_index + 1)
in
if String.length next.program_id <> 32 then 1
else if next.program_id = expected_program_id then 0
else 2
```

See [`examples/instruction_introspect_demo.ml`](../examples/instruction_introspect_demo.ml).
The paired test constructs a two-instruction transaction fixture.

## 11. Choosing the right sysvar

Use Clock when the rule depends on slot.
Use Clock when the rule depends on epoch.
Use Clock when the rule depends on unix timestamp.
Use Rent when the rule depends on rent-exemption policy.
Use Rent when the rule depends on byte-year cost.
Use Instructions when the rule depends on sibling transaction instructions.
Use StakeHistory when recent stake activation data is part of the rule.
Use EpochSchedule when slot-to-epoch geometry matters.
Do not use sysvars as randomness.
Do not treat zero-value records as proof of valid cluster state.
Prefer `Sysvar.*` bindings for clarity and future backend compatibility.
Keep sysvar account positions explicit in examples and tests.

## 12. Security notes

Sysvar readers make data accessible.
They do not authenticate the account for you.
Tests should pass canonical sysvar accounts where possible.
Programs accepting arbitrary accounts should validate account keys externally.
Never let a user-controlled account masquerade as a sysvar in authorization logic.
Check decoded lengths before indexing arrays.
Check decoded lengths before indexing byte strings.
Check `instruction_count` before reading an instruction by index.
Check `program_id` length before comparing program ids.
Keep `latest_count` for StakeHistory small and bounded.
Reject zero `slots_per_epoch` before EpochSchedule division.
Reject impossible Clock or Rent values when real cluster data is required.
Document fixture values next to Mollusk setup code.
Prefer branch-returned program errors over implicit sentinel acceptance.

## 13. Verification checklist

Identify which account carries the sysvar.
Decide whether the program needs a decoded reader or raw layout witness.
Run `omlz check` before building BPF.
Build the example with `omlz build --target=bpf`.
Run the matching Mollusk test when account bytes are involved.
For Clock, assert both slot and timestamp when possible.
For Rent, assert the lamports-per-byte-year field used by the program.
For Instructions, assert the target instruction index exists.
For StakeHistory, assert the number of returned rows.
For EpochSchedule, assert warmup and first-normal fields when branching.
Record commit hashes for public documentation claims.

## 14. Troubleshooting

A zero Clock usually means the fixture passed short or empty data.
A zero Rent usually means the rent account was missing or malformed.
An empty Instructions header usually means the count or offset table is malformed.
An empty instruction usually means an out-of-bounds index.
An empty instruction can also mean a malformed instruction body.
An empty StakeHistory result usually means no rows were available.
An empty StakeHistory result can also mean the declared count was zero.
A zero EpochSchedule usually means the account was too short.
If an Instructions program-id comparison fails, verify account-meta count first.
If a demo writes too few bytes, verify output account size and writability.
If hosted output differs from Mollusk, prefer Mollusk for SVM account layout behavior.

## 15. File map

`runtime/zig/sysvar.zig` owns serialized sysvar layouts and readers.
`stdlib/core.ml` owns `Sysvar` binding signatures and record aliases.
`src/backend/zig_codegen/runtime_imports.zig` maps `sysvar.*` externals.
`examples/clock_rent_demo.ml` demonstrates Clock and Rent.
`examples/instruction_introspect_demo.ml` demonstrates Instructions.
`tests/clock_rent_demo_test.rs` validates Clock and Rent fixtures.
`tests/instruction_introspect_demo_test.rs` validates a two-instruction fixture.
`CHANGELOG.md` records the five sysvar milestone commits.
`mission-internal/canonical-facts.md` records current post-M-SYSVAR values.
