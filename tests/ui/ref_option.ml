let entrypoint _ =
  let cur = ref (Some 3) in
  let _ = cur := Some 7 in
  match !cur with Some v -> v | None -> 0
