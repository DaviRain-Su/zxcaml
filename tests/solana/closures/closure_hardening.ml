let entrypoint _ =
  let opt = Some 6 in
  let f = fun y -> match opt with Some v -> y + v | None -> y in
  if f 6 = 12 then 0 else 1
