# 07 — 仓库布局

> **Languages / 语言**: [English](../07-repo-layout.md) · **简体中文**

## 1. 顶层

```text
ZxCaml/
├── README.md
├── docs/                       -- 设计文档（本目录）
├── build.zig                   -- 单一 build driver（ADR-011）
├── build.zig.zon               -- pin 到 Zig 0.16
├── src/
│   ├── frontend/               -- OCaml 胶水（zxc-frontend）
│   │   ├── zxc_frontend.ml
│   │   ├── zxc_subset.ml
│   │   ├── zxc_sexp.ml
│   │   └── zxc_sexp_format.md  -- wire 契约
│   ├── frontend_bridge/        -- Zig 端 sexp 消费者
│   │   ├── sexp_lexer.zig
│   │   ├── sexp_parser.zig
│   │   └── ttree.zig           -- 接受的 Typedtree 子集的 Zig 镜像
│   ├── core/                   -- Core IR（ANF、Layout）
│   ├── lower/                  -- ArenaStrategy（P1）
│   ├── backend/                -- ZigBackend、解释器、stub
│   ├── driver/                 -- CLI 管线、BPF 接线
│   ├── util/                   -- arena、诊断、interner
│   ├── main.zig                -- omlz 入口
│   └── root.zig                -- 给测试用的库 re-export
├── runtime/
│   └── zig/                    -- 链接进用户程序的 runtime helper
├── stdlib/
│   └── core.ml                 -- option / result / list（真 OCaml；子集内）
├── examples/                   -- acceptance corpus + smoke fixtures
│   ├── hello.ml
│   ├── option_chain.ml
│   ├── result_basic.ml
│   ├── list_sum.ml
│   ├── enum_adt.ml / tree_adt.ml
│   ├── nested_pattern.ml / guard_match.ml
│   ├── tuple_basic.ml / record_person.ml
│   ├── stdlib_list.ml / closure_adt.ml
│   └── solana_hello.ml         -- BPF 验收程序
├── tests/
│   ├── ui/                     -- 端到端 .ml → 期望输出
│   ├── golden/                 -- Core IR + sexp snapshot 测试
│   └── solana/                 -- solana-test-validator 集成
└── .github/workflows/          -- CI
```

### 1.1 双语言边界

整个 repo 只有一道跨语言边界，在
`src/frontend/`（OCaml）↔ `src/frontend_bridge/`（Zig）。
两边都很小。除此之外没有任何 OCaml 代码，没有第二道跨语言接缝。
构建编排在 `build.zig` 里，通过 `ocamlfind` 调 OCaml 那侧
（见 `09-decisions.md` ADR-011）。

## 2. `src/`（编译器本体）

```text
src/
├── main.zig                    -- CLI 入口：omlz check/build/run
├── root.zig                    -- 给测试用的库 re-export
│
├── util/
│   ├── arena.zig               -- 编译器自用 arena（NOT 用户 arena）
│   ├── diag.zig                -- 带 span 的诊断
│   └── intern.zig              -- 字符串 / 符号 interner
│
├── frontend/                   -- OCaml 端胶水（编译成 native 二进制）
│   ├── zxc_frontend.ml         -- 主程序；驱动 compiler-libs
│   ├── zxc_subset.ml           -- Typedtree 子集白名单 + walker
│   ├── zxc_sexp.ml             -- S-expression 序列化器
│   └── zxc_sexp_format.md      -- 有版本的 wire 契约
│
├── frontend_bridge/            -- Zig 端 sexp 消费者
│   ├── sexp_lexer.zig
│   ├── sexp_parser.zig
│   └── ttree.zig               -- 接受的 Typedtree 子集的 Zig 镜像
│
├── core/
│   ├── ir.zig                  -- Core IR 数据模型（CONTRACT）
│   ├── layout.zig              -- Region / Repr / Layout（EXTENSION POINT）
│   ├── anf.zig                 -- ttree → Core IR
│   └── pretty.zig              -- IR pretty-printer（golden tests）
│
├── lower/
│   ├── strategy.zig            -- LoweringStrategy 接口（EXTENSION POINT）
│   ├── lir.zig                 -- Lowered IR
│   └── arena.zig               -- ArenaStrategy（P1 唯一实现）
│
├── backend/
│   ├── api.zig                 -- Backend 接口（EXTENSION POINT）
│   ├── zig_codegen.zig         -- ZigBackend
│   ├── interp.zig              -- 树遍历解释器
│   ├── ocaml_stub.zig          -- 仅编译占位（不是前端；前端在 frontend/）
│   └── llvm_stub.zig           -- 仅编译占位
│
└── driver/
    ├── pipeline.zig            -- spawn zxc-frontend，驱动剩下流水线
    ├── build.zig               -- 调 ZigBackend，再调 `zig build-lib` + `sbpf-linker`
    └── bpf.zig                 -- BPF 目标接线
```

之前草案里的 `src/syntax/` 和 `src/types/` 都消失了 ——
它们的职责现在分别落到 `src/frontend/`（OCaml）和 `src/frontend_bridge/`（Zig）。
这是 ADR-010 的具体落地。

### 2.1 标记为 **EXTENSION POINT** 的文件

未来 phase（P3+ 内存模型，P5+ 后端）应该只在这几个地方扩展。
为了加新后端或新内存模型而去动其它地方，那是设计味道有问题。

- `src/core/layout.zig`
- `src/lower/strategy.zig`
- `src/backend/api.zig`

### 2.2 标记为 **CONTRACT** 的文件

Core IR 数据模型是项目的稳定契约。
这里的改动必须在同一次变更里同步更新所有消费者
（anf、lower、interp、zig_codegen、pretty）。

- `src/core/ir.zig`

## 3. `runtime/zig/`

```text
runtime/zig/
├── arena.zig                   -- bump allocator
├── panic.zig                   -- BPF 安全的 panic
├── prelude.zig                 -- list cons / 元组 helper / 绕回算术
└── bpf_entry.zig               -- Solana 用 entrypoint shim
```

这些文件是 **复制**（或 `@embedFile`）到生成产物里去的，
不是从编译器那里静态链接出来的。它们是用户程序的产物。

## 4. `stdlib/`

```text
stdlib/
└── core.ml                     -- option, result, list 和基础组合子
```

`stdlib/` 的规则：

- 必须能被 `omlz` parse。
- 当本机有 `ocaml` 编译器时，必须也能被它 parse 通过（CI 门槛）。
- 不许 import `runtime/zig/` 的任何东西。
  编译器会注入 runtime；stdlib 是纯表层代码。


## 5. `examples/`

```text
examples/
├── hello.ml                    -- list head + Some/None demo
├── option_chain.ml             -- Option.map / Option.bind acceptance
├── result_basic.ml             -- Result 构造与模式匹配
├── list_sum.ml                 -- 列表递归求和
├── enum_adt.ml                 -- 用户自定义 enum ADT
├── option_adt.ml / tree_adt.ml -- 参数化和递归 ADT
├── nested_pattern.ml           -- 嵌套构造器 pattern
├── guard_match.ml              -- guarded match arm + decision-tree dispatch
├── tuple_basic.ml              -- tuple 构造/解构和 ADT payload
├── record_person.ml            -- record、字段访问、函数式 update
├── stdlib_list.ml              -- 扩展 List 函数和 closure
├── closure_adt.ml              -- 捕获 ADT 值的 closure
├── solana_hello.ml             -- canonical BPF acceptance program
├── factorial.ml                -- 递归 smoke test
├── arith_wrap.ml               -- i64 wrap semantics smoke test
├── div_zero.ml                 -- 稳定 division-by-zero panic marker
└── m0_unsupported.ml           -- 刻意失败的诊断 fixture
```

`examples/` 也是 regression suite。Corpus loop 必须跳过预期失败的 `m0_unsupported.ml`。

## 6. `tests/`

```text
tests/
├── ui/                         -- 端到端：.ml 文件 + .expected stdout
│   ├── hello.ml
│   └── hello.expected
├── golden/                     -- IR snapshot 测试
│   ├── hello.ml
│   └── hello.core.snapshot
└── solana/
    ├── hello/                  -- canonical BPF 验收骨架
    │   ├── solana_hello.ml
    │   ├── invoke.sh           -- 启 solana-test-validator + 部署
    │   └── expected_output.txt -- invoke.sh 的稳定末尾输出
    └── closures/               -- P2 BPF closure 验收骨架
        └── invoke.sh
```

`tests/solana/` 骨架是可选的（慢，需要 Solana 工具链），不是每次 commit 都跑。
P1 验收门槛挂在这里。


## 7. `.github/workflows/`

CI 表面仍是 `.github/workflows/ci.yml`，在 push 到 `main` 和 pull request 时运行。
workflow 覆盖 `macos-latest` 与 `ubuntu-latest`，调用本地同一个 root `./init.sh`，随后运行：

```text
zig build
zig build test
zig-out/bin/omlz check examples/*.ml   # 跳过 m0_unsupported.ml
tests/solana/hello/invoke.sh          # SOLANA_BPF=1 时
```

P2 使用与 P1 相同的 build/test 命令。Examples corpus loop 基于 glob，因此新增 P2 examples
无需结构性 CI 改动就会被检查。Solana BPF harness 仍由环境变量 opt-in；closure 验收可本地通过
`SOLANA_BPF=1 tests/solana/closures/invoke.sh` 运行。

## 8. 约定

- **不用 git submodule。** 通过 `build.zig.zon` 拉或者 vendor。
- **生成代码不进 `src/`。** 生成的 `.zig` 永远落在 `out/`。
- **`src/util/` 里没有可变全局状态。** 一切都是 per-compilation。
- **测试和它测的区域住在一起**，端到端套件除外（在 `tests/` 下）。
