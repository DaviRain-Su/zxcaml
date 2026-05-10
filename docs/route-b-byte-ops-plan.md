# Route B: OCaml 字节操作 + 位运算支持 — 实施计划

## 目标

扩展 ZxCaml 编译器，使 OCaml 代码可以直接操作字节和位运算，
从而纯 OCaml 编写 Solana 指令编码和账户数据读写，不再需要手写 Zig。

## ✅ 实施完成（5 步全部完成）

### Step 1: 位运算 ✅
- `land`, `lor`, `lxor`, `lsl`, `lsr`, `lnot`
- 走 `prim` 路径（`is_whitelisted_prim` 白名单）
- 6 个新 `PrimOp` 变体：`BitAnd`, `BitOr`, `BitXor`, `ShiftLeft`, `ShiftRight`, `BitNot`
- 常量折叠支持
- 测试：`examples/bitwise_ops.ml` ✅

### Step 2: 只读 Bytes 操作 ✅
- `Bytes.get`, `Bytes.length`, `Bytes.sub`, `Bytes.of_string`
- 复用 `StringGet`/`StringLength`/`StringSub` PrimOp（零新变体）
- 走 `builtinCallOp` 路径
- 测试：`examples/bytes_read.ml`, `examples/bytes_le_decode.ml` ✅

### Step 3: 可变 Bytes 操作 ✅
- `Bytes.create`, `Bytes.set`
- `BytesCreate`: arena 分配 + `@memset` 清零
- `BytesSet`: `@constCast` 写入，DCE 标记副作用
- 测试：`examples/bytes_mutable.ml`, `examples/spl_transfer_encode.ml`, `examples/bytes_le_codec.ml` ✅

### Step 4: 批量 Bytes 操作 ✅
- `Bytes.blit`, `Bytes.fill`
- `BytesBlit`: `@memcpy` + `@constCast` 目标
- `BytesFill`: `@memset` + `@constCast` 目标
- 测试：`examples/bytes_blit_fill.ml` ✅

### Step 5: 示例验证 ✅
- `examples/solana_instruction_encode.ml` — 纯 OCaml 编码 4 种 Solana 指令（System Transfer, SPL Transfer, SPL TransferChecked, System CreateAccount）✅
- `examples/spl_transfer_pure_ocaml.ml` — 纯 OCaml 编码 SPL Token Transfer，等价于原 `spl_token_transfer.ml` ✅
- `examples/system_transfer_pure_ocaml.ml` — 纯 OCaml 编码 System Transfer，等价于原 `simple_cpi.ml` 的数据部分 ✅

## 改动的文件（按管线顺序）

| 文件 | 改动 |
|---|---|
| `src/frontend/zxc_subset.ml` | 白名单 `land`\|`lor`\|`lxor`\|`lsl`\|`lsr`\|`lnot` |
| `src/core/ir.zig` | `PrimOp` 加 8 个变体：`BitAnd`, `BitOr`, `BitXor`, `ShiftLeft`, `ShiftRight`, `BitNot`, `BytesCreate`, `BytesSet`, `BytesBlit`, `BytesFill` |
| `src/core/anf/module.zig` | `builtinCallOp`/`lowerPrimOp`/`primOpArity`/`primOpReturnTy`/`builtinCallArgTys`/`builtinCallReturnTy` |
| `src/core/anf/match.zig` | 模式匹配上下文加新 case |
| `src/core/pretty.zig` | `primOpName` 加新条目 |
| `src/core/const_fold.zig` | 位运算编译期求值 + Bytes 操作标记不可折叠 |
| `src/core/dce.zig` | `BytesSet`/`BytesBlit`/`BytesFill` 标记有副作用（防止 DCE 消除） |
| `src/lower/lir.zig` | `LPrimOp` 加对应变体 |
| `src/lower/arena.zig` | Lower 映射 |
| `src/backend/interp.zig` | 解释器：位运算求值 + `BytesCreate` arena 分配 + `BytesSet` 可变写入 + `BytesBlit`/`BytesFill` |
| `src/backend/zig_codegen/common.zig` | `primOpToken` unreachable 列表 |
| `src/backend/zig_codegen/expr_emission.zig` | 核心代码生成：位运算 Zig 操作符 + `BytesCreate` arena 分配 + `BytesSet` `@constCast` + `BytesBlit` `@memcpy` + `BytesFill` `@memset` |

## 新增示例

| 文件 | 测试内容 |
|---|---|
| `examples/bitwise_ops.ml` | 位运算全部 6 种操作 ✅ |
| `examples/bytes_read.ml` | Bytes.get/length/sub 只读操作 ✅ |
| `examples/bytes_le_decode.ml` | Bytes.get + 位运算解码 LE u32 ✅ |
| `examples/bytes_mutable.ml` | Bytes.create + Bytes.set 构造 System Transfer buffer ✅ |
| `examples/bytes_le_codec.ml` | Bytes.create + Bytes.set + 位运算编码/解码 LE u32 ✅ |
| `examples/spl_transfer_encode.ml` | 纯 OCaml SPL Token Transfer 编码 ✅ |
| `examples/bytes_blit_fill.ml` | Bytes.blit + Bytes.fill 批量操作 ✅ |
| `examples/solana_instruction_encode.ml` | 4 种 Solana 指令纯 OCaml 编码 ✅ |
| `examples/spl_transfer_pure_ocaml.ml` | SPL Transfer 纯 OCaml 版本 ✅ |
| `examples/system_transfer_pure_ocaml.ml` | System Transfer 纯 OCaml 版本 ✅ |

## 测试基线

**671/672 tests passed (1 skipped)** — 零回归，所有 5 步完成后维持不变。

## 设计决策总结

1. **位运算走 `prim` 路径**：OCaml 将 `land` 等视为中缀运算符，与 `+`/`-` 走相同路径
2. **Bytes.* 走 `builtinCallOp` 路径**：前端看到的是函数调用，与 `String.length` 走相同路径
3. **Bytes 只读操作复用 String PrimOp**：`Bytes.get` → `StringGet`，零新变体
4. **BytesCreate arena 分配**：`arena.allocIntoOrTrap` + `@memset` 清零
5. **BytesSet `@constCast`**：将 `[]const u8` 转为 `[]u8` 实现就地修改
6. **DCE 副作用标记**：`BytesSet`/`BytesBlit`/`BytesFill` 标记为有副作用，防止被优化消除
7. **BytesFill 使用 `@memset`**：高效填充多个字节
8. **BytesBlit 使用 `@memcpy`**：高效批量复制
