let entrypoint _ =
  let f = let rec g x = if x <= 0 then 0 else g (x - 1) in g in
  f 3
