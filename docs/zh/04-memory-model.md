# 04 — 内存模型

> **Languages / 语言**: [English](../04-memory-model.md) · **简体中文**

## 1. 定位

P1 阶段，ZxCaml 只有 **一种** 内存模型：

> 整个程序使用一个 arena，启动时分配好，所有堆上的值都从这里来。
> 没有 GC，没有引用计数，没有逐值的生命周期。
> 用户**看不到**这个模型 —— 他们写的是 OCaml。

Core IR 上的 `Layout` 字段是一个 **向前兼容的描述符**，
不是用户层的旋钮。它存在的意义是让未来阶段
（区域推断、RC、所有权）能不改架构地引入更复杂的模型。

## 2. 为什么用 arena？

对一个 Solana BPF 程序来说：

- 执行模型有界且确定。
- 总活跃内存很小（KB 级别，不是 MB）。
- 不存在长期可变线程；程序是 request/response 形态。
- 任何动态分配都需要便宜，并且能整体回收。

bump arena 完美符合：O(1) 分配、零 per-object 开销，
"程序结束 = 整体丢弃 arena"。


## 3. 单 arena 规则

As built，`runtime/zig/arena.zig` 暴露的是一个很小的 caller-owned bump arena：

```zig
pub const Arena = struct {
    buffer: []u8,
    offset: usize,

    pub fn fromStaticBuffer(buf: []u8) Arena
    pub fn alloc(self: *Arena, comptime T: type, count: usize) ![]T
    pub fn reset(self: *Arena) void
};
```

arena **不拥有**内存。BPF entry shim 提供静态 byte buffer，构造
`Arena.fromStaticBuffer(&buf)`，编译后的函数把 `arena: *Arena` 作为隐式第一个参数。
`alloc` 会做 checked size arithmetic、通过 `std.mem.alignForward` 对齐，并在静态
buffer 耗尽时返回 `error.OutOfMemory`。`reset` 在程序退出时把 bump cursor 归零。

## 4. 哪些值住哪里

| 值类别 | Region | Repr |
|---|---|---|
| 整数常量 | Static | Flat |
| unit 值 / unit 参数 | Static | Flat |
| 无 payload 构造器（`None`、`[]`） | Static | TaggedImmediate |
| 字符串字面量 | Static | Boxed（指向只读数据） |
| 带 payload 构造器 / list cons cell | Arena | Boxed |
| 顶层 lambda | Arena | Flat |
| 一等 closure record | Arena | Boxed |
| 保留给未来的不逃逸值 | Stack | Boxed |

这些规则住在 `Typed AST → Core IR` lowering 中（见 `03-core-ir.md` §4）。
这是前端控制的 **唯一** 旋钮。

## 5. ADT 表示（P1）

对一个有 `n` 个 variant 的 ADT：

- 如果所有 variant 都是零参：编码成小整数（`u8`/`u16`），`TaggedImmediate`。
- 否则：扁平结构体
  ```
  struct {
    tag: uN,                         // 判别符
    payload: union { v0_struct, v1_struct, ... },
  }
  ```
  通过 `Boxed` 指针指向 arena 中的实例。

判别符宽度由后端选。解释器允许用宿主语言原生的 tagged-union 表示，
不受这个编码约束。


## 6. Closure 与 recursion 表示（P1）

P1 有三种 as-built 情况：

1. **顶层函数** lower 成使用 arena-threaded 调用约定的直接 Zig helper function。
2. **不逃逸的嵌套递归函数** lower 成直接 helper function，捕获值作为额外参数传递。
3. **逃逸的一等 closure** 在 Lowered IR 中表示为 arena 分配的 closure record，包含 code pointer
   和 capture array（`prelude.Closure`）。该路径通过了 interpreter/native 验证；BPF 一等 closure
   code pointer 不属于 P1 Solana acceptance example，仍是 P2/P3 hardening 项，因为本 mission
   在该形状上观察到 `Relocations found but no .rodata section` linker 失败。

用户仍然看不到这些机制；他们只写普通的 `let` / `let rec` OCaml 子集代码。

## 7. 字符串（P1）

字符串在 P1 只存在于：

- 字符串字面量（interned，住 `Static`）。
- 字符串相等和长度（解释器和 stdlib 诊断内部用）。

P1 **没有** runtime 字符串拼接、格式化、分配。
这是有意为之 —— 字符串是任何 BPF 项目里的"诱人麻烦源"。

## 8. **不允许** 的事

- 任何值的 mutation（`ref`、可变记录字段、数组）。
- 异常（`try` / `raise`）。
- 无界递归引发的无界分配（允许；见 §9）。
- 任何 arena 之外的分配。

## 9. 栈 / 递归预算

BPF 有固定的调用栈。前端在 P1 不静态约束递归，因此：

- Zig 后端发出 Zig 函数；`zig` 自己的栈分析适用。
- runtime arena 大小在编译期通过 build 时常量决定（默认 32 KiB；可由 CLI 覆盖）。
- BPF 程序里栈溢出由 Solana 报告，不是我们。

P3 引入可选的"无分配"标注，并加上一个分析来验证。

## 10. 向前兼容

从"P1 单 arena"到"P4 区域推断"的路径：

1. 保留每个分配点上的 `Layout` 字段。✅（P1 已经做到）
2. 加 `Region::Region(id)` 和一道区域推断 pass，把 `Arena` 细化成具体 region。
3. 升级 `ArenaStrategy`（或加 `RegionStrategy`），按 region 发不同 arena。
4. 后端消费新的 region id；Core IR 形态不变。

到"P4+ 所有权 / RC"的路径：

1. 加 `Region::Rc` 和借用 / move 分析。
2. lowering 在 `Boxed` 且 region 为 `Rc` 的值周围发 `inc_ref` / `dec_ref`。
3. 后端加 `Rc` runtime helper；现有 `Arena` 路径不动。

两种情况里，Core IR 变体集都在增长；现有代码路径都不改。

## 11. 这份文档 **不规定** 的内容

- 记录和 ADT 的具体字节布局（由后端决定）。
- arena 的分配策略（bump？slab？页对齐？）。P1 默认是从静态 buffer 单向 bump。
- 多线程、并发、pinning。范围之外。
