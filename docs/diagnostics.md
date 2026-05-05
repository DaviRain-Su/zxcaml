# Diagnostics

## Schema

`omlz --error-format=json` writes newline-delimited JSON diagnostics to
stderr. Each line is one diagnostic object with required keys `file`, `line`,
`col`, `severity`, and `message`; optional keys are `end_line`, `end_col`,
`code`, and `snippet`. The `snippet` value is the raw source line text with no
ANSI escape sequences.
