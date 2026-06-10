# Diagnostics

> **Languages / 语言**: **English** · [简体中文](./zh/diagnostics.md)

## Overview

P9 replaces the pre-P9 one-line diagnostic surface with a rustc-style block by
default. Before P9, frontend errors looked like:

```text
/tmp/p9_dx_probes/dx1_parse.ml:2:2: error: Unbound value "x"
```

The default human renderer now shows the severity, optional diagnostic code,
source location, source line, and caret span:

```text
error[OCAML-FRONTEND]: This expression has type "string" but an expression was expected of type "int"
 --> tests/golden/dx1_json_format.ml:1:13
  |
1 | let _: int = "json"
  |             ^^^^^^
```

This is a renderer-side developer-experience change. It does not change the
accepted OCaml subset, type checking, lowering, or exit-code behavior.

## --error-format

`omlz check`, `omlz build`, `omlz idl`, and `omlz run` accept:

| Value | Meaning | Intended use |
| --- | --- | --- |
| `human` | The default rustc-style multi-line block with a source snippet and caret. | Local terminal use and editor-integrated command output. |
| `json` | Newline-delimited JSON objects written to stderr, one diagnostic per line. | Tools, LSP plumbing, and structured CI ingestion. |
| `oneline` | The legacy `path:line:col: severity: message` shape. | Grep-oriented CI logs, shell scripts, and compatibility with pre-P9 fixtures. |

If the flag is omitted, `human` is used. Use `oneline` when a pipeline needs a
stable single-line record that can be matched with expressions such as
`^[^:]+:[0-9]+:[0-9]+: (error|warning):`.

Examples:

```sh
omlz check tests/golden/dx1_json_format.ml
omlz check --error-format=oneline tests/golden/dx1_json_format.ml
omlz check --error-format=json tests/golden/dx1_json_format.ml
```

## --color

`--color` controls ANSI escape sequences in the human renderer:

| Value | Meaning |
| --- | --- |
| `auto` | Default. Emit color only when stderr is a TTY and `NO_COLOR` is not present. |
| `always` | Emit color even when stderr is redirected, unless `NO_COLOR` is present. |
| `never` | Never emit color. |

The `json` and `oneline` formats are plain text formats and do not include ANSI
color escapes.

## NO_COLOR

If the `NO_COLOR` environment variable is present, `omlz` suppresses ANSI color
in human diagnostics. `NO_COLOR` takes precedence over both `--color=auto` and
`--color=always`; this keeps logs deterministic in environments that globally
opt out of colorized output.

For deterministic test fixtures and copy-pasteable bug reports, prefer:

```sh
NO_COLOR=1 omlz check --color=never path/to/file.ml
```

## JSON Schema

`--error-format=json` writes JSON Lines to stderr. Each non-empty line is one
diagnostic object; consumers should parse lines independently rather than
expecting a JSON array.

### Schema object

```json
{
  "type": "object",
  "required": ["file", "line", "col", "severity", "message"],
  "properties": {
    "file": {
      "type": "string",
      "description": "Path reported by the frontend for the diagnostic source."
    },
    "line": {
      "type": "integer",
      "minimum": 1,
      "description": "One-based start line."
    },
    "col": {
      "type": "integer",
      "minimum": 0,
      "description": "Zero-based start column, matching OCaml location columns."
    },
    "end_line": {
      "type": "integer",
      "minimum": 1,
      "description": "Optional one-based end line. If absent, use line."
    },
    "end_col": {
      "type": "integer",
      "minimum": 0,
      "description": "Optional zero-based exclusive end column. If absent, use col + 1 for a one-column caret."
    },
    "severity": {
      "type": "string",
      "enum": ["error", "warning"],
      "description": "Diagnostic severity."
    },
    "code": {
      "type": "string",
      "description": "Optional stable diagnostic code or current compatibility alias."
    },
    "message": {
      "type": "string",
      "description": "Human-readable diagnostic message with no ANSI escapes."
    },
    "snippet": {
      "type": "string",
      "description": "Optional raw source line text, included when the source file can be read."
    }
  },
  "additionalProperties": true
}
```

### Required keys

| Key | Type | Notes |
| --- | --- | --- |
| `file` | string | Source path for the diagnostic. |
| `line` | integer | One-based start line. |
| `col` | integer | Zero-based start column. |
| `severity` | string | Currently `error` or `warning`. |
| `message` | string | Plain diagnostic message. |

### Optional keys

| Key | Type | Notes |
| --- | --- | --- |
| `end_line` | integer | One-based end line for the highlighted span. |
| `end_col` | integer | Zero-based exclusive end column for the highlighted span. |
| `code` | string | Stable code or compatibility alias for the diagnostic family. |
| `snippet` | string | Raw source line text; omitted if the file cannot be read. |

## Error code catalog

DX1 preserved current compatibility aliases while reserving stable numeric codes
for the diagnostic families already emitted by the compiler. DX2 starts emitting
stable `E0010+` codes for tailored subset-violation diagnostics so downstream
tools can key on codes instead of matching message text.

| Stable code | Current alias | Diagnostic family | Status |
| --- | --- | --- | --- |
| E0001 | `OCAML-FRONTEND` | OCaml parser/type-checker errors surfaced by `zxc-frontend`. | Reserved by DX1; currently emitted with the alias in JSON and human output. |
| E0002 | `P1-UNSUPPORTED` | Generic ZxCaml subset rejection from the typedtree subset checker. | Reserved by DX1; M-DX2 will split this into narrower codes. |
| E0003 | `M0-INTERNAL` | Internal frontend bridge error fallback. | Reserved for unexpected internal frontend failures. |
| E0010 | _n/a_ | Polymorphic variants. | Emitted for `Texp_variant`; polymorphic variants are outside the ZxCaml subset. |
| E0011 | _n/a_ | Float constants. | Emitted for `Const_float`; floats cannot be lowered to BPF. |
| E0012 | _n/a_ | Other unsupported constants. | Emitted for integer-width literals not represented in the current subset. |
| E0013 | _n/a_ | Unsupported mutable references / mutable updates. | Emitted for ref element types outside the R10 whitelist and for mutable field/instance writes outside the supported array/ref/account paths. |
| E0014 | _n/a_ | First-class modules. | Emitted for `Texp_pack` and local module expressions. |
| E0015 | _n/a_ | Recursive modules. | Emitted for `Tstr_recmodule`; recursive modules are not yet supported. |
| E0016 | _n/a_ | Exceptions. | Emitted for `try` / exception declarations. |
| E0017 | _n/a_ | Unsupported loop fallback. | Reserved for `for` / `while` only if native ADR-015 loop desugaring is bypassed or the loop shape is outside the supported subset. |
| E0018 | _n/a_ | Objects and method calls. | Emitted for OCaml object-oriented expression nodes. |
| E0019 | _n/a_ | Unsupported array forms. | Emitted for array forms outside the R9 `int`-array subset (for example non-literal `Array.make` sizes or unsupported array helpers). |
| E0020 | _n/a_ | Lazy expressions. | Emitted for `Texp_lazy`. |
| E0021 | _n/a_ | Binding operators. | Emitted for `Texp_letop`. |
| E0022 | _n/a_ | Unreachable expressions. | Emitted for `Texp_unreachable`. |
| E0023 | _n/a_ | Extension constructors. | Emitted for extension-constructor nodes. |
| E0024 | _n/a_ | Unknown constructors. | Emitted when a constructor is not present in the subset type environment. |
| E0030 | _n/a_ | Missing required label. | Emitted when a call to a whitelisted labelled stdlib function omits a required `~label:` argument. |
| E0031 | _n/a_ | Unknown or duplicate label. | Emitted when a call to a whitelisted labelled stdlib function uses an unknown label or supplies the same label more than once. |
| E0090–E0099 | _n/a_ | Generic subset fallback buckets. | Used only when a more specific tailored subset code does not apply. |
| E0100 | _n/a_ | Cannot resolve `open` to a file. | Emitted before `ocamlc` when a top-level `open Foo` does not resolve to `foo.ml` in the entry file's directory (ADR-016). |
| E0101 | _n/a_ | `open` dependency cycle. | Emitted when the ADR-016 multi-file closure contains a cycle; the message lists the cycle path. |
| E0102 | _n/a_ | Duplicate top-level name across files. | Emitted when two files in the joined closure declare the same top-level value, type, or constructor name. |
| E0103 | _n/a_ | `open` of a bundled stdlib module. | Emitted when `open` names a bundled stdlib module (or a user file shadows one); the stdlib is auto-opened and matched by qualified name. |
| E0200 | _n/a_ | Unknown `--report` kind. | Emitted by `omlz check --report=<kind>` when `<kind>` is not one of `cu`, `stack`, or `all`. |
| DX2-NOALLOC | _n/a_ | Arena allocation rejected under `--no-alloc`. | Emitted by `omlz check --no-alloc` at the allocating expression (payload constructors, closures, string concat, arrays, refs). Wire 1.6 makes the caret expression-precise. |
| DX2-REGION | _n/a_ | Checked region inference failure. | Emitted when escape analysis cannot assign a consistent static/stack/arena region; also runs inside `omlz build` before codegen. |

Consumers should treat `code` as optional. When present, prefer exact matching
over parsing message text.

## Wire format history (current default 1.7)

DX2 bumps the frontend bridge wire from `1.1` to `1.2` so frontend-emitted
S-expressions can carry source locations into the Zig bridge, following the
minimum-invasive plan in `mission-internal/p9-investigation/report.md` §2. The
mission-local canonical facts snapshot,
`mission-internal/canonical-facts.md`, is the historical citation for the
pre-DX2 canonical wire value (`1.1`); the post-bump implementation source of
truth is now `src/frontend_bridge/sexp_parser.zig`
(`expected_wire_version = "1.7"`; the reader still accepts compatible `1.2+` shapes).

### Optional `(loc ...)` schema

Wire `1.2` adds optional `(loc ...)` metadata and may annotate an expression
with:

```text
(located (loc <file> <line> <col> <end_line> <end_col>) <expr>)
```

The `(loc ...)` tuple is optional. When present, its fields are:

| Field | Type | Meaning |
| --- | --- | --- |
| `<file>` | string atom | Source file path reported by OCaml. |
| `<line>` | integer | One-based start line. |
| `<col>` | integer | Zero-based start column. |
| `<end_line>` | integer | One-based end line. |
| `<end_col>` | integer | Zero-based exclusive end column. |

The bridge also accepts a trailing `(loc ...)` field on expression nodes for
tests and future printers. When a wire `1.1` expression or compatibility blob
omits the tuple, the bridge uses `Loc.unknown`.

Older compatibility emitters remain available only as migration windows. The
current `1.5` reader continues to accept prior additive shapes; missing
locations are treated as `Loc.unknown`, missing typed-param payloads as untyped
(`null`), and pre-ref wires simply omit the `ref-*` nodes.

### Wire `1.3` — typed lambda parameters

R8 bumps the wire to `1.3` so each lambda or `let rec` parameter carries an
inferred OCaml type. Parameters are emitted as `(name (ty <type-expr>))`
where `<type-expr>` follows the existing Core IR type-expression grammar; the
new `(any)` sentinel marks unresolved/polymorphic params and the bridge maps
it to `null`. The Core IR lowerer prefers explicit wire types when its
existing structural heuristics do not already pick a more specific shape; if
the wire type is `null`, the lowerer falls back to the legacy heuristic chain
(`Ty.Int` default). See `docs/wire-compat.md` for the cross-version reader
behavior.

Wire `1.4` / `1.5` add the ADR-015 mutable surface: `1.4` covers the narrow
array/loop-era additive shapes, and `1.5` adds `ref-make`, `ref-get`, and
`ref-set` for arena-backed `int` / `bool` ref cells. Diagnostics continue to
report locations through the same optional `(loc ...)` schema.

## Examples

The same type error is shown below in all three formats.

| `human` (default, `--color=never` shown) | `oneline` | `json` |
| --- | --- | --- |
| <pre>error[OCAML-FRONTEND]: This expression has type "string" but an expression was expected of type "int"<br> --> tests/golden/dx1_json_format.ml:1:13<br>  &#124;<br>1 &#124; let _: int = "json"<br>  &#124;             ^^^^^^</pre> | <pre>tests/golden/dx1_json_format.ml:1:13: error: This expression has type "string" but an expression was expected of type "int"</pre> | <pre>{"file":"tests/golden/dx1_json_format.ml","line":1,"col":13,"end_line":1,"end_col":19,"severity":"error","code":"OCAML-FRONTEND","message":"This expression has type \"string\" but an expression was expected of type \"int\"","snippet":"let _: int = \"json\""}</pre> |

### Pre-P9 probe baselines

Appendix A of `mission-internal/p9-investigation/report.md` recorded the
post-Phase-6, pre-P9 probe output. These baselines preserve the legacy one-line
shape while abbreviating the old subset whitelist dump, so readers can compare
the prior surface with the P9 renderers:

```text
=== DX1 parse error ===
/tmp/p9_dx_probes/dx1_parse.ml:2:2: error: Unbound value "x"
exit=2

=== DX2 type error ===
/tmp/p9_dx_probes/dx2_type.ml:2:19: error: This expression has type "int" but an expression was expected of type "string"
exit=2

=== DX3 default check (should succeed) ===
exit=0

=== DX3b --no-alloc ===
no_alloc: FAIL function entrypoint: allocation site Core.Constr(payload) ::
exit=1

=== DX4 polyvariant ===
/tmp/p9_dx_probes/dx4_unsupp.ml:2:10: error: Texp_variant is not supported in the current ZxCaml subset; [legacy whitelist dump omitted]
exit=1

=== DX4 float ===
/tmp/p9_dx_probes/dx4_float.ml:2:10: error: Texp_constant is not supported in the current ZxCaml subset; [legacy whitelist dump omitted]
exit=1

=== DX5 idl broken ===
/tmp/p9_dx_probes/dx5_idl.ml:1:18: error: Unbound type constructor "context"
exit=2
```
