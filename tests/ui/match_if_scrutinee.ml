let entrypoint _ =
  let x = 0 in
  match (if x = 0 then Some 1 else None) with Some v -> v | None -> 0
