let pick x = if x = 0 then Some 42 else None
let entrypoint _ = match pick 0 with Some v -> v | None -> 0
