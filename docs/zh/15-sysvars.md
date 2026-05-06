# 15 — Solana sysvar 读取器

> **Languages / 语言**: [English](../15-sysvars.md) · **简体中文**
>
> **范围：** ZxCaml runtime 与 stdlib 暴露的 Solana sysvar account 读取器：
> Clock、Rent、Instructions、StakeHistory、EpochSchedule。
>
> **相关文档：** [`docs/runtime-api.md`](../runtime-api.md)、
> [`docs/11-solana-p3.md`](../11-solana-p3.md)、
> [`examples/clock_rent_demo.ml`](../../examples/clock_rent_demo.ml)、
> [`examples/instruction_introspect_demo.ml`](../../examples/instruction_introspect_demo.ml)。

## 1. 定位

Sysvar 是 runtime 数据 account，不是新的 OCaml 语法。
ZxCaml 源码仍然是普通 `.ml`。
frontend 会类型检查 `Sysvar.clock_from_account account.data` 这样的调用。
Zig backend 会识别 `sysvar.*` 命名空间下的 bundled external。
生成的 BPF 代码会在 account bytes 上调用 `runtime/zig/sysvar.zig` 读取器。
公开 API 读取 account data，而不是直接 fetch sysvar。
这种形态方便用 Mollusk sysvar account 测试。
它也把 serialized layout 明确集中在一个 runtime 模块里。
畸形或过短数据会返回零值或空值 sentinel。
当程序需要真实 sysvar state 时，仍应拒绝这些 sentinel。
Clock 与 Rent 由 `examples/clock_rent_demo.ml` 覆盖。
Instructions 由 `examples/instruction_introspect_demo.ml` 覆盖。
StakeHistory 与 EpochSchedule 共用同一 account-data reader 模式。
本 milestone 的实现 commit 是 `12cb702`、`944d42c`、`111a7ad`、`7b3e25d` 和 `e02837e`。

## 2. ABI 总览

五个公开读取器都消费 `account_data`。
`account_data` 是 `bytes` 的别名。
runtime 接收的是 `[]const u8`。
字段按 little-endian 顺序逐个读取。
runtime 不会把任意 bytes cast 成 packed struct。
Clock 占 40 个 serialized bytes。
Rent 在 reader 中占 17 个 serialized bytes。
Instructions 以 little-endian `u16` instruction count 开头。
后面每条 instruction 对应一个 little-endian `u16` offset。
解码后的 instruction 包含 account metas、program id 和 data。
StakeHistory 以 little-endian `u64` entry count 开头。
每条 StakeHistory row 包含 epoch 和三种 stake amount。
EpochSchedule 保存五个 packed 字段。
它的 `warmup` 字段编码为一个 byte。
过短 Clock、Rent、EpochSchedule payload 返回零值 record。
畸形 Instructions payload 返回空 header 或空 instruction record。
畸形 StakeHistory row 会停止 cursor 迭代。

| Sysvar | Runtime entry point | OCaml binding | 输出 |
|---|---|---|---|
| Clock | `readClock([]const u8)` | `Sysvar.clock_from_account` | `clock_record` |
| Rent | `readRent([]const u8)` | `Sysvar.rent_from_account` | `rent_record` |
| Instructions header | `readInstructionsHeader([]const u8)` | `Sysvar.instructions_header_from_account` | `instructions_header` |
| Instruction at index | `readInstructionAt([]const u8, usize)` | `Sysvar.instruction_at` | `instruction_info` |
| StakeHistory latest rows | `readStakeHistory(cursor)` | `Sysvar.stake_history_latest_from_account` | `stake_history_record array` |
| EpochSchedule | `readEpochSchedule([]const u8)` | `Sysvar.epoch_schedule_from_account` | `epoch_schedule_record` |

## 3. Stdlib 绑定签名

bundled stdlib 位于 [`stdlib/core.ml`](../../stdlib/core.ml)。
sysvar API 在 `module Sysvar` 中。
公开 alias 让用户代码更可读。
compiler 会把这些 record values 映射到生成的 Zig struct。

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

`clock_record` 是 `clock` record type。
`rent_record` 是 `rent` record type。
`instruction_info` 与公开的 `instruction` record 同形。
`stake_history_record` 包含 epoch、effective、activating、deactivating。
`epoch_schedule_record` 包含 schedule geometry 和 `warmup`。
新代码优先使用这些 `Sysvar.*` 名称，不要手写 byte parser。

## 4. Clock

Clock 是 slot 和 timestamp 上下文的主要来源。
它适合 lockup。
它适合过期时间。
它适合 vesting window。
它适合 epoch-gated 行为。
layout 是 `slot`、`epoch_start_timestamp`、`epoch`、`leader_schedule_epoch`、`unix_timestamp`。
整数字段都是 little-endian 64-bit 值。
timestamp 字段在 runtime 中是 signed。
生成代码会把它们转换为 OCaml `int`。
过短 account data 返回零值 clock。
因此 `slot = 0` 通常是 sentinel，除非 fixture 刻意模拟 genesis。
程序需要真实 cluster data 时，应拒绝明显不可能的 Clock。

```ocaml
let clock = Sysvar.clock_from_account clock_account.data in
let slot = clock.slot in
let now = clock.unix_timestamp in
if now < unlock_timestamp then 1 else 0
```

Runtime ABI 形态：

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

Clock demo 从 `clock_account.data` 读取。
它把 slot 和 unix timestamp 写入 output payload。
参见 [`examples/clock_rent_demo.ml`](../../examples/clock_rent_demo.ml)。
配套 Mollusk test 是 [`tests/clock_rent_demo_test.rs`](../../tests/clock_rent_demo_test.rs)。

## 5. Rent

Rent 描述 cluster rent 参数。
它适合 minimum-balance 检查。
它适合 rent-exemption 计算。
layout 是 `lamports_per_byte_year`、`exemption_threshold`、`burn_percent`。
`lamports_per_byte_year` 是 unsigned 64-bit integer。
`exemption_threshold` 在 Zig 中按 `f64` 读取。
当前 OCaml record 把 threshold 暴露为 integer witness。
`burn_percent` 是单个 byte。
过短 account data 返回零值 rent record。
零值 rent record 是 sentinel，不是 production policy。

```ocaml
let rent = Sysvar.rent_from_account rent_account.data in
let per_year = rent.lamports_per_byte_year in
if per_year <= 0 then 1 else 0
```

Runtime ABI 形态：

```zig
pub const Rent = struct {
    lamports_per_byte_year: u64,
    exemption_threshold: f64,
    burn_percent: u8,
};
pub fn readRent(account_data: []const u8) Rent
```

Clock + Rent demo 会写出 `lamports_per_byte_year`。
这样 fixture 可以专注验证 byte decoding。
参见 [`examples/clock_rent_demo.ml`](../../examples/clock_rent_demo.ml)。
测试中应从同一份 sysvar bytes 推导 expected rent values。

## 6. Instructions

Instructions sysvar 暴露当前 transaction 的 instruction list。
它是 instruction introspection 的工具。
当程序需要检查 sibling instruction 时使用它。
常见场景包括前置 verification instruction。
常见场景也包括检查下一条 program id。
读取器有两个公开步骤。
`instructions_header_from_account` 读取 count 和 offset table。
`instruction_at data idx` 按 transaction 绝对 index 解码 instruction。
畸形输入返回空 instruction record。
越界 index 也返回空 instruction record。
解码出的 program id 是 32 字节 `bytes`。
解码出的 account metas 暴露 pubkey、writable、signer flags。
解码出的 data 字段是 sibling instruction data slice。

```ocaml
let header = Sysvar.instructions_header_from_account instructions_account.data in
if header.instruction_count <= next_index then 1 else
let next = Sysvar.instruction_at instructions_account.data next_index in
if String.length next.program_id = 32 then 0 else 2
```

Runtime ABI 形态：

```zig
pub fn readInstructionsHeader(account_data: []const u8) InstructionsHeader
pub fn readInstructionAt(account_data: []const u8, idx: usize) InstructionInfo
```

runtime 把 decoded account metas 限制为 `max_instruction_accounts = 256`。
这样畸形 payload 不会产生无界状态。
程序仍应检查精确 program id 和需要的 account metas。
公开 demo 走 raw bytes，让 serialized layout 直接可见。
参见 [`examples/instruction_introspect_demo.ml`](../../examples/instruction_introspect_demo.ml)。
配套 Mollusk test 是 [`tests/instruction_introspect_demo_test.rs`](../../tests/instruction_introspect_demo_test.rs)。

## 7. StakeHistory

StakeHistory 包含按 epoch 记录的 stake activation 历史。
每条 row 有一个 epoch。
每条 row 有 `effective` amount。
每条 row 有 `activating` amount。
每条 row 有 `deactivating` amount。
account 格式以 declared row count 开头。
后续 row 都是固定 32 字节 record。
公开 stdlib 调用返回最新 `N` 条 row 的数组。
底层 Zig 实现使用 newest-first cursor。
cursor 从最新可用 row 开始向后走。
畸形 row 会停止迭代，而不是 trap。
请求超过实际数量时，只返回可用 rows。

```ocaml
let latest =
  Sysvar.stake_history_latest_from_account stake_history_account.data 2
in
let first_epoch = if Array.length latest = 0 then 0 else latest.(0).epoch in
first_epoch
```

Runtime ABI 形态：

```zig
pub fn stakeHistoryCursor(account_data: []const u8, latest_count: usize) StakeHistoryCursor
pub fn readStakeHistory(account_data: []const u8, cursor: *StakeHistoryCursor) ?StakeHistoryRecord
```

当 stake warmup 或 cooldown 影响授权时使用 StakeHistory。
请求数量要保持小。
如果只需要最新 epoch，请请求 `1`。
如果没有 rows 返回，要显式分支。
目前没有单独公开 demo。
这个 binding 与 Clock、Rent、Instructions 共用 sysvar-reader backend。

## 8. EpochSchedule

EpochSchedule 描述 slot 如何映射到 epoch。
当程序需要 epoch boundary 时使用它。
layout 有五个字段。
`slots_per_epoch` 设置稳定状态 epoch 大小。
`leader_schedule_slot_offset` 控制 leader schedule timing。
`warmup` 编码为一个 byte。
`first_normal_epoch` 标记离开 warmup 的 epoch。
`first_normal_slot` 标记对应 slot。
过短 account data 返回零值 schedule。
零值 schedule 只是 malformed-data sentinel。
做 schedule math 前要拒绝零 `slots_per_epoch`。

```ocaml
let schedule =
  Sysvar.epoch_schedule_from_account epoch_schedule_account.data
in
if schedule.slots_per_epoch = 0 then 1
else if schedule.warmup then 2
else 0
```

Runtime ABI 形态：

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

把 EpochSchedule 与 Clock 一起用于 epoch-relative 规则。
Clock 给出当前 slot 和 epoch。
EpochSchedule 解释 schedule geometry。
portable example 不要硬编码 mainnet schedule constants。

## 9. 示例：Clock + Rent payload writer

Clock + Rent demo 接收三个 account。
第一个 account 是 writable output。
第二个 account 是 Clock sysvar account。
第三个 account 是 Rent sysvar account。
它会 log 一条短消息，方便 trace。
它用 `Sysvar.clock_from_account` 读取 `clock_account.data`。
它用 `Sysvar.rent_from_account` 读取 `rent_account.data`。
它写出 `slot`、`unix_timestamp`、`lamports_per_byte_year`。
这是同时需要时间与 rent policy 的紧凑模式。

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

参见 [`examples/clock_rent_demo.ml`](../../examples/clock_rent_demo.ml)。
test fixture 会提供 mock Clock 与 Rent accounts。

## 10. 示例：Instructions introspection

Instructions demo 接收一个 writable output account。
它也接收一个 Instructions sysvar account。
在 fixture 中，它把当前 instruction index 视为零。
它检查是否存在下一条 instruction。
它从 sysvar account 读取下一条 instruction offset。
它在 account metas 之后计算下一条 program-id offset。
它把这 32 字节 program id 与 instruction data 比较。
匹配成功时，它写出一个小型 proof payload。
同样的 control-flow 可用于 verification precondition。
demo 使用 raw byte reads，让 serialized layout 可见。
新应用代码可使用 `Sysvar.instruction_at` 获取 decoded shape。

```ocaml
let next =
  Sysvar.instruction_at instructions_account.data (current_index + 1)
in
if String.length next.program_id <> 32 then 1
else if next.program_id = expected_program_id then 0
else 2
```

参见 [`examples/instruction_introspect_demo.ml`](../../examples/instruction_introspect_demo.ml)。
配套测试构造了一个两条 instruction 的 transaction fixture。

## 11. 如何选择 sysvar

规则依赖 slot 时使用 Clock。
规则依赖 epoch 时使用 Clock。
规则依赖 unix timestamp 时使用 Clock。
规则依赖 rent-exemption policy 时使用 Rent。
规则依赖 byte-year cost 时使用 Rent。
规则依赖 sibling transaction instruction 时使用 Instructions。
规则依赖近期 stake activation 数据时使用 StakeHistory。
规则依赖 slot-to-epoch geometry 时使用 EpochSchedule。
不要把 sysvar 当随机数。
不要把零值 record 当成有效 cluster state 证明。
为了清晰和未来 backend 兼容，优先使用 `Sysvar.*` binding。
示例与测试中要明确 sysvar account 的位置。

## 12. 安全注意事项

Sysvar reader 只是让数据可访问。
它不会替你认证 account。
测试应尽量传 canonical sysvar account。
接收任意 account 的程序，应在外层验证 account key。
不要让 user-controlled account 在授权逻辑中冒充 sysvar。
索引数组前要检查 decoded length。
索引 byte string 前也要检查 decoded length。
按 index 读取 instruction 前要检查 `instruction_count`。
比较 program id 前要检查 `program_id` 长度。
StakeHistory 的 `latest_count` 要小且有界。
进行 EpochSchedule 除法前要拒绝零 `slots_per_epoch`。
需要真实 cluster data 时，要拒绝不可能的 Clock 或 Rent 值。
Mollusk setup 旁边要记录 fixture values。
优先用显式 branch 返回 program error，不要默默接受 sentinel。

## 13. 验证清单

先确认哪个 account 承载 sysvar。
再决定程序需要 decoded reader，还是 raw layout witness。
构建 BPF 前运行 `omlz check`。
用 `omlz build --target=bpf` 构建 example。
涉及 account bytes 时运行对应 Mollusk test。
Clock 尽量同时断言 slot 与 timestamp。
Rent 断言程序使用的 lamports-per-byte-year 字段。
Instructions 断言目标 instruction index 存在。
StakeHistory 断言返回 row 数。
EpochSchedule 分支时断言 warmup 与 first-normal 字段。
公开文档 claim 依赖实现时记录 commit hash。

## 14. 排错

零值 Clock 通常说明 fixture 传入过短或空数据。
零值 Rent 通常说明 rent account 缺失或畸形。
空 Instructions header 通常说明 count 或 offset table 畸形。
空 instruction 通常说明 index 越界。
空 instruction 也可能说明 instruction body 畸形。
空 StakeHistory 结果通常说明没有 rows。
空 StakeHistory 结果也可能说明 declared count 为零。
零值 EpochSchedule 通常说明 account 过短。
如果 Instructions program-id 比较失败，请先验证 account-meta count。
如果 demo 写入字节过少，请验证 output account size 和 writable flag。
如果 hosted output 与 Mollusk 不一致，SVM account layout 行为以 Mollusk 为准。

## 15. 文件地图

`runtime/zig/sysvar.zig` 维护 serialized sysvar layout 与 reader。
`stdlib/core.ml` 维护 `Sysvar` binding signature 和 record alias。
`src/backend/zig_codegen/runtime_imports.zig` 映射 `sysvar.*` external。
`examples/clock_rent_demo.ml` 演示 Clock 与 Rent。
`examples/instruction_introspect_demo.ml` 演示 Instructions。
`tests/clock_rent_demo_test.rs` 验证 Clock 与 Rent fixture。
`tests/instruction_introspect_demo_test.rs` 验证两条 instruction fixture。
`CHANGELOG.md` 记录五个 sysvar milestone commit。
`mission-internal/canonical-facts.md` 记录当前 post-M-SYSVAR 值。
