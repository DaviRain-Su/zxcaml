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

```text
fn entrypoint(input: *const u8, len: usize) -> u64 {
    var arena: Arena = Arena.init_from_static_buffer(...);
    defer arena.reset();
    return user_main(&arena, input, len);
}
```

每个被编译出来的函数都把 arena 作为 **隐式首参数** 接收。
前端用户从来不写它；后端始终把它穿进去。

## 4. 哪些值住哪里

| 值类别 | Region | Repr |
|---|---|---|
| `int`、`bool`、`unit` | Static（即时值） | TaggedImmediate |
| 零参构造子 | Static | TaggedImmediate |
| 字符串字面量 | Static | Boxed（指向只读数据） |
| 元组、记录、ADT payload | Arena | Boxed |
| 闭包 | Arena | Boxed |
| （P1.5 可选）逃逸分析能证明不逃逸的值 | Stack | Boxed |

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

## 6. 闭包表示（P1）

```
struct Closure {
  code: *const fn(*Arena, /* captures */, /* args */) -> Ret,
  captures: { ... 字段，按值或 boxed ... },
}
```

分配在 arena 上，`Boxed`。
自由变量由 ANF lowering 计算并写到 `RLam.free_vars`。
`ArenaStrategy` 直接发出 capture struct。

P1 **不** 对已知 callee 做特化；调闭包就是走间接函数指针。
具体优化交给 `zig`。

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
