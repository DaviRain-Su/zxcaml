# Runtime API / 运行时 API

> **Languages / 语言**: [English](../runtime-api.md) · **简体中文**

这份文档面向需要阅读或维护 Zig runtime 的人，而不是介绍 OCaml 源语言本身。
它描述的是 RT 之后 generated ZxCaml code 会导入的运行时表面：哪些类型、常量和函数
构成兼容契约，哪些文件才是修改行为前必须先检查的事实源。

阅读时请把下面几条规则放在前面：

- 以 `runtime/zig/*.zig` 和 `runtime/zig/programs/*.zig` 中的 `pub` 声明为准。
- 文中提到私有 helper 时，只是为了说明行为边界；它们不构成对 generated code 的承诺。
- 修改导出的结构体、常量或函数之前，先回到对应源文件确认调用点和测试。
- 运行时 ABI、BPF loader 布局、OCaml 用户语法是三层不同的问题，不要混在同一个改动里。

## 导入根（Import roots）

`runtime/zig/root.zig` 是规范入口：新的 Solana 相关代码应通过它的命名空间
导入，而不是直接伸进单个文件。

- `runtime.core` —— arena、panic 标记、bs58、prelude 值形态。
- `runtime.solana` —— account 视图、系统调用、sysvar、CPI、SPL token 编解码。
- `runtime.sdk` —— vendored `solana-program-sdk-zig` 的适配器根。
- `runtime.shims` —— generated code 与 SDK 之间的 entrypoint/指令上下文胶水。
- `runtime.programs` —— fixture 与示例使用的手写程序移植。

旧式单文件导入（`arena.zig`、`account.zig`、`cpi.zig`、`entry_context.zig`、
`programs/*.zig`）仍是同一类型的别名；`runtime/zig/import_matrix.zig` 是把
规范根与旧别名钉死为相同布局的测试——新增公共根时同步扩展它。绝不要直接
从 `vendor/solana-program-sdk-zig/**` 导入；一律经 `runtime.sdk`，这样
vendor 刷新永远只是单缝改动。

## Arena

事实源：`runtime/zig/arena.zig`。

Arena 是 generated code 和 runtime helper 共享的极小 bump allocator。它不拥有内存，
只在调用方给出的 buffer 上移动一个 cursor；因此它适合 BPF entrypoint 这种预先准备
scratch 空间、执行结束后整块丢弃的模型。

- `Arena` 保存 `buffer: []u8` 和 `offset: usize`，没有隐藏的 heap 句柄。
- `Arena.fromStaticBuffer(buf)` 只是把静态或栈上的字节区包装成 arena 视图。
- `Arena.alloc(T, count)` 返回类型化 slice；空间不足或整数溢出会走错误返回。
- `Arena.allocIntoOrTrap(T, count, out)` 直接写入输出 slice 指针，失败时 trap，适合简化 BPF ABI。
- `Arena.allocOneOrTrap(T)` 分配单个值，并把 slot 按 8 字节边界取整。
- `Arena.reset()` 只把 cursor 归零，不清除旧内容，也不会释放 backing buffer。
- 普通 `alloc` 会按 `@alignOf(T)` 对齐；调用者不需要手工补 padding。
- OCaml 用户代码看不到 arena 参数；它由生成的 entry 代码和 runtime 桥接层隐式携带。
- hosted test 可以用很小的栈 buffer 构造 arena，验证不依赖 Solana loader 的 helper。
- arena 的引用生命周期跟 backing buffer 绑定；不要把其中的 slice 存到更长生命周期的位置。

示例：

```zig
var scratch: [1024]u8 align(8) = undefined;
var arena = Arena.fromStaticBuffer(&scratch);
const cells = try arena.alloc(u64, 4);
```

维护约定：

- 测试里优先用 `alloc`，因为错误值比 trap 更容易定位。
- BPF hot path 里优先用 `OrTrap` 变体，避免把复杂错误形状暴露给 entry ABI。
- 仍在使用当前 pass 分配结果时，不要调用 `reset`。
- region inference 和 stack-placement 策略属于 compiler lowering，不应塞进 `arena.zig`。

## Syscalls

事实源：`runtime/zig/syscalls.zig`。

Syscalls 层把 Solana BPF 的 syscall dispatch 地址集中到一个文件里，并给 generated code
提供 Zig 形状的薄封装。BPF 目标会走 Solana runtime；hosted 目标则保留确定性 fallback，
方便 native test 对 hash 等结果做断言。

- `Pubkey` 和 `Hash` 都是 `[32]u8`，分别服务于公钥和哈希输出。
- `SolBytes` 是 Solana hash syscall 需要的 C ABI 字节切片描述符。
- `Clock` 和 `Rent` 按 Solana sysvar layout 建模，hosted fallback 返回零值结构。
- `sol_log_address`、`sol_log_64_address`、`sol_log_pubkey_address` 固定日志 syscall 地址。
- `sol_sha256_address`、`sol_keccak256_address` 固定两类 hash syscall 地址。
- `sol_get_clock_sysvar_address`、`sol_get_rent_sysvar_address` 固定 sysvar 查询地址。
- `sol_log_compute_units_address` 和 `sol_remaining_compute_units_address` 覆盖 compute-budget 探针。
- `sol_log_(message)`、`sol_log_64_(...)`、`sol_log_pubkey(pubkey)` 都是不分配的日志包装。
- `sol_sha256(payload)` 与 `sol_keccak256(payload)` 返回固定 32 字节 digest。
- `sol_sha256_alloc(arena, payload)` 与 `sol_keccak256_alloc(arena, payload)` 把 digest 拷进 arena slice。
- `sol_get_clock_sysvar()`、`sol_get_rent_sysvar()`、`sol_log_compute_units_()` 和
  `sol_remaining_compute_units()` 是 runtime inspection helper。
- syscall 地址由单元测试锁住；改动地址常量时必须同步验证 MurmurHash3-32 期望值。

示例：

```zig
syscalls.sol_log_("zxcaml: entered");
const digest = syscalls.sol_sha256(instruction_data);
```

维护约定：

- 新 syscall 只有在 compiler 或 runtime 直接需要时才加到这里。
- 日志 helper 不应引入 arena 或 heap 分配。
- `sol_remaining_compute_units()` 在 hosted 目标上返回 `0`；不要把它当作跨目标性能计数器。
- 若某个外部示例只需要普通 OCaml API，不要为了它扩大 syscall surface。

## CPI

事实源：`runtime/zig/cpi.zig`。

CPI 层保留 Solana cross-program invocation、PDA 和 return-data 的公共原语。RT 把
program-specific entrypoint 搬到了 `runtime/zig/programs/`，所以 `cpi.zig` 应继续保持
“只放通用 CPI 机制”的边界。

- `Pubkey` 直接复用 `syscalls.Pubkey`，避免 account、syscall、CPI 三处出现不同公钥类型。
- `max_seed_len = 32`、`max_seeds = 16` 对齐 Solana PDA 约束。
- `pda_marker` 是 PDA 派生里的 `ProgramDerivedAddress` domain separator。
- `SolAccountMeta` 表示 CPI instruction 的 account meta：pubkey、writable、signer。
- `SolInstruction` 表示 C ABI instruction 描述符；`fromSlices` 从 Zig slice 安全构造它。
- `SolAccountInfo` 是 CPI 调用时传给 callee 的 account-info 描述符。
- `SolSignerSeed.fromSlice(seed)` 和 `SolSignerSeeds.toC()` 把 Zig seed 集合转换成 C ABI 形状。
- `accountInfoFromView(view)` 把 `account.AccountView` 接到 CPI account-info。
- `sol_invoke_signed_c(instruction, infos, signer_seeds)` 对接 Solana CPI syscall；hosted 目标返回成功。
- `invoke(instruction, infos)` 是无 PDA signer seeds 的便捷包装。
- `sol_create_program_address` 与 `sol_try_find_program_address` 有 BPF 绑定和 hosted fallback。
- `sol_set_return_data`、`sol_get_return_data`、`sol_get_return_data_alloc` 负责 Solana return data。

示例：

```zig
const ix = cpi.SolInstruction.fromSlices(&program_id, metas[0..], data[0..]);
const status = cpi.invoke(&ix, infos[0..]);
```

维护约定：

- 不要把新的示例入口函数放回 `cpi.zig`；应放入 `runtime/zig/programs/<name>.zig`。
- hosted `invoke` 的目标是验证 instruction 构造，不是模拟完整 loader。
- PDA helper 会拒绝非法 seed 和 on-curve 派生结果；不要在调用方绕过这些检查。
- return data 的 hosted scratch 区容量为 1024 字节；超过需求时应先讨论 API，而不是静默放大。

## Account

事实源：`runtime/zig/account.zig`。

Account 层解析 Solana BPF loader 传入的序列化 account buffer，并用零拷贝视图暴露给
generated code。它的职责是安全地找到 key、lamports、data、owner、rent epoch 和 flags；
业务逻辑应留给 program helper。

- `AccountView` 是单个序列化 account 的 view，不复制 key、owner 或 data。
- `is_signer`、`is_writable`、`executable` 把 loader flags 转成布尔值。
- `key`、`owner` 指向输入 buffer 里的 32 字节公钥。
- `lamports` 是指向输入 buffer 的可变 `u64` 指针；写入会影响序列化 account。
- `data` 是 account data 的可变字节视图。
- `rent_epoch` 指向输入 buffer 中的 rent epoch。
- `lamportsValue()` 和 `rentEpochValue()` 通过指针读取当前值。
- `ParseError` 覆盖 `TruncatedInput`、`InvalidPadding`、`AccountCountOverflow`、`OutOfMemory`。
- `parseAccounts(arena, input)` 面向 bounded mutable buffer，适合测试和 harness。
- `parseAccountsFromPtr(arena, input)` 面向 Solana entrypoint 原始指针。
- `parseAccountsFromPtrInto(arena, input, out)` 避免在 BPF 上按值返回大 slice。
- `parseAccountsFromPtrIntoStorage(input, storage, out)` 允许调用方提供 view storage。
- `parseInstructionData` 与 `parseInstructionDataFromPtr` 定位 accounts 后面的 instruction payload。
- `logAccountsFromPtr(input)` 用本地 scratch arena 打印 account key 和 lamports，解析失败时静默返回。

示例：

```zig
const views = try account.parseAccountsFromPtr(&arena, input);
const data = try account.parseInstructionDataFromPtr(input);
```

维护约定：

- bounded parser 负责截断和 padding 检查；raw pointer parser 信任 Solana loader 布局。
- `data` 和 `lamports` 都是 view，业务代码写入它们会修改原始输入 buffer。
- parser 已处理 Solana permitted data growth 区和 8 字节对齐。
- 需要完全避免 arena view 分配时，优先使用 `parseAccountsFromPtrIntoStorage`。

## SPL Token

事实源：`runtime/zig/spl_token.zig`。
术语别名：SPL Token|SplToken。

SPL Token helper 是有意收窄的运行时表面：当前只覆盖 examples 需要的 legacy Tokenkeg
Transfer 编码、account meta 构造、canonical program id 和 packed token account 解析。
RT 后 program id 不再手写 32 字节数组，而是在 comptime 通过 Bs58 解码规范字符串。

- `Pubkey` 复用 `cpi.Pubkey`，保证 CPI 和 token helper 的公钥类型一致。
- `pubkey_len = 32` 是 Solana 公钥字节长度。
- `transfer_discriminator = 3` 是 legacy Tokenkeg Transfer instruction tag。
- `transfer_instruction_data_len = 9`，即 1 字节 discriminator 加 8 字节 little-endian amount。
- `token_account_len = 165` 是 runtime 当前解析的 packed SPL Token account 长度。
- `program_id_base58` 保存规范 `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA` 字符串。
- `program_id` 在 comptime 通过 `runtime/zig/bs58.zig` 解码得到 32 字节 Tokenkeg id。
- `Error` 目前包含 `OutputTooShort`、`TruncatedInput`、`InvalidOptionTag`。
- `TokenAccountView` 暴露 mint、owner、amount、delegate、state、native flag、delegated amount、close authority。
- `writeProgramId(out)` 把规范 Tokenkeg id 写入调用方提供的 `Pubkey`。
- `writeProgramIdFromBytes(out, bytes)` 支持原始 32 字节 id，也支持规范 base58 文本长度的入口。
- `encodeTransfer(amount)` 返回固定长度 Transfer payload。
- `encodeTransferInto(out, amount)` 写入调用方 buffer，并返回实际写入的前缀。
- `transferAccountMetas(source, destination, authority)` 构造 Transfer 的三个标准 metas。
- `zxcaml_transfer_one(arena, input)` 从初始 accounts 解析并发起 1 token Transfer。
- `parseTokenAccount(data)` 对 packed token account 做零拷贝解析，并拒绝未知 option tag。

示例：

```zig
const data = spl_token.encodeTransfer(1_000);
const metas = spl_token.transferAccountMetas(&source, &destination, &authority);
```

维护约定：

- 这不是完整 SPL Token SDK；新增 instruction 前要先确认 generated code 确实需要。
- source 和 destination meta 应标为 writable，authority meta 应标为 signer。
- `program_id` 的 Bs58 解码应保持 comptime 形态，避免给 BPF hot path 增加运行时成本。
- `parseTokenAccount` 返回的是指向原始 packed buffer 的 view，不要在调用方假定已复制。

## Bs58

事实源：`runtime/zig/bs58.zig`。
术语别名：Bs58|bs58。

Bs58 模块提供 Solana 常用的 Bitcoin/Base58 alphabet 编解码。它没有外部依赖；通用
encode/decode 走调用方 allocator，32 字节 Pubkey 场景则提供固定长度输出，方便
comptime 常量和测试夹具使用。

- `alphabet` 是 `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`。
- `pubkey32_encoded_len = 44`，覆盖 32 字节 Solana Pubkey 的最长 base58 文本。
- `Error.InvalidCharacter` 用于拒绝不在 alphabet 内的字符。
- `encode(allocator, bytes)` 对任意字节串编码，并返回精确长度的分配结果。
- `decode(allocator, text)` 对 Base58 文本解码，并返回精确长度的分配结果。
- `encodePubkey32(bytes)` 把一个 32 字节公钥编码到 `[44]u8`。
- 原始 bytes 前导 `0x00` 会编码成前导 `1`。
- 文本前导 `1` 会解码回前导零字节。
- `encodePubkey32` 未使用的尾部字节填 `NUL`，调用方按实际文本长度切片。
- fixture 测试覆盖全零 pubkey、全 `0xff` pubkey、Tokenkeg 和 Associated Token Account ids。
- invalid-character 测试拒绝 `0`、`O`、`I`、`l`，这些都不是 Solana Base58 字符。
- 通用 encode/decode 的返回值归调用方所有；测试里要按 allocator 约定释放。

示例：

```zig
const decoded = try bs58.decode(allocator, spl_token.program_id_base58);
const encoded = bs58.encodePubkey32(&pubkey);
```

维护约定：

- 规范 program id 字符串优先在 comptime 解码，再落成固定 32 字节常量。
- `encodePubkey32` 适合无分配展示或 fixture；任意长度字节串仍应使用通用 `encode`。
- 不要引入第三方包；runtime 的可审计性比少写几行代码更重要。
- 修改 alphabet 或前导零规则会影响 Solana Pubkey 兼容性，必须有 fixture 兜底。

## Programs

事实源：`runtime/zig/programs/common.zig`、`runtime/zig/programs/transfer_sol.zig`、
`runtime/zig/programs/vault.zig`、`runtime/zig/programs/vault_v2.zig`、
`runtime/zig/programs/hackathon_greet.zig`、`runtime/zig/programs/token_vault.zig`、
`runtime/zig/programs/escrow_full.zig`。

Programs 目录承接 RT 拆分出来的 program-specific entry helper。它们仍是 runtime 的一部分，
但不再污染 CPI primitive 层；generated code 通过 codegen import 具体 program module。

- `common.isZeroPubkeyBytes(bytes)` 识别全零 32 字节公钥。
- `common.isSystemProgramKey(key)` 识别 fixture 使用的 all-zero System Program id。
- `common.isTokenProgramKey(key)` 识别规范 Tokenkeg program id。
- `common.writeU64Le(out, value)` 和 `common.readU64LeSlice(bytes)` 处理 little-endian `u64`。
- `common.programIdFromInput(input)` 从 Solana input 末尾找到当前 invoked program id。
- `common.writeSystemTransferData(out, amount)` 编码 System Program Transfer payload。
- `common.pubkeyEq(lhs, rhs)` 做逐字节 Pubkey 比较。
- `zxcaml_transfer_sol_process(arena, input, instruction_data)` 处理 transfer-sol amount payload。
- `zxcaml_vault_process(arena, input, views, instruction_data)` 处理原始 vault deposit/withdraw。
- `zxcaml_vault_v2_process(arena, input, views, instruction_data)` 处理 zignocchio-compatible vault flow。
- `zxcaml_hackathon_greet_process(arena, input, views, instruction_data)` 处理 demo PDA counter 的 init/greet。
- `zxcaml_token_vault_process(arena, input, views, instruction_data)` 处理 token-vault initialize/deposit/withdraw。
- `zxcaml_escrow_full_process(arena, input, views, instruction_data)` 处理 escrow make/accept/refund。
- 这些 helper 按约定返回 `0` 表示成功，返回 `1` 表示输入或校验失败。

示例：

```zig
const views = try account.parseAccountsFromPtr(&arena, input);
return programs.hackathon_greet.zxcaml_hackathon_greet_process(&arena, input, views, ix_data);
```

维护约定：

- 新 program entrypoint 应继续放在 `runtime/zig/programs/`，不要回流到 `cpi.zig`。
- 多个 fixture 使用 canonical bump `255`；相关检查应保留在具体 program helper 中。
- 需要共享 raw account 或整数解析时，先看 `common.zig` 是否已有 helper。
- 只有通用 CPI/PDA/return-data 原语才属于 `cpi.zig`；业务分发和 fixture 规则属于 Programs 层。

## 测试覆盖

Runtime program 现在采用两层覆盖策略。第一层是
`runtime/zig/programs/*.zig` 内联的 Zig 白盒测试，直接检查私有 helper、
分支 guard、PDA seed 和字节布局。第二层是 `tests/` 下的 Mollusk
集成测试，把编译后的 BPF program 放进接近 Solana loader 的 account fixture
里运行，用来锁住公开 happy path 的真实行为。

下面的内联白盒数量来自当前源码，而不是手抄计划值；抽取命令是
`rg -nP '^test "' runtime/zig/programs/<name>.zig | wc -l`：

| Program file | 内联测试数 | 白盒关注点 |
|---|---:|---|
| `ata.zig` | 4 | ATA program id、metas 和错误 account 形状 |
| `ata_transfer.zig` | 5 | init/transfer 状态写入和错误 instruction 形状 |
| `common.zig` | 7 | little-endian helper、pubkey predicate 和 raw input parsing |
| `dao_voting.zig` | 7 | proposal 生命周期、vote guard、close path 和 PDA 校验 |
| `escrow_full.zig` | 7 | accept/refund 状态变化，以及 make 路径的提前拒绝 |
| `hackathon_greet.zig` | 14 | init/greet happy path、PDA 派生和负向 fixture |
| `order_book.zig` | 9 | post/fill 流程、算术 guard、mint 检查和 side 校验 |
| `spl_burn.zig` | 4 | burn 状态变更，以及错误 SPL account/data |
| `spl_close_account.zig` | 4 | close-account 状态变更、authority 检查和 lamport overflow |
| `spl_revoke.zig` | 4 | revoke 状态变更、owner 检查和错误输入 |
| `token_vault.zig` | 7 | initialize/deposit/withdraw 状态迁移和 guard rails |
| `transfer_sol.zig` | 7 | amount 解码，以及 System Program CPI 之前的提前拒绝 |
| `vault.zig` | 10 | deposit/withdraw dispatch guard，全部停在 CPI 之前 |
| `vault_v2.zig` | 10 | vault-v2 PDA/account guard，全部停在 CPI 之前 |

会触碰 CPI 的成功路径不会放在这一层白盒测试里断言。
`transfer_sol.zig`、`vault.zig`、`vault_v2.zig`，以及
`escrow_full.zig` 的 make 分支都会通过 Solana `invoke` 或
`sol_invoke_signed_c` 返回；hosted Zig unit test 只覆盖进入 CPI 前就返回的
负向分支。它们的 happy path 由 Mollusk 负责，在那里 loader、account owner、
signer flag、lamports 和 CPI 副作用都作为集成行为来验证，而不是在 runtime
内部伪造。

内联测试还遵守“每个文件自带私有 mock”的约定。每个 program 把小型 fixture
builder 放在被测代码旁边，让分支期望保持局部、可审查。仓库刻意不引入共享的
`test_support.zig`；可复用的生产级解析或整数 helper 应进入 `common.zig`，
而只服务测试的 account buffer 与 mock PDA input 则留在需要它们的 program 文件中。
