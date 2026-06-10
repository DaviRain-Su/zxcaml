#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])

mirrored_pairs = [
    ("README.md", "docs/zh/README.md"),
    ("INSTALLING.md", "docs/zh/INSTALLING.md"),
    ("AGENTS.md", "docs/zh/AGENTS.md"),
    ("docs/01-architecture.md", "docs/zh/01-architecture.md"),
    ("docs/06-bpf-target.md", "docs/zh/06-bpf-target.md"),
    ("docs/07-repo-layout.md", "docs/zh/07-repo-layout.md"),
    ("docs/08-roadmap.md", "docs/zh/08-roadmap.md"),
    ("docs/11-solana-p3.md", "docs/zh/11-solana-p3.md"),
    ("docs/runtime-api.md", "docs/zh/runtime-api.md"),
]

basic_pairs = [
    ("docs/00-overview.md", "docs/zh/00-overview.md"),
    ("docs/02-grammar.md", "docs/zh/02-grammar.md"),
    ("docs/03-core-ir.md", "docs/zh/03-core-ir.md"),
    ("docs/04-memory-model.md", "docs/zh/04-memory-model.md"),
    ("docs/05-backends.md", "docs/zh/05-backends.md"),
    ("docs/09-decisions.md", "docs/zh/09-decisions.md"),
    ("docs/10-frontend-bridge.md", "docs/zh/10-frontend-bridge.md"),
    ("docs/14-hash-syscalls.md", "docs/zh/14-hash-syscalls.md"),
    ("docs/15-sysvars.md", "docs/zh/15-sysvars.md"),
    ("docs/16-omlz-fmt.md", "docs/zh/16-omlz-fmt.md"),
    ("docs/17-lsp-latency.md", "docs/zh/17-lsp-latency.md"),
    ("docs/20-solana-dx-api-polish-plan.md", "docs/zh/20-solana-dx-api-polish-plan.md"),
    ("docs/alternatives-considered.md", "docs/zh/alternatives-considered.md"),
    ("docs/oxcaml-relationship.md", "docs/zh/oxcaml-relationship.md"),
    ("docs/zignocchio-relationship.md", "docs/zh/zignocchio-relationship.md"),
]

routed_pairs = [
    ("docs/12-real-world-examples.md", "docs/zh/12-real-world-examples.md"),
    ("docs/13-omlz-test.md", "docs/zh/13-omlz-test.md"),
    ("docs/18-fixed-point.md", "docs/zh/18-fixed-point.md"),
    ("docs/19-functional-multichain-roadmap.md", "docs/zh/19-functional-multichain-roadmap.md"),
    ("docs/20-functional-multichain-architecture-adr.md", "docs/zh/20-functional-multichain-architecture-adr.md"),
    ("docs/diagnostics.md", "docs/zh/diagnostics.md"),
    ("docs/lsp.md", "docs/zh/lsp.md"),
    ("docs/source-map.md", "docs/zh/source-map.md"),
    ("docs/wire-compat.md", "docs/zh/wire-compat.md"),
]

historical_globs = [
    "docs/preflight-results.md",
    "docs/preflight-results-spike-beta.md",
    "docs/route-b-byte-ops-plan.md",
    "docs/solana-zig-integration-research.md",
    "docs/hackathon/*.md",
]

active_stale_scan = {
    "README.md",
    "INSTALLING.md",
    "AGENTS.md",
    "demo.sh",
    "docs/01-architecture.md",
    "docs/06-bpf-target.md",
    "docs/07-repo-layout.md",
    "docs/08-roadmap.md",
    "docs/11-solana-p3.md",
    "docs/20-solana-dx-api-polish-plan.md",
    "docs/runtime-api.md",
    "docs/zh/README.md",
    "docs/zh/INSTALLING.md",
    "docs/zh/AGENTS.md",
    "docs/zh/01-architecture.md",
    "docs/zh/06-bpf-target.md",
    "docs/zh/07-repo-layout.md",
    "docs/zh/08-roadmap.md",
    "docs/zh/11-solana-p3.md",
    "docs/zh/20-solana-dx-api-polish-plan.md",
    "docs/zh/runtime-api.md",
}

failures: list[str] = []
checked: list[str] = []

forbidden_terms = {
    "solana-test-validator": "Current guidance must use Surfpool, not solana-test-validator.",
    "sbpf-linker": "Current guidance must describe the direct solana-zig path; sbpf-linker is historical only.",
    "bpfel-freestanding": "Current guidance must describe the direct solana-zig path; bpfel-freestanding is historical only.",
    "ELF post-pass": "Current guidance must describe the post-pass as removed/historical only.",
}
historical_markers = (
    "historical",
    "history",
    "legacy",
    "older",
    "removed",
    "superseded",
    "compatibility",
    "no longer",
    "not required",
    "does not invoke",
    "old",
    "历史",
    "旧",
    "已移除",
    "兼容",
    "保留",
)


def read(rel: str) -> str:
    path = root / rel
    if not path.exists():
        failures.append(f"Missing required file: {rel}")
        return ""
    checked.append(rel)
    return path.read_text()


def rel_link(src: str, dest: str) -> str:
    src_parent = (root / src).parent
    value = os.path.relpath(root / dest, src_parent).replace(os.sep, "/")
    if not value.startswith("."):
        value = "./" + value
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def top_banner(text: str) -> str:
    return "\n".join(text.splitlines()[:6])


def check_language_switcher(src: str, dest: str) -> None:
    src_text = read(src)
    dest_text = read(dest)
    src_banner = top_banner(src_text)
    dest_banner = top_banner(dest_text)
    require("Languages / 语言" in src_banner, f"{src} is missing the language switcher near the top.")
    require("Languages / 语言" in dest_banner, f"{dest} is missing the language switcher near the top.")
    require(rel_link(src, dest) in src_banner, f"{src} does not link to {dest} in its language switcher.")
    require(rel_link(dest, src) in dest_banner, f"{dest} does not link back to {src} in its language switcher.")


def extract_local_links(rel: str, text: str) -> list[str]:
    links = []
    for match in re.finditer(r"\[[^\]]+\]\(([^)]+)\)", text):
        target = match.group(1).strip()
        if not target or target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        target = target.split("#", 1)[0]
        target = target.split("?", 1)[0]
        if not target:
            continue
        links.append(target)
    return links


def check_links(rel: str) -> None:
    text = read(rel)
    for target in extract_local_links(rel, text):
        resolved = ((root / rel).parent / target).resolve()
        require(resolved.exists(), f"{rel} contains a broken local link: {target}")


def extract_shell_commands(text: str) -> list[str]:
    commands: list[str] = []
    in_sh = False
    for line in text.splitlines():
        if line.startswith("```"):
            fence = line.strip().strip("`").strip()
            if in_sh:
                in_sh = False
            else:
                in_sh = fence in {"sh", "bash", "shell"}
            continue
        if not in_sh:
            continue
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            commands.append(stripped)
    return commands


def check_command_parity(src: str, dest: str) -> None:
    src_text = read(src)
    dest_text = read(dest)
    for command in extract_shell_commands(src_text):
        require(command in dest_text, f"{dest} is missing a shell command mirrored from {src}: {command}")


def classify_top_level_docs() -> set[str]:
    classified = {src for src, _ in mirrored_pairs + basic_pairs + routed_pairs}
    classified.update({dest for _, dest in mirrored_pairs + basic_pairs + routed_pairs})
    for pattern in historical_globs:
        classified.update(
            str(path.relative_to(root)).replace(os.sep, "/")
            for path in root.glob(pattern)
        )
    return classified


for src, dest in mirrored_pairs + basic_pairs + routed_pairs:
    require((root / src).exists(), f"Missing expected English doc: {src}")
    require((root / dest).exists(), f"Missing expected Chinese doc: {dest}")
    check_language_switcher(src, dest)

for src, dest in routed_pairs:
    route_text = read(dest)
    require("Route note" in route_text, f"{dest} should explicitly state that it is a routed Chinese counterpart.")

for src, dest in mirrored_pairs:
    check_command_parity(src, dest)

for rel in sorted(classify_top_level_docs()):
    if rel.endswith(".md") or rel in {"README.md", "INSTALLING.md"}:
        if (root / rel).exists():
            check_links(rel)

top_level_docs = {
    str(path.relative_to(root)).replace(os.sep, "/")
    for path in (root / "docs").glob("*.md")
}
classified_top_level = {
    src for src, _ in mirrored_pairs + basic_pairs + routed_pairs
}.union({
    rel for rel in classify_top_level_docs() if rel.startswith("docs/") and rel.count("/") == 1
})
missing_classifications = sorted(top_level_docs - classified_top_level)
require(not missing_classifications, f"Unclassified top-level docs surfaces: {', '.join(missing_classifications)}")

# Canonical facts and counts
examples_count = len(list((root / "examples").glob("*.ml")))
rust_test_files = len(list((root / "tests").glob("*_test.rs")))
rust_test_cases = sum(path.read_text().count("#[test]") for path in (root / "tests").glob("*_test.rs"))

readme_en = read("README.md")
readme_zh = read("docs/zh/README.md")
roadmap_en = read("docs/08-roadmap.md")
roadmap_zh = read("docs/zh/08-roadmap.md")

for fact in [
    "compiler-libs",
    "Zig 0.16",
    ".ml",
    "`omlz`",
    "1.6",
    "solana-zig build-lib",
    "32 KiB",
    "3 KiB",
    "solana-program-sdk-zig",
    "Surfpool",
    "127.0.0.1:8899",
    "./scripts/check_docs_sync.sh",
]:
    require(fact in readme_en, f"README.md is missing canonical fact: {fact}")

for fact in [
    "compiler-libs",
    "Zig 0.16",
    ".ml",
    "`omlz`",
    "1.6",
    "solana-zig build-lib",
    "32 KiB",
    "3 KiB",
    "solana-program-sdk-zig",
    "Surfpool",
    "127.0.0.1:8899",
    "./scripts/check_docs_sync.sh",
]:
    require(fact in readme_zh, f"docs/zh/README.md is missing canonical fact: {fact}")

require(f"{examples_count} programs" in readme_en, "README.md examples count is stale.")
require(f"{rust_test_files} Rust integration-test files ({rust_test_cases} Rust test cases)" in readme_en, "README.md Rust test inventory is stale.")
require(f"{examples_count} 个 `.ml` 程序" in roadmap_zh, "docs/zh/08-roadmap.md examples count is stale.")
require(
    f"{examples_count} `.ml` programs" in roadmap_en
    or f"{examples_count}\n`.ml` programs" in roadmap_en,
    "docs/08-roadmap.md examples count is stale.",
)
require(f"{rust_test_files} Rust integration-test files\n({rust_test_cases} Rust test cases)" in roadmap_en or f"{rust_test_files} Rust integration-test files ({rust_test_cases} Rust test cases)" in roadmap_en, "docs/08-roadmap.md Rust test inventory is stale.")
require(f"{rust_test_files} 个 Rust 集成测试文件（{rust_test_cases} 个 Rust test case）" in roadmap_zh, "docs/zh/08-roadmap.md Rust test inventory is stale.")

# Repo-layout facts
for rel in ("docs/07-repo-layout.md", "docs/zh/07-repo-layout.md"):
    text = read(rel)
    for required_path in ("src/omlz/", "src/lsp/", "runtime/zig/programs/", "runtime/zig/sdk/"):
        require(required_path in text, f"{rel} is missing current repo-layout path: {required_path}")
    require("src/root.zig" not in text, f"{rel} still references removed path src/root.zig.")

# Solana-guide/runtime facts
for rel in ("docs/11-solana-p3.md", "docs/zh/11-solana-p3.md"):
    text = read(rel)
    require("solana-program-sdk-zig" in text, f"{rel} should mention the SDK-backed runtime.")
    require("127.0.0.1:8899" in text, f"{rel} should mention Surfpool RPC port 8899.")

demo_text = read("demo.sh")
require("Surfpool" in demo_text, "demo.sh should describe the Surfpool localnet flow.")
require("solana test-validator" not in demo_text, "demo.sh still mentions the old test-validator flow.")

# Stale terminology scan
for rel in sorted(active_stale_scan):
    text = read(rel)
    for idx, line in enumerate(text.splitlines(), start=1):
        lowered = line.lower()
        for term, message in forbidden_terms.items():
            if term.lower() not in lowered:
                continue
            if any(marker in lowered for marker in historical_markers):
                continue
            failures.append(f"{rel}:{idx}: {message} Found `{term}` in active guidance.")

if failures:
    print("docs sync check: FAIL", file=sys.stderr)
    for item in failures:
        print(f" - {item}", file=sys.stderr)
    sys.exit(1)

print("docs sync check: PASS")
print(f"  mirrored pairs: {len(mirrored_pairs)}")
print(f"  basic pairs:    {len(basic_pairs)}")
print(f"  routed pairs:   {len(routed_pairs)}")
print(f"  examples:       {examples_count}")
print(f"  Rust tests:     {rust_test_files} files / {rust_test_cases} cases")
PY
