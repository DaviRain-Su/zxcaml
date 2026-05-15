let entrypoint _ =
  let a = [| 1; 2; 3 |] in
  let _ = a.(99) <- 0 in
  a.(0)
