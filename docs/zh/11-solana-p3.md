# 11 — Solana P3 指南

> **Languages / 语言**: [English](../11-solana-p3.md) · **简体中文**

## TL;DR

P3 让 ZxCaml 具备 Solana 运行时意识。程序可以接收带类型的 account 视图，
调用一组 Solana syscall，构造 cross-program invocation（CPI），编码
SPL-Token transfer，请 `omlz` 证明某个源文件不分配，并通过 `omlz idl`
发出一个小型 JSON IDL。

实现仍保持轻量：

- account 数据在 Zig runtime 中被解析为 BPF 输入 buffer 上的零拷贝视图；
- syscall 和 CPI 直接使用 Solana BPF ABI；
- arena 模型仍对 OCaml 用户隐藏，但 BPF entry arena 已从旧的 P1/P2 1 KiB
  buffer 增加到 **32 KiB**；
- `no_alloc` 是保守的 Core IR 分析，不是新的类型系统模式；
- IDL 输出是 ZxCaml JSON，尚不兼容 Anchor。

## 1. Account 处理

P3 runtime 在用户代码运行前，把 Solana BPF loader 输入解析为 account 视图。
解析器理解真实 BPF invocation 使用的 loader 序列化形态：

```text
u64 num_accounts
for each account:
  u8  dup_info
  u8  is_signer
  u8  is_writable
  u8  executable
  u32 padding
  u64 original_data_len
  [32]u8 key
  u64 lamports
  u64 data_len
  u8[data_len] data, 8-byte aligned
  [32]u8 owner
  u64 rent_epoch
```

用户可见的内置 record 是：

```ocaml
type account = {
  key : bytes;
  lamports : int;
  data : bytes;
  owner : bytes;
  is_signer : bool;
  is_writable : bool;
  executable : bool;
}
```

runtime 把 `key`、`data` 和 `owner` 保存为指向序列化输入 buffer 的视图，
而不是复制这些字节。这样能让 BPF 上的 account 访问保持可预测，并符合仅
arena 的内存模型。

### 示例

`examples/log_accounts.ml` 是 account/syscall smoke 程序。当前 backend 会把
这个示例 lower 到 BPF account 解析器，并记录 harness 提供的真实 account key
和 lamports。

本地运行完整 account logging harness：

```sh
SOLANA_BPF=1 \
ZXCAML_SOLANA_SRC=examples/log_accounts.ml \
ZXCAML_SOLANA_INVOKE_ACCOUNTS=1 \
ZXCAML_EXPECT_ACCOUNT_LOGS=1 \
tests/solana/hello/invoke.sh
```

## 2. Syscall

Solana BPF syscall 通过 32 位 MurmurHash3 dispatch 地址（seed `0`）解析。
P3 绑定了 account、CPI、SPL-Token 和诊断示例所需的 syscall。

| OCaml 侧 helper | Runtime syscall | Hash |
|---|---|---:|
| `Syscall.sol_log` | `sol_log_` | `0x20755f21` |
| `Syscall.sol_log_64` | `sol_log_64_` | `0x5c2a3178` |
| `Syscall.sol_log_pubkey` | `sol_log_pubkey` | `0x7ef08fcb` |
| `Syscall.sol_sha256` | `sol_sha256` | `0x11f49d42` |
| `Syscall.sol_keccak256` | `sol_keccak256` | `0xd763ada3` |
| `Syscall.sol_get_clock_sysvar` | `sol_get_clock_sysvar` | `0x85532d94` |
| `Syscall.sol_get_rent_sysvar` | `sol_get_rent_sysvar` | `0x9aca9a41` |
| `Syscall.sol_remaining_compute_units` | `sol_remaining_compute_units` | `0x4e3bc231` |

`examples/syscall_test.ml` 覆盖 hash、Clock sysvar 读取、remaining
compute-unit 读取、字符串日志，以及 `sol_log_64`。

## 3. CPI 模式

P3 新增了 CPI 形态的内置 record：

```ocaml
type account_meta = {
  pubkey : bytes;
  is_writable : bool;
  is_signer : bool;
}

type instruction = {
  program_id : bytes;
  accounts : account_meta array;
  data : bytes;
}
```

runtime 侧镜像 Solana 的 C ABI：

- `SolInstruction` 指向 program id、account metas 和 instruction data；
- `SolAccountMeta` 记录 public key 以及 signer/writable 标志；
- `SolSignerSeeds` / `SolSignerSeedsC` 描述 PDA signer seeds；
- `sol_invoke_signed_c` 执行调用；
- PDA helper 绑定 `sol_create_program_address` 和
  `sol_try_find_program_address`；
- return data helper 绑定 `sol_set_return_data` 和 `sol_get_return_data`。

`invoke` 用于普通 CPI。`invoke_signed` 会额外传入 PDA 签名用的 signer seeds。
只有 callee 必须写入时才把 account meta 标为 writable，并且只把 authority
account 标为 signer。

`examples/simple_cpi.ml` 演示 system-program transfer 形态。本地 harness 路径：

```sh
SOLANA_BPF=1 \
ZXCAML_SOLANA_SRC=examples/simple_cpi.ml \
ZXCAML_SOLANA_SIMPLE_CPI=1 \
tests/solana/hello/invoke.sh
```

## 4. SPL-Token transfer

P3 为 legacy Tokenkeg program 包含了一层小型 SPL-Token helper：

```text
TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA
```

transfer payload 编码为 discriminator `3` 加 little-endian `u64` 金额：

```text
03 amount_le_u64
```

期望的 account metas 是：

| Account | Writable | Signer |
|---|---:|---:|
| source token account | yes | no |
| destination token account | yes | no |
| authority | no | yes |

`examples/spl_token_transfer.ml` 是 P3 SPL-Token acceptance 示例。harness 会创建
Tokenkeg accounts、mint tokens、调用编译出的 ZxCaml 程序，并检查 transfer 后的
余额：

```sh
SOLANA_BPF=1 \
ZXCAML_SOLANA_SRC=examples/spl_token_transfer.ml \
ZXCAML_SOLANA_SPL_TOKEN=1 \
tests/solana/hello/invoke.sh
```

## 5. `no_alloc`

`omlz check --no-alloc <file.ml>` 会运行一道保守的 Core IR pass，拒绝 lowered
Core graph 中包含 arena 分配点的程序。当前分析会对 tuple construction、record
construction、带 payload 的 constructor，以及 lambda capture 等会分配的 Core
node 报告失败。

示例：

```sh
zig build
zig-out/bin/omlz check --no-alloc examples/arith_wrap.ml
```

期望输出：

```text
no_alloc: PASS
```

失败时，CLI 会打印函数名和导致证明失败的 Core IR node kind。这道 pass 有意保持
保守："无法证明不分配"会被报告为失败，而不是静默接受程序。

## 6. IDL 发出

`omlz idl <file.ml>` 会发出一个 JSON 文档，描述发现的程序形态：

- `schema_version`；
- program name 和可选 program id；
- 带 name、discriminator、accounts、arguments 的 instructions；
- 用户定义的 record 和 variant 类型；
- 结构化错误常量。

示例：

```sh
zig build
zig-out/bin/omlz idl tests/idl/entrypoint.ml | python3 -m json.tool
```

该 schema 有意保持小而且 ZxCaml 专用。它适合 smoke test 和 client-code 实验，
但**尚不**兼容 Anchor。

## 7. CI 覆盖

CI 继续在 macOS 和 Ubuntu 上运行跨平台 matrix：

```sh
./init.sh
zig build
zig build test
```

P3 新增显式 smoke check：

- `omlz check --no-alloc examples/arith_wrap.ml`；
- `omlz idl tests/idl/entrypoint.ml`，并通过 `python3 -m json.tool` 验证 JSON；
- 完整 examples `omlz check` corpus，包括 P3 示例。

BPF deploy/invoke acceptance 仍可通过上面的本地 harness 运行，并可在 CI 中通过
`SOLANA_BPF=1` opt-in。
