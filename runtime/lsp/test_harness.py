#!/usr/bin/env python3
"""Compatibility wrapper for the canonical LSP harness in tests/lsp/.

F-OT3's mission contract names runtime/lsp/test_harness.py, while the existing
M-LSP harness lives at tests/lsp/run_lsp_check.py and is wired into zig build.
Keep this shim tiny so both contract paths exercise the same codelens,
executecommand, and runTest implementation.
"""

import os
import runpy
import sys


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HARNESS = os.path.join(ROOT, "tests", "lsp", "run_lsp_check.py")

if len(sys.argv) == 1:
    sys.argv = [HARNESS, "all"]
else:
    sys.argv[0] = HARNESS

runpy.run_path(HARNESS, run_name="__main__")
