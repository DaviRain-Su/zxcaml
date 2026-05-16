#!/usr/bin/env python3

from __future__ import annotations

import argparse
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "examples" / "ml-layout-manifest.tsv"
README = ROOT / "examples" / "README.md"
SCOPE_GLOBS = ("examples/**/*.ml", "tests/**/*.ml", "runtime/lsp/**/*.ml")

ALLOWED_CATEGORIES = {
    "user_example",
    "acceptance_fixture",
    "compiler_corpus",
    "solana_harness_source",
    "excluded_historical",
}

BLOCK_MARKERS = {
    "user_examples": ("<!-- user-examples:start -->", "<!-- user-examples:end -->"),
    "acceptance_fixtures": (
        "<!-- acceptance-fixtures:start -->",
        "<!-- acceptance-fixtures:end -->",
    ),
    "validation_summary": (
        "<!-- validation-summary:start -->",
        "<!-- validation-summary:end -->",
    ),
}


@dataclass(frozen=True)
class Entry:
    category: str
    path: str
    surface: str


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"ERROR: {message}")


def load_manifest() -> list[Entry]:
    if not MANIFEST.exists():
        fail(f"manifest not found: {MANIFEST}")

    entries: list[Entry] = []
    seen_paths: set[str] = set()
    for line_number, raw_line in enumerate(MANIFEST.read_text().splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        fields = raw_line.split("\t")
        if len(fields) != 3:
            fail(
                f"{MANIFEST.relative_to(ROOT)}:{line_number} must have exactly 3 tab-separated fields; "
                f"got {len(fields)}"
            )

        category, path, surface = fields
        if category not in ALLOWED_CATEGORIES:
            fail(
                f"{MANIFEST.relative_to(ROOT)}:{line_number} has unknown category {category!r}; "
                f"expected one of {sorted(ALLOWED_CATEGORIES)}"
            )
        if not path.endswith(".ml"):
            fail(f"{MANIFEST.relative_to(ROOT)}:{line_number} path must end in .ml: {path}")
        if path in seen_paths:
            fail(f"{MANIFEST.relative_to(ROOT)}:{line_number} duplicates path {path}")
        seen_paths.add(path)

        full_path = ROOT / path
        if not full_path.exists():
            fail(f"{MANIFEST.relative_to(ROOT)}:{line_number} points to missing file {path}")
        entries.append(Entry(category=category, path=path, surface=surface))

    if not entries:
        fail(f"{MANIFEST.relative_to(ROOT)} is empty")
    return entries


def collect_actual_paths() -> list[str]:
    actual_paths = {
        path.relative_to(ROOT).as_posix()
        for pattern in SCOPE_GLOBS
        for path in ROOT.glob(pattern)
        if path.is_file()
    }
    return sorted(actual_paths)


def validate_entry_shape(entry: Entry) -> None:
    path = Path(entry.path)
    parent = path.parent.as_posix()

    if entry.category == "user_example":
        if parent != "examples":
            fail(f"user_example entries must live directly under examples/: {entry.path}")
        if entry.surface != "user-examples":
            fail(f"user_example surface must be user-examples: {entry.path}")
        return

    if entry.category == "excluded_historical":
        if parent != "examples":
            fail(f"excluded_historical entries must live directly under examples/: {entry.path}")
        if entry.surface != "historical-diagnostic":
            fail(f"excluded_historical surface must be historical-diagnostic: {entry.path}")
        return

    if entry.category == "acceptance_fixture":
        if parent != "examples/tests":
            fail(f"acceptance_fixture entries must live under examples/tests/: {entry.path}")
        if entry.surface != "omlz-test":
            fail(f"acceptance_fixture surface must be omlz-test: {entry.path}")
        return

    if entry.category == "solana_harness_source":
        if not entry.path.startswith("tests/solana/"):
            fail(f"solana_harness_source entries must live under tests/solana/: {entry.path}")
        parts = entry.path.split("/")
        expected_surface = parts[2]
        if entry.surface != expected_surface:
            fail(
                f"solana_harness_source surface must match tests/solana subdirectory "
                f"({expected_surface}) for {entry.path}"
            )
        return

    if entry.category == "compiler_corpus":
        allowed_prefixes = {
            "runtime/lsp/fixtures/": "runtime-lsp-fixture",
            "tests/codegen/": "codegen",
            "tests/golden/": "golden",
            "tests/idl/": "idl",
            "tests/lsp/": "lsp",
            "tests/ui/": "ui",
        }
        if entry.path.startswith("tests/fixtures/"):
            parts = entry.path.split("/")
            expected_surface = f"fixtures-{parts[2]}"
            if entry.surface != expected_surface:
                fail(
                    f"compiler_corpus fixtures surface must be {expected_surface} for {entry.path}, "
                    f"got {entry.surface}"
                )
            return

        for prefix, expected_surface in allowed_prefixes.items():
            if entry.path.startswith(prefix):
                if entry.surface != expected_surface:
                    fail(
                        f"compiler_corpus surface for {entry.path} must be {expected_surface}, "
                        f"got {entry.surface}"
                    )
                return

        fail(f"compiler_corpus entry has unsupported path prefix: {entry.path}")


def validate_manifest(entries: list[Entry]) -> None:
    manifest_paths = sorted(entry.path for entry in entries)
    actual_paths = collect_actual_paths()

    missing = sorted(set(actual_paths) - set(manifest_paths))
    extra = sorted(set(manifest_paths) - set(actual_paths))
    if missing:
        fail("manifest is missing .ml files:\n  - " + "\n  - ".join(missing))
    if extra:
        fail("manifest references paths outside the current recursive .ml surface:\n  - " + "\n  - ".join(extra))

    for entry in entries:
        validate_entry_shape(entry)


def markdown_link(path: str) -> str:
    relative = Path(path).relative_to("examples").as_posix()
    return f"[`{path}`](./{relative})"


def render_bullet_block(paths: list[str], start: str, end: str) -> str:
    lines = [start]
    lines.extend(f"- {markdown_link(path)}" for path in paths)
    lines.append(end)
    return "\n".join(lines)


def render_validation_summary(entries: list[Entry]) -> str:
    counter = Counter(entry.category for entry in entries)
    lines = [
        BLOCK_MARKERS["validation_summary"][0],
        "- `compiler_corpus`: "
        f"{counter['compiler_corpus']} files under `runtime/lsp/fixtures/`, `tests/codegen/`, "
        "`tests/fixtures/`, `tests/golden/`, `tests/idl/`, `tests/lsp/`, and `tests/ui/`.",
        f"- `solana_harness_source`: {counter['solana_harness_source']} files under `tests/solana/`.",
        "- `excluded_historical`: "
        f"{counter['excluded_historical']} file kept out of the default user corpus "
        f"(`examples/m0_unsupported.ml`).",
        BLOCK_MARKERS["validation_summary"][1],
    ]
    return "\n".join(lines)


def replace_block(content: str, block_name: str, replacement: str) -> str:
    start, end = BLOCK_MARKERS[block_name]
    if start not in content or end not in content:
        fail(f"{README.relative_to(ROOT)} is missing managed markers {start} / {end}")

    start_index = content.index(start)
    end_index = content.index(end, start_index) + len(end)
    return content[:start_index] + replacement + content[end_index:]


def render_readme(entries: list[Entry], current_content: str) -> str:
    user_examples = [entry.path for entry in entries if entry.category == "user_example"]
    acceptance_fixtures = [entry.path for entry in entries if entry.category == "acceptance_fixture"]

    rendered = current_content
    rendered = replace_block(
        rendered,
        "user_examples",
        render_bullet_block(
            user_examples,
            BLOCK_MARKERS["user_examples"][0],
            BLOCK_MARKERS["user_examples"][1],
        ),
    )
    rendered = replace_block(
        rendered,
        "acceptance_fixtures",
        render_bullet_block(
            acceptance_fixtures,
            BLOCK_MARKERS["acceptance_fixtures"][0],
            BLOCK_MARKERS["acceptance_fixtures"][1],
        ),
    )
    rendered = replace_block(rendered, "validation_summary", render_validation_summary(entries))
    return rendered


def validate_readme(entries: list[Entry], write: bool) -> None:
    current = README.read_text()
    expected = render_readme(entries, current)

    if write and expected != current:
        README.write_text(expected)
        current = expected

    if expected != current:
        fail(
            f"{README.relative_to(ROOT)} has stale managed sections; "
            "run `python3 scripts/check_examples_layout.py --write`"
        )


def print_category(entries: list[Entry], category: str) -> None:
    if category not in ALLOWED_CATEGORIES:
        fail(f"--print-category must be one of {sorted(ALLOWED_CATEGORIES)}")
    for entry in entries:
        if entry.category == category:
            print(entry.path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the exact recursive .ml layout manifest and managed examples README sections."
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="Regenerate the managed examples/README.md sections from the manifest.",
    )
    parser.add_argument(
        "--print-category",
        metavar="CATEGORY",
        help="Print manifest paths for CATEGORY and exit after manifest validation.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    entries = load_manifest()
    validate_manifest(entries)

    if args.print_category:
        print_category(entries, args.print_category)
        return 0

    validate_readme(entries, write=args.write)

    counter = Counter(entry.category for entry in entries)
    print(
        "Examples layout check passed: "
        f"{len(entries)} files classified "
        f"({counter['user_example']} user examples, "
        f"{counter['acceptance_fixture']} acceptance fixtures, "
        f"{counter['compiler_corpus']} compiler corpus, "
        f"{counter['solana_harness_source']} Solana harness sources, "
        f"{counter['excluded_historical']} excluded historical)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
