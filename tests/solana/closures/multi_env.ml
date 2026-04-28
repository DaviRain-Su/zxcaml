let make_op a b = fun x -> (x + a) * b

let entrypoint _ =
  let op = make_op 4 3 in
  if op 5 = 27 then 0 else 1
