# 14 — Hash syscall 与 secp256k1 恢复

> **Languages / 语言**: [English](../14-hash-syscalls.md) · **简体中文**
>
> **范围：** ZxCaml runtime 与 stdlib 暴露的 Solana hash syscall：
> SHA-256、Keccak-256、BLAKE3，以及 secp256k1 公钥恢复。
>
> **相关文档：** [`docs/runtime-api.md`](../runtime-api.md)、
> [`docs/11-solana-p3.md`](../11-solana-p3.md)、
> [`examples/keccak_demo.ml`](../../examples/keccak_demo.ml)、
> [`examples/blake3_demo.ml`](../../examples/blake3_demo.ml)、
> [`examples/secp_recover_demo.ml`](../../examples/secp_recover_demo.ml)。

## 1. 定位

Hashing 是 runtime 边界，不是新的语言特性。
ZxCaml 源码仍然是普通 `.ml`。
frontend 会类型检查 `Crypto.keccak256 payload` 这类调用。
Zig backend 会识别 bundled external。
生成的 BPF 代码通过 `runtime/zig/syscalls.zig` 调用 Solana syscall。
hosted native build 对 hash digest 使用确定性的 `std.crypto` fallback。
hosted secp256k1 recovery 只提供形状正确的成功返回；真实恢复属于 SVM。
公开的 OCaml API 有意统一返回 `bytes`。
digest 永远是 32 字节。
成功恢复出的 secp256k1 公钥永远是 64 字节。
恢复失败用零长度 byte slice 表示。
这样示例里的使用方式很直接，同时仍然贴合 SBF ABI。
本 milestone 的实现 commit 是 `cd2bc31`、`721aeae`、`e48ea82`、
`973850b` 和 `40fa8bd`。

## 2. ABI 总览

所有 digest syscall 都使用 Solana 的 byte-slice descriptor ABI。
`runtime/zig/syscalls.zig` 把这个 descriptor 命名为 `SolBytes`。
descriptor 是一个 extern struct，包含两个字段。
`addr` 指向某个 segment 的第一个字节。
`len` 是该 segment 的长度，类型为 `u64`。
syscall 接收第一个 descriptor 的指针。
syscall 还接收 descriptor 数量。
syscall 把 32 字节 digest 写入调用方提供的输出内存。
syscall 返回 `u64` 状态码。
当前公开的 `Crypto.*` wrapper 会为一个 OCaml `bytes` 传一个 descriptor。
runtime 形态仍然为未来的多 segment wrapper 留出空间。
secp256k1 recovery 使用单独的四参数 ABI。
它接收 32 字节 hash 指针。
它接收 `u64` 形式的 recovery id。
它接收 64 字节 compact signature 指针。
它接收可变的 64 字节输出指针，用于写入未压缩公钥。
成功返回 0，失败返回非 0。
ZxCaml wrapper 会先验证明显的长度与 recovery-id 错误。

| 操作 | Runtime wrapper | SBF syscall 地址 | 输出 |
|---|---|---:|---|
| SHA-256 | `sol_sha256` / `sol_sha256_alloc` | `0x11f49d86` | 32 字节 digest |
| Keccak-256 | `sol_keccak256` / `sol_keccak256_alloc` | `0xd7793abb` | 32 字节 digest |
| BLAKE3 | `sol_blake3` / `sol_blake3_alloc` | `0x174c5122` | 32 字节 digest |
| secp256k1 recovery | `sol_secp256k1_recover_alloc` | `0x17e40350` | 64 字节 pubkey 或空 bytes |

## 3. Stdlib 绑定签名

bundled stdlib 位于 [`stdlib/core.ml`](../../stdlib/core.ml)。
hash API 在 `module Crypto` 中。
当前签名故意保持很小：

```ocaml
module Crypto : sig
  val sha256 : bytes -> bytes
  val keccak256 : bytes -> bytes
  val blake3 : bytes -> bytes
  val secp256k1_recover : bytes -> int -> bytes -> bytes
end
```

`Crypto.sha256 payload` 返回 32 字节 SHA-256 digest。
`Crypto.keccak256 payload` 返回 32 字节 Keccak-256 digest。
`Crypto.blake3 payload` 返回 32 字节 BLAKE3 digest。
`Crypto.secp256k1_recover hash recovery_id signature` 返回恢复结果。
`hash` 参数必须正好 32 字节。
`signature` 参数必须正好 64 字节 compact ECDSA 数据。
`recovery_id` 参数必须在闭区间 `0..3` 内。
恢复成功返回 64 字节。
恢复失败返回 `Bytes.length result = 0`。
底层的 `Syscall.sol_sha256` 仍保留给旧示例使用。
新代码优先使用 `Crypto.*`，因为算法名在调用点更清楚。

## 4. SHA-256

SHA-256 在本 milestone 之前已经是 runtime surface 的一部分。
当 Solana 或 Anchor 惯例只说 “hash” 而没有指定以太坊兼容时，它仍是保守默认值。
Anchor instruction discriminator 应使用 SHA-256。
本仓库已有 PDA helper 材料也继续使用 SHA-256。
已有示例调用 `sol_sha256_alloc` 时，也应保持 SHA-256。
协议文档明确写 SHA-256 时，不要换成别的算法。
不要因为 Keccak-256 也是 32 字节就替换它。
也不要因为 BLAKE3 在 off-chain 很快就替换它。
digest 类型只是 byte string，所以 domain separation 由调用方负责。
请在 hash 之前加上应用自己的前缀。
前缀要稳定，也要写进协议说明。

```ocaml
let digest : bytes = Crypto.sha256 payload
```

runtime wrapper 是：

```zig
pub inline fn sol_sha256(payload: []const u8) Hash
pub inline fn sol_sha256_alloc(arena: *Arena, payload: []const u8) []const u8
```

在 BPF 上，wrapper 通过固定 dispatch address 调用 `sol_sha256`。
在 hosted target 上，它调用 `std.crypto.hash.sha2.Sha256.hash`。
同一输入在两条路径上都得到 32 字节输出。

## 5. Keccak-256

Keccak-256 用于以太坊风格 digest 的兼容场景。
当签名 fixture、bridge protocol 或 off-chain indexer 期待以太坊 Keccak-256 时使用它。
函数名刻意写成 `keccak256`，不是 `sha3_256`。
这样可以避免常见的 Keccak/SHA3 padding 混淆。
BPF wrapper 的形状与 SHA-256 完全一致。
hosted fallback 使用 Zig 的 Keccak 实现。
公开示例是 [`examples/keccak_demo.ml`](../../examples/keccak_demo.ml)。
该程序对 instruction data 做 hash，并把 digest 写入 account data。
对应的 Mollusk fixture 会在 SVM 中逐字节检查 digest。

```ocaml
let entrypoint output_account instruction_data =
  let digest = Crypto.keccak256 instruction_data in
  set_account_data output_account digest;
  0
```

runtime ABI 形态：

```zig
const SolHashFn = *align(1) const fn ([*]const u8, u64, [*]u8) u64;
pub inline fn sol_keccak256(payload: []const u8) Hash
pub inline fn sol_keccak256_alloc(arena: *Arena, payload: []const u8) []const u8
```

`Crypto.keccak256` 当前的 descriptor count 是 1。
输出长度永远是 32 字节。
由于 runtime 自己持有有效指针，wrapper 不暴露原始状态码。
如果 Solana 改动 syscall contract，应先更新 `runtime/zig/syscalls.zig`。

## 6. BLAKE3

BLAKE3 用于明确选择现代 BLAKE3 digest 的协议。
Solana syscall 返回固定的 32 字节 digest。
ZxCaml 也遵循这个固定 digest 大小。
它不暴露 BLAKE3 的 extendable-output 模式。
只有当 on-chain 或 off-chain 协议明确写 BLAKE3 时才使用它。
Anchor discriminator 不应使用 BLAKE3。
以太坊兼容 message hash 也不应使用 BLAKE3。
如果双方 verifier 都同意，BLAKE3 很适合内部 content hash。
公开示例是 [`examples/blake3_demo.ml`](../../examples/blake3_demo.ml)。
它与 Keccak demo 结构相同。
配套 Mollusk test 会把 SVM digest 与已知 BLAKE3 值比较。

```ocaml
let entrypoint output_account instruction_data =
  let digest = Crypto.blake3 instruction_data in
  set_account_data output_account digest;
  0
```

runtime ABI 形态：

```zig
pub inline fn sol_blake3(payload: []const u8) Hash
pub inline fn sol_blake3_alloc(arena: *Arena, payload: []const u8) []const u8
```

当返回给 OCaml 时，wrapper 会从 BPF entry arena 分配 32 字节。
生成的 Zig 代码里可以看到这次 arena allocation。
OCaml 用户只看到一个 `bytes` 值。
示例复制输出时，目标 account 必须至少有 32 个可写字节。

## 7. secp256k1 恢复

`sol_secp256k1_recover` 用于验证并恢复以太坊风格的公钥。
它不会替你 hash 消息。
调用方传入的必须是已经算好的 32 字节 hash。
调用方传入 compact 64 字节 ECDSA signature，顺序是 `r || s`。
调用方单独传 recovery id。
合法 recovery-id 只有 `0`、`1`、`2`、`3`。
范围外的值会在调用 BPF syscall 前失败。
hash 或 signature 长度错误也会在 syscall 前失败。
成功返回 64 字节未压缩 secp256k1 公钥。
它是 x 坐标后接 y 坐标。
它不是 33 字节 compressed SEC1 key。
它也不是带 `0x04` 前缀的 65 字节 key。
公开示例是 [`examples/secp_recover_demo.ml`](../../examples/secp_recover_demo.ml)。
Mollusk test 使用来自 Bitcoin Core recovery tests 的 libsecp256k1 fixture。

```ocaml
match String.length (Crypto.secp256k1_recover hash recovery_id signature) with
| 64 -> (* success: write or compare the recovered key *) 0
| _ -> (* failure: invalid id, invalid lengths, or syscall rejection *) 1
```

runtime ABI 形态：

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

`_alloc` wrapper 会把 `null` 映射为空 slice。
因此面向 OCaml 的生成代码只需要一个 `bytes` 返回类型。
凡是接收用户签名的调用点，都应清楚写出失败处理方式。

## 8. 如何选择操作

Solana-native 约定没有另行说明时，用 SHA-256。
Anchor discriminator 兼容场景用 SHA-256。
本仓库已有 PDA helper 材料也用 SHA-256。
以太坊 message-hash 兼容场景用 Keccak-256。
复现 `ecrecover` 流程时用 Keccak-256。
只有协议明确承诺 BLAKE3 时才用 BLAKE3。
内部 content hash 可以用 BLAKE3，但所有 verifier 必须一致。
secp256k1 recovery 只在已经有 32 字节 digest 后使用。
不要把任意用户文本直接喂给 recovery。
不要把恢复出的 64 字节公钥当作 Solana `Pubkey`。
如果需要以太坊地址，请按协议规则对恢复公钥再做 Keccak-256，并在此 primitive 外派生地址。
即使两个协议使用同一 hash 算法，也要使用 domain-separated prefix。
如果 hash 用于授权，请把 program id、account key 和用途绑定进去。

## 9. 安全注意事项

Hash 函数不会自动修复含糊的编码。
请用固定长度字段或显式长度前缀编码 typed fields。
不要无分隔地拼接多个可变长度字段。
同一组字段用于不同上下文时，要加入 domain string。
授权 program-specific action 时，要把 program id 纳入 digest。
授权 account-specific state change 时，要把 account key 纳入 digest。
除非协议明确指定，不要只比较 digest 前缀。
digest 输出写 account 时应保持固定大小。
输出长度不符合预期时应拒绝或忽略。
secp256k1 的 `recovery_id` 必须在 `0..3` 内。
runtime wrapper 已经做了这件事，但显式检查能改善诊断。
ECDSA signature 如果协议不要求 low-`s`，就可能存在 malleability。
recovery syscall 只恢复公钥，本身不强制 low-`s`。
如果协议依赖不可延展性，应在协议层验证 canonical signature，或使用说明了 canonical 规则的 fixture 来源。
demo fixture 是互操作性证明，不是生产授权策略。
接受 recovered key 之前，仍必须检查它是不是预期 signer。
不要在日志里打印私密签名材料。

## 10. 示例：digest writer

Keccak 和 BLAKE3 demo 都采用同一种模式。
它们接收一个可写 output account 和 instruction data。
它们对全部 instruction data 计算一个 digest。
它们把 digest 复制进 output account。
写入完成后返回 0。
下面的 helper 在源码中只是类型见证。
真正的 account-data copy 由生成的 BPF 代码执行。

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

BLAKE3 版本只需要把 `Crypto.keccak256` 换成 `Crypto.blake3`。
参见 [`examples/keccak_demo.ml`](../../examples/keccak_demo.ml)。
参见 [`examples/blake3_demo.ml`](../../examples/blake3_demo.ml)。

## 11. 示例：recovery writer

recovery demo 使用固定 instruction-data layout。
字节 `0..32` 是 message hash。
字节 `32` 是 recovery id。
字节 `33..97` 是 compact signature。
程序会切出 hash 和 signature。
它用 OCaml 分支检查 recovery id。
然后调用 recovery external。
最后把结果写入第一个 account。
空 recovery result 表示没有 key bytes 可写。
Mollusk test 会提供已知正确的 tuple。

```ocaml
let hash = String.sub instruction_data 0 32
let signature = String.sub instruction_data 33 64
let recovered = recover hash checked_recovery_id signature
```

参见 [`examples/secp_recover_demo.ml`](../../examples/secp_recover_demo.ml)。
测试 fixture 在 [`tests/secp_recover_demo_test.rs`](../../tests/secp_recover_demo_test.rs)
中写明了来源。

## 12. 验证清单

新增 hash-using program 时，先检查输入形状。
第二步检查精确算法名。
第三步检查预期输出长度。
确认结果到底是 digest、address，还是 public key。
构建 BPF 之前先运行 `omlz check`。
涉及 account write 时运行对应 Mollusk test。
digest writer 应断言写入了 32 字节。
recovery writer 成功路径应断言 64 字节。
recovery 失败路径应断言零字节或显式 program error。
静态签名数据旁边要保留 fixture provenance 注释。
优先使用 known-answer vector，不要在测试里临时生成 signature。
公开 docs 或 CHANGELOG claim 依赖实现时，记录 commit hash。

## 13. 排错

32 字节 digest 不匹配，通常是选错算法。
请先检查 Keccak-256 和 SHA3-256 是否混用。
然后检查输入 bytes 是否包含 prefix、discriminator 或 length。
secp256k1 返回零长度，说明 wrapper 拒绝了输入，或 SVM syscall 返回非零。
检查 `hash` 长度是否为 32。
检查 `signature` 长度是否为 64。
检查 `recovery_id` 是否在 0 到 3 之间。
检查 signature 是否是 compact `r || s`，而不是 DER。
检查预期 key 是否没有 SEC1 `0x04` 前缀。
hosted native recovery test 不能证明真实 secp256k1 recovery。
请使用 Mollusk 或其他 SVM-backed 路径验证。
BPF account-write 失败通常意味着 account data 太小，或 test fixture 没有把 account 设为 writable。

## 14. 文件地图

`runtime/zig/syscalls.zig` 维护 syscall 地址、wrapper 和 hosted fallback。
`stdlib/core.ml` 维护 `Crypto` 绑定签名。
`src/backend/zig_codegen/runtime_imports.zig` 把 bundled external 映射到 wrapper。
`examples/keccak_demo.ml` 是 Keccak digest writer。
`examples/blake3_demo.ml` 是 BLAKE3 digest writer。
`examples/secp_recover_demo.ml` 是 secp256k1 recovery writer。
`tests/keccak_demo_test.rs` 用 Mollusk 验证 Keccak。
`tests/blake3_demo_test.rs` 用 Mollusk 验证 BLAKE3。
`tests/secp_recover_demo_test.rs` 验证 recovery 与 fixture provenance。
`CHANGELOG.md` 在 `[Unreleased]` 下记录五个 milestone commit。
`mission-internal/canonical-facts.md` 记录当前 post-M-HASH 值。
