let entrypoint _ =
  let x = 0 in
  let (a, b) = (if x = 0 then (3, 4) else (1, 2)) in
  a + b
