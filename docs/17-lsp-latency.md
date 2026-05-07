# 17 — LSP latency hardening

> **Languages / 语言**: **English** · [简体中文](./zh/17-lsp-latency.md)
>
> **Scope:** M-LSPFIX2 latency hardening: warmup trimming, p50/p99 reporting,
> default thresholds, environment overrides, `omlz lsp-bench`, and
> `make lsp-bench`.

## 1. Position

M-LSPFIX2 is a measurement hardening milestone.
It does not add a new language feature.
It does not change the LSP protocol surface.
It replaces the flaky Python timing path with a Zig probe.
The probe is a stdio JSON-RPC client.
The probe forks `zig-out/bin/omlz-lsp` once per sample.
Each sample drives initialize, didOpen, didChange, diagnostics, shutdown, and exit.
The measured interval starts just before `textDocument/didChange`.
The measured interval ends at the first matching `publishDiagnostics`.
The output is designed for humans and automation.
Human output prints `samples_ms=[...]`.
Human output also prints `warmup`, `rounds`, `p50_ms`, `p99_ms`, `min_ms`, and `max_ms`.
JSON output prints one object with the same core fields.
The public CLI is `omlz lsp-bench`.
The Makefile convenience target is `make lsp-bench`.
The installed low-level executable is `zig-out/bin/lsp-bench`.
Most users should prefer the Makefile or `omlz` wrapper.
Direct `lsp-bench` use is mainly for probe debugging.

## 2. Sample shape

A sample starts a fresh language-server process.
The probe opens stdin and stdout pipes.
The probe sends an `initialize` request.
The probe waits for the matching response.
The probe sends the `initialized` notification.
The probe opens a clean synthetic OCaml document.
The probe waits for clean diagnostics.
The probe changes the same URI to a broken document.
The wall clock starts immediately before this change frame is sent.
The wall clock stops when diagnostics for the broken document arrive.
The probe then sends `shutdown`.
The probe waits for the shutdown response.
The probe sends `exit`.
The probe waits for exit code zero.
A protocol failure is not treated as a slow sample.
A non-zero server exit is a probe failure.
A framing error is a probe failure.
A missing diagnostic is a probe failure.
The sample measures observable editor feedback.
It includes JSON-RPC framing cost.
It includes temporary file cost inside the server.
It includes the forked `omlz check --error-format=json` path.
It excludes editor rendering.
It excludes network transport because the server uses local stdio.

## 3. Warmup model

Warmup is the count of initial samples discarded before statistics.
The default warmup count is 3.
The default total round count is 10.
The default measured set therefore has 7 post-warmup samples.
The CLI exposes warmup as `--warmup N`.
The CLI exposes total samples as `--rounds K`.
The invariant is `rounds > warmup`.
If `rounds <= warmup`, the probe exits with a clear error.
Warmup samples still run the real protocol path.
Warmup samples still appear in `samples_ms`.
Warmup samples do not contribute to p50.
Warmup samples do not contribute to p99.
Warmup samples do not contribute to min.
Warmup samples do not contribute to max.
The baseline script uses 5 warmup samples.
The baseline script uses 30 total samples.
That leaves 25 samples for percentile computation.
Warmup absorbs one-time host effects.
Warmup absorbs cold dynamic-loader cost.
Warmup absorbs first filesystem path setup.
Warmup absorbs first process-spawn cache effects.
Warmup does not hide repeated slowness.

## 4. Warmup math

Let `S` be the ordered list of raw sample times.
Let `W` be the warmup count.
Let `K` be the total round count.
The probe requires `K > W`.
The trimmed list is `T = S[W..K]`.
The measured sample count is `M = K - W`.
With defaults, `K = 10`.
With defaults, `W = 3`.
With defaults, `M = 7`.
With the baseline script, `K = 30`.
With the baseline script, `W = 5`.
With the baseline script, `M = 25`.
Only `T` is sorted for percentile computation.
The original order remains visible in `samples_ms`.
Keeping raw order helps diagnose host spikes.
Sorting only the trimmed list avoids warmup bias.
Min and max are also taken from the trimmed list.
A cold warmup spike does not become `max_ms`.
A post-warmup spike still becomes `max_ms`.
The pass/fail check uses trimmed p50 and trimmed p99.
The JSON `samples_ms` field remains the full raw list.

## 5. Percentile rationale

The probe reports p50 because p50 describes steady-state editor feedback.
The p50 is the median request after warmup.
The median resists a single outlier better than the mean.
The median is easy for humans to explain.
The median makes local iteration predictable.
The probe also reports p99 because rare stalls matter in editors.
A language server feels broken if one request hangs near a second.
The p99 exposes those high-tail samples.
The p99 is stricter than only checking max visually.
The p99 is still more stable than a max-only gate.
The implementation uses nearest-rank percentile selection.
The sorted post-warmup list is the percentile input.
For p50, the rank lands near the middle.
For p99, the rank lands near the high end.
Small default sample sets make p99 close to max.
Longer baseline runs make p99 easier to compare.
The pair catches both broad regressions and tail regressions.

## 6. Threshold rationale

The default p50 threshold is 350 ms.
The default p99 threshold is 800 ms.
The old Python latency path used a 200 ms median-style gate.
That gate was too tight under cold-cache parallel `zig build test`.
The new p50 threshold leaves room for process startup and host noise.
The new p50 threshold still requires sub-half-second median feedback.
A p50 above 350 ms means ordinary edit diagnostics feel slow.
The p99 threshold acknowledges tail behavior.
A p99 above 800 ms means some edits feel close to frozen.
The 800 ms budget catches that without failing on mild fluctuation.
The local 30-round baseline observed p50 174 ms.
The local 30-round baseline observed p99 304 ms.
The local 30-round baseline observed min 162 ms.
The local 30-round baseline observed max 304 ms.
Those values leave meaningful headroom.
The thresholds are defaults, not permanent law.
Developers may tighten them during local experiments.
CI should not relax them without recorded evidence.
If a host is consistently slower, investigate load first.
If the server changes, refresh the baseline evidence.

## 7. Environment variables

`ZXCAML_LSP_LATENCY_P50_MS` overrides the default p50 threshold.
`ZXCAML_LSP_LATENCY_P99_MS` overrides the default p99 threshold.
Both values are unsigned millisecond integers.
Invalid values produce a threshold parsing error.
The low-level probe reads these variables directly.
The `omlz lsp-bench` wrapper also supports CLI threshold flags.
`--p50 MS` maps to `ZXCAML_LSP_LATENCY_P50_MS`.
`--p99 MS` maps to `ZXCAML_LSP_LATENCY_P99_MS`.
Environment variables are useful in CI matrix jobs.
CLI flags are useful for one-off local runs.
Prefer CLI flags in reproduction commands.
Prefer environment variables when a runner owns configuration.
Do not commit relaxed environment values as defaults.
Do not hide a regression by only raising thresholds.
Lower thresholds are useful for failure-message tests.
Raised thresholds are only for overloaded-machine comparisons.
The baseline script respects the same environment names.

## 8. CLI usage

Build before running the benchmark.

```sh
./init.sh
zig build
```

Run the default latency check.

```sh
./zig-out/bin/omlz lsp-bench
```

Run the explicit default shape.

```sh
./zig-out/bin/omlz lsp-bench --warmup 3 --rounds 10
```

Run a longer local check.

```sh
./zig-out/bin/omlz lsp-bench --warmup 5 --rounds 30
```

Emit JSON for scripts.

```sh
./zig-out/bin/omlz lsp-bench --warmup 5 --rounds 30 --json
```

Tighten thresholds for a stress test.

```sh
./zig-out/bin/omlz lsp-bench --p50 250 --p99 500
```

Use environment variables instead of flags.

```sh
ZXCAML_LSP_LATENCY_P50_MS=350 ZXCAML_LSP_LATENCY_P99_MS=800 ./zig-out/bin/omlz lsp-bench
```

The CLI exits zero when both percentile checks pass.
The CLI exits non-zero when p50 or p99 reaches the configured threshold.
Failure text names the percentile, observed value, and threshold.

## 9. Makefile usage

`make lsp-bench` is the preferred smoke command.
It rebuilds the repository first.
It then runs the installed CLI wrapper.
The target runs `./zig-out/bin/omlz lsp-bench --warmup 3 --rounds 10`.
Use it before touching LSP latency-sensitive code.
Use it after changing the LSP server.
Use it after changing `omlz check` diagnostics.
Use it after changing temporary-file behavior.
Use it when checking a loaded host before the full suite.
The Makefile target is intentionally short.
It does not write the 30-round baseline JSON.
It does not change thresholds by default.
It remains a quick observability target.
For machine-readable output, use the CLI directly with `--json`.
For recorded baseline evidence, use the baseline script.

## 10. Baseline capture

The baseline helper is `scripts/lsp_bench_30_rounds.py`.
It runs `omlz lsp-bench --rounds 30 --warmup 5 --json`.
It writes `mission-internal/lsp-bench-baseline.json`.
The output path is gitignored.
The JSON includes an ISO timestamp.
The JSON includes `uname -a` host information.
The JSON includes `warmup: 5`.
The JSON includes `rounds: 30`.
The JSON includes all 30 raw `samples_ms`.
The JSON includes p50, p99, min, and max after warmup trimming.
The JSON includes `passed`.
The current captured baseline passed.
The current captured p50 is 174 ms.
The current captured p99 is 304 ms.
The current captured min is 162 ms.
The current captured max is 304 ms.
Refresh the baseline after meaningful LSP or diagnostics changes.
Treat the gitignored JSON as local evidence, not release documentation.

## 11. Interpreting output

Start with `samples_ms`.
Look for cold samples at the beginning.
A cold first sample is usually expected.
Look for clusters of slow samples after warmup.
Clusters after warmup indicate sustained host or server cost.
Compare p50 against 350 ms.
Compare p99 against 800 ms.
Check min for the best-case server path.
Check max for the worst post-warmup path.
If p50 fails, most post-warmup requests are too slow.
If p99 fails while p50 passes, tail latency is the problem.
If only warmup samples are slow, the result should stay green.
If JSON says `passed: false`, inspect stderr for the threshold failure.
If stdout is not valid JSON, the wrapper or probe failed before summary emission.
If the server exits non-zero, reproduce with `python3 tests/lsp/run_lsp_check.py all`.

## 12. Loaded-host troubleshooting

Close CPU-heavy applications before capturing a baseline.
Avoid running multiple full Zig builds while measuring.
Avoid running `cargo test` in parallel with the probe.
Avoid running other `omlz-lsp` stress tests at the same time.
Check Activity Monitor or `top` for sustained CPU pressure.
Check whether indexing, backups, or scanners are active.
Rerun with `--warmup 5 --rounds 30`.
Compare the first five samples with the remaining samples.
If all samples are high, host overload or server regression is likely.
If only the first samples are high, warmup is working.
Use `--json` when attaching output to an issue.
Record the host line from baseline JSON.
Record the exact thresholds used.
Record whether the command ran inside `zig build test`.
Do not immediately raise thresholds on a shared machine.
First prove the same commit is green when the host is idle.

## 13. Parallel test interactions

The previous failure mode came from latency checks inside broad parallel tests.
Parallel build steps can compete for CPU.
Parallel build steps can compete for filesystem cache.
Parallel build steps can amplify process-spawn variance.
M-LSPFIX2 addresses this with warmup and percentile trimming.
It does not make the machine immune to overload.
A parallel full-suite failure should be investigated with the standalone probe.
Run `make lsp-bench` immediately after a failure.
Then run `./zig-out/bin/omlz lsp-bench --warmup 5 --rounds 30 --json`.
If standalone numbers are healthy, the scheduler may be the trigger.
If standalone numbers are unhealthy, LSP or diagnostics likely regressed.
Keep `pgrep -f omlz-lsp` clean after manual tests.
The probe normally shuts every server down.
A surviving server indicates a crash or interrupted run.
Do not kill unrelated user processes by name in shared environments.
Only clean processes this session started, or use mission-provided cleanup commands.

## 14. Operational checklist

Run `zig build` before benchmarking.
Run `make lsp-bench` for the default smoke check.
Run the 30-round script when recording a milestone baseline.
Keep defaults at p50 350 ms and p99 800 ms unless evidence says otherwise.
Prefer increasing warmup or rounds for analysis before changing thresholds.
Use `--json` for automation.
Use CLI `--p50` and `--p99` for explicit reproductions.
Use environment variables for runner-level overrides.
Keep the raw sample list in bug reports.
Include host information when comparing machines.
Confirm no orphan `omlz-lsp` remains after stress testing.
Confirm no `surfpool` process is involved.
Remember that this benchmark targets diagnostics latency only.
Formatting latency has its own checks.
CodeLens latency has its own LSP harness path.

## 15. Cross-references

`tests/lsp/lsp_bench.zig` owns the low-level protocol probe.
`src/omlz/lsp_bench.zig` owns the public wrapper and threshold flag mapping.
`Makefile` owns the `lsp-bench` smoke target.
`scripts/lsp_bench_30_rounds.py` owns baseline JSON capture.
`runtime/lsp/test_harness.py` keeps functional LSP PASS markers.
`docs/lsp.md` documents the LSP server itself.
This document documents latency measurement and operational interpretation.
Keep these responsibilities separate.
Do not duplicate every LSP method here.
Do not move benchmark troubleshooting into the protocol guide unless it affects editor setup.
Update this document when defaults, output fields, or threshold names change.
Update the Chinese mirror in the same change.
Keep heading parity between this file and the Chinese mirror.

## Python harness env thresholds (M-LSPFIX-3)

M-LSPFIX-3 closes the remaining Python-harness latency debt from Phase 17.
The old Python `latency` scenario no longer owns a 200 ms diagnostics budget.
That 200 ms assertion was removed because it duplicated a contract that now has a better owner.
The single source of truth for diagnostics latency is `omlz lsp-bench`.
The Zig probe already performs warmup trimming.
The Zig probe already reports p50 and p99.
The Zig probe already enforces the canonical 350 ms p50 and 800 ms p99 defaults.
Keeping a separate Python median threshold made parallel `zig build test` depend on host load.
It also forced workers into the Phase 17 `-j1` fallback even when the canonical probe was healthy.
The Python `latency` command now acts as a shim rather than a benchmark authority.
It locates the installed low-level binary at `zig-out/bin/lsp-bench`.
If that binary is missing, the harness builds the project first.
It runs the bench from the repository root.
It forwards the bench stdout and stderr so operators still see timings.
It asserts that the completed process returns code zero.
It does not compute its own median.
It does not compare against the old 200 ms number.
A failing `latency` check therefore means the Zig latency contract failed or the probe could not run.
The PASS marker remains in the Python all-checks loop.
This preserves functional harness accounting while moving latency policy to the Zig probe.

Two adjacent Python micro-benchmarks still keep local thresholds.
`LATENCY_CODELENS_THRESHOLD_MS` controls `python3 tests/lsp/run_lsp_check.py codelens_latency`.
Its default is `100`.
`LATENCY_FORMATTING_THRESHOLD_MS` controls `python3 runtime/lsp/test_harness.py formatting_latency`.
Its default is `30`.
These thresholds cover narrow feature-specific paths, not diagnostics latency.
They remain in Python because CodeLens and formatting are measured by the Python harnesses directly.
They are now environment-tunable so loaded hosts can be diagnosed without editing source.
For example:

```sh
LATENCY_CODELENS_THRESHOLD_MS=200 python3 tests/lsp/run_lsp_check.py codelens_latency
LATENCY_FORMATTING_THRESHOLD_MS=60 python3 runtime/lsp/test_harness.py formatting_latency
```

The failure messages cite the configured threshold.
Use lower values when testing the negative path.
Use higher values only as an explicit local comparison on a busy machine.
Do not commit relaxed values into project defaults.
Do not treat these Python variables as replacements for the canonical diagnostics contract.

The M-LSPFIX2 variables have a different scope.
`ZXCAML_LSP_LATENCY_P50_MS` and `ZXCAML_LSP_LATENCY_P99_MS` configure the Zig diagnostics probe.
Those variables define the canonical latency contract used by `omlz lsp-bench`.
They map to the p50 and p99 checks over post-warmup diagnostics samples.
The new `LATENCY_*_THRESHOLD_MS` variables only tune Python micro-benchmarks.
They are single-scenario escape valves for CodeLens and formatting checks.
The Zig variables describe editor diagnostics feedback.
The Python variables describe feature-specific harness budgets.
Keep that boundary clear when debugging failures.

Migration is strict after M-LSPFIX-3.
The Phase 17 `zig build -j1 test` fallback is withdrawn.
Strict parallel `zig build test` is the only no-regress path.
If the old Python `latency` check fails, investigate `omlz lsp-bench`.
If `codelens_latency` or `formatting_latency` fails, inspect the scenario-specific threshold.
Record any override in the command line used for reproduction.
Keep `pgrep -f omlz-lsp` clean after manual stress tests.
Update this section whenever the Python threshold names or defaults change.
Update the Chinese mirror in the same commit.
