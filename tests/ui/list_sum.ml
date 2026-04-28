let entrypoint _ =
  let rec sum xs = match xs with [] -> 0 | x :: rest -> x + sum rest in
  sum [1; 2; 3]
