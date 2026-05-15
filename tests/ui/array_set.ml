let entrypoint _ =
  let a = [| 1; 2; 3 |] in
  let _ = a.(1) <- 99 in
  a.(0) + a.(1) + a.(2)
