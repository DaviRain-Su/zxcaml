let rec fact_loop n acc =
  if n <= 1 then acc else fact_loop (n - 1) (acc * n)

let entrypoint _ =
  let _ = fact_loop 12000 1 in
  0
