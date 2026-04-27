# 05 — 后端

> **Languages / 语言**: [English](../05-backends.md) · **简体中文**

## 1. Backend trait（概念）

后端消费 `Lowered IR`（解释器除外，它直接消费 `Core IR`），
然后产出 *某种东西*。两种情况下接口形状一致：

```text
Backend:
  name              : string
  target_triple()   : string                     -- 信息性
  emit_module(m)    : EmitResult
  link(parts...)    : LinkResult                 -- 后端特定

  -- 诊断接口
  pretty_emit(m)    : string                     -- 始终可用
```

返回对象都是 POD；后端对单次调用是无状态的。

P1 出货：

- `ZigBackend`        —— 主路径，产出 `.zig` 源码。
- `Interpreter`       —— 仅开发用，执行 Core IR。

P1 stub（仅签名，必须能编译，被调用时返回"未实现"诊断）：

- `OCamlBackend`      —— 占位。注：之前草案说它是"子集正确性参考"，
  这一角色已删除，因为 ADR-010 让漂移在结构上不可能 ——
  上游 OCaml 编译器**已经**作为前端在主路径上。
- `LlvmBackend`       —— 占位。

## 2. ZigBackend

### 2.1 输入

由 `ArenaStrategy` 产出的 `Lowered IR`。
后端 **不允许** 回头读上游 `Typedtree`、sexp wire 格式、Zig 的 `ttree` 镜像，
也不允许直接读 Core IR。

### 2.2 输出

一个 `.zig` 源文件，外加一个 `build.zig` 片段驱动按目标平台调对应工具链。
`--target=bpf` 时链路是
`zig build-lib -target bpfel-freestanding -femit-llvm-bc`
然后 `sbpf-linker --cpu v2 --export entrypoint`，
产出 `program.so`（详见 `06-bpf-target.md` §2 / §6、ADR-012、ADR-013）。

```text
out/
├── program.zig         -- 生成的用户代码
├── runtime.zig         -- 链接所需的 runtime/zig/* 副本
└── build.zig           -- 最小驱动，由生成器写出
```

### 2.3 映射

| Core IR / Lowered IR | Zig 输出 |
|---|---|
| `TyInt` | `i64`（BPF ABI 和 native 都用 `i64`） |
| `TyBool` | `bool` |
| `TyUnit` | `void`（或 `u0`，内部选择） |
| `TyString` | `[]const u8`（只读切片） |
| `TyTuple` | 匿名 `struct` |
| `TyAdt`（全零参） | `enum(uN)` |
| `TyAdt`（带 payload） | `struct { tag: uN, payload: union(enum) {...} }` |
| `TyRecord` | `struct { ... }` |
| `RLam` | 顶层 `fn` + arena 上的 capture 结构体 |
| `RApp` | 直接 `fn` 调用（已知 callee）或经闭包间接调用 |
| `RCtor` | arena 上放置的 struct 字面量 |
| `RProj` | `obj.*.field` |
| `EMatch` | 在判别符上 `switch` + 各 arm 内绑定 |
| `EIf` | `if (cond) ... else ...` |
| `RPrim IAdd / ...` | Zig 原生运算符（绕回 / 截断语义按 §2.5 规定） |

### 2.4 Arena 穿线

每个发出的函数都把 `arena: *Arena` 作为首参。
入口 shim（`runtime/zig/bpf_entry.zig`）从静态 buffer 创建 arena 并用它调 user `main`。

### 2.5 整数语义

P1 发 `i64`，算术用 Zig 的 `+%`、`-%`、`*%`（绕回）。
除法和取余通过 runtime helper 包装 `@divTrunc` 和 `@rem`，
这样除零 panic 和 `min_int / -1` 边界在各后端保持一致；
精确定义见 §6 的确定性要求。

### 2.6 命名

生成的标识符前缀加 `omlz_` 防止和 runtime 冲突。
源级标识符用 `Symbol` id 修饰，处理 shadowing。

### 2.7 它 **不做** 的事

- 不做优化 pass。信任 `zig`（BPF 用 `-O ReleaseSmall`）。
- 不做增量输出。每次都整模块。
- P1 不带源码映射 / 调试信息。

## 3. 解释器

### 3.1 用途

- 驱动 `omlz run`，方便快速迭代。
- 在测试中作为语义参考：
  同一个程序经解释器和 Zig 后端运行，必须产生相同的可观察结果。

### 3.2 输入

直接是 `Core IR` —— 解释器**不**消费 Lowered IR。
这意味着解释器**独立**于 lowering 策略，
测试可以把"前端 bug"和"后端 bug"隔离开。

### 3.3 实现要点

- 宿主里（Zig）一个 tagged-union `Value` 类型。
- 闭包是 `(env, body)` 对，分配在宿主 arena 上。
- 模式匹配是递归遍历；P1 不编译成 decision tree。
- ADT 用 `{ tag, payload: []Value }` 表示。

### 3.4 限制

- 递归函数受宿主栈限制。
- 字符串只读，不支持拼接（与 P1 stdlib 一致）。
- I/O：仅支持向 stdout `print`（仅解释器，不是 stdlib 函数 ——
  通过 CLI flag 暴露）。

## 4. Stub 后端

`OCamlBackend` 和 `LlvmBackend` 存在的唯一目的是让 backend trait 被多个实现锻炼一下，
以证明这个扩展点确实有用。它们：

- 实现 trait 签名。
- `emit_module` 返回 `error.NotImplemented`（或宿主等价物）。
- 默认构建里被排除，但 `omlz build --backend=...` 的开关里能看到。

## 5. 后端选择

CLI：

```
omlz build foo.ml --backend=zig --target=bpf
omlz build foo.ml --backend=zig --target=native      # 顺带的，不支持
omlz run   foo.ml                                     # 始终走解释器
```

驱动逻辑：

1. 解析、类型检查（实际由 `zxc-frontend` 完成）、lower 到 Core IR。
2. 如果是 `run`：把 Core IR 给 `Interpreter`，打印结果。
3. 如果是 `build`：
   a. 应用 `ArenaStrategy` → Lowered IR。
   b. 把 Lowered IR 给所选后端。
   c. 后端发出产物；driver 调外部工具（`zig`）。

## 6. 确定性要求

对于 P1 子集中任何程序和任何输入：

```
Interpreter(P)  ≡  ZigBackend(P)   （在可观察输出上）
```

这是一个 **强制不变量**，由属性测试套件保证 —— 跑一组 `.ml` 文件穿过两条路径，
diff 结果。出现分歧就是 P0 bug。

**固定整数语义（F14）**：ZxCaml 的 `int` 在 P1 固定为有符号 64 位
`i64`，这刻意不同于上游 OCaml 的 63 位立即整数；`+`/`-`/`*`
按 `+%`/`-%`/`*%` 绕回，`/` 向零截断，`mod` 使用 remainder 语义，
除零或 `mod 0` 统一以 `ZXCAML_PANIC:division_by_zero` 标记 panic。
