let entrypoint _ =
  let kept = if 7 > 0 then Some 7 else None in
  match kept with
  | Some value -> value
  | None -> 0
