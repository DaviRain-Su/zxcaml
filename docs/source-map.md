# ZxCaml Source Maps

ZxCaml source maps connect Solana BPF instruction offsets back to OCaml source
locations. The design follows the P9 investigation in
`mission-internal/p9-investigation/report.md` Section 4: emit a deterministic
JSON sidecar first, then reuse the same data for a non-allocated ELF section and
for `omlz unmap`.

## Schema

The sidecar file is written next to the compiled BPF artifact as
`out/<name>.map`. It is a stable JSON object with no timestamps, UUIDs, process
IDs, absolute paths, or other build-local fields:

```json
{
  "version": 1,
  "program": "<name>",
  "entries": [
    {
      "pc": 0,
      "ml_file": "examples/hackathon_greet.ml",
      "ml_line": 12,
      "ml_col": 3
    }
  ]
}
```

Top-level fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `version` | `u32` | Schema version. Version `1` is the only accepted value. |
| `program` | string | Program basename, such as `hackathon_greet`. |
| `entries` | array | Source-map entries sorted by `pc` ascending. |

Each entry contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `pc` | `u32` | BPF instruction offset used for reverse lookup. |
| `ml_file` | string | OCaml file path relative to the repository root. |
| `ml_line` | `u32` | One-based OCaml source line. |
| `ml_col` | `u32` | One-based OCaml source column. |

Entries must be sorted by `pc` ascending. The serializer and parser reject
unsorted entries so repeated builds produce deterministic byte-for-byte output.

## ELF Section

Later SRCMAP features embed the same source-map data in the BPF `.so` as a
custom section named `.zxcaml.srcmap`. The P9 investigation's Section 4.2
verified that `llvm-objcopy --add-section` creates a `SHT_PROGBITS` section with
no allocation flag by default, so the Solana loader ignores it while developer
tools can still discover it with `llvm-objdump -h`.

## Section Flags

The embedded section is metadata only:

- Name: `.zxcaml.srcmap`
- Type: `SHT_PROGBITS`
- Flags: no `SHF_ALLOC`, no executable flag, no writable runtime data flag
- Payload: deterministic source-map JSON, minified and gzip-compressed by the
  embedding feature

The sidecar remains the full-fidelity map. The ELF payload may be pruned in
later features to reduce `.so` growth, but it must retain the same schema shape.

## unmap

`omlz unmap` is the CLI reverse lookup tool planned for the SRCMAP milestone:

```sh
omlz unmap --map out/hackathon_greet.map --pc 0x80
omlz unmap --so out/hackathon_greet.so --pc 0x80
```

Exact matches print `ml_file:ml_line:ml_col`. Unknown PCs choose the nearest
preceding entry and mark the result as approximate. If no entry can answer the
query, the command exits non-zero with a clear diagnostic.

## --no-srcmap

By default, future BPF builds write `out/<name>.map` next to the `.so`. The
planned `--no-srcmap` flag suppresses sidecar emission for workflows that need
only the executable artifact. The flag never changes the schema: it only decides
whether the sidecar file is written.
