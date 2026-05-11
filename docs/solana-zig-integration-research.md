# Solana-Zig-Bootstrap 集成调研

## 目标

研究是否可以用 `solana-zig-bootstrap` 编译器替代 `sbpf-linker`，
解决 Ubuntu CI 上 BPF 测试因缺少 LLVM 而失败的问题。

## 发现

### solana-zig-bootstrap 是什么

[joncinque/solana-zig-bootstrap](https://github.com/joncinque/solana-zig-bootstrap) 
从源码编译一个定制的 Zig 0.16.0，链接了 Solana LLVM fork (anza-xyz/llvm-project)。
这个编译器内置 BPF/SBF 目标支持，可以直接编译出 `.so` 文件，**不需要 sbpf-linker**。

### 历史 ZxCaml BPF 编译流程（已弃用）

历史上该流程是两步：先 `zig build-lib -femit-llvm-bc` 得到 bitcode，再由
`sbpf-linker` 链接成 `.so`。该路径依赖系统 LLVM 库分发，并在特定平台上
出现兼容性与维护成本问题。当前工程已切到 direct `solana-zig`，该历史路径
仅保留文档史料，不再作为默认构建策略。

### solana-zig-bootstrap 的方案（一步）

```
Zig source → `solana-zig build` → 直接生成 .so
```

内置 Solana LLVM fork，`zig build-lib -target sbf-solana` 直接编译成 SBF ELF。

### solana-program-sdk-zig 的使用方式

[joncinque/solana-program-sdk-zig](https://github.com/joncinque/solana-program-sdk-zig) 
提供 Zig Solana SDK，使用 `solana-zig-bootstrap` 编译器。

关键配置：
```zig
// build.zig 中的目标定义
pub const sbf_target: std.Target.Query = .{
    .cpu_arch = .sbf,
    .os_tag = .solana,
};

pub const bpf_target: std.Target.Query = .{
    .cpu_arch = .bpfel,
    .os_tag = .freestanding,
    .cpu_features_add = std.Target.bpf.featureSet(&.{.solana}),
};

// 构建共享库（不是 build-lib 生成 bitcode）
const program = b.addLibrary(.{
    .name = "program_name",
    .linkage = .dynamic,
    .root_module = mod,
});

// 关键：使用自定义链接脚本
lib.setLinkerScript(linker_script);
lib.stack_size = 4096;
lib.link_z_notext = true;
lib.root_module.pic = true;
lib.root_module.strip = true;
lib.entry = .{ .symbol_name = "entrypoint" };
```

链接脚本 (`bpf.ld`):
```
PHDRS { text PT_LOAD; rodata PT_LOAD; data PT_LOAD; dynamic PT_DYNAMIC; }
SECTIONS {
    . = SIZEOF_HEADERS;
    .text : { *(.text*) } :text
    .rodata : { *(.rodata*) } :rodata
    .data.rel.ro : { *(.data.rel.ro*) } :rodata
    .dynamic : { *(.dynamic) } :dynamic
    .dynsym : { *(.dynsym) } :data
    .dynstr : { *(.dynstr) } :data
    .rel.dyn : { *(.rel.dyn) } :data
    /DISCARD/ : { *(.eh_frame*) *(.gnu.hash*) *(.hash*) }
}
```

## 可行的集成方案

### 方案 A：替换 BPF 编译流程（推荐）

用 `solana-zig-bootstrap` 编译器替代标准 Zig + sbpf-linker 两步流程：

```
OCaml → ZxCaml → Zig codegen → program.zig
  → `solana-zig build-lib -target sbf-solana -dynamic` → program.so
```

**改动**：
1. `init.sh`: 下载 `solana-zig` 编译器（~70MB，比安装 LLVM 省空间）
2. `src/driver/bpf.zig`: 检测 `solana-zig` 可用时，直接编译成 .so（一步）
3. `build.zig`: BPF 测试步骤使用 `solana-zig`

**优点**：
- 完全消除 sbpf-linker 依赖
- CI 不需要安装 LLVM（下载 ~70MB solana-zig vs ~400MB LLVM）
- 一步编译更快
- 使用 Solana 官方 SBF 目标（sbf-solana），比 bpfel-freestanding 更标准

**风险**：
- solana-zig-bootstrap 是社区维护的，不是官方 Solana 工具
- ZxCaml 生成的 Zig 代码可能需要适配（ABI、链接脚本等）
- sbf-solana 目标的运行时（arena、syscalls）需要验证兼容性

### 历史方案 B：兼容说明（可选，仅供记录）

原先保留的兼容路径已被标记为不推荐。当前默认与 CI 标准流程使用方案 A 的
`solana-zig build-lib` 直接链路，不再在新工作流中维护历史两步回退路径。

### 方案 C：保留旧行为（仅备选）

历史上用于离线/回退场景的保留策略。建议仅在确需兼容旧环境时临时使用；新
工程推进以方案 A 为准。

**优点**：最少变更成本
**缺点**：会继续承载旧链路的环境依赖

## 对比

| 方案 | CI 改动 | 运行时兼容性 | 维护成本 | 推荐 |
|---|---|---|---|---|
| A: 替换流程 | 中等 | 需验证 | 低 | ⭐ 推荐 |
| C: 保留旧行为（历史兼容） | 无 | 无风险 | 低 | 仅历史参考 |

## 下一步

如果选择方案 A（当前基线），实施路径：

1. 下载 solana-zig 到本地，验证 ZxCaml 生成的 Zig 代码可以直接编译为 SBF .so
2. 修改 `buildBpf()` 函数，支持 solana-zig 直接编译模式
3. 添加链接脚本 `bpf.ld`
4. 更新 `init.sh` 下载 solana-zig
5. 更新 CI 配置

验证命令：
```bash
# 下载 solana-zig
./install-solana-zig.sh

# 验证 ZxCaml 生成的 Zig 代码能编译
./solana-zig/zig build-lib -target sbf-solana -O ReleaseSmall \
  -fstrip -fPIC -dynamic --entry entrypoint \
  out/program.zig -o test_program.so
```
