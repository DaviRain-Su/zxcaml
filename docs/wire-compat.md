# Wire Compatibility

DX2 bumps the frontend bridge wire from `1.1` to `1.2` so location-aware
S-expressions can carry `(loc <file> <line> <col> <end_line> <end_col>)`
annotations into the Zig bridge. See `docs/diagnostics.md` for the full
diagnostics-facing schema and `mission-internal/p9-investigation/report.md` §2
for the implementation rationale.

`omlz check --wire=1.1 ...` is a deprecated one-mission compatibility window
that forwards `--wire=1.1` to `zxc-frontend` and emits the old location-free
shape. The `1.2` reader still accepts `1.1` sexps and treats missing locations
as `Loc.unknown`.
