let entrypoint _ =
  let base = 2 in
  let rec loop n = if n <= 0 then base else loop (n - 1) in
  loop 3
