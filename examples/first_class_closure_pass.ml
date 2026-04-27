let apply h = h 3

let entrypoint _ =
  let rec g x = if x <= 0 then 0 else g (x - 1) in
  apply g
