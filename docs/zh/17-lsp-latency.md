# 17 — LSP latency hardening

> **Languages / 语言**: [English](../17-lsp-latency.md) · **简体中文**
>
> **范围：** M-LSPFIX2 交付的 latency hardening：warmup 裁剪、p50/p99
> 报告、默认阈值、环境变量覆盖、`omlz lsp-bench` 与 `make lsp-bench`。

## 1. 定位

M-LSPFIX2 是一次测量链路 hardening。
它不是新的语言特性。
它不改变 LSP 协议表面。
它把不稳定的 Python timing 路径换成 Zig probe。
这个 probe 是 stdio JSON-RPC client。
probe 每个 sample 都 fork 一次 `zig-out/bin/omlz-lsp`。
每个 sample 会执行 initialize、didOpen、didChange、diagnostics、shutdown 和 exit。
计时从 `textDocument/didChange` 发送前开始。
计时在收到对应的第一条 `publishDiagnostics` 时结束。
输出同时面向人工与自动化。
人工输出会打印 `samples_ms=[...]`。
人工输出也会打印 `warmup`、`rounds`、`p50_ms`、`p99_ms`、`min_ms` 和 `max_ms`。
JSON 输出是一条包含同样核心字段的 object。
公开 CLI 是 `omlz lsp-bench`。
Makefile 便捷入口是 `make lsp-bench`。
底层安装后的 executable 是 `zig-out/bin/lsp-bench`。
大多数用户应优先使用 Makefile 或 `omlz` wrapper。
直接运行 `lsp-bench` 主要用于调试 probe 本身。

## 2. Sample 形状

一个 sample 会启动一个全新的 language-server process。
probe 打开 stdin 和 stdout pipes。
probe 发送 `initialize` request。
probe 等待匹配的 response。
probe 发送 `initialized` notification。
probe 打开一个 clean synthetic OCaml document。
probe 等待 clean diagnostics。
probe 把同一个 URI 改成 broken document。
wall clock 在这个 change frame 发送前开始。
wall clock 在 broken document 的 diagnostics 到达时停止。
probe 随后发送 `shutdown`。
probe 等待 shutdown response。
probe 发送 `exit`。
probe 等待 exit code zero。
协议失败不会被当作慢 sample。
server 非零退出是 probe failure。
framing error 是 probe failure。
缺失 diagnostic 是 probe failure。
sample 测的是编辑器可观察到的反馈路径。
它包含 JSON-RPC framing cost。
它包含 server 内部 temporary file cost。
它包含 fork 出来的 `omlz check --error-format=json` 路径。
它不包含 editor rendering。
它不包含网络传输，因为 server 使用 local stdio。

## 3. Warmup 模型

warmup 是统计前丢弃的初始 sample 数。
默认 warmup count 是 3。
默认 total round count 是 10。
所以默认 measured set 有 7 个 post-warmup samples。
CLI 用 `--warmup N` 暴露 warmup。
CLI 用 `--rounds K` 暴露 total samples。
不变量是 `rounds > warmup`。
如果 `rounds <= warmup`，probe 会给出清晰错误并退出。
warmup samples 仍然运行真实协议路径。
warmup samples 仍然出现在 `samples_ms` 中。
warmup samples 不参与 p50。
warmup samples 不参与 p99。
warmup samples 不参与 min。
warmup samples 不参与 max。
baseline script 使用 5 个 warmup samples。
baseline script 使用 30 个 total samples。
这留下 25 个 samples 计算 percentile。
warmup 吸收一次性的 host effects。
warmup 吸收 cold dynamic-loader cost。
warmup 吸收首次 filesystem path setup。
warmup 吸收首次 process-spawn cache 影响。
warmup 不会掩盖反复出现的慢。

## 4. Warmup 数学

令 `S` 是按发生顺序记录的 raw sample times。
令 `W` 是 warmup count。
令 `K` 是 total round count。
probe 要求 `K > W`。
trim 后的 list 是 `T = S[W..K]`。
参与测量的 sample count 是 `M = K - W`。
默认情况下，`K = 10`。
默认情况下，`W = 3`。
默认情况下，`M = 7`。
baseline script 中，`K = 30`。
baseline script 中，`W = 5`。
baseline script 中，`M = 25`。
只有 `T` 会被排序后用于 percentile computation。
原始顺序仍保留在 `samples_ms` 中。
保留 raw order 有助于诊断 host spikes。
只排序 trimmed list 可以避免 warmup bias。
min 和 max 也来自 trimmed list。
warmup 阶段的 cold spike 不会变成 `max_ms`。
post-warmup spike 仍然会变成 `max_ms`。
pass/fail check 使用 trimmed p50 和 trimmed p99。
JSON 的 `samples_ms` 字段保留完整 raw list。

## 5. Percentile 选择

probe 报告 p50，因为 p50 描述 steady-state editor feedback。
p50 是 warmup 后 request 的 median。
median 比 mean 更能抵抗单个 outlier。
median 对人工解释很直接。
median 让本地迭代更可预测。
probe 也报告 p99，因为少量卡顿在编辑器里也很重要。
如果一次 request 接近一秒，language server 会显得像卡住。
p99 会暴露这种 high-tail sample。
p99 比只凭肉眼看 max 更严格。
p99 又比 max-only gate 更稳定。
实现使用 nearest-rank percentile selection。
排序后的 post-warmup list 是 percentile 输入。
对 p50 来说，rank 落在中间附近。
对 p99 来说，rank 落在高端附近。
默认小样本会让 p99 接近 max。
较长 baseline run 更适合比较 p99。
p50 和 p99 组合能同时捕获整体 regression 和 tail regression。

## 6. 阈值依据

默认 p50 threshold 是 350 ms。
默认 p99 threshold 是 800 ms。
旧 Python latency path 使用 200 ms median-style gate。
这个 gate 在 cold-cache parallel `zig build test` 下太紧。
新的 p50 threshold 给 process startup 和 host noise 留出空间。
新的 p50 threshold 仍要求 median feedback 低于半秒。
p50 高于 350 ms 时，普通编辑诊断会显得慢。
p99 threshold 用来约束 tail behavior。
p99 高于 800 ms 时，一些编辑反馈会接近卡住。
800 ms budget 能捕获这种情况，同时避免轻微波动频繁失败。
本机 30-round baseline 观察到 p50 174 ms。
本机 30-round baseline 观察到 p99 304 ms。
本机 30-round baseline 观察到 min 162 ms。
本机 30-round baseline 观察到 max 304 ms。
这些值在两个阈值下都有有效余量。
阈值是默认值，不是永久法律。
开发者可在本地实验中收紧阈值。
CI 不应在没有证据时放宽阈值。
如果某台 host 持续更慢，先调查 load。
如果 server 改变，先刷新 baseline evidence。

## 7. 环境变量

`ZXCAML_LSP_LATENCY_P50_MS` 覆盖默认 p50 threshold。
`ZXCAML_LSP_LATENCY_P99_MS` 覆盖默认 p99 threshold。
两个值都按 unsigned millisecond integer 解释。
非法值会产生 threshold parsing error。
底层 probe 会直接读取这些变量。
`omlz lsp-bench` wrapper 也支持 CLI threshold flags。
`--p50 MS` 映射到 `ZXCAML_LSP_LATENCY_P50_MS`。
`--p99 MS` 映射到 `ZXCAML_LSP_LATENCY_P99_MS`。
环境变量适合 CI matrix jobs。
CLI flags 适合一次性本地运行。
reproduction command 中优先写 CLI flags。
外层 runner 持有配置时优先用环境变量。
不要把放宽后的 environment values 作为默认值提交。
不要只靠提高 thresholds 隐藏 regression。
更低 thresholds 可用于验证 failure message。
更高 thresholds 只适合比较 overloaded machines。
baseline script 也尊重同样的环境变量名。

## 8. CLI 用法

benchmark 前先构建。

```sh
./init.sh
zig build
```

运行默认 latency check。

```sh
./zig-out/bin/omlz lsp-bench
```

运行显式默认形状。

```sh
./zig-out/bin/omlz lsp-bench --warmup 3 --rounds 10
```

运行更长的本地检查。

```sh
./zig-out/bin/omlz lsp-bench --warmup 5 --rounds 30
```

为脚本输出 JSON。

```sh
./zig-out/bin/omlz lsp-bench --warmup 5 --rounds 30 --json
```

收紧 thresholds 做 stress test。

```sh
./zig-out/bin/omlz lsp-bench --p50 250 --p99 500
```

用环境变量代替 flags。

```sh
ZXCAML_LSP_LATENCY_P50_MS=350 ZXCAML_LSP_LATENCY_P99_MS=800 ./zig-out/bin/omlz lsp-bench
```

两个 percentile check 都通过时，CLI exit zero。
p50 或 p99 达到配置阈值时，CLI exit non-zero。
failure text 会指出 percentile、observed value 和 threshold。

## 9. Makefile 用法

`make lsp-bench` 是首选 smoke command。
它会先 rebuild repository。
然后运行安装后的 CLI wrapper。
target 运行 `./zig-out/bin/omlz lsp-bench --warmup 3 --rounds 10`。
修改 LSP latency-sensitive code 前可以运行它。
修改 LSP server 后可以运行它。
修改 `omlz check` diagnostics 后可以运行它。
修改 temporary-file behavior 后可以运行它。
full suite 前可以用它判断 loaded host 状态。
Makefile target 有意保持短小。
它不会写 30-round baseline JSON。
它默认不改变 thresholds。
它应保持为快速 observability target。
需要 machine-readable output 时，直接用 CLI 加 `--json`。
需要记录 baseline evidence 时，使用 baseline script。

## 10. Baseline 捕获

baseline helper 是 `scripts/lsp_bench_30_rounds.py`。
它运行 `omlz lsp-bench --rounds 30 --warmup 5 --json`。
它写入 `mission-internal/lsp-bench-baseline.json`。
输出路径已 gitignore。
JSON 包含 ISO timestamp。
JSON 包含 `uname -a` host information。
JSON 包含 `warmup: 5`。
JSON 包含 `rounds: 30`。
JSON 包含全部 30 个 raw `samples_ms`。
JSON 包含 warmup trimming 后的 p50、p99、min 和 max。
JSON 包含 `passed`。
当前捕获的 baseline 已通过。
当前捕获的 p50 是 174 ms。
当前捕获的 p99 是 304 ms。
当前捕获的 min 是 162 ms。
当前捕获的 max 是 304 ms。
有意义的 LSP 或 diagnostics 变化后应刷新 baseline。
gitignored JSON 是本地证据，不是 release documentation。

## 11. 解读输出

先看 `samples_ms`。
检查开头是否有 cold samples。
第一个 sample 冷通常是预期现象。
检查 warmup 后是否有一串慢 samples。
warmup 后成簇变慢说明 host 或 server cost 是持续的。
把 p50 与 350 ms 比较。
把 p99 与 800 ms 比较。
看 min 理解最佳 server path。
看 max 理解最坏 post-warmup path。
如果 p50 fail，多数 post-warmup requests 太慢。
如果 p99 fail 但 p50 pass，问题在 tail latency。
如果只有 warmup samples 慢，结果应保持 green。
如果 JSON 显示 `passed: false`，查看 stderr 中的 threshold failure。
如果 stdout 不是合法 JSON，wrapper 或 probe 在 summary 前失败。
如果 server 非零退出，用 `python3 tests/lsp/run_lsp_check.py all` 复现。

## 12. Loaded-host 排障

捕获 baseline 前关闭 CPU-heavy applications。
测量时避免同时运行多个完整 Zig build。
测量时避免并行运行 `cargo test`。
测量时避免同时运行其他 `omlz-lsp` stress tests。
用 Activity Monitor 或 `top` 检查持续 CPU pressure。
检查 indexing、backup 或 scanner 是否活跃。
用 `--warmup 5 --rounds 30` 重新运行。
比较前五个 samples 和剩余 samples。
如果所有 samples 都高，host overload 或 server regression 更可疑。
如果只有前几个 samples 高，warmup 正在发挥作用。
给 issue 附输出时使用 `--json`。
记录 baseline JSON 中的 host line。
记录实际使用的 thresholds。
记录命令是否运行在 `zig build test` 内。
不要在 shared machine 上立刻提高 thresholds。
先证明同一 commit 在 idle host 上是 green。

## 13. Parallel test 交互

之前的 failure mode 来自 broad parallel tests 内部的 latency checks。
并行 build steps 会竞争 CPU。
并行 build steps 会竞争 filesystem cache。
并行 build steps 会放大 process-spawn variance。
M-LSPFIX2 用 warmup 和 percentile trimming 缓解这个问题。
它不会让机器对 overload 免疫。
parallel full-suite failure 应用 standalone probe 继续调查。
失败后立即运行 `make lsp-bench`。
随后运行 `./zig-out/bin/omlz lsp-bench --warmup 5 --rounds 30 --json`。
如果 standalone numbers 健康，scheduler 可能是触发点。
如果 standalone numbers 不健康，LSP 或 diagnostics 更可能 regression。
手动测试后保持 `pgrep -f omlz-lsp` 干净。
probe 正常会关闭每个 server。
残留 server 表示 crash 或 run 被中断。
不要在 shared environments 中按进程名杀掉无关 user processes。
只清理由本 session 启动的进程，或使用 mission-provided cleanup commands。

## 14. 操作 checklist

benchmark 前运行 `zig build`。
默认 smoke check 用 `make lsp-bench`。
记录 milestone baseline 时运行 30-round script。
默认保持 p50 350 ms 和 p99 800 ms，除非证据要求改变。
分析时先增加 warmup 或 rounds，再考虑改 thresholds。
自动化使用 `--json`。
明确复现命令使用 CLI `--p50` 和 `--p99`。
runner-level override 使用环境变量。
bug report 中保留 raw sample list。
比较机器时包含 host information。
stress test 后确认没有 orphan `omlz-lsp`。
确认没有 `surfpool` process 参与。
记住这个 benchmark 只针对 diagnostics latency。
formatting latency 有自己的 checks。
CodeLens latency 有自己的 LSP harness path。

## 15. Cross-references

`tests/lsp/lsp_bench.zig` 拥有底层 protocol probe。
`src/omlz/lsp_bench.zig` 拥有 public wrapper 和 threshold flag mapping。
`Makefile` 拥有 `lsp-bench` smoke target。
`scripts/lsp_bench_30_rounds.py` 拥有 baseline JSON capture。
`runtime/lsp/test_harness.py` 保留 functional LSP PASS markers。
`docs/lsp.md` 记录 LSP server 本身。
本文记录 latency measurement 和 operational interpretation。
这些职责应保持分离。
不要在这里重复每个 LSP method。
除非影响 editor setup，否则不要把 benchmark troubleshooting 搬进 protocol guide。
当 defaults、output fields 或 threshold names 改变时，更新本文。
同一次 change 中也要更新 Chinese mirror。
保持本文与英文文档的 heading parity。

## Python harness env thresholds（M-LSPFIX-3）

M-LSPFIX-3 关闭了 Phase 17 留下的 Python harness latency 技术债。
旧的 Python `latency` 场景不再拥有 200 ms 的 diagnostics 预算。
删除这个 200 ms assertion，是因为它重复了一个已经有更合适 owner 的 contract。
diagnostics latency 的单一事实来源是 `omlz lsp-bench`。
Zig probe 已经执行 warmup trimming。
Zig probe 已经报告 p50 和 p99。
Zig probe 已经执行默认的 350 ms p50 与 800 ms p99 规范。
保留另一个 Python median threshold 会让并行 `zig build test` 受 host load 影响。
它也会迫使 worker 在 canonical probe 健康时仍然走 Phase 17 的 `-j1` fallback。
现在 Python `latency` command 是 shim，而不是 benchmark authority。
它会查找安装后的底层 binary：`zig-out/bin/lsp-bench`。
如果这个 binary 不存在，harness 会先构建项目。
它从 repository root 运行 bench。
它转发 bench 的 stdout 和 stderr，所以 operator 仍能看到真实 timings。
它只断言 completed process 的 return code 是 zero。
它不再计算自己的 median。
它不再和旧的 200 ms 数字比较。
因此 `latency` check 失败表示 Zig latency contract 失败，或 probe 本身无法运行。
Python all-checks loop 中的 PASS marker 保持不变。
这样既保留了 functional harness accounting，也把 latency policy 移交给 Zig probe。

相邻的两个 Python micro-benchmark 仍保留本地阈值。
`LATENCY_CODELENS_THRESHOLD_MS` 控制 `python3 tests/lsp/run_lsp_check.py codelens_latency`。
它的默认值是 `100`。
`LATENCY_FORMATTING_THRESHOLD_MS` 控制 `python3 runtime/lsp/test_harness.py formatting_latency`。
它的默认值是 `30`。
这些 thresholds 覆盖的是窄的 feature-specific 路径，不是 diagnostics latency。
它们继续留在 Python 中，因为 CodeLens 和 formatting 是由 Python harness 直接测量的。
现在它们可以通过环境变量调整，便于在 loaded host 上诊断，而不需要改源码。
例如：

```sh
LATENCY_CODELENS_THRESHOLD_MS=200 python3 tests/lsp/run_lsp_check.py codelens_latency
LATENCY_FORMATTING_THRESHOLD_MS=60 python3 runtime/lsp/test_harness.py formatting_latency
```

failure message 会写出实际配置的 threshold。
验证 negative path 时使用更低的值。
只有在繁忙机器上做显式本地比较时，才使用更高的值。
不要把放宽后的值提交为项目默认值。
不要把这些 Python 变量当成 canonical diagnostics contract 的替代品。

M-LSPFIX2 的变量属于另一个层级。
`ZXCAML_LSP_LATENCY_P50_MS` 和 `ZXCAML_LSP_LATENCY_P99_MS` 配置 Zig diagnostics probe。
这些变量定义 `omlz lsp-bench` 使用的 canonical latency contract。
它们映射到 warmup 后 diagnostics samples 的 p50 和 p99 checks。
新的 `LATENCY_*_THRESHOLD_MS` 变量只调节 Python micro-benchmarks。
它们是 CodeLens 和 formatting checks 的单场景 escape valves。
Zig 变量描述 editor diagnostics feedback。
Python 变量描述 feature-specific harness budgets。
排查 failure 时要保持这条边界清晰。

M-LSPFIX-3 之后的迁移规则是 strict。
Phase 17 的 `zig build -j1 test` fallback 已经撤回。
strict parallel `zig build test` 是唯一 no-regress 路径。
如果旧的 Python `latency` check 失败，请调查 `omlz lsp-bench`。
如果 `codelens_latency` 或 `formatting_latency` 失败，请检查场景自己的 threshold。
复现命令里要记录所有 override。
手动 stress tests 后保持 `pgrep -f omlz-lsp` 干净。
当 Python threshold 名称或默认值变化时，更新本节。
同一次 commit 中也要更新英文镜像。
