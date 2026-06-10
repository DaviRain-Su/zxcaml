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
- 当前 Solana runtime 已切到 **SDK-backed** 形态：通过 vendored
  `solana-program-sdk-zig` 子树上的 adapter 和 SDK-style entrypoint 提供能力；
- arena 模型仍对 OCaml 用户隐藏；native build 保留 **32 KiB** entry arena，
  BPF build 使用 **3 KiB** stack-bounded entry arena，以避开 SBF 4 KiB 栈帧上限；
- `no_alloc` 是保守的 Core IR 分析，不是新的类型系统模式；
- 当前 IDL 输出是 Anchor-compatible JSON：最初 P3 的 smoke schema 已在已封存 P5 工作中扩展；
- 本地 deploy/invoke 验证现在统一走 Surfpool harness，默认端口为
  `127.0.0.1:8899` / `127.0.0.1:8900`，而不是手工管理的旧 validator 会话。

## 1. Account 处理

### Entrypoint 期望

每个程序都声明一个名字必须是 `entrypoint` 的函数。接受的形态是若干位置式
`account` 参数后跟 instruction-data 的 `bytes` 参数——例如
`let entrypoint (authority : account) (guarded : account)
(instruction_data : bytes) = ...`——返回值必须是 `int` 状态码（`0` 表示成
功；入口 ABI 把它映射为程序的退出状态）。常见错误在 codegen 之前就会以
`DX2-REGION` 诊断拦截：缺失/改名的 `entrypoint`、非函数绑定、或在该写状态
int 的位置留下一个 `bool` 表达式（`tests/ui/entrypoint_*.ml` 钉住全部三类）。

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

### Account guard helper 模式

entrypoint 在 mutation 前验证 account meta 时，优先使用 `Account` stdlib helper：

```ocaml
let error_missing_signer = 1
let error_missing_writable = 2
let error_wrong_owner = 3

let entrypoint authority guarded_account instruction_data =
  let _ = instruction_data in
  if not (Account.is_signer authority) then error_missing_signer
  else if not (Account.is_writable guarded_account) then error_missing_writable
  else if not (Account.is_owned_by guarded_account (Account.key authority)) then error_wrong_owner
  else 0
```

这样 account 顺序保持显式（先 `authority`，再 `guarded_account`），程序返回稳定
custom code 而不是 panic，并且 `omlz idl` 会从同一组 guard 表达式推导 `signer` /
`writable` metadata。`Account.is_signer 1`、`Account.data_len bytes` 或
`Account.has_key account 1` 这类误用会在 lowering 前由 OCaml frontend 拒绝。

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

### AccountMeta 构造器

不必手写裸 `account_meta` record 字面量（`is_writable` / `is_signer` 两个
旗标极易写反），用直接以旗标组合命名的 `AccountMeta` 构造器：

```ocaml
AccountMeta.writable p          (* { pubkey = p; is_writable = true;  is_signer = false } *)
AccountMeta.signer p            (* { pubkey = p; is_writable = false; is_signer = true  } *)
AccountMeta.writable_signer p   (* { pubkey = p; is_writable = true;  is_signer = true  } *)
AccountMeta.readonly p          (* { pubkey = p; is_writable = false; is_signer = false } *)
AccountMeta.of_account a        (* 转发 a 自身的 key 与 writable/signer 权限 *)
```

`AccountMeta.of_account` 覆盖最常见的流程——把 entrypoint 收到的某个账户
连同其既有权限转发进 CPI。这些构造器降级为普通的 record 构造，因此在所有
路径（解释器、原生、BPF、`--no-alloc` 核算）上的行为与手写字面量完全一致。
`examples/account_meta_helpers.ml` 演练了全部五个构造器。当辅助函数接受
`account_meta` 参数时，请显式注解——`let meta_flags (m : account_meta) = ...`
——注解即可让该 helper 正确定型（wire 1.7 携带注解标记；见
`examples/account_meta_annotated.ml`）。对于*未注解*的参数，`pubkey` 读取
否决仍然有效：读取 `m.pubkey`（`account_meta` 独有的字段）能让参数类型
启发式不再把该参数误归为 entrypoint 的 `account`（见
`examples/account_meta_param.ml`）。

### PDA 派生

`Pda.create_program_address seeds program_id` 从 signer seeds（用
`Array.of_list` 组装的 `Bytes.of_string` 片段）派生程序地址。BPF 上运行真实
的 `sol_create_program_address` 系统调用；解释器与原生目标上该助手原样返回
`program_id`——与 `stdlib/core.ml` 为纯 OCaml 运行定义的确定性链下 stub 一
致，模式同 `Cpi.invoke` 链下 stub 为 `0`。裸名 `create_program_address` 仍然
可用；`Pda.` 是可发现的命名空间。`Pda.try_find_program_address seeds
program_id` 返回 `Some (address, bump)`（`(bytes * int) option`）：BPF 上经
`sol_try_find_program_address` 运行真实的 bump 搜索，确定性的链下 stub 则产
出 `Some (program_id, 0)`。`examples/pda_derive.ml` 端到端演练这两个助手。

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

`omlz idl <file.ml>` 会发出一个 Anchor-compatible JSON 文档，描述发现的程序形态：

- program name 和可选 program id；
- Anchor 0.30+ instruction entries，包含 name、discriminator、accounts 和 arguments；
- 用户定义的 record 和 variant 类型；
- source 暴露出的 events、errors 和 constants。

示例：

```sh
zig build
zig-out/bin/omlz idl tests/idl/entrypoint.ml | python3 -m json.tool
```

最初的 P3 schema 有意保持小而且 ZxCaml 专用。当前已封存的 P5/P8 toolchain 会发出
Anchor-compatible IDL JSON，同时仍以 `.ml` 程序作为事实源。

R13 的 account helper call 也会进入 IDL account metadata pass。例如
`Account.is_signer authority` 会把 `authority` 标记为 `signer: true`，
`Account.is_writable guarded_account` 会把 `guarded_account` 标记为
`writable: true`；这些 account 参数会出现在 instruction 的 `accounts` 中，而不是普通
`args`。推荐把稳定 custom code 常量命名为 `error_` 前缀（例如
`error_missing_signer = 1`），这样 `omlz idl` 可以把它们暴露在顶层 `errors` 数组中。
R14 还会从这个 suffix 派生人类可读的 `msg`（`error_missing_signer` 对应
`"Missing signer"`），同时保留源码里的 `name` 和数值 `code`。

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
