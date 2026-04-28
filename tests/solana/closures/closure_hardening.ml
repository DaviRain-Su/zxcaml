let entrypoint _ =
  let opt = Some 6 in
  let f = match opt with Some v -> fun y -> y + v | None -> fun y -> y in
  if f 6 = 12 then 0 else 1
